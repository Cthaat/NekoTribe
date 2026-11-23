use std::time::Instant;

use axum::{body::Body, extract::MatchedPath, http::Request, middleware::Next, response::Response};

use crate::httpx::request::redact_query_pairs;

pub async fn observe_request(request: Request<Body>, next: Next) -> Response {
    if request.uri().path() == crate::observability::contract().metrics_path {
        return next.run(request).await;
    }
    let start = Instant::now();
    let method = request.method().clone();
    let path = request.extensions().get::<MatchedPath>().cloned();
    let id = request
        .extensions()
        .get::<super::request_id::RequestId>()
        .cloned();
    let response = next.run(request).await;
    let elapsed = start.elapsed();
    crate::observability::metrics().http(&method, response.status(), elapsed);
    tracing::info!(
        event = "http.complete",
        request_id = id.as_ref().map(|id| id.0.as_str()),
        %method,
        path = path.as_ref().map_or("[unmatched]", MatchedPath::as_str),
        status = response.status().as_u16(),
        duration_ms = elapsed.as_millis() as u64,
        "HTTP request completed"
    );
    response
}

pub async fn log_request_response(request: Request<Body>, next: Next) -> Response {
    let start = Instant::now();
    let method = request.method().clone();
    let uri = request.uri().clone();
    let sanitized_query = uri
        .query()
        .map(|query| sanitize_query(uri.path(), query))
        .unwrap_or_default();
    let path = if uri.path().starts_with("/api/v2/groups/invite-codes/") {
        "/api/v2/groups/invite-codes/[invite]"
    } else if uri.path().starts_with("/api/v2/users/me/passkeys/") {
        "/api/v2/users/me/passkeys/[credential]"
    } else {
        uri.path()
    };

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

fn sanitize_query(path: &str, query: &str) -> String {
    if path.trim_end_matches('/') == "/api/v2/links/preview"
        || path.trim_end_matches('/') == "/api/v2/auth/oauth/github/callback"
        || path.starts_with("/api/v2/auth/passkeys/")
        || path.starts_with("/api/v2/users/me/passkeys")
    {
        return "[redacted]".into();
    }
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
            sanitize_query("/api/v2/posts", "page=2&password=secret&access_token=token"),
            "page=2&password=[redacted]&access_token=[redacted]"
        );
    }

    #[test]
    fn link_preview_query_is_redacted_as_a_whole() {
        assert_eq!(
            sanitize_query("/api/v2/links/preview", "url=fixture&unknown=fixture"),
            "[redacted]"
        );
    }

    #[test]
    fn github_oauth_callback_query_is_redacted_as_a_whole() {
        assert_eq!(
            sanitize_query(
                "/api/v2/auth/oauth/github/callback",
                "state=fixture&code=fixture&error_description=fixture",
            ),
            "[redacted]"
        );
    }
}
