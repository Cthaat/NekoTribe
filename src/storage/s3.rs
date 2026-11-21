use axum::{
    body::Body,
    http::{header, HeaderMap, HeaderValue, Response, StatusCode},
};
use hmac::{Hmac, Mac};
use reqwest::{Client, Method, Url};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fmt, io,
    sync::{LazyLock, OnceLock},
    time::Duration,
};
use tokio::io::{AsyncReadExt, AsyncSeekExt};

use crate::media::private_read::PrivateKey;

use super::{
    local_http::{error, mime, missing},
    local_policy::{is_private_storage_key, normalize_local_key},
};

#[derive(Clone, PartialEq, Eq)]
pub struct S3Storage {
    endpoint: Url,
    bucket: String,
    region: String,
    access: String,
    secret: String,
    token: Option<String>,
}

impl fmt::Debug for S3Storage {
    fn fmt(&self, output: &mut fmt::Formatter<'_>) -> fmt::Result {
        output.write_str("S3Storage { configured }")
    }
}

static BUCKET: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(r"^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$").unwrap());
static REGION: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(r"^[a-z0-9-]{1,63}$").unwrap());
static ACCESS: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(r"^[A-Za-z0-9_+=.@-]{1,128}$").unwrap());
static RANGE: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(r"(?i)^bytes=([0-9]{0,16})-([0-9]{0,16})$").unwrap());
static PARTIAL: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(r"^bytes [0-9]+-[0-9]+/[0-9]+$").unwrap());
static UNSATISFIED: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(r"^bytes \*/[0-9]+$").unwrap());

fn unavailable() -> io::Error {
    io::Error::other("media storage unavailable")
}

fn client() -> io::Result<&'static Client> {
    static CLIENT: OnceLock<Option<Client>> = OnceLock::new();
    CLIENT
        .get_or_init(|| {
            Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .connect_timeout(Duration::from_secs(30))
                .timeout(Duration::from_secs(300))
                .build()
                .ok()
        })
        .as_ref()
        .ok_or_else(unavailable)
}

fn printable(value: &str, limit: usize) -> bool {
    !value.is_empty() && value.len() <= limit && value.bytes().all(|b| (b'!'..=b'~').contains(&b))
}

pub(super) fn managed(raw: &str) -> Option<String> {
    let key = normalize_local_key(raw).ok()?;
    (key.starts_with("posts/") || key.starts_with("avatars/")).then_some(key)
}

fn uri_path(path: &str) -> String {
    use fmt::Write;
    let mut out = String::new();
    for byte in path.bytes() {
        if byte.is_ascii_alphanumeric() || b"-._~/".contains(&byte) {
            out.push(char::from(byte));
        } else {
            write!(out, "%{byte:02X}").expect("writing to String");
        }
    }
    out
}

fn mac(key: &[u8], text: &str) -> Vec<u8> {
    let mut value = Hmac::<Sha256>::new_from_slice(key).expect("HMAC accepts any key size");
    value.update(text.as_bytes());
    value.finalize().into_bytes().to_vec()
}

struct Upload<'a> {
    mime: &'a str,
    size: u64,
    digest: String,
    body: reqwest::Body,
}

impl S3Storage {
    pub(super) fn from_lookup(value: impl Fn(&str) -> Option<String>) -> Option<Self> {
        let raw = value("STORAGE_S3_ENDPOINT")?;
        let endpoint = Url::parse(&raw).ok()?;
        let bucket = value("STORAGE_S3_BUCKET")?;
        let region = value("STORAGE_S3_REGION")?;
        let access = value("STORAGE_S3_ACCESS_KEY")?;
        let secret = value("STORAGE_S3_SECRET_KEY")?;
        let token = value("STORAGE_S3_SESSION_TOKEN");
        if !matches!(endpoint.scheme(), "http" | "https")
            || endpoint.host().is_none()
            || endpoint.path() != "/"
            || !endpoint.username().is_empty()
            || endpoint.password().is_some()
            || endpoint.query().is_some()
            || endpoint.fragment().is_some()
            || !BUCKET.is_match(&bucket)
            || !REGION.is_match(&region)
            || !ACCESS.is_match(&access)
            || !printable(&secret, 512)
            || token.as_ref().is_some_and(|v| !printable(v, 8192))
        {
            return None;
        }
        Some(Self {
            endpoint,
            bucket,
            region,
            access,
            secret,
            token,
        })
    }

    async fn request(
        &self,
        method: Method,
        raw: &str,
        range: Option<&str>,
        upload: Option<Upload<'_>>,
        private_read: bool,
    ) -> io::Result<reqwest::Response> {
        let key = normalize_local_key(raw).map_err(|_| unavailable())?;
        let private = is_private_storage_key(&key);
        let private_allowed = private
            && (matches!(method, Method::PUT | Method::DELETE)
                || (private_read && matches!(method, Method::GET | Method::HEAD)));
        if managed(&key).is_none() && !private_allowed {
            return Err(unavailable());
        }
        let path = uri_path(&format!("/{}/{key}", self.bucket));
        let url = format!("{}{path}", self.endpoint.as_str().trim_end_matches('/'));
        let hostname = self.endpoint.host_str().ok_or_else(unavailable)?;
        let host = self
            .endpoint
            .port()
            .map_or_else(|| hostname.to_owned(), |port| format!("{hostname}:{port}"));
        let date = chrono::Utc::now().format("%Y%m%dT%H%M%SZ").to_string();
        let digest = upload.as_ref().map_or_else(
            || hex::encode(Sha256::digest([])),
            |value| value.digest.clone(),
        );
        let mut headers = BTreeMap::from([
            ("host", host),
            ("x-amz-content-sha256", digest.clone()),
            ("x-amz-date", date.clone()),
        ]);
        if let Some(ref token) = self.token {
            headers.insert("x-amz-security-token", token.clone());
        }
        if let Some(ref upload) = upload {
            headers.insert("content-length", upload.size.to_string());
            headers.insert("content-type", upload.mime.to_owned());
            headers.insert("if-none-match", "*".into());
            if private {
                headers.insert("cache-control", "private, no-store".into());
            }
        }
        if let Some(range) = range {
            headers.insert("range", range.to_owned());
        }
        let signed = headers.keys().copied().collect::<Vec<_>>().join(";");
        let canonical: String = headers
            .iter()
            .map(|(key, value)| {
                format!(
                    "{key}:{}\n",
                    value.split_ascii_whitespace().collect::<Vec<_>>().join(" ")
                )
            })
            .collect();
        let canonical_hash = hex::encode(Sha256::digest(format!(
            "{method}\n{path}\n\n{canonical}\n{signed}\n{digest}"
        )));
        let day = &date[..8];
        let scope = format!("{day}/{}/s3/aws4_request", self.region);
        let key = mac(
            &mac(
                &mac(
                    &mac(format!("AWS4{}", self.secret).as_bytes(), day),
                    &self.region,
                ),
                "s3",
            ),
            "aws4_request",
        );
        let signature = hex::encode(mac(
            &key,
            &format!("AWS4-HMAC-SHA256\n{date}\n{scope}\n{canonical_hash}"),
        ));
        let auth = format!(
            "AWS4-HMAC-SHA256 Credential={}/{scope},SignedHeaders={signed},Signature={signature}",
            self.access
        );
        let mut request = client()?
            .request(method, url)
            .header(header::AUTHORIZATION, auth)
            .header(header::ACCEPT_ENCODING, "identity");
        for (name, value) in headers {
            request = request.header(name, value);
        }
        if let Some(upload) = upload {
            request = request.body(upload.body);
        }
        request.send().await.map_err(|_| unavailable())
    }

    pub(crate) async fn put(
        &self,
        mut file: tokio::fs::File,
        size: u64,
        key: &str,
        mime: &str,
    ) -> io::Result<()> {
        let info = file.metadata().await?;
        if size == 0 || !info.is_file() || info.len() != size {
            return Err(unavailable());
        }
        file.seek(io::SeekFrom::Start(0)).await?;
        let mut hasher = Sha256::new();
        let mut buffer = vec![0; 65536];
        let mut remaining = size;
        while remaining > 0 {
            let count = remaining.min(buffer.len() as u64) as usize;
            file.read_exact(&mut buffer[..count]).await?;
            hasher.update(&buffer[..count]);
            remaining -= count as u64;
        }
        file.seek(io::SeekFrom::Start(0)).await?;
        let stream =
            futures_util::stream::try_unfold((file, size), |(mut file, remaining)| async move {
                if remaining == 0 {
                    return Ok::<_, io::Error>(None);
                }
                let mut bytes = vec![0; remaining.min(65536) as usize];
                file.read_exact(&mut bytes).await?;
                let left = remaining - bytes.len() as u64;
                Ok(Some((bytes, (file, left))))
            });
        let upload = Upload {
            mime,
            size,
            digest: hex::encode(hasher.finalize()),
            body: reqwest::Body::wrap_stream(stream),
        };
        if self
            .request(Method::PUT, key, None, Some(upload), false)
            .await?
            .status()
            == StatusCode::OK
        {
            Ok(())
        } else {
            Err(unavailable())
        }
    }

    pub(crate) async fn delete(&self, key: &str) -> io::Result<()> {
        match self
            .request(Method::DELETE, key, None, None, false)
            .await?
            .status()
        {
            StatusCode::NO_CONTENT | StatusCode::NOT_FOUND => Ok(()),
            _ => Err(unavailable()),
        }
    }

    pub(super) async fn read(&self, key: &str, incoming: &HeaderMap, head_only: bool) -> Response<Body> {
        if managed(key).is_none() {
            return missing(key);
        }
        self.read_object(key, incoming, head_only, false).await
    }

    pub(super) async fn read_private(
        &self,
        key: &PrivateKey,
        incoming: &HeaderMap,
        head_only: bool,
    ) -> Response<Body> {
        self.read_object(key.as_str(), incoming, head_only, true).await
    }

    async fn unsatisfied_range(
        &self,
        key: &str,
        private_read: bool,
        content_range: &str,
    ) -> Response<Body> {
        let mut result = error(StatusCode::RANGE_NOT_SATISFIABLE);
        let value = if UNSATISFIED.is_match(content_range) {
            content_range.to_owned()
        } else {
            let Ok(metadata) = self
                .request(Method::HEAD, key, None, None, private_read)
                .await
            else {
                return error(StatusCode::SERVICE_UNAVAILABLE);
            };
            if metadata.status() == StatusCode::NOT_FOUND {
                return missing(key);
            }
            let length = metadata
                .headers()
                .get(header::CONTENT_LENGTH)
                .and_then(|v| v.to_str().ok());
            let Some(length) = length
                .filter(|value| !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit()))
            else {
                return error(StatusCode::SERVICE_UNAVAILABLE);
            };
            if metadata.status() != StatusCode::OK {
                return error(StatusCode::SERVICE_UNAVAILABLE);
            }
            format!("bytes */{length}")
        };
        result.headers_mut().insert(
            header::CONTENT_RANGE,
            HeaderValue::from_str(&value).expect("validated storage range"),
        );
        result
    }

    async fn read_object(
        &self,
        key: &str,
        incoming: &HeaderMap,
        head_only: bool,
        private_read: bool,
    ) -> Response<Body> {
        let range = match incoming.get(header::RANGE).filter(|_| !head_only) {
            Some(value) => match value.to_str().ok().map(str::trim) {
                Some("") => None,
                Some(value) if RANGE.is_match(value) && !value.eq_ignore_ascii_case("bytes=-") => {
                    Some(value.to_ascii_lowercase())
                }
                _ => return self.unsatisfied_range(key, private_read, "").await,
            },
            None => None,
        };
        let method = if head_only { Method::HEAD } else { Method::GET };
        let Ok(response) = self.request(method, key, range.as_deref(), None, private_read).await else {
            return error(StatusCode::SERVICE_UNAVAILABLE);
        };
        let status = response.status();
        let headers = response.headers();
        let content_range = headers
            .get(header::CONTENT_RANGE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        match status {
            StatusCode::NOT_FOUND => return missing(key),
            StatusCode::RANGE_NOT_SATISFIABLE if range.is_some() => {
                let content_range = content_range.to_owned();
                drop(response);
                return self
                    .unsatisfied_range(key, private_read, &content_range)
                    .await;
            }
            StatusCode::OK if range.is_none() => {}
            StatusCode::PARTIAL_CONTENT if range.is_some() && PARTIAL.is_match(content_range) => {}
            _ => return error(StatusCode::SERVICE_UNAVAILABLE),
        }
        let mut builder = Response::builder()
            .status(status)
            .header(header::CONTENT_TYPE, mime(key))
            .header(header::ACCEPT_RANGES, "bytes")
            .header(header::CACHE_CONTROL, "public, max-age=31536000, immutable")
            .header("x-content-type-options", "nosniff");
        if status == StatusCode::PARTIAL_CONTENT {
            builder = builder.header(header::CONTENT_RANGE, content_range);
        }
        for name in [header::CONTENT_LENGTH, header::ETAG, header::LAST_MODIFIED] {
            if let Some(value) = headers.get(&name) {
                builder = builder.header(name, value);
            }
        }
        builder
            .body(if head_only { Body::empty() } else { Body::from_stream(response.bytes_stream()) })
            .expect("validated storage headers")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{body::to_bytes, extract::Request, routing::any, Router};
    use std::sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    };
    use tokio::io::AsyncWriteExt;

    #[tokio::test]
    async fn writes_reads_and_removes_managed_objects() {
        const KEY: &str = "posts/images/42/a.txt";
        const PRIVATE_KEY: &str = "private/chat/42/a.txt";
        const DATA: &[u8] = b"source-content";
        let exists = Arc::new(AtomicBool::new(false));
        let app = Router::new().fallback(any(move |request: Request| {
            let exists = exists.clone();
            async move {
                let (parts, body) = request.into_parts();
                let private = parts.uri.path().ends_with(PRIVATE_KEY);
                assert_eq!(
                    parts.uri.path(),
                    format!("/neko-media/{}", if private { PRIVATE_KEY } else { KEY })
                );
                assert!(!private || matches!(parts.method, Method::PUT | Method::DELETE));
                assert!(parts.headers[header::AUTHORIZATION]
                    .to_str()
                    .unwrap()
                    .starts_with("AWS4-HMAC-SHA256 Credential=fixture-key/"));
                match parts.method {
                    Method::PUT => {
                        assert_eq!(parts.headers["if-none-match"], "*");
                        if private {
                            assert_eq!(parts.headers[header::CACHE_CONTROL], "private, no-store");
                        }
                        assert_eq!(
                            parts.headers["x-amz-content-sha256"],
                            hex::encode(Sha256::digest(DATA))
                        );
                        assert_eq!(to_bytes(body, 1024).await.unwrap().as_ref(), DATA);
                        error(if exists.swap(true, Ordering::SeqCst) {
                            StatusCode::PRECONDITION_FAILED
                        } else {
                            StatusCode::OK
                        })
                    }
                    Method::GET if exists.load(Ordering::SeqCst) => {
                        if parts.headers[header::RANGE] == "bytes=20-" {
                            return error(StatusCode::RANGE_NOT_SATISFIABLE);
                        }
                        assert_eq!(parts.headers[header::RANGE], "bytes=0-5");
                        Response::builder()
                            .status(206)
                            .header(header::CONTENT_RANGE, "bytes 0-5/14")
                            .body(Body::from(&DATA[..6]))
                            .unwrap()
                    }
                    Method::GET => error(StatusCode::NOT_FOUND),
                    Method::HEAD if exists.load(Ordering::SeqCst) => {
                        assert!(!parts.headers.contains_key(header::RANGE));
                        Response::builder()
                            .header(header::CONTENT_LENGTH, DATA.len())
                            .body(Body::empty())
                            .unwrap()
                    }
                    Method::DELETE => {
                        exists.store(false, Ordering::SeqCst);
                        error(StatusCode::NO_CONTENT)
                    }
                    _ => error(StatusCode::METHOD_NOT_ALLOWED),
                }
            }
        }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        let storage = S3Storage::from_lookup(|key| match key {
            "STORAGE_S3_ENDPOINT" => Some(endpoint.clone()),
            "STORAGE_S3_BUCKET" => Some("neko-media".into()),
            "STORAGE_S3_REGION" => Some("us-east-1".into()),
            "STORAGE_S3_ACCESS_KEY" => Some("fixture-key".into()),
            "STORAGE_S3_SECRET_KEY" => Some("fixture-secret".into()),
            _ => None,
        })
        .unwrap();
        for expected in [true, false] {
            let mut file = tokio::fs::File::from_std(tempfile::tempfile().unwrap());
            file.write_all(DATA).await.unwrap();
            file.flush().await.unwrap();
            assert_eq!(
                storage
                    .put(file, DATA.len() as u64, KEY, "text/plain")
                    .await
                    .is_ok(),
                expected
            );
        }
        let mut headers = HeaderMap::new();
        headers.insert(header::RANGE, "bytes=0-5".parse().unwrap());
        let response = storage.read(KEY, &headers, false).await;
        assert_eq!(response.status(), 206);
        assert_eq!(
            to_bytes(response.into_body(), 1024).await.unwrap().as_ref(),
            &DATA[..6]
        );
        let response = storage.read(KEY, &headers, true).await;
        assert_eq!(response.status(), 200);
        assert_eq!(response.headers()[header::CONTENT_LENGTH], DATA.len().to_string().as_str());
        assert!(!response.headers().contains_key(header::CONTENT_RANGE));
        assert!(to_bytes(response.into_body(), 1024).await.unwrap().is_empty());
        for value in ["bytes=20-", "bytes=1-2,4-5"] {
            let mut range_headers = HeaderMap::new();
            range_headers.insert(header::RANGE, HeaderValue::from_static(value));
            let response = storage.read(KEY, &range_headers, false).await;
            assert_eq!(response.status(), StatusCode::RANGE_NOT_SATISFIABLE);
            assert_eq!(
                response.headers()[header::CONTENT_RANGE],
                format!("bytes */{}", DATA.len()).as_str()
            );
        }
        storage.delete(KEY).await.unwrap();
        assert_eq!(storage.read(KEY, &headers, false).await.status(), 404);
        let mut file = tokio::fs::File::from_std(tempfile::tempfile().unwrap());
        file.write_all(DATA).await.unwrap();
        file.flush().await.unwrap();
        storage.put(file, DATA.len() as u64, PRIVATE_KEY, "text/plain").await.unwrap();
        assert_eq!(
            storage.read(PRIVATE_KEY, &headers, false).await.status(),
            404
        );
        assert_eq!(storage.read(PRIVATE_KEY, &headers, true).await.status(), 404);
        storage.delete(PRIVATE_KEY).await.unwrap();
        server.abort();
    }
}
