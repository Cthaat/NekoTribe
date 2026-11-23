use crate::{
    auth::sessions::NativeState,
    config::env::RedisConfig,
    httpx::{errors::ApiError, response::V2Response},
    posts::bookmark::interaction_actor,
};
use axum::{
    extract::{OriginalUri, State},
    http::HeaderMap,
    Extension, Json,
};
use futures_util::future::BoxFuture;
use ipnet::IpNet;
use reqwest::{header, redirect, Client, Response, StatusCode};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    io,
    net::{IpAddr, SocketAddr},
    sync::{Arc, OnceLock},
    time::Duration,
};
use tokio::{
    net::lookup_host,
    time::{timeout_at, Instant},
};
use url::{Host, Url};

mod metadata;

#[derive(Deserialize)]
struct Policy {
    max_url_bytes: usize,
    timeout_ms: u64,
    max_redirects: usize,
    max_body_bytes: usize,
    cache_timeout_ms: u64,
    cache_ttl_seconds: u64,
    cache_prefix: String,
    title_chars: usize,
    description_chars: usize,
    site_name_chars: usize,
    blocked_host_suffixes: Vec<String>,
    ipv6_public_prefix: String,
    blocked_cidrs: Vec<String>,
}

fn policy() -> &'static Policy {
    static POLICY: OnceLock<Policy> = OnceLock::new();
    POLICY.get_or_init(|| {
        serde_json::from_str(include_str!("../contracts/requirements/link-preview.json"))
            .expect("valid link preview contract")
    })
}

#[derive(Debug, PartialEq, Eq)]
struct Blocked;

fn unsafe_raw(value: &str) -> bool {
    value
        .bytes()
        .any(|byte| matches!(byte, b'\\' | 0..=32 | 127))
}

fn parse_target(raw: &str) -> Result<Url, Blocked> {
    if raw.len() > policy().max_url_bytes || unsafe_raw(raw) {
        return Err(Blocked);
    }
    let (scheme, rest) = raw.split_once("://").ok_or(Blocked)?;
    if !scheme.eq_ignore_ascii_case("http") && !scheme.eq_ignore_ascii_case("https") {
        return Err(Blocked);
    }
    let authority = rest.split(['/', '?', '#']).next().ok_or(Blocked)?;
    if authority.is_empty() || authority.contains(['@', '%']) || authority.ends_with(':') {
        return Err(Blocked);
    }
    let mut url = Url::parse(raw).map_err(|_| Blocked)?;
    if !url.username().is_empty() || url.password().is_some() || url.port().is_some() {
        return Err(Blocked);
    }
    match url.host().ok_or(Blocked)? {
        Host::Ipv4(ip) => {
            let raw_host = authority.split(':').next().ok_or(Blocked)?;
            if raw_host != ip.to_string() || !public_ip(IpAddr::V4(ip)) {
                return Err(Blocked);
            }
        }
        Host::Ipv6(ip) if !public_ip(IpAddr::V6(ip)) => return Err(Blocked),
        Host::Domain(domain) if !public_hostname(domain) => return Err(Blocked),
        _ => {}
    }
    url.set_fragment(None);
    if url.as_str().len() > policy().max_url_bytes {
        return Err(Blocked);
    }
    Ok(url)
}

fn public_hostname(domain: &str) -> bool {
    let name = domain.strip_suffix('.').unwrap_or(domain);
    name.len() <= 253
        && name.split('.').all(|label| {
            (1..=63).contains(&label.len())
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
        && !policy().blocked_host_suffixes.iter().any(|suffix| {
            name == suffix
                || name
                    .strip_suffix(suffix.as_str())
                    .is_some_and(|prefix| prefix.ends_with('.'))
        })
}

fn public_ip(ip: IpAddr) -> bool {
    static NETWORKS: OnceLock<(IpNet, Vec<IpNet>)> = OnceLock::new();
    let (public_v6, blocks) = NETWORKS.get_or_init(|| {
        (
            policy()
                .ipv6_public_prefix
                .parse()
                .expect("valid public IPv6 prefix"),
            policy()
                .blocked_cidrs
                .iter()
                .map(|value| value.parse().expect("valid blocked CIDR"))
                .collect(),
        )
    });
    (ip.is_ipv4() || public_v6.contains(&ip)) && blocks.iter().all(|network| !network.contains(&ip))
}

fn redirect_target(previous: &Url, location: &str) -> Result<Url, Blocked> {
    if location.len() > policy().max_url_bytes || unsafe_raw(location) || location.is_empty() {
        return Err(Blocked);
    }
    if location.starts_with("//") {
        return parse_target(&format!("{}:{location}", previous.scheme()));
    }
    if location
        .split(['/', '?', '#'])
        .next()
        .is_some_and(|part| part.contains(':'))
    {
        return parse_target(location);
    }
    let resolved = previous.join(location).map_err(|_| Blocked)?;
    parse_target(resolved.as_str())
}

enum Hop {
    Redirect(String),
    Html(Vec<u8>),
}

trait Transport {
    fn resolve<'a>(&self, host: &'a str, port: u16) -> BoxFuture<'a, Option<Vec<SocketAddr>>>;
    fn send<'a>(&self, target: &'a Url, approved: &'a [SocketAddr]) -> BoxFuture<'a, Option<Hop>>;
}

struct Http;

impl Transport for Http {
    fn resolve<'a>(&self, host: &'a str, port: u16) -> BoxFuture<'a, Option<Vec<SocketAddr>>> {
        Box::pin(async move {
            let absolute = if host.ends_with('.') {
                host.to_owned()
            } else {
                format!("{host}.")
            };
            let addresses = lookup_host((absolute.as_str(), port)).await.ok()?;
            Some(addresses.collect())
        })
    }

    fn send<'a>(&self, target: &'a Url, approved: &'a [SocketAddr]) -> BoxFuture<'a, Option<Hop>> {
        Box::pin(send(target, approved))
    }
}

struct NoUnverifiedDns;

impl reqwest::dns::Resolve for NoUnverifiedDns {
    fn resolve(&self, _: reqwest::dns::Name) -> reqwest::dns::Resolving {
        Box::pin(async { Err(io::Error::other("unverified link preview resolution").into()) })
    }
}

fn pinned_client(target: &Url, approved: &[SocketAddr]) -> Option<Client> {
    let mut builder = Client::builder()
        .no_proxy()
        .redirect(redirect::Policy::none())
        .referer(false)
        .retry(reqwest::retry::never())
        .no_gzip()
        .no_brotli()
        .no_deflate()
        .no_zstd()
        .dns_resolver(Arc::new(NoUnverifiedDns));
    if let Some(domain) = target.domain() {
        builder = builder.resolve_to_addrs(domain, approved);
    }
    builder.build().ok()
}

async fn send(target: &Url, approved: &[SocketAddr]) -> Option<Hop> {
    let mut response = pinned_client(target, approved)?
        .get(target.clone())
        .header(header::ACCEPT, "text/html, application/xhtml+xml")
        .header(header::ACCEPT_ENCODING, "identity")
        .send()
        .await
        .ok()?;
    if !response
        .remote_addr()
        .is_some_and(|peer| approved.contains(&peer))
    {
        return None;
    }
    if matches!(
        response.status(),
        StatusCode::MOVED_PERMANENTLY
            | StatusCode::FOUND
            | StatusCode::SEE_OTHER
            | StatusCode::TEMPORARY_REDIRECT
            | StatusCode::PERMANENT_REDIRECT
    ) {
        let location = response
            .headers()
            .get(header::LOCATION)?
            .to_str()
            .unwrap_or_default();
        return Some(Hop::Redirect(location.to_owned()));
    }
    if !response.status().is_success() || !readable_body(&response) {
        return None;
    }
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.ok()? {
        if chunk.len() > policy().max_body_bytes.saturating_sub(body.len()) {
            return None;
        }
        body.extend_from_slice(&chunk);
    }
    Some(Hop::Html(body))
}

fn readable_body(response: &Response) -> bool {
    readable_headers(response.headers(), response.content_length())
}

fn readable_headers(headers: &HeaderMap, len: Option<u64>) -> bool {
    let mime = headers
        .get(header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(';').next())
        .unwrap_or_default()
        .trim();
    (mime.eq_ignore_ascii_case("text/html") || mime.eq_ignore_ascii_case("application/xhtml+xml"))
        && headers.get_all(header::CONTENT_TYPE).iter().count() == 1
        && headers.get_all(header::CONTENT_ENCODING).iter().count() <= 1
        && headers
            .get_all(header::CONTENT_ENCODING)
            .iter()
            .all(|value| {
                value
                    .to_str()
                    .ok()
                    .is_some_and(|encoding| encoding.trim().eq_ignore_ascii_case("identity"))
            })
        && len.is_none_or(|size| size <= policy().max_body_bytes as u64)
}

async fn fetch_chain(
    transport: &impl Transport,
    mut target: Url,
) -> Result<Option<Preview>, Blocked> {
    for hop in 0..=policy().max_redirects {
        let port = target.port_or_known_default().ok_or(Blocked)?;
        let approved = match target.host().ok_or(Blocked)? {
            Host::Ipv4(ip) => vec![SocketAddr::new(IpAddr::V4(ip), port)],
            Host::Ipv6(ip) => vec![SocketAddr::new(IpAddr::V6(ip), port)],
            Host::Domain(host) => match transport.resolve(host, port).await {
                Some(answers) => answers,
                None => return Ok(None),
            },
        };
        if approved
            .iter()
            .any(|peer| peer.port() != port || !public_ip(peer.ip()))
        {
            return Err(Blocked);
        }
        if approved.is_empty() {
            return Ok(None);
        }
        match transport.send(&target, &approved).await {
            Some(Hop::Redirect(location)) => {
                target = redirect_target(&target, &location)?;
                if hop == policy().max_redirects {
                    return Ok(None);
                }
            }
            Some(Hop::Html(body)) if body.len() <= policy().max_body_bytes => {
                return Ok(metadata::preview(&target, &body))
            }
            _ => return Ok(None),
        }
    }
    Ok(None)
}

#[derive(Deserialize, Serialize, Debug, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct Preview {
    url: String,
    title: String,
    description: String,
    site_name: String,
}

#[derive(Clone)]
pub struct PreviewCache(redis::Client);

impl PreviewCache {
    pub fn from_config(config: &RedisConfig) -> Option<Self> {
        redis::Client::open(config.connection_url()).ok().map(Self)
    }

    async fn lookup(&self, key: &str) -> redis::RedisResult<Option<Preview>> {
        let mut connection = self.0.get_multiplexed_async_connection().await?;
        let value = redis::cmd("GET")
            .arg(key)
            .query_async::<Option<String>>(&mut connection)
            .await?;
        Ok(value.as_deref().and_then(cached_preview))
    }

    async fn store(&self, key: &str, preview: &Preview) {
        let Ok(value) = serde_json::to_string(preview) else {
            return;
        };
        let Ok(mut connection) = self.0.get_multiplexed_async_connection().await else {
            return;
        };
        let _ = redis::cmd("SETEX")
            .arg(key)
            .arg(policy().cache_ttl_seconds)
            .arg(value)
            .query_async::<()>(&mut connection)
            .await;
    }
}

fn cached_preview(value: &str) -> Option<Preview> {
    let policy = policy();
    if value.len()
        > (policy.max_url_bytes
            + policy.title_chars
            + policy.description_chars
            + policy.site_name_chars)
            * 6
            + 256
    {
        return None;
    }
    let preview: Preview = serde_json::from_str(value).ok()?;
    let url = parse_target(&preview.url).ok()?;
    if url.as_str() != preview.url
        || preview.title.is_empty()
        || preview.title.chars().count() > policy.title_chars
        || preview.description.chars().count() > policy.description_chars
        || preview.site_name.chars().count() > policy.site_name_chars
    {
        return None;
    }
    Some(preview)
}

fn key(url: &Url) -> String {
    format!(
        "{}{}",
        policy().cache_prefix,
        hex::encode(Sha256::digest(url.as_str()))
    )
}

async fn preview(target: Url, cache: Option<&PreviewCache>) -> Result<Option<Preview>, Blocked> {
    use crate::observability::{metrics, CacheResult};
    let deadline = Instant::now() + Duration::from_millis(policy().timeout_ms);
    let cache_key = cache.map(|_| key(&target));
    let cache_deadline =
        || deadline.min(Instant::now() + Duration::from_millis(policy().cache_timeout_ms));
    let cache_result = match (cache, &cache_key) {
        (Some(cache), Some(key)) => match timeout_at(cache_deadline(), cache.lookup(key)).await {
            Ok(Ok(Some(preview))) => {
                metrics().cache(CacheResult::Hit);
                return Ok(Some(preview));
            }
            Ok(Ok(None)) => CacheResult::Miss,
            Ok(Err(_)) | Err(_) => CacheResult::Degraded,
        },
        _ => CacheResult::Degraded,
    };
    metrics().cache(cache_result);
    let result = timeout_at(deadline, fetch_chain(&Http, target))
        .await
        .unwrap_or(Ok(None))?;
    if let (Some(cache), Some(key), Some(preview)) = (cache, &cache_key, &result) {
        let _ = timeout_at(cache_deadline(), cache.store(key, preview)).await;
    }
    Ok(result)
}

#[derive(Serialize)]
pub(crate) struct PreviewData {
    preview: Option<Preview>,
}

pub(crate) async fn route(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
    cache: Option<Extension<PreviewCache>>,
) -> Result<Json<V2Response<PreviewData>>, ApiError> {
    interaction_actor(&state, &headers).await?;
    let invalid = || ApiError::bad_request("url 参数错误");
    let mut values = url::form_urlencoded::parse(uri.query().unwrap_or_default().as_bytes())
        .filter(|(key, _)| key == "url")
        .map(|(_, value)| value);
    let raw = values.next().ok_or_else(invalid)?;
    if values.next().is_some() {
        return Err(invalid());
    }
    let target = parse_target(&raw).map_err(|_| invalid())?;
    let preview = preview(target, cache.as_ref().map(|cache| &cache.0))
        .await
        .map_err(|_| invalid())?;
    Ok(Json(V2Response::ok(PreviewData { preview })))
}

#[cfg(test)]
mod tests;
