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
