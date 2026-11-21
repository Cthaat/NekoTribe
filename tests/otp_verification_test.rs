#[path = "support/otp_attempt.rs"]
mod otp_attempt;

use axum::{body::Body, http::Request};
use http_body_util::BodyExt;
use nekotribe_backend::auth::{
    sessions::{
        build_native_router, CorsPolicy, SessionRepository, SessionStoreError, StoreFuture,
    },
    TokenClaims, TokenCodec,
};
use serde_json::Value;
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};
use tower::ServiceExt;

struct Fake {
    base: Value,
    expired: bool,
    fault: String,
    updates: AtomicUsize,
}
impl SessionRepository for Fake {
    fn touch<'a>(&'a self, _: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn otp_lookup<'a>(
        &'a self,
        account: &'a str,
        kind: &'a str,
        id: &'a str,
    ) -> StoreFuture<'a, Option<String>> {
        Box::pin(async move {
            if self.fault == "lookup" {
                return Err(SessionStoreError);
            };
            Ok((!self.expired
                && self.base["account"] == account
                && self.base["type"] == kind
                && self.base["verification_id"] == id)
                .then(|| self.base["hash"].as_str().unwrap().to_owned()))
        })
    }
    fn otp_mark<'a>(&'a self, _: &'a str) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            if self.fault == "update" {
                return Err(SessionStoreError);
            };
            self.updates.fetch_add(1, Ordering::SeqCst);
            Ok(())
        })
    }
    fn otp_verified_at<'a>(&'a self, _: &'a str) -> StoreFuture<'a, Option<String>> {
        Box::pin(async move {
            if self.fault == "readback" {
                return Err(SessionStoreError);
            };
            Ok(Some(self.base["verified_at"].as_str().unwrap().into()))
        })
    }
}
#[tokio::test]
async fn shared_otp_verification() {
    let f: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/auth-otp-verification.json"
    ))
    .unwrap();
    let cases = f["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 18);
    for case in cases {
        let repo = Arc::new(Fake {
            base: f["fixture"].clone(),
            expired: case["expired"].as_bool().unwrap_or(false),
            fault: case["fault"].as_str().unwrap_or("").into(),
            updates: AtomicUsize::new(0),
        });
        let codec = TokenCodec::new(b"synthetic-access-key", b"synthetic-refresh-key").unwrap();
        let app = build_native_router(
            codec,
            repo.clone(),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
        )
        .layer(otp_attempt::fixture(match case["fault"].as_str() {
            Some("exhausted") => 429,
            Some("unavailable") => 503,
            _ => 200,
        }));
        let n = if case["repeat"].as_bool().unwrap_or(false) {
            2
        } else {
            1
        };
        for _ in 0..n {
            let req = Request::builder()
                .method("POST")
                .uri("/api/v2/auth/otp/verification")
                .header("content-type", "application/json")
                .header("cookie", "access_token=expired")
                .body(Body::from(case["body"].to_string()))
                .unwrap();
            let response = app.clone().oneshot(req).await.unwrap();
            assert_eq!(
                response.status().as_u16(),
                case["status"].as_u64().unwrap() as u16,
                "{}",
                case["id"]
            );
            assert_eq!(response.headers().get_all("set-cookie").iter().count(), 0);
            let bytes = response.into_body().collect().await.unwrap().to_bytes();
            let text = String::from_utf8(bytes.to_vec()).unwrap();
            assert!(!text.contains("private"));
            if case["status"] == 200 {
                let body: Value = serde_json::from_str(&text).unwrap();
                assert_eq!(body["data"]["account"], f["fixture"]["account"]);
                assert_eq!(body["data"]["verified"], true);
                assert_eq!(body["data"]["verified_at"], f["fixture"]["verified_at"]);
            }
        }
        assert_eq!(
            repo.updates.load(Ordering::SeqCst),
            case["updates"].as_u64().unwrap() as usize,
            "{}",
            case["id"]
        );
    }
}
