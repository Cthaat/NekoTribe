#[path = "support/otp_attempt.rs"]
mod otp_attempt;

use axum::{body::Body, http::Request};
use http_body_util::BodyExt;
use nekotribe_backend::{
    auth::{
        sessions::{
            build_native_router, CorsPolicy, SessionRepository, SessionStoreError, StoreFuture,
        },
        TokenClaims, TokenCodec,
    },
    users::email_change::{EmailChange, EmailChangeData},
};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

struct Store {
    case: Value,
    hash: String,
    counts: Mutex<(u64, u64)>,
}
impl SessionRepository for Store {
    fn touch<'a>(&'a self, claims: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async move {
            Ok(u64::from(
                self.case["auth"] != "revoked" && claims.user_id == 42,
            ))
        })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn email_in_use<'a>(&'a self, user: u64, _email: &'a str) -> StoreFuture<'a, bool> {
        Box::pin(async move {
            if self.case["fault"] == "duplicate" || user != 42 {
                return Err(SessionStoreError);
            };
            Ok(self.case["duplicate"] == true)
        })
    }
    fn otp_lookup<'a>(
        &'a self,
        email: &'a str,
        kind: &'a str,
        id: &'a str,
    ) -> StoreFuture<'a, Option<String>> {
        Box::pin(async move {
            if self.case["fault"] == "lookup" {
                return Err(SessionStoreError);
            }
            Ok((self.case["expired"] != true
                && self.counts.lock().unwrap().0 == 0
                && email == "new@example.test"
                && kind == "change_email"
                && id == "email_fixture")
                .then(|| self.hash.clone()))
        })
    }
    fn change_email_atomic<'a>(
        &'a self,
        user: u64,
        email: &'a str,
        id: &'a str,
        hash: &'a str,
    ) -> StoreFuture<'a, EmailChange> {
        Box::pin(async move {
            let mut counts = self.counts.lock().unwrap();
            if self.case["fault"] == "commit" && self.case["commit_applied"] == true {
                counts.0 += 1;
                counts.1 += 1;
                return Err(SessionStoreError);
            }
            if self.case["fault"].as_str().is_some_and(|f| !f.is_empty())
                || self.case["claim_count"].as_u64().unwrap_or(1) > 1
                || self.case["write_count"].as_u64().unwrap_or(1) > 1
            {
                return Err(SessionStoreError);
            }
            if self.case["lost_race"] == true || counts.0 > 0 {
                return Ok(EmailChange::Expired);
            }
            if self.case["missing_user"] == true {
                return Ok(EmailChange::UserMissing);
            }
            if self.case["unique_race"] == true {
                return Ok(EmailChange::Conflict);
            }
            if user != 42
                || email != "new@example.test"
                || id != "email_fixture"
                || hash != self.hash
            {
                return Err(SessionStoreError);
            }
            counts.0 += 1;
            counts.1 += 1;
            Ok(EmailChange::Committed(EmailChangeData {
                email: email.into(),
                email_verified_at: "2026-01-02T03:04:05.000Z".into(),
            }))
        })
    }
}
fn app(store: Arc<Store>) -> (axum::Router, String) {
    let tokens: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let codec = TokenCodec::new(
        tokens["keys"]["access"].as_str().unwrap().as_bytes(),
        tokens["keys"]["refresh"].as_str().unwrap().as_bytes(),
    )
    .unwrap();
    let token = tokens["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap()
        .to_owned();
    (
        build_native_router(
            codec,
            store,
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
        ).layer(otp_attempt::fixture(200)),
        token,
    )
}
#[tokio::test]
async fn shared_email_change() {
    let f: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/auth-email-change.json"
    ))
    .unwrap();
    let cases = f["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 25);
    let hash = bcrypt::hash("123456", 4).unwrap();
    for c in cases {
        let store = Arc::new(Store {
            case: c.clone(),
            hash: hash.clone(),
            counts: Mutex::new((0, 0)),
        });
        let (app, token) = app(store.clone());
        let mut body = f["base"].as_object().unwrap().clone();
        for (k, v) in c["patch"].as_object().unwrap() {
            body.insert(k.clone(), v.clone());
        }
        let mut req = Request::builder()
            .method("PATCH")
            .uri("/api/v2/users/me/email")
            .header("content-type", "application/json");
        if c["auth"] != "none" {
            req = req.header("authorization", format!("Bearer {token}"))
        }
        let response = app
            .oneshot(
                req.body(Body::from(Value::Object(body).to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            response.status().as_u16(),
            c["status"].as_u64().unwrap() as u16,
            "{}",
            c["id"]
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
        assert!(!text.contains("123456") && !text.contains("email-private-fixture"));
        let result: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(result["message"], c["message"], "{}", c["id"]);
        assert_eq!(
            *store.counts.lock().unwrap(),
            (c["marks"].as_u64().unwrap(), c["writes"].as_u64().unwrap())
        );
        if c["status"] == 200 {
            assert_eq!(
                result["data"],
                json!({"email":"new@example.test","email_verified_at":f["verified_at"]})
            );
        }
    }
}

#[tokio::test]
async fn email_change_form_replay_and_concurrent_claims() {
    let store = Arc::new(Store {
        case: json!({}),
        hash: bcrypt::hash("123456", 4).unwrap(),
        counts: Mutex::new((0, 0)),
    });
    let (app, token) = app(store.clone());
    let form = || {
        Request::builder()
            .method("PATCH")
            .uri("/api/v2/users/me/email")
            .header("content-type", "application/x-www-form-urlencoded")
            .header("cookie", format!("access_token={token}"))
            .body(Body::from(
                "new_email=new%40example.test&verification_id=email_fixture&code=123456",
            ))
            .unwrap()
    };
    let (a, b) = tokio::join!(app.clone().oneshot(form()), app.clone().oneshot(form()));
    let mut statuses = [a.unwrap().status().as_u16(), b.unwrap().status().as_u16()];
    statuses.sort_unstable();
    assert_eq!(statuses, [200, 400]);
    let replay = app.oneshot(form()).await.unwrap();
    assert_eq!(replay.status().as_u16(), 400);
    assert_eq!(*store.counts.lock().unwrap(), (1, 1));
}
