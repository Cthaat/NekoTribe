use axum::{
    body::{to_bytes, Body},
    http::{Request, StatusCode},
};
use nekotribe_backend::storage::local_http::{self, LocalStorageConfig};
use std::{fs, path::PathBuf};
use tower::ServiceExt;

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("neko-storage-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(path.join("images")).unwrap();
        fs::write(path.join("images/cat.png"), b"0123456789").unwrap();
        fs::write(path.join("images/empty.txt"), b"").unwrap();
        Self(path)
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[tokio::test]
async fn public_file_http_enforces_rules_and_streams_ranges() {
    let fixture = Fixture::new();
    let app = local_http::router(LocalStorageConfig {
        root: fixture.0.clone(),
        unsupported: false,
    });
    for (url, range, status, expected, content_range) in [
        ("/storage/images/cat.png", "", 200, "0123456789", ""),
        (
            "/storage/images/cat.png",
            "bytes=2-4",
            206,
            "234",
            "bytes 2-4/10",
        ),
        (
            "/storage/images/cat.png",
            "bytes=-3",
            206,
            "789",
            "bytes 7-9/10",
        ),
        (
            "/storage/images/cat.png",
            "bytes=20-",
            416,
            "",
            "bytes */10",
        ),
        (
            "/storage/images/empty.txt",
            "bytes=0-",
            416,
            "",
            "bytes */0",
        ),
        ("/storage/%2e%2e/secret", "", 400, "", ""),
        ("/storage/temp/private", "", 404, "", ""),
        ("/storage/images", "", 404, "", ""),
    ] {
        let mut req = Request::builder().uri(url);
        if !range.is_empty() {
            req = req.header("range", range);
        }
        let response = app
            .clone()
            .oneshot(req.body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), status, "{url} {range}");
        assert_eq!(
            response
                .headers()
                .get("content-range")
                .and_then(|v| v.to_str().ok())
                .unwrap_or(""),
            content_range
        );
        if status == 200 {
            assert_eq!(response.headers()["x-content-type-options"], "nosniff");
        }
        let body = to_bytes(response.into_body(), 1024).await.unwrap();
        if !expected.is_empty() {
            assert_eq!(&body[..], expected.as_bytes());
        }
    }
    let response = app
        .oneshot(
            Request::builder()
                .uri("/storage/default-avatar.png")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.headers()["content-type"], "image/png");
}

#[cfg(unix)]
#[tokio::test]
async fn rejects_symlink_even_when_target_is_inside_root() {
    let fixture = Fixture::new();
    std::os::unix::fs::symlink(fixture.0.join("images"), fixture.0.join("link")).unwrap();
    let app = local_http::router(LocalStorageConfig {
        root: fixture.0.clone(),
        unsupported: false,
    });
    let response = app
        .oneshot(
            Request::builder()
                .uri("/storage/link/cat.png")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn native_router_uses_configured_storage_without_nuxt() {
    use nekotribe_backend::{app::routes::build_router, config::env::AppConfig};
    let fixture = Fixture::new();
    let root = fixture.0.to_string_lossy().to_string();
    let config = AppConfig::native_from_lookup(|key| match key {
        "ACCESS_SECRET" => Some("access-private".into()),
        "REFRESH_SECRET" => Some("refresh-private".into()),
        "ORACLE_HOST" => Some("not-used.invalid".into()),
        "ORACLE_SERVICE_NAME" | "ORACLE_USER" | "ORACLE_PASSWORD" => Some("unused".into()),
        "STORAGE_PATH" => Some(root.clone()),
        _ => None,
    })
    .unwrap();
    let response = build_router(config)
        .oneshot(
            Request::builder()
                .uri("/storage/images/cat.png")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        &to_bytes(response.into_body(), 1024).await.unwrap()[..],
        b"0123456789"
    );
}

#[tokio::test]
async fn s3_does_not_fall_back_to_local() {
    let fixture = Fixture::new();
    let root = fixture.0.to_string_lossy().to_string();
    let config = LocalStorageConfig::from_lookup(|key| match key {
        "STORAGE_PATH" => Some(format!(" {root} ")),
        "STORAGE_ROOT_DIR" => Some("ignored".into()),
        "STORAGE_TYPE" => Some("s3".into()),
        _ => None,
    });
    assert_eq!(config.root, fixture.0);
    let response = local_http::router(config)
        .oneshot(
            Request::builder()
                .uri("/storage/images/cat.png")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_IMPLEMENTED);
}
