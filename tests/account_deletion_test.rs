use axum::{body::Body, http::Request};
use http_body_util::BodyExt;
use nekotribe_backend::auth::{
    sessions::{build_native_router, CorsPolicy, SessionRepository, StoreFuture},
    TokenClaims, TokenCodec,
};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;
struct Store {
    case: Value,
    writes: Mutex<u64>,
    hash: String,
}
impl SessionRepository for Store {
    fn account_credential(
        &self,
        _: u64,
    ) -> StoreFuture<'_, Option<nekotribe_backend::auth::login::LoginAccount>> {
        Box::pin(async move {
            if self.case["fault"] == "credential" {
                return Err(nekotribe_backend::auth::sessions::SessionStoreError);
            }
            Ok(Some(nekotribe_backend::auth::login::LoginAccount {
                user_id: 42,
                username: "tester".into(),
                password_hash: self.hash.clone(),
                status: "active".into(),
                active: self.case["fault"] != "inactive",
            }))
        })
    }
    fn delete_account_atomic<'a>(
        &'a self,
        user: u64,
        old: &'a str,
        new: &'a str,
    ) -> StoreFuture<'a, bool> {
        Box::pin(async move {
            assert_eq!(user, 42);
            assert_eq!(old, self.hash);
            assert!(!bcrypt::verify("test-password", new).unwrap());
            let fault = self.case["fault"].as_str().unwrap_or("");
            if fault == "changed" {
                return Ok(false);
            }
            if fault == "commit_applied" {
                *self.writes.lock().unwrap() += 1;
                return Err(nekotribe_backend::auth::sessions::SessionStoreError);
            }
            if !fault.is_empty() && fault != "presence" {
                return Err(nekotribe_backend::auth::sessions::SessionStoreError);
            }
            *self.writes.lock().unwrap() += 1;
            Ok(true)
        })
    }
    fn touch<'a>(&'a self, _: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async move { Ok(u64::from(self.case["auth"] != "revoked")) })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn login_profile(&self, _: u64) -> StoreFuture<'_, Option<Value>> {
        Box::pin(async move {
            if self.case["fault"] == "profile" {
                return Err(nekotribe_backend::auth::sessions::SessionStoreError);
            }
            Ok(
                (self.case["fault"] != "missing")
                    .then(|| json!({"user_id":42,"username":"tester"})),
            )
        })
    }
}
#[tokio::test]
async fn shared_account_deletion() {
    let f: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/auth-account-deletion.json"
    ))
    .unwrap();
    let tokens: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = tokens["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    let hash = bcrypt::hash("test-password", 4).unwrap();
    for c in f["cases"].as_array().unwrap() {
        let store = Arc::new(Store {
            case: c.clone(),
            writes: Mutex::new(0),
            hash: hash.clone(),
        });
        let codec = TokenCodec::new(
            tokens["keys"]["access"].as_str().unwrap().as_bytes(),
            tokens["keys"]["refresh"].as_str().unwrap().as_bytes(),
        )
        .unwrap();
        let app = build_native_router(
            codec,
            store.clone(),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
        );
        let mut body = f["base"].clone();
        for (k, v) in c["patch"].as_object().unwrap() {
            body[k] = v.clone()
        }
        let mut req = Request::builder()
            .method("DELETE")
            .uri("/api/v2/users/me")
            .header("content-type", "application/json");
        if c["auth"] != "none" {
            req = req.header("authorization", format!("Bearer {token}"));
        }
        let res = app
            .oneshot(req.body(Body::from(body.to_string())).unwrap())
            .await
            .unwrap();
        assert_eq!(
            res.status().as_u16(),
            c["status"].as_u64().unwrap() as u16,
            "{}",
            c["id"]
        );
        assert_eq!(*store.writes.lock().unwrap(), c["writes"].as_u64().unwrap());
        assert_eq!(
            res.headers().get_all("set-cookie").iter().count(),
            if c["status"] == 200 { 2 } else { 0 }
        );
        let data: Value =
            serde_json::from_slice(&res.into_body().collect().await.unwrap().to_bytes()).unwrap();
        if c["message"].is_string() {
            assert_eq!(data["message"], c["message"]);
        }
    }
}
