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
    Arc, Mutex,
};
use tower::ServiceExt;

struct Store {
    fault: String,
    expired: bool,
    missing: bool,
    empty_readback: bool,
    otp_hash: String,
    password_hash: Mutex<Option<String>>,
    marks: AtomicUsize,
    writes: AtomicUsize,
}
impl SessionRepository for Store {
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
        email: &'a str,
        kind: &'a str,
        id: &'a str,
    ) -> StoreFuture<'a, Option<String>> {
        Box::pin(async move {
            if self.fault == "lookup" {
                return Err(SessionStoreError);
            }
            Ok((!self.expired
                && email == "fake@example.test"
                && kind == "password_reset"
                && id == "otp_fixture")
                .then(|| self.otp_hash.clone()))
        })
    }
    fn otp_mark<'a>(&'a self, _: &'a str) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            if self.fault == "mark" {
                return Err(SessionStoreError);
            }
            self.marks.fetch_add(1, Ordering::SeqCst);
            Ok(())
        })
    }
    fn otp_verified_at<'a>(&'a self, _: &'a str) -> StoreFuture<'a, Option<String>> {
        Box::pin(async move {
            if self.fault == "readback" {
                return Err(SessionStoreError);
            }
            Ok((!self.empty_readback).then(|| "2026-01-02T03:04:05.000Z".into()))
        })
    }
    fn reset_password<'a>(&'a self, email: &'a str, hash: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async move {
            self.writes.fetch_add(1, Ordering::SeqCst);
            if self.fault == "write" {
                return Err(SessionStoreError);
            }
            if self.missing || email != "fake@example.test" {
                return Ok(0);
            }
            *self.password_hash.lock().unwrap() = Some(hash.into());
            Ok(1)
        })
    }
}

#[tokio::test]
async fn shared_password_reset() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/auth-password-reset.json"
    ))
    .unwrap();
    let cases = fixture["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 17);
    let otp_hash = bcrypt::hash("123456", 4).unwrap();
    for case in cases {
        let store = Arc::new(Store {
            fault: case["fault"].as_str().unwrap_or("").into(),
            expired: case["expired"].as_bool().unwrap_or(false),
            missing: case["missing_user"].as_bool().unwrap_or(false),
            empty_readback: case["empty_readback"].as_bool().unwrap_or(false),
            otp_hash: otp_hash.clone(),
            password_hash: Mutex::new(None),
            marks: AtomicUsize::new(0),
            writes: AtomicUsize::new(0),
        });
        let codec = TokenCodec::new(b"synthetic-access-key", b"synthetic-refresh-key").unwrap();
        let app = build_native_router(
            codec,
            store.clone(),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
        );
        let mut body = fixture["base"].as_object().unwrap().clone();
        for (key, value) in case["patch"].as_object().unwrap() {
            body.insert(key.clone(), value.clone());
        }
        let request = Request::builder()
            .method("POST")
            .uri("/api/v2/auth/password-reset")
            .header("content-type", "application/json")
            .header("cookie", "access_token=expired")
            .body(Body::from(Value::Object(body.clone()).to_string()))
            .unwrap();
        let response = app.oneshot(request).await.unwrap();
        assert_eq!(
            response.status().as_u16(),
            case["status"].as_u64().unwrap() as u16,
            "{}",
            case["id"]
        );
        assert_eq!(response.headers().get_all("set-cookie").iter().count(), 0);
        let text = String::from_utf8(
            response
                .into_body()
                .collect()
                .await
                .unwrap()
                .to_bytes()
                .to_vec(),
        )
        .unwrap();
        assert!(
            !text.contains("synthetic-new-password") && !text.contains("reset-private-fixture")
        );
        let result: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(result["message"], case["message"], "{}", case["id"]);
        assert_eq!(
            store.marks.load(Ordering::SeqCst),
            case["marks"].as_u64().unwrap() as usize,
            "{}",
            case["id"]
        );
        assert_eq!(
            store.writes.load(Ordering::SeqCst),
            case["writes"].as_u64().unwrap() as usize,
            "{}",
            case["id"]
        );
        if case["status"] == 200 {
            assert!(bcrypt::verify(
                body["new_password"].as_str().unwrap().trim(),
                store.password_hash.lock().unwrap().as_ref().unwrap()
            )
            .unwrap());
            assert_eq!(
                result,
                serde_json::json!({"code":200,"message":"password reset success","data":null,"meta":null})
            );
        }
    }
}
