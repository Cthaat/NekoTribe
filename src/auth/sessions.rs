use crate::{
    auth::{TokenClaims, TokenCodec, TokenKind},
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    body::Body,
    extract::{OriginalUri, State},
    http::{HeaderMap, HeaderValue, Request, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{delete, get},
    Json, Router,
};
use serde_json::json;
use std::{
    future::Future,
    pin::Pin,
    sync::{Arc, OnceLock},
};

#[derive(Debug, Clone, Copy, thiserror::Error)]
#[error("session store unavailable")]
pub struct SessionStoreError;
pub type StoreFuture<'a, T> =
    Pin<Box<dyn Future<Output = Result<T, SessionStoreError>> + Send + 'a>>;
pub trait SessionRepository: Send + Sync {
    fn touch<'a>(&'a self, claims: &'a TokenClaims) -> StoreFuture<'a, u64>;
    fn revoke<'a>(&'a self, user_id: u64, id: &'a str) -> StoreFuture<'a, u64>;
    fn revoke_others<'a>(&'a self, user_id: u64, current: &'a str) -> StoreFuture<'a, u64>;
}
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CorsPolicy {
    pub origins: Vec<String>,
    pub localhost: bool,
}
#[derive(Clone)]
struct NativeState {
    codec: Arc<TokenCodec>,
    repository: Arc<dyn SessionRepository>,
    clock: Arc<dyn Fn() -> u64 + Send + Sync>,
}
pub fn build_native_router(
    codec: TokenCodec,
    repository: Arc<dyn SessionRepository>,
    cors: CorsPolicy,
    clock: Arc<dyn Fn() -> u64 + Send + Sync>,
) -> Router {
    Router::new()
        .route(
            "/api/health",
            get(|| async { Json(json!({"status":"ok","service":"nekotribe"})) }),
        )
        .route("/api/v2/auth/sessions/others", delete(revoke))
        .route("/api/v2/auth/sessions/{id}", delete(revoke))
        .fallback(|| async { ApiError::route_not_found() })
        .layer(middleware::from_fn_with_state(cors, cors_middleware))
        .with_state(NativeState {
            codec: Arc::new(codec),
            repository,
            clock,
        })
}
async fn revoke(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let token = access_token(&headers);
    if token.is_empty() {
        return Err(ApiError::unauthorized("请先登录"));
    }
    let claims = state
        .codec
        .verify(&token, TokenKind::Access, (state.clock)())
        .map_err(|_| ApiError::unauthorized("Token无效或已过期"))?;
    if state.repository.touch(&claims).await.unwrap_or(0) != 1 {
        return Err(ApiError::unauthorized("Token无效或已过期"));
    }
    // OriginalUri preserves opaque encoding; Axum Path would percent-decode it.
    let id = uri
        .path()
        .strip_prefix("/api/v2/auth/sessions/")
        .unwrap_or_default();
    if id == "others" {
        let n = state
            .repository
            .revoke_others(claims.user_id, &claims.session_id)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?;
        return Ok(Json(V2Response::ok_with_message(
            json!({"revoked_count":n}),
            "other sessions revoked",
        ))
        .into_response());
    }
    let n = state
        .repository
        .revoke(claims.user_id, id)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    if n == 0 {
        return Err(ApiError::not_found("会话不存在"));
    }
    let mut response = Json(V2Response::null("session revoked")).into_response();
    if id == claims.session_id {
        for value in [
            "access_token=; Max-Age=0; Path=/",
            "refresh_token=; Max-Age=0; Path=/",
        ] {
            response
                .headers_mut()
                .append("set-cookie", HeaderValue::from_static(value));
        }
    }
    Ok(response)
}
fn access_token(headers: &HeaderMap) -> String {
    // Repeated Cookie fields are ordered like one semicolon-joined value.
    // Select the first matching name across every field, including empty values,
    // before deciding whether Authorization is the fallback.
    let cookie = headers
        .get_all("cookie")
        .iter()
        .filter_map(|h| h.to_str().ok())
        .flat_map(|raw| raw.split(';'))
        .find_map(|cookie| {
            let (name, value) = cookie.trim().split_once('=')?;
            if name.trim() != "access_token" {
                return None;
            }
            let value = value.trim();
            Some(
                value
                    .strip_prefix('"')
                    .and_then(|v| v.strip_suffix('"'))
                    .unwrap_or(value),
            )
        });
    if let Some(value) = cookie.filter(|v| !v.is_empty()) {
        return percent_decode(value).unwrap_or_else(|| value.to_owned());
    }
    let header = headers
        .get("authorization")
        .and_then(|h| h.to_str().ok())
        .unwrap_or_default();
    static BEARER: OnceLock<regex::Regex> = OnceLock::new();
    BEARER
        .get_or_init(|| regex::Regex::new(r"(?i)^Bearer\s+").expect("static bearer regex"))
        .replace(header, "")
        .trim()
        .to_owned()
}
fn percent_decode(value: &str) -> Option<String> {
    let mut out = Vec::new();
    let b = value.as_bytes();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' {
            let pair = value.get(i + 1..i + 3)?;
            out.push(u8::from_str_radix(pair, 16).ok()?);
            i += 3
        } else {
            out.push(b[i]);
            i += 1
        }
    }
    String::from_utf8(out).ok()
}

pub const ALLOWED_HEADERS:&str="authorization,content-type,accept,origin,x-requested-with,x-request-id,x-client-platform,x-client-route,x-client-component,x-client-source,x-client-referer,x-device-fingerprint,x-device-info";
pub const ALLOWED_METHODS: &str = "GET,POST,PUT,PATCH,DELETE,OPTIONS";
fn normalize_origin(origin: &str) -> Option<String> {
    let url = reqwest::Url::parse(origin).ok()?;
    let serialized = url.origin().ascii_serialization();
    if matches!(url.scheme(), "http" | "https") && origin == serialized {
        Some(serialized)
    } else {
        None
    }
}
impl CorsPolicy {
    pub fn from_lookup(get: impl Fn(&str) -> Option<String>) -> Self {
        let mut policy = Self::default();
        for key in ["CORS_ALLOWED_ORIGINS", "NUXT_CORS_ALLOWED_ORIGINS"] {
            for raw in get(key).unwrap_or_default().split(',') {
                if let Some(origin) = normalize_origin(raw.trim()) {
                    if !policy.origins.contains(&origin) {
                        policy.origins.push(origin)
                    }
                }
            }
        }
        let local = get("NUXT_CORS_ALLOW_LOCALHOST_ORIGINS")
            .or_else(|| get("CORS_ALLOW_LOCALHOST_ORIGINS"));
        policy.localhost = local.as_deref() == Some("true")
            || (local.is_none() && get("NODE_ENV").as_deref() == Some("development"));
        policy
    }
    fn allows(&self, origin: &str) -> bool {
        if normalize_origin(origin).is_none() {
            return false;
        };
        if self.origins.iter().any(|o| o == origin) {
            return true;
        };
        if !self.localhost {
            return false;
        };
        let url = reqwest::Url::parse(origin).expect("normalized URL");
        let host = url.host_str().unwrap_or_default();
        host == "localhost"
            || host == "[::1]"
            || host == "::1"
            || host
                .parse::<std::net::Ipv4Addr>()
                .is_ok_and(|ip| ip.octets()[0] == 127)
    }
}
async fn cors_middleware(
    State(policy): State<CorsPolicy>,
    request: Request<Body>,
    next: Next,
) -> Response {
    let h = request.headers();
    let origin = h
        .get("origin")
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default();
    let mut allowed = policy.allows(origin);
    let preflight = request.method() == axum::http::Method::OPTIONS;
    if let Some(method) = h.get("access-control-request-method").filter(|_| preflight) {
        allowed &= method
            .to_str()
            .is_ok_and(|m| ALLOWED_METHODS.split(',').any(|v| v == m))
    }
    let mut requested = Vec::new();
    if let Some(headers) = h
        .get("access-control-request-headers")
        .filter(|_| preflight)
    {
        for name in headers.to_str().unwrap_or_default().split(',') {
            let name = name.trim().to_ascii_lowercase();
            allowed &= ALLOWED_HEADERS.split(',').any(|v| v == name);
            if !requested.contains(&name) {
                requested.push(name)
            }
        }
    }
    let cors = if allowed {
        let mut headers = HeaderMap::new();
        for (name, value) in [
            ("access-control-allow-origin", origin.to_owned()),
            ("access-control-allow-credentials", "true".into()),
            ("access-control-allow-methods", ALLOWED_METHODS.into()),
            (
                "access-control-allow-headers",
                if requested.is_empty() {
                    ALLOWED_HEADERS.into()
                } else {
                    requested.join(",")
                },
            ),
            (
                "access-control-expose-headers",
                "content-length,content-type".into(),
            ),
            ("access-control-max-age", "86400".into()),
        ] {
            if let Ok(value) = HeaderValue::from_str(&value) {
                headers.insert(axum::http::header::HeaderName::from_static(name), value);
            }
        }
        headers
    } else {
        HeaderMap::new()
    };
    let mut response = if preflight {
        if origin.is_empty() || allowed {
            StatusCode::NO_CONTENT.into_response()
        } else {
            ApiError::forbidden("Forbidden").into_response()
        }
    } else {
        next.run(request).await
    };
    response.headers_mut().extend(cors);
    merge_vary(response.headers_mut());
    response
}
fn merge_vary(headers: &mut HeaderMap) {
    let existing = headers
        .get_all("vary")
        .iter()
        .filter_map(|h| h.to_str().ok())
        .collect::<Vec<_>>()
        .join(",");
    let mut values: Vec<String> = existing
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .collect();
    if !values.iter().any(|v| v == "*") {
        for value in [
            "Origin",
            "Access-Control-Request-Method",
            "Access-Control-Request-Headers",
        ] {
            if !values.iter().any(|v| v.eq_ignore_ascii_case(value)) {
                values.push(value.to_owned())
            }
        }
    };
    if let Ok(v) = HeaderValue::from_str(&values.join(", ")) {
        headers.insert("vary", v);
    }
}
