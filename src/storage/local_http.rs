use super::local_policy::{normalize_local_key, parse_local_byte_range};
use crate::media::private_read::PrivateKey;
use axum::{
    body::Body,
    extract::{OriginalUri, Path, State},
    http::{header, HeaderMap, Method, Response, StatusCode},
    response::IntoResponse,
    routing::get,
    Json, Router,
};
use base64::{engine::general_purpose::STANDARD, Engine};
use std::{
    fs::{self, File, Metadata},
    io,
    path::{Path as FsPath, PathBuf},
};
use tokio::io::{AsyncReadExt, AsyncSeekExt};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LocalStorageConfig {
    pub root: PathBuf,
    pub unsupported: bool,
    pub s3: Option<super::s3::S3Storage>,
}
impl LocalStorageConfig {
    pub fn from_lookup(get: impl Fn(&str) -> Option<String>) -> Self {
        let value = |key: &str| {
            get(key)
                .map(|s| s.trim().to_owned())
                .filter(|s| !s.is_empty())
        };
        let use_s3 = value("STORAGE_TYPE").as_deref() == Some("s3");
        let s3 = use_s3
            .then(|| super::s3::S3Storage::from_lookup(&value))
            .flatten();
        Self {
            root: value("STORAGE_PATH")
                .or_else(|| value("STORAGE_ROOT_DIR"))
                .unwrap_or_else(|| "./storage".into())
                .into(),
            unsupported: use_s3 && s3.is_none(),
            s3,
        }
    }
}

pub fn router(config: LocalStorageConfig) -> Router {
    Router::new()
        .route("/storage/{*key}", get(read).head(read))
        .route("/uploads/{*key}", get(retired_storage))
        .route("/upload/{*key}", get(retired_storage))
        .with_state(config)
}

async fn retired_storage(OriginalUri(uri): OriginalUri) -> impl IntoResponse {
    let requested = uri.path();
    let prefix = if requested.starts_with("/uploads/") {
        "/uploads"
    } else {
        "/upload"
    };
    (
        StatusCode::GONE,
        [(header::CACHE_CONTROL, "no-store")],
        Json(serde_json::json!({
            "code": 410,
            "message": format!("Legacy {prefix} path removed. Public files are served from /storage."),
            "data": {"requested_path": requested, "storage_base": "/storage"},
            "meta": null
        })),
    )
}

const AVATAR: &str = "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAA/UlEQVR42u2YOw4CMQxENyOuyg2oKai5AbejouQI9FCQOJOf8lyuVva8OJE/6fl6HyubjsUNAAAAAAAAAJa2UyO/t/vj68v1cm4RKNl7oV/pTTHUU33ODyMBMsV5GdRZvZ1B/dV7GagDFWdpSQIZAAAAAMLtjaUvIgPRs3S1pbYMFAkyNtXOK5QpyzsSmN/AX3H2gSY12k4vPFJSyAA49tkLucbCmvcdfMT27UgYQ5OoD7vVJOrDzjWP+lgITaU+EGibOtDt+EvDUYkBAGATgEbzVH24na5QtyQUBdKQbZQxhEZt1FzONWop63JbtVZZeKSkkAEAAAAAADCHfQBIWmGUrvIeKwAAAABJRU5ErkJggg==";

pub(super) fn error(status: StatusCode) -> Response<Body> {
    Response::builder()
        .status(status)
        .body(Body::empty())
        .unwrap()
}

pub(super) fn missing(key: &str) -> Response<Body> {
    if key == "default-avatar.png" {
        let data = STANDARD.decode(AVATAR).expect("constant avatar");
        return Response::builder()
            .status(200)
            .header(header::CONTENT_TYPE, "image/png")
            .header(header::CACHE_CONTROL, "public, max-age=31536000, immutable")
            .header(header::CONTENT_LENGTH, data.len())
            .body(Body::from(data))
            .unwrap();
    }
    error(StatusCode::NOT_FOUND)
}

pub(crate) fn link(metadata: &Metadata) -> bool {
    if metadata.file_type().is_symlink() {
        return true;
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return true;
        }
    }
    false
}

fn open_checked(root: &FsPath, key: &str) -> io::Result<File> {
    let mut current = root.to_path_buf();
    let parts: Vec<_> = key.split('/').collect();
    for (i, part) in parts.iter().enumerate() {
        current.push(part);
        let meta = fs::symlink_metadata(&current)?;
        if link(&meta)
            || (i + 1 < parts.len() && !meta.is_dir())
            || (i + 1 == parts.len() && !meta.is_file())
        {
            return Err(io::Error::from(io::ErrorKind::NotFound));
        }
    }
    File::open(current)
}

async fn read(
    State(config): State<LocalStorageConfig>,
    Path(raw): Path<String>,
    headers: HeaderMap,
    method: Method,
) -> Response<Body> {
    let head_only = method == Method::HEAD;
    let key = match normalize_local_key(&raw) {
        Ok(key) => key,
        Err(_) => return error(StatusCode::BAD_REQUEST),
    };
    if key
        .split('/')
        .next()
        .is_some_and(|s| s.eq_ignore_ascii_case("temp") || s.eq_ignore_ascii_case("private"))
    {
        return error(StatusCode::NOT_FOUND);
    }
    if config.unsupported {
        return if super::s3::managed(&key).is_some() {
            error(StatusCode::SERVICE_UNAVAILABLE)
        } else {
            missing(&key)
        };
    }
    if let Some(s3) = config.s3 {
        return s3.read(&key, &headers, head_only).await;
    }
    read_local(config.root, &key, &headers, head_only).await
}

pub(crate) async fn read_private(
    config: LocalStorageConfig,
    key: &PrivateKey,
    headers: &HeaderMap,
    head_only: bool,
) -> Response<Body> {
    if let Some(s3) = config.s3 {
        return s3.read_private(key, headers, head_only).await;
    }
    read_local(config.root, key.as_str(), headers, head_only).await
}

pub(crate) async fn read_vision_image(config: LocalStorageConfig, key: &str, scope: &str) -> Response<Body> {
    if config.unsupported {
        return error(StatusCode::SERVICE_UNAVAILABLE);
    }
    let headers = HeaderMap::new();
    if scope == "post" {
        let Some(key) = PrivateKey::new(key, scope) else {
            return error(StatusCode::NOT_FOUND);
        };
        return read_private(config, &key, &headers, false).await;
    }
    let Ok(key) = normalize_local_key(key) else {
        return error(StatusCode::NOT_FOUND);
    };
    if scope != "public" || key == "default-avatar.png" || key.split('/').next().is_none_or(|part| {
        part.eq_ignore_ascii_case("temp") || part.eq_ignore_ascii_case("private")
    }) {
        return error(StatusCode::NOT_FOUND);
    }
    if let Some(s3) = config.s3 {
        return s3.read(&key, &headers, false).await;
    }
    read_local(config.root, &key, &headers, false).await
}

async fn read_local(
    root: PathBuf,
    key: &str,
    headers: &HeaderMap,
    head_only: bool,
) -> Response<Body> {
    let name = key.to_owned();
    let file = match tokio::task::spawn_blocking(move || open_checked(&root, &name)).await {
        Ok(Ok(file)) => file,
        Ok(Err(e)) if e.kind() == io::ErrorKind::NotFound => return missing(key),
        _ => return error(StatusCode::INTERNAL_SERVER_ERROR),
    };
    let metadata = match file.metadata() {
        Ok(m) if m.is_file() => m,
        Ok(_) => return error(StatusCode::NOT_FOUND),
        Err(_) => return error(StatusCode::INTERNAL_SERVER_ERROR),
    };
    let size = metadata.len();
    let raw_range = match headers.get(header::RANGE).filter(|_| !head_only) {
        Some(v) => match v.to_str() {
            Ok(s) => s,
            Err(_) => "invalid",
        },
        None => "",
    };
    let range = match parse_local_byte_range(raw_range, size) {
        Ok(r) => r,
        Err(_) => {
            return Response::builder()
                .status(416)
                .header(header::CONTENT_RANGE, format!("bytes */{size}"))
                .body(Body::empty())
                .unwrap()
        }
    };
    let start = range.as_ref().map_or(0, |r| r.start);
    let length = range.as_ref().map_or(size, |r| r.end - r.start + 1);
    let mut file = tokio::fs::File::from_std(file);
    if start != 0 && file.seek(io::SeekFrom::Start(start)).await.is_err() {
        return error(StatusCode::INTERNAL_SERVER_ERROR);
    }
    let stream = futures_util::stream::unfold((file, length), |(mut file, remaining)| async move {
        if remaining == 0 {
            return None;
        }
        let mut buf = vec![0u8; remaining.min(65536) as usize];
        match file.read(&mut buf).await {
            Ok(0) => Some((
                Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "file truncated",
                )),
                (file, 0),
            )),
            Ok(n) => {
                buf.truncate(n);
                Some((Ok(buf), (file, remaining - n as u64)))
            }
            Err(e) => Some((Err(e), (file, 0))),
        }
    });
    let mut builder = Response::builder()
        .status(if range.is_some() { 206 } else { 200 })
        .header(header::CONTENT_TYPE, mime(key))
        .header(header::CONTENT_LENGTH, length)
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::CACHE_CONTROL, "public, max-age=31536000, immutable")
        .header("x-content-type-options", "nosniff");
    if let Some(r) = range {
        builder = builder.header(
            header::CONTENT_RANGE,
            format!("bytes {}-{}/{size}", r.start, r.end),
        );
    }
    if let Ok(modified) = metadata.modified() {
        let date: chrono::DateTime<chrono::Utc> = modified.into();
        builder = builder.header(
            header::LAST_MODIFIED,
            date.format("%a, %d %b %Y %H:%M:%S GMT").to_string(),
        );
        if let Ok(duration) = modified.duration_since(std::time::UNIX_EPOCH) {
            let millis = duration.as_secs_f64() * 1000.0;
            builder = builder.header(header::ETAG, format!("\"{size}-{millis}\""));
        }
    }
    builder
        .body(if head_only {
            Body::empty()
        } else {
            Body::from_stream(stream)
        })
        .unwrap()
}

pub(super) fn mime(key: &str) -> &'static str {
    match FsPath::new(key)
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase()
        .as_str()
    {
        "7z" => "application/x-7z-compressed",
        "avif" => "image/avif",
        "csv" => "text/csv",
        "doc" => "application/msword",
        "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "gif" => "image/gif",
        "gz" => "application/gzip",
        "jpeg" | "jpg" => "image/jpeg",
        "json" => "application/json",
        "md" => "text/markdown",
        "mp3" => "audio/mpeg",
        "mp4" => "video/mp4",
        "odp" => "application/vnd.oasis.opendocument.presentation",
        "ods" => "application/vnd.oasis.opendocument.spreadsheet",
        "odt" => "application/vnd.oasis.opendocument.text",
        "oga" | "ogg" | "opus" | "spx" => "audio/ogg",
        "ogm" | "ogv" => "video/ogg",
        "pdf" => "application/pdf",
        "png" => "image/png",
        "ppt" => "application/vnd.ms-powerpoint",
        "pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "rar" => "application/vnd.rar",
        "rtf" => "application/rtf",
        "tar" => "application/x-tar",
        "tsv" => "text/tab-separated-values",
        "txt" => "text/plain",
        "wav" => "audio/wav",
        "webm" => "video/webm",
        "webp" => "image/webp",
        "xls" => "application/vnd.ms-excel",
        "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "xml" => "application/xml",
        "zip" => "application/zip",
        _ => "application/octet-stream",
    }
}
