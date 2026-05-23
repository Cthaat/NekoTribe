use axum::{body::Body, http::Request, middleware::Next, response::Response};

pub async fn cache_passthrough(request: Request<Body>, next: Next) -> Response {
    next.run(request).await
}
