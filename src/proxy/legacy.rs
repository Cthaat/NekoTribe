use axum::{
    body::{to_bytes, Body},
    extract::State,
    http::{header, HeaderMap, HeaderName, HeaderValue, Request, StatusCode, Uri},
    response::{IntoResponse, Response},
};
use serde_json::Value;
use std::sync::OnceLock;

use crate::{
    app::state::AppState, httpx::errors::ApiError, media::upload::PRIVATE_UPLOAD_ROUTE,
};

const MAX_PROXY_BODY_BYTES: usize = 64 * 1024 * 1024;
const V2_OPENAPI_JSON: &str = include_str!("../../contracts/v2.openapi.json");
static V2_ROUTES: OnceLock<Vec<V2RoutePattern>> = OnceLock::new();

#[derive(Debug, Clone, PartialEq, Eq)]
struct V2RoutePattern {
    method: String,
    pattern: String,
}

pub async fn proxy_to_legacy(State(state): State<AppState>, request: Request<Body>) -> Response {
    let path = request.uri().path();
    if let Some(response) = crate::sentiment_retirement::response(request.method(), path) {
        return response;
    }
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
    if method.eq_ignore_ascii_case("OPTIONS") {
        return v2_routes()
            .iter()
            .any(|route| route_pattern_matches(&route.pattern, path));
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
        .expect("contracts/v2.openapi.json must be valid json");
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
    if pattern == PRIVATE_UPLOAD_ROUTE {
        return path == pattern;
    }
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

fn private_upload_proxy_error() -> ApiError {
    ApiError::new(StatusCode::BAD_GATEWAY, 50201, "媒体存储暂不可用")
}

fn private_upload_client() -> Result<&'static reqwest::Client, ApiError> {
    static CLIENT: OnceLock<Result<reqwest::Client, reqwest::Error>> = OnceLock::new();
    CLIENT
        .get_or_init(|| {
            reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .build()
        })
        .as_ref()
        .map_err(|_| private_upload_proxy_error())
}

async fn forward(state: AppState, request: Request<Body>) -> Result<Response, ApiError> {
    let (parts, body) = request.into_parts();
    let upstream_url = build_upstream_url(&state.config.legacy_backend.base_url, &parts.uri)?;
    let private_upload = parts.uri.path() == PRIVATE_UPLOAD_ROUTE;
    let body = to_bytes(body, MAX_PROXY_BODY_BYTES)
        .await
        .map_err(|_| ApiError::bad_request("请求体读取失败"))?;
    let client = if private_upload {
        private_upload_client()?
    } else {
        &state.http_client
    };
    let mut upstream = client.request(parts.method.clone(), upstream_url).body(body);

    for (name, value) in &parts.headers {
        if should_forward_request_header(name, &parts.headers) {
            upstream = upstream.header(name, value);
        }
    }

    let upstream_response = upstream.send().await.map_err(|error| {
        if private_upload {
            private_upload_proxy_error()
        } else {
            ApiError::server_error(format!("legacy backend unavailable: {error}"))
        }
    })?;
    let status = upstream_response.status();
    if private_upload && status.is_redirection() {
        return Err(private_upload_proxy_error());
    }
    let headers = upstream_response.headers().clone();
    let bytes = upstream_response
        .bytes()
        .await
        .map_err(|_| ApiError::server_error("legacy backend response read failed"))?;

    let mut response = (status, bytes).into_response();
    copy_response_headers(&headers, response.headers_mut());
    Ok(response)
}

fn should_forward_request_header(name: &HeaderName, headers: &HeaderMap) -> bool {
    *name != header::HOST && should_forward_response_header(name, headers)
}

fn should_forward_response_header(name: &HeaderName, headers: &HeaderMap) -> bool {
    !matches!(
        name.as_str(),
        "connection"
            | "keep-alive"
            | "proxy-authenticate"
            | "proxy-authorization"
            | "proxy-connection"
            | "te"
            | "trailer"
            | "transfer-encoding"
            | "upgrade"
            | "content-length"
    ) && !headers.get_all(header::CONNECTION).iter().any(|value| {
        value.to_str().is_ok_and(|value| {
            value
                .split(',')
                .any(|token| token.trim().eq_ignore_ascii_case(name.as_str()))
        })
    })
}

fn copy_response_headers(source: &HeaderMap, target: &mut HeaderMap) {
    for (name, value) in source {
        if should_forward_response_header(name, source) {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proxy_removes_hop_headers_and_all_connection_nominated_headers() {
        let mut headers = HeaderMap::new();
        headers.append(
            header::CONNECTION,
            HeaderValue::from_static("keep-alive, X-Hop"),
        );
        headers.append(header::CONNECTION, HeaderValue::from_static(" x-Other "));
        for name in [
            "x-hop",
            "x-other",
            "te",
            "trailer",
            "upgrade",
            "proxy-authorization",
        ] {
            let name = HeaderName::from_static(name);
            assert!(!should_forward_request_header(&name, &headers));
            assert!(!should_forward_response_header(&name, &headers));
        }
        assert!(!should_forward_request_header(&header::HOST, &headers));
        for name in [header::ORIGIN, header::AUTHORIZATION, header::COOKIE] {
            assert!(should_forward_request_header(&name, &headers));
        }
    }

    #[test]
    fn response_keeps_cors_and_multiple_cookies_but_drops_connection_headers() {
        let mut source = HeaderMap::new();
        source.insert(header::CONNECTION, HeaderValue::from_static("X-Hop"));
        source.insert("x-hop", HeaderValue::from_static("private"));
        source.insert(
            header::ACCESS_CONTROL_ALLOW_ORIGIN,
            HeaderValue::from_static("https://client.example"),
        );
        source.insert(header::VARY, HeaderValue::from_static("Origin"));
        source.append(
            header::SET_COOKIE,
            HeaderValue::from_static("a=1; HttpOnly"),
        );
        source.append(
            header::SET_COOKIE,
            HeaderValue::from_static("b=2; HttpOnly"),
        );
        let mut target = HeaderMap::new();
        copy_response_headers(&source, &mut target);
        assert!(!target.contains_key(header::CONNECTION));
        assert!(!target.contains_key("x-hop"));
        assert_eq!(
            target[header::ACCESS_CONTROL_ALLOW_ORIGIN],
            "https://client.example"
        );
        assert_eq!(target[header::VARY], "Origin");
        assert_eq!(target.get_all(header::SET_COOKIE).iter().count(), 2);
    }
}
