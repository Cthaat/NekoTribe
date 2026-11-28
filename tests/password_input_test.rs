#[path = "support/otp_attempt.rs"]
mod otp_attempt;

use axum::{body::Body, http::Request};
use nekotribe_backend::auth::{
    registration::RegistrationRecord,
    sessions::{build_native_router, CorsPolicy, SessionRepository, StoreFuture},
    TokenClaims, TokenCodec,
};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;
struct Store {
    hash: String,
    profile: Value,
    writes: Mutex<(u64, String)>,
}
impl SessionRepository for Store {
    fn login_account<'a>(
        &'a self,
        _: &'a str,
    ) -> StoreFuture<'a, Option<nekotribe_backend::auth::login::LoginAccount>> {
        Box::pin(async {
            Ok(Some(nekotribe_backend::auth::login::LoginAccount {
                user_id: 123,
                username: "edge".into(),
                password_hash: self.hash.clone(),
                status: "active".into(),
                active: true,
            }))
        })
    }
    fn two_factor_readiness(&self) -> StoreFuture<'_, ()> {
        Box::pin(async { Ok(()) })
    }
    fn login_two_factor(&self, _: u64) -> StoreFuture<'_, bool> {
        Box::pin(async { Ok(false) })
    }
    fn login_insert_session<'a>(
        &'a self,
        _: &'a nekotribe_backend::auth::login::LoginSession,
    ) -> StoreFuture<'a, Option<nekotribe_backend::auth::login::LoginHistory>> {
        Box::pin(async move {
            self.writes.lock().unwrap().0 += 1;
            Ok(Some(nekotribe_backend::auth::login::LoginHistory {
                known_device: true,
                previous_ip: None,
            }))
        })
    }
    fn touch<'a>(&'a self, _: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(1) })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn registration_otp<'a>(&'a self, _: &'a str, _: &'a str) -> StoreFuture<'a, bool> {
        Box::pin(async { Ok(true) })
    }
    fn registration_exists<'a>(&'a self, _: &'a str, _: &'a str) -> StoreFuture<'a, bool> {
        Box::pin(async { Ok(false) })
    }
    fn registration_next_id(&self) -> StoreFuture<'_, u64> {
        Box::pin(async { Ok(123) })
    }
    fn registration_insert<'a>(&'a self, r: &'a RegistrationRecord, _: &'a str) -> StoreFuture<'a, nekotribe_backend::auth::registration::Outcome> {
        Box::pin(async move {
            *self.writes.lock().unwrap() = (1, r.password_hash.clone());
            Ok(nekotribe_backend::auth::registration::Outcome::Registered)
        })
    }
    fn login_profile(&self, _: u64) -> StoreFuture<'_, Option<Value>> {
        Box::pin(async { Ok(Some(self.profile.clone())) })
    }
    fn otp_lookup<'a>(
        &'a self,
        _: &'a str,
        kind: &'a str,
        _: &'a str,
    ) -> StoreFuture<'a, Option<String>> {
        Box::pin(async move {
            assert_eq!(kind, "password_reset");
            Ok(Some(self.hash.clone()))
        })
    }
    fn reset_password_atomic<'a>(
        &'a self,
        _: &'a str,
        _: &'a str,
        _: &'a str,
        hash: &'a str,
    ) -> StoreFuture<'a, u64> {
        Box::pin(async move {
            *self.writes.lock().unwrap() = (1, hash.into());
            Ok(0)
        })
    }
}

#[tokio::test]
async fn new_password_policy_preserves_legacy_login() {
    let f: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/auth-registration.json"
    ))
    .unwrap();
    let store = Arc::new(Store {
        hash: bcrypt::hash("x", 4).unwrap(),
        profile: f["profile"].clone(),
        writes: Mutex::new((0, String::new())),
    });
    let codec = TokenCodec::new(b"synthetic-access-key", b"synthetic-refresh-key").unwrap();
    let app = build_native_router(
        codec,
        store.clone(),
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_000),
    ).layer(otp_attempt::fixture(200));
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v2/auth/tokens")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"account":"edge","password":" x "}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status().as_u16(), 200);
    assert_eq!(store.writes.lock().unwrap().0, 1);
    assert!(res.headers().get_all("set-cookie").iter().count() > 0);
}
#[tokio::test]
async fn shared_new_password_inputs() {
    let f: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/auth-password-input.json"
    ))
    .unwrap();
    assert_eq!(f["cases"].as_array().unwrap().len(), 19);
    let registration: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/auth-registration.json"
    ))
    .unwrap();
    let hash = bcrypt::hash("123456", 4).unwrap();
    for c in f["cases"]
        .as_array()
        .unwrap()
        .iter()
        .chain(f["apiCases"].as_array().unwrap())
    {
        for reset in [false, true] {
            let store = Arc::new(Store {
                hash: hash.clone(),
                profile: registration["profile"].clone(),
                writes: Mutex::new((0, String::new())),
            });
            let codec = TokenCodec::new(b"synthetic-access-key", b"synthetic-refresh-key").unwrap();
            let app = build_native_router(
                codec,
                store.clone(),
                CorsPolicy::default(),
                Arc::new(|| 1_700_000_000),
            ).layer(otp_attempt::fixture(200));
            let (body, path, valid) = if reset {
                (
                    json!({"email":"fake@example.test","verification_id":"otp_fixture","code":"123456","new_password":c["raw"]}),
                    "/api/v2/auth/password-reset",
                    c["validNewPassword"] == true,
                )
            } else {
                let mut body = registration["base"].clone();
                body["password"] = c["raw"].clone();
                body["confirm_password"] = c["confirm"].clone();
                (
                    body,
                    "/api/v2/auth/registration",
                    c["validNewPassword"] == true && c["matches"] == true,
                )
            };
            let res = app
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri(path)
                        .header("content-type", "application/json")
                        .body(Body::from(body.to_string()))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(
                res.status().as_u16(),
                if valid { 200 } else { 400 },
                "{} reset={reset}",
                c["id"]
            );
            let writes = store.writes.lock().unwrap();
            assert_eq!(writes.0, u64::from(valid));
            if valid {
                assert!(bcrypt::verify(c["normalized"].as_str().unwrap(), &writes.1).unwrap());
            }
        }
    }
}

#[tokio::test]
async fn shared_account_inputs() {
    let f: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/auth-account-input.json"
    ))
    .unwrap();
    let registration: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/auth-registration.json"
    ))
    .unwrap();
    for c in f["cases"].as_array().unwrap() {
        let store = Arc::new(Store {
            hash: String::new(),
            profile: registration["profile"].clone(),
            writes: Mutex::new((0, String::new())),
        });
        let codec = TokenCodec::new(b"synthetic-access-key", b"synthetic-refresh-key").unwrap();
        let app = build_native_router(
            codec,
            store.clone(),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
        ).layer(otp_attempt::fixture(200));
        let mut body = registration["base"].clone();
        body[c["field"].as_str().unwrap()] = c["raw"].clone();
        let res = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/v2/auth/registration")
                    .header("content-type", "application/json")
                    .body(Body::from(body.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        let valid = c["valid"] == true;
        assert_eq!(
            res.status().as_u16(),
            if valid { 200 } else { 400 },
            "{}",
            c["id"]
        );
        assert_eq!(store.writes.lock().unwrap().0, u64::from(valid));
    }
}

#[tokio::test]
async fn invalid_new_email_at_native_routes() {
    use http_body_util::BodyExt;
    let f: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/auth-account-input.json"
    ))
    .unwrap();
    let tokens: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/auth-tokens.json"
    ))
    .unwrap();
    let token = tokens["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    for c in f["emailCases"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|c| c["valid"] == false && c["normalized"] != "")
    {
        for kind in ["register", "change_email", "mutation"] {
            let store = Arc::new(Store {
                hash: String::new(),
                profile: Value::Null,
                writes: Mutex::new((0, String::new())),
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
            ).layer(otp_attempt::fixture(200));
            let (method, path, body) = if kind == "mutation" {
                (
                    "PATCH",
                    "/api/v2/users/me/email",
                    json!({"new_email":c["raw"],"verification_id":"email_fixture","code":"123456"}),
                )
            } else {
                (
                    "POST",
                    "/api/v2/auth/otp",
                    json!({"account":c["raw"],"type":kind}),
                )
            };
            let res = app
                .oneshot(
                    Request::builder()
                        .method(method)
                        .uri(path)
                        .header("content-type", "application/json")
                        .header("authorization", format!("Bearer {token}"))
                        .body(Body::from(body.to_string()))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status().as_u16(), 400, "{} {kind}", c["id"]);
            let body: Value =
                serde_json::from_slice(&res.into_body().collect().await.unwrap().to_bytes())
                    .unwrap();
            assert_eq!(body["message"], "邮箱格式错误");
            assert_eq!(store.writes.lock().unwrap().0, 0);
        }
    }
}
