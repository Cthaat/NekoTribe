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

struct Store {
    touches: AtomicUsize,
    profiles: AtomicUsize,
    revoked: bool,
    touch_fail: bool,
    missing: bool,
    fault: bool,
    profile: Value,
}
impl SessionRepository for Store {
    fn touch<'a>(&'a self, claims: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async move {
            self.touches.fetch_add(1, Ordering::SeqCst);
            if self.touch_fail {
                return Err(SessionStoreError);
            };
            Ok(u64::from(
                !self.revoked && claims.user_id == 42 && claims.session_id == "fixture-session-42",
            ))
        })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn login_profile<'a>(&'a self, user: u64) -> StoreFuture<'a, Option<Value>> {
        Box::pin(async move {
            self.profiles.fetch_add(1, Ordering::SeqCst);
            if self.fault || user != 42 {
                return Err(SessionStoreError);
            };
            Ok((!self.missing).then(|| self.profile.clone()))
        })
    }
}

#[tokio::test]
async fn shared_self_profile() {
    let f: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/user-self-profile.json"
    ))
    .unwrap();
    let tokens: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = |id: &str| {
        tokens["cases"]
            .as_array()
            .unwrap()
            .iter()
            .find(|v| v["id"] == id)
            .unwrap()["token"]
            .as_str()
            .unwrap()
    };
    let cases = f["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 10);
    for tc in cases {
        let store = Arc::new(Store {
            touches: AtomicUsize::new(0),
            profiles: AtomicUsize::new(0),
            revoked: tc["revoked"].as_bool().unwrap_or(false),
            touch_fail: tc["touch_fail"].as_bool().unwrap_or(false),
            missing: tc["missing"].as_bool().unwrap_or(false),
            fault: tc["fault"].as_bool().unwrap_or(false),
            profile: f["profile"].clone(),
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
        let uri = format!("/api/v2/users/me{}", tc["query"].as_str().unwrap_or(""));
        let mut req = Request::builder().uri(uri);
        match tc["auth"].as_str().unwrap() {
            "valid" => {
                req = req.header("authorization", format!("Bearer {}", token("access-hs256")))
            }
            "cookie" => {
                req = req.header("cookie", format!("access_token={}", token("access-hs256")))
            }
            "bad-cookie" => {
                req = req
                    .header("authorization", format!("Bearer {}", token("access-hs256")))
                    .header("cookie", "access_token=bad")
            }
            "expired" => req = req.header("authorization", format!("Bearer {}", token("expired"))),
            _ => {}
        }
        let response = app.oneshot(req.body(Body::empty()).unwrap()).await.unwrap();
        assert_eq!(
            response.status().as_u16(),
            tc["status"].as_u64().unwrap() as u16,
            "{}",
            tc["id"]
        );
        assert_eq!(response.headers().get_all("set-cookie").iter().count(), 0);
        if tc["status"] == 200 {
            assert_eq!(
                response.headers().get("cache-control").unwrap(),
                "private, no-store"
            );
        }
        assert_eq!(
            store.touches.load(Ordering::SeqCst),
            tc["touches"].as_u64().unwrap() as usize,
            "{}",
            tc["id"]
        );
        assert_eq!(
            store.profiles.load(Ordering::SeqCst),
            tc["profiles"].as_u64().unwrap() as usize,
            "{}",
            tc["id"]
        );
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
        assert!(!text.contains("private-profile-fixture"));
        if tc["status"] == 200 {
            let payload: Value = serde_json::from_str(&text).unwrap();
            assert_eq!(
                payload,
                serde_json::json!({"code":200,"message":"success","data":f["profile"],"meta":null})
            );
        }
    }
}

#[tokio::test]
async fn self_profile_respects_storage_address_and_redacts_credentials() {
    use nekotribe_backend::auth::{
        sessions::{build_native_router_with_storage, RefreshPolicy},
        storage_urls::StorageUrlPolicy,
    };
    let f: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/user-self-profile.json"
    ))
    .unwrap();
    let tokens: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = tokens["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    for (base, status, avatar) in [
        (
            "https://cdn.example.test",
            200,
            "https://cdn.example.test/storage/default-avatar.png",
        ),
        ("https://user:synthetic-secret@example.test", 500, ""),
    ] {
        let store = Arc::new(Store {
            touches: AtomicUsize::new(0),
            profiles: AtomicUsize::new(0),
            revoked: false,
            touch_fail: false,
            missing: false,
            fault: false,
            profile: f["profile"].clone(),
        });
        let codec = TokenCodec::new(
            tokens["keys"]["access"].as_str().unwrap().as_bytes(),
            tokens["keys"]["refresh"].as_str().unwrap().as_bytes(),
        )
        .unwrap();
        let storage =
            StorageUrlPolicy::from_lookup(|key| (key == "BASE_URL").then(|| base.to_owned()));
        let app = build_native_router_with_storage(
            codec,
            store,
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
            RefreshPolicy::default(),
            storage,
        );
        let req = Request::builder()
            .uri("/api/v2/users/me")
            .header("authorization", format!("Bearer {token}"))
            .body(Body::empty())
            .unwrap();
        let response = app.oneshot(req).await.unwrap();
        assert_eq!(response.status().as_u16(), status);
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
        assert!(!text.contains("synthetic-secret"));
        if status == 200 {
            let result: Value = serde_json::from_str(&text).unwrap();
            assert_eq!(result["data"]["avatar_url"], avatar);
        }
    }
}
