use axum::{body::Body, http::Request};
use http_body_util::BodyExt;
use nekotribe_backend::auth::{
    sessions::{
        build_native_router, CorsPolicy, SessionRepository, SessionStoreError, StoreFuture,
    },
    TokenClaims, TokenCodec,
};
use serde_json::Value;
use std::{
    collections::BTreeMap,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, Mutex,
    },
};
use tower::ServiceExt;
struct Store {
    writes: AtomicUsize,
    profiles: AtomicUsize,
    fields: Mutex<BTreeMap<String, String>>,
    revoked: bool,
    touch_fail: bool,
    update_fail: bool,
    profile_fail: bool,
    missing: bool,
    profile: Value,
}
impl SessionRepository for Store {
    fn touch<'a>(&'a self, c: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async move {
            if self.touch_fail {
                return Err(SessionStoreError);
            };
            Ok(u64::from(!self.revoked && c.user_id == 42))
        })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn update_self_profile<'a>(
        &'a self,
        user: u64,
        fields: &'a BTreeMap<String, String>,
    ) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            self.writes.fetch_add(1, Ordering::SeqCst);
            *self.fields.lock().unwrap() = fields.clone();
            if user != 42 || self.update_fail {
                return Err(SessionStoreError);
            };
            Ok(())
        })
    }
    fn login_profile<'a>(&'a self, user: u64) -> StoreFuture<'a, Option<Value>> {
        Box::pin(async move {
            self.profiles.fetch_add(1, Ordering::SeqCst);
            if user != 42 || self.profile_fail {
                return Err(SessionStoreError);
            };
            Ok((!self.missing).then(|| self.profile.clone()))
        })
    }
}
#[tokio::test]
async fn shared_profile_updates() {
    let data: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/user-self-profile-update.json"
    ))
    .unwrap();
    let tokens: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let profile: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/user-self-profile.json"
    ))
    .unwrap();
    let token = |id: &str| {
        tokens["cases"]
            .as_array()
            .unwrap()
            .iter()
            .find(|x| x["id"] == id)
            .unwrap()["token"]
            .as_str()
            .unwrap()
    };
    let cases = data["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 18);
    for tc in cases {
        let flag = |key: &str| tc[key].as_bool().unwrap_or(false);
        let s = Arc::new(Store {
            writes: AtomicUsize::new(0),
            profiles: AtomicUsize::new(0),
            fields: Mutex::new(BTreeMap::new()),
            revoked: flag("revoked"),
            touch_fail: flag("touch_fail"),
            update_fail: flag("update_fail"),
            profile_fail: flag("profile_fail"),
            missing: flag("missing"),
            profile: profile["profile"].clone(),
        });
        let codec = TokenCodec::new(
            tokens["keys"]["access"].as_str().unwrap().as_bytes(),
            tokens["keys"]["refresh"].as_str().unwrap().as_bytes(),
        )
        .unwrap();
        let app = build_native_router(
            codec,
            s.clone(),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
        );
        let mut req = Request::builder()
            .method("PATCH")
            .uri("/api/v2/users/me?user_id=99")
            .header("content-type", "application/json");
        req = match tc["auth"].as_str().unwrap() {
            "valid" => req.header("authorization", format!("Bearer {}", token("access-hs256"))),
            "cookie" => req.header("cookie", format!("access_token={}", token("access-hs256"))),
            "bad-cookie" => req
                .header("cookie", "access_token=bad")
                .header("authorization", format!("Bearer {}", token("access-hs256"))),
            "expired" => req.header("authorization", format!("Bearer {}", token("expired"))),
            _ => req,
        };
        let response = app
            .oneshot(req.body(Body::from(tc["body"].to_string())).unwrap())
            .await
            .unwrap();
        assert_eq!(
            response.status().as_u16(),
            tc["status"].as_u64().unwrap() as u16,
            "{}",
            tc["id"]
        );
        assert_eq!(
            s.writes.load(Ordering::SeqCst),
            tc["updates"].as_u64().unwrap() as usize,
            "{}",
            tc["id"]
        );
        assert_eq!(
            s.profiles.load(Ordering::SeqCst),
            tc["profiles"].as_u64().unwrap() as usize,
            "{}",
            tc["id"]
        );
        if s.writes.load(Ordering::SeqCst) > 0 {
            assert_eq!(
                serde_json::to_value(&*s.fields.lock().unwrap()).unwrap(),
                tc["fields"]
            )
        }
        if tc["status"] == 200 {
            assert_eq!(response.headers()["cache-control"], "private, no-store");
            assert_eq!(response.headers().get_all("set-cookie").iter().count(), 0)
        }
        let body = response.into_body().collect().await.unwrap().to_bytes();
        assert!(!String::from_utf8_lossy(&body).contains("private-"));
    }
}
