use nekotribe_backend::{
    config::env::AppConfig,
    proxy::legacy::{build_upstream_url, is_known_v2_route},
};

#[test]
fn legacy_proxy_preserves_path_and_query_for_v2_storage_and_uploads() {
    let config = AppConfig::for_test();

    assert_eq!(
        build_upstream_url(
            &config.legacy_backend.base_url,
            &"/api/v2/posts?page=1&page_size=20".parse().unwrap()
        )
        .unwrap(),
        "http://127.0.0.1:30001/api/v2/posts?page=1&page_size=20"
    );
    assert_eq!(
        build_upstream_url(
            &config.legacy_backend.base_url,
            &"/storage/media/avatar.png".parse().unwrap()
        )
        .unwrap(),
        "http://127.0.0.1:30001/storage/media/avatar.png"
    );
    assert_eq!(
        build_upstream_url(
            &config.legacy_backend.base_url,
            &"/uploads/old.png".parse().unwrap()
        )
        .unwrap(),
        "http://127.0.0.1:30001/uploads/old.png"
    );
}

#[test]
fn legacy_proxy_rejects_non_http_base_url() {
    assert!(build_upstream_url("file:///tmp", &"/api/v2/users/me".parse().unwrap()).is_err());
}

#[test]
fn legacy_proxy_only_forwards_known_v2_routes() {
    assert!(is_known_v2_route("GET", "/api/v2/posts"));
    assert!(is_known_v2_route("GET", "/api/v2/users/100001/posts"));
    assert!(is_known_v2_route(
        "POST",
        "/api/v2/integrations/sentiment-flow/predict"
    ));
    assert!(!is_known_v2_route("GET", "/api/v2/not-exists"));
}

#[tokio::test]
async fn preflight_preserves_upstream_cors_policy_and_rejects_unknown_routes() {
    use axum::{
        body::Body,
        http::{header, HeaderMap, Request, StatusCode},
        routing::options,
        Router,
    };
    use nekotribe_backend::app::routes::build_router;
    use tower::ServiceExt;

    let upstream = Router::new().route(
        "/api/v2/auth/tokens",
        options(|headers: HeaderMap| async move {
            assert_eq!(headers[header::ACCESS_CONTROL_REQUEST_METHOD], "POST");
            let mut response_headers = HeaderMap::new();
            if headers[header::ORIGIN] == "http://localhost:5173" {
                response_headers.insert(
                    header::ACCESS_CONTROL_ALLOW_ORIGIN,
                    headers[header::ORIGIN].clone(),
                );
            }
            (StatusCode::NO_CONTENT, response_headers)
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move { axum::serve(listener, upstream).await.unwrap() });
    let mut config = AppConfig::for_test();
    config.legacy_backend.base_url = format!("http://{address}");
    let app = build_router(config);

    for origin in ["http://localhost:5173", "https://untrusted.example"] {
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("OPTIONS")
                    .uri("/api/v2/auth/tokens")
                    .header(header::ORIGIN, origin)
                    .header(header::ACCESS_CONTROL_REQUEST_METHOD, "POST")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NO_CONTENT);
        assert_eq!(
            response
                .headers()
                .get(header::ACCESS_CONTROL_ALLOW_ORIGIN)
                .is_some(),
            origin == "http://localhost:5173"
        );
    }
    let response = app
        .oneshot(
            Request::builder()
                .method("OPTIONS")
                .uri("/api/v2/not-exists")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
    assert!(!is_known_v2_route("OPTIONS", "/api/v2/posts/1/nonexistent"));
    assert!(is_known_v2_route("OPTIONS", "/api/v2/users/100001/posts"));
    server.abort();
}
