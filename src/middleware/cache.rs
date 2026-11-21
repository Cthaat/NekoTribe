use axum::{
    body::Body,
    http::{header, HeaderValue, Method, Request},
    middleware::Next,
    response::Response,
};

pub async fn api_no_store(request: Request<Body>, next: Next) -> Response {
    let path = request.uri().path();
    let api = request.method() != Method::OPTIONS && (path == "/api/v2" || path.starts_with("/api/v2/"));
    let mut response = next.run(request).await;
    if api {
        response.headers_mut().insert(
            header::CACHE_CONTROL,
            HeaderValue::from_static("private, no-store"),
        );
    }
    response
}
