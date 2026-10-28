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
    calls: AtomicUsize,
    revoked: bool,
    touch_fail: bool,
    missing: bool,
    fault: bool,
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
    fn public_profile<'a>(&'a self, viewer: u64, target: u64) -> StoreFuture<'a, Option<Value>> {
        Box::pin(async move {
            self.calls.fetch_add(1, Ordering::SeqCst);
            if self.fault || viewer != 42 || (target != 7 && target != 9_007_199_254_740_991) {
                return Err(SessionStoreError);
            };
            Ok((!self.missing).then(|| self.profile.clone()))
        })
    }
}
#[tokio::test]
async fn shared_public_profile() {
    let data: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/user-public-profile.json"
    ))
    .unwrap();
    let tokens: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
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
    assert_eq!(cases.len(), 21);
    for tc in cases {
        let flag = |k: &str| tc[k].as_bool().unwrap_or(false);
        let mut profile = data["profile"].clone();
        if flag("hidden") {
            profile["online_status"] = "hidden".into();
            profile["last_seen_at"] = Value::Null
        }
        if flag("offline") {
            profile["online_status"] = "offline".into()
        }
        let s = Arc::new(Store {
            calls: AtomicUsize::new(0),
            revoked: flag("revoked"),
            touch_fail: flag("touch_fail"),
            missing: flag("missing"),
            fault: flag("fault"),
            profile: profile.clone(),
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
        let mut req = Request::builder().uri(format!(
            "/api/v2/users/{}?viewer_id=99",
            tc["target"].as_str().unwrap()
        ));
        req = match tc["auth"].as_str().unwrap() {
            "valid" => req.header("authorization", format!("Bearer {}", token("access-hs256"))),
            "cookie" => req.header("cookie", format!("access_token={}", token("access-hs256"))),
            "bad-cookie" => req
                .header("cookie", "access_token=bad")
                .header("authorization", format!("Bearer {}", token("access-hs256"))),
            "expired" => req.header("authorization", format!("Bearer {}", token("expired"))),
            _ => req,
        };
        let response = app.oneshot(req.body(Body::empty()).unwrap()).await.unwrap();
        assert_eq!(
            response.status().as_u16(),
            tc["status"].as_u64().unwrap() as u16,
            "{}",
            tc["id"]
        );
        assert_eq!(
            s.calls.load(Ordering::SeqCst),
            tc["profiles"].as_u64().unwrap() as usize,
            "{}",
            tc["id"]
        );
        if tc["status"] == 200 {
            assert_eq!(response.headers()["cache-control"], "private, no-store")
        };
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        let text = String::from_utf8(bytes.to_vec()).unwrap();
        assert!(!text.contains("private-profile-error"));
        if tc["status"] == 200 {
            let v: Value = serde_json::from_str(&text).unwrap();
            assert_eq!(v["data"], profile);
            for k in ["email", "phone", "birth_date", "password"] {
                assert!(v["data"].get(k).is_none())
            }
        }
    }
}
