use axum::{body::Body, http::Request, Router};
use http_body_util::BodyExt;
use nekotribe_backend::{
    app::routes::build_router,
    auth::{
        sessions::{build_native_router, CorsPolicy, SessionRepository, StoreFuture},
        TokenClaims, TokenCodec,
    },
    config::env::{AppConfig, BackendMode},
};
use serde_json::Value;
use std::sync::Arc;
use tower::ServiceExt;

struct UnusedStore;

impl SessionRepository for UnusedStore {
    fn touch<'a>(&'a self, _: &'a TokenClaims) -> StoreFuture<'a, u64> {
        panic!("retired routes must not authenticate");
    }

    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        panic!("retired routes must not revoke sessions");
    }

    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        panic!("retired routes must not revoke sessions");
    }
}

async fn assert_retirement(app: Router) {
    let policy: Value = serde_json::from_str(include_str!(
        "../contracts/requirements/sentiment-retirement.json"
    ))
    .unwrap();
    let scenarios: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/sentiment-retirement.json"
    ))
    .unwrap();
    for case in scenarios["cases"].as_array().unwrap() {
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(case["method"].as_str().unwrap())
                    .uri(case["path"].as_str().unwrap())
                    .header("content-type", "application/json")
                    .body(Body::from("{"))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            u64::from(response.status().as_u16()),
            case["status"].as_u64().unwrap(),
            "{}",
            case["id"]
        );
        assert_eq!(response.headers()["cache-control"], "private, no-store");
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        let body: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(body["code"], case["code"]);
        assert!(body["meta"].is_null());
        if case["status"] == 200 {
            assert_eq!(body["data"], policy["config"]);
        } else {
            assert!(body["data"].is_null());
            if case["status"] == 410 {
                assert_eq!(body["message"], policy["retiredMessage"]);
            }
        }
    }
}

#[tokio::test]
async fn native_retirement_does_not_use_oracle() {
    let codec = TokenCodec::new(
        b"isolated-retirement-access-key",
        b"isolated-retirement-refresh-key",
    )
    .unwrap();
    assert_retirement(build_native_router(
        codec,
        Arc::new(UnusedStore),
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_000),
    ))
    .await;
}

#[tokio::test]
async fn compat_retirement_does_not_use_the_upstream() {
    let mut config = AppConfig::for_test();
    config.backend_mode = BackendMode::Compat;
    config.legacy_backend.base_url = "http://127.0.0.1:1".into();
    assert_retirement(build_router(config)).await;
}
