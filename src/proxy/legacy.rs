use axum::{
    body::{to_bytes, Body},
    extract::State,
    http::{header, HeaderMap, HeaderName, HeaderValue, Request, StatusCode, Uri},
    response::{IntoResponse, Response},
};
use serde_json::Value;
use std::sync::OnceLock;

use crate::{app::state::AppState, httpx::errors::ApiError};

const MAX_PROXY_BODY_BYTES: usize = 64 * 1024 * 1024;
const V2_OPENAPI_JSON: &str = include_str!("../../../doc/v2.openapi.json");
static V2_ROUTES: OnceLock<Vec<V2RoutePattern>> = OnceLock::new();

#[derive(Debug, Clone, PartialEq, Eq)]
struct V2RoutePattern {
    method: String,
    pattern: String,
}

pub async fn proxy_to_legacy(State(state): State<AppState>, request: Request<Body>) -> Response {
    let path = request.uri().path();
    if path.starts_with("/api/v2/") && !is_known_v2_route(request.method().as_str(), path) {
        return ApiError::route_not_found().into_response();
    }

    match forward(state, request).await {
        Ok(response) => response,
        Err(error) => error.into_response(),
    }
}

pub fn build_upstream_url(base_url: &str, uri: &Uri) -> Result<String, ApiError> {
    let base = base_url.trim_end_matches('/');
    let path_and_query = uri
        .path_and_query()
        .map(|value| value.as_str())
        .unwrap_or("/");

    if !base.starts_with("http://") && !base.starts_with("https://") {
        return Err(ApiError::server_error("legacy backend base url invalid"));
    }

    Ok(format!("{base}{path_and_query}"))
}

pub fn is_known_v2_route(method: &str, path: &str) -> bool {
    if path.starts_with("/api/v2/integrations/sentiment-flow") {
        return true;
    }

    let method = method.to_ascii_lowercase();
    v2_routes()
        .iter()
        .any(|route| route.method == method && route_pattern_matches(&route.pattern, path))
}

fn v2_routes() -> &'static [V2RoutePattern] {
    V2_ROUTES.get_or_init(load_v2_routes)
}

fn load_v2_routes() -> Vec<V2RoutePattern> {
    let parsed = serde_json::from_str::<Value>(V2_OPENAPI_JSON)
        .expect("doc/v2.openapi.json must be valid json");
    let Some(paths) = parsed.get("paths").and_then(Value::as_object) else {
        return Vec::new();
    };

    paths
        .iter()
        .flat_map(|(path, operations)| {
            operations
                .as_object()
                .into_iter()
                .flat_map(|operations| operations.keys())
                .filter(|method| {
                    matches!(
                        method.as_str(),
                        "get" | "post" | "put" | "patch" | "delete" | "head" | "options"
                    )
                })
                .map(|method| V2RoutePattern {
                    method: method.to_string(),
                    pattern: path.to_string(),
                })
                .collect::<Vec<_>>()
        })
        .collect()
}

fn route_pattern_matches(pattern: &str, path: &str) -> bool {
    let pattern_segments = pattern.trim_matches('/').split('/').collect::<Vec<_>>();
    let path_segments = path.trim_matches('/').split('/').collect::<Vec<_>>();

    pattern_segments.len() == path_segments.len()
        && pattern_segments
            .iter()
            .zip(path_segments.iter())
            .all(|(pattern, actual)| {
                (pattern.starts_with('{') && pattern.ends_with('}')) || pattern == actual
            })
}

async fn forward(state: AppState, request: Request<Body>) -> Result<Response, ApiError> {
    let (parts, body) = request.into_parts();
    let upstream_url = build_upstream_url(&state.config.legacy_backend.base_url, &parts.uri)?;
    let body = to_bytes(body, MAX_PROXY_BODY_BYTES)
        .await
        .map_err(|_| ApiError::bad_request("请求体读取失败"))?;
    let mut upstream = state
        .http_client
        .request(parts.method.clone(), upstream_url)
        .body(body);

    for (name, value) in &parts.headers {
        if should_forward_request_header(name) {
            upstream = upstream.header(name, value);
        }
    }

    let upstream_response = upstream
        .send()
        .await
        .map_err(|error| ApiError::server_error(format!("legacy backend unavailable: {error}")))?;
    let status = upstream_response.status();
    let headers = upstream_response.headers().clone();
    let bytes = upstream_response
        .bytes()
        .await
        .map_err(|_| ApiError::server_error("legacy backend response read failed"))?;

    let mut response = (status, bytes).into_response();
    copy_response_headers(&headers, response.headers_mut());
    Ok(response)
}

fn should_forward_request_header(name: &HeaderName) -> bool {
    !matches!(
        name.as_str(),
        "host" | "connection" | "transfer-encoding" | "content-length"
    )
}

fn should_forward_response_header(name: &HeaderName) -> bool {
    !matches!(
        name.as_str(),
        "connection" | "transfer-encoding" | "content-length"
    )
}

fn copy_response_headers(source: &HeaderMap, target: &mut HeaderMap) {
    for (name, value) in source {
        if should_forward_response_header(name) {
            append_header(target, name, value);
        }
    }
}

fn append_header(target: &mut HeaderMap, name: &HeaderName, value: &HeaderValue) {
    if *name == header::SET_COOKIE {
        target.append(name, value.clone());
    } else {
        target.insert(name, value.clone());
    }
}

pub fn legacy_proxy_unavailable() -> Response {
    (
        StatusCode::BAD_GATEWAY,
        "legacy backend unavailable for compatibility proxy",
    )
        .into_response()
}
