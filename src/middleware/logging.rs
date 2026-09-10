use std::time::Instant;

use axum::{body::Body, http::Request, middleware::Next, response::Response};

use crate::httpx::request::redact_query_pairs;

pub async fn log_request_response(request: Request<Body>, next: Next) -> Response {
    let start = Instant::now();
    let method = request.method().clone();
    let uri = request.uri().clone();
    let sanitized_query = uri.query().map(sanitize_query).unwrap_or_default();
    let path = uri.path().to_string();

    tracing::info!(
        %method,
        %path,
        query = %sanitized_query,
        "http request"
    );

    let response = next.run(request).await;
    tracing::info!(
        %method,
        %path,
        status = response.status().as_u16(),
        duration_ms = start.elapsed().as_millis(),
        "http response"
    );
    response
}

fn sanitize_query(query: &str) -> String {
    let pairs = query.split('&').filter_map(|pair| {
        let mut parts = pair.splitn(2, '=');
        let key = parts.next()?;
        let value = parts.next().unwrap_or_default();
        Some((key, value))
    });

    redact_query_pairs(pairs)
        .into_iter()
        .map(|(key, value)| format!("{key}={value}"))
        .collect::<Vec<_>>()
        .join("&")
}

#[cfg(test)]
mod tests {
    use super::sanitize_query;

    #[test]
    fn sanitize_query_keeps_public_values_and_redacts_sensitive_values() {
        assert_eq!(
            sanitize_query("page=2&password=secret&access_token=token"),
            "page=2&password=[redacted]&access_token=[redacted]"
        );
    }
}
