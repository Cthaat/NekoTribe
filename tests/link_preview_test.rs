use axum::{body::Body, http::Request, Router};
use http_body_util::BodyExt;
use nekotribe_backend::auth::{
    sessions::{build_native_router, CorsPolicy, SessionRepository, StoreFuture},
    TokenClaims, TokenCodec,
};
use serde_json::Value;
use std::sync::Arc;
use tower::ServiceExt;

struct Repository;

impl SessionRepository for Repository {
    fn touch<'a>(&'a self, claims: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async move { Ok(u64::from(claims.user_id == 42)) })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
}

fn router() -> (Router, String) {
    let fixture: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = fixture["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|case| case["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    let codec = TokenCodec::new(
        fixture["keys"]["access"].as_str().unwrap().as_bytes(),
        fixture["keys"]["refresh"].as_str().unwrap().as_bytes(),
    )
    .unwrap();
    (
        build_native_router(
            codec,
            Arc::new(Repository),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
        ),
        format!("Bearer {token}"),
    )
}

async fn request(router: &Router, query: &str, token: Option<&str>) -> (u16, Value) {
    let mut request = Request::get(format!("/api/v2/links/preview?{query}"));
    if let Some(token) = token {
        request = request.header("authorization", token);
    }
    let response = router
        .clone()
        .oneshot(request.body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(response.headers()["cache-control"], "private, no-store");
    let status = response.status().as_u16();
    let body =
        serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes()).unwrap();
    (status, body)
}

#[tokio::test]
async fn link_preview_requires_a_session_and_rejects_unsafe_targets_without_dialing() {
    let (router, token) = router();
    assert_eq!(
        request(&router, "url=https%3A%2F%2Fexample.org", None)
            .await
            .0,
        401
    );
    let token = Some(token.as_str());
    for query in [
        "",
        "url=one&url=two",
        "url=http%3A%2F%2F127.0.0.1%2F",
        "url=https%3A%2F%2Fname%3Apass%40example.org",
    ] {
        let (status, body) = request(&router, query, token).await;
        assert_eq!(status, 400);
        assert_eq!(body["code"], 40001);
        assert!(body["data"].is_null());
        assert!(!body.to_string().contains("pass"));
    }
}
