#[path = "support/otp_attempt.rs"]
mod otp_attempt;

use axum::{body::Body, http::Request};
use http_body_util::BodyExt;
use nekotribe_backend::auth::{
    registration::RegistrationRecord,
    sessions::{
        build_native_router, CorsPolicy, SessionRepository, SessionStoreError, StoreFuture,
    },
    TokenClaims, TokenCodec,
};
use serde_json::Value;
use std::sync::{
    atomic::{AtomicBool, AtomicUsize, Ordering},
    Arc, Mutex,
};
use tower::ServiceExt;
struct Store {
    otp: bool,
    duplicate: bool,
    fault: String,
    profile: Value,
    inserts: AtomicUsize,
    record: Mutex<Option<RegistrationRecord>>,
    profile_missing: bool,
    flow: bool,
    otp_event: Mutex<Option<nekotribe_backend::auth::otp::OtpEvent>>,
    otp_verified: AtomicBool,
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
    fn registration_otp<'a>(&'a self, email: &'a str, id: &'a str) -> StoreFuture<'a, bool> {
        Box::pin(async move {
            if self.fault == "otp" {
                return Err(SessionStoreError);
            };
            if self.flow {
                let event = self.otp_event.lock().unwrap();
                return Ok(self.otp_verified.load(Ordering::SeqCst)
                    && event.as_ref().is_some_and(|e| {
                        e.account == email && e.id == id && e.kind == "register"
                    }));
            }
            Ok(self.otp && email == "new@example.test" && id == "otp_fixture")
        })
    }
    fn registration_exists<'a>(&'a self, _: &'a str, _: &'a str) -> StoreFuture<'a, bool> {
        Box::pin(async move {
            if self.fault == "duplicate" {
                return Err(SessionStoreError);
            };
            Ok(self.duplicate)
        })
    }
    fn registration_next_id<'a>(&'a self) -> StoreFuture<'a, u64> {
        Box::pin(async move {
            if self.fault == "sequence" {
                return Err(SessionStoreError);
            };
            Ok(123)
        })
    }
    fn registration_insert<'a>(&'a self, record: &'a RegistrationRecord, _: &'a str) -> StoreFuture<'a, nekotribe_backend::auth::registration::Outcome> {
        use nekotribe_backend::auth::registration::Outcome;
        Box::pin(async move {
            if self.fault == "consumed" { return Ok(Outcome::MissingOtp); }
            if self.fault == "insert" {
                return Err(SessionStoreError);
            };
            self.inserts.fetch_add(1, Ordering::SeqCst);
            *self.record.lock().unwrap() = Some(record.clone());
            Ok(Outcome::Registered)
        })
    }
    fn login_profile<'a>(&'a self, _: u64) -> StoreFuture<'a, Option<Value>> {
        Box::pin(async move {
            if self.fault == "profile" {
                return Err(SessionStoreError);
            };
            if self.profile_missing {
                return Ok(None);
            }
            Ok(Some(self.profile.clone()))
        })
    }
    fn otp_next_id<'a>(&'a self) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(321) })
    }
    fn otp_insert<'a>(
        &'a self,
        event: &'a nekotribe_backend::auth::otp::OtpEvent,
    ) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            *self.otp_event.lock().unwrap() = Some(event.clone());
            Ok(())
        })
    }
    fn otp_lookup<'a>(
        &'a self,
        account: &'a str,
        kind: &'a str,
        id: &'a str,
    ) -> StoreFuture<'a, Option<String>> {
        Box::pin(async move {
            let event = self.otp_event.lock().unwrap();
            Ok(event
                .as_ref()
                .filter(|e| e.account == account && e.kind == kind && e.id == id)
                .map(|e| e.hash.clone()))
        })
    }
    fn otp_mark<'a>(&'a self, _: &'a str) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            self.otp_verified.store(true, Ordering::SeqCst);
            Ok(())
        })
    }
    fn otp_verified_at<'a>(&'a self, _: &'a str) -> StoreFuture<'a, Option<String>> {
        Box::pin(async { Ok(Some("2026-01-02T03:04:05.000Z".into())) })
    }
}
#[tokio::test]
async fn shared_registration() {
    let f: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/auth-registration.json"
    ))
    .unwrap();
    let cases = f["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 30);
    let interop = &f["hashInterop"];
    let hashes = interop["hashes"].as_array().unwrap();
    assert_eq!(hashes.len(), 2);
    for sample in hashes {
        let hash = sample["hash"].as_str().unwrap();
        assert!(bcrypt::verify(interop["password"].as_str().unwrap(), hash).unwrap());
        assert!(!bcrypt::verify(interop["wrongPassword"].as_str().unwrap(), hash).unwrap());
    }
    for case in cases {
        let store = Arc::new(Store {
            otp: case["otp"].is_null(),
            duplicate: case["duplicate"].as_bool().unwrap_or(false),
            fault: case["fault"].as_str().unwrap_or("").into(),
            profile: f["profile"].clone(),
            inserts: AtomicUsize::new(0),
            record: Mutex::new(None),
            profile_missing: case["profile_missing"].as_bool().unwrap_or(false),
            flow: false,
            otp_event: Mutex::new(None),
            otp_verified: AtomicBool::new(false),
        });
        let codec = TokenCodec::new(b"synthetic-access-key", b"synthetic-refresh-key").unwrap();
        let app = build_native_router(
            codec,
            store.clone(),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
        );
        let mut body = f["base"].as_object().unwrap().clone();
        for (k, v) in case["patch"].as_object().unwrap() {
            body.insert(k.clone(), v.clone());
        }
        let req = Request::builder()
            .method("POST")
            .uri("/api/v2/auth/registration")
            .header("content-type", "application/json")
            .header("cookie", "access_token=expired")
            .body(Body::from(Value::Object(body.clone()).to_string()))
            .unwrap();
        let response = app.oneshot(req).await.unwrap();
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
            !text.contains("synthetic-password") && !text.contains("registration-internal-fixture")
        );
        assert_eq!(
            store.inserts.load(Ordering::SeqCst),
            case["inserts"].as_u64().unwrap() as usize,
            "{}",
            case["id"]
        );
        if case["status"] == 200 {
            let result: Value = serde_json::from_str(&text).unwrap();
            assert_eq!(result["data"]["user"], f["profile"]);
            let record = store.record.lock().unwrap();
            let record = record.as_ref().unwrap();
            assert_eq!(record.user_id, 123);
            if let Some(expected) = case["expected_phone"].as_str() {
                assert_eq!(record.phone, expected, "{}", case["id"]);
            }
            assert!(
                bcrypt::verify(body["password"].as_str().unwrap(), &record.password_hash).unwrap()
            );
            if case["id"] == "REG-19" {
                assert_eq!(record.bio, "  retained  ");
                assert_eq!(record.location, "false");
                assert_eq!(record.phone, "123");
            }
        }
    }
}

#[tokio::test]
async fn registration_rejects_unsafe_storage_configuration_after_insert() {
    use nekotribe_backend::auth::{
        sessions::{build_native_router_with_storage, RefreshPolicy},
        storage_urls::StorageUrlPolicy,
    };
    let f: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/auth-registration.json"
    ))
    .unwrap();
    let store = Arc::new(Store {
        otp: true,
        duplicate: false,
        fault: String::new(),
        profile: f["profile"].clone(),
        inserts: AtomicUsize::new(0),
        record: Mutex::new(None),
        profile_missing: false,
        flow: false,
        otp_event: Mutex::new(None),
        otp_verified: AtomicBool::new(false),
    });
    let policy = StorageUrlPolicy::from_lookup(&|key: &str| {
        if key == "BASE_URL" {
            Some("https://user:synthetic-secret@example.test".into())
        } else {
            None
        }
    });
    let codec = TokenCodec::new(b"synthetic-access-key", b"synthetic-refresh-key").unwrap();
    let app = build_native_router_with_storage(
        codec,
        store.clone(),
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_000),
        RefreshPolicy::default(),
        policy,
    );
    let req = Request::builder()
        .method("POST")
        .uri("/api/v2/auth/registration")
        .header("content-type", "application/json")
        .body(Body::from(f["base"].to_string()))
        .unwrap();
    let response = app.oneshot(req).await.unwrap();
    assert_eq!(response.status(), 500);
    assert_eq!(store.inserts.load(Ordering::SeqCst), 1);
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
    assert!(!text.contains("synthetic-secret"));
}

struct RegistrationFlowMail {
    code: Mutex<String>,
}
struct RegistrationFlowLimit;
impl nekotribe_backend::auth::otp_send_limit::OtpSendLimiter for RegistrationFlowLimit {
    fn reserve<'a>(&'a self, _: &'a str) -> nekotribe_backend::auth::otp_send_limit::ReserveFuture<'a> {
        Box::pin(async { Ok(0) })
    }
}
impl nekotribe_backend::auth::otp::OtpMailer for RegistrationFlowMail {
    fn send<'a>(
        &'a self,
        _: &'a str,
        code: &'a str,
    ) -> nekotribe_backend::auth::otp::MailFuture<'a> {
        Box::pin(async move {
            *self.code.lock().unwrap() = code.into();
            Ok(())
        })
    }
}
#[tokio::test]
async fn isolated_otp_to_registration_flow() {
    use nekotribe_backend::auth::{
        sessions::{build_native_router_with_mail, RefreshPolicy},
        storage_urls::StorageUrlPolicy,
    };
    let f: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/auth-registration.json"
    ))
    .unwrap();
    let store = Arc::new(Store {
        otp: false,
        duplicate: false,
        fault: String::new(),
        profile: f["profile"].clone(),
        inserts: AtomicUsize::new(0),
        record: Mutex::new(None),
        profile_missing: false,
        flow: true,
        otp_event: Mutex::new(None),
        otp_verified: AtomicBool::new(false),
    });
    let mail = Arc::new(RegistrationFlowMail {
        code: Mutex::new(String::new()),
    });
    let codec = TokenCodec::new(b"synthetic-access-key", b"synthetic-refresh-key").unwrap();
    let app = build_native_router_with_mail(
        codec,
        store.clone(),
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_000),
        RefreshPolicy::default(),
        StorageUrlPolicy::default(),
        mail.clone(),
    ).layer(axum::Extension(nekotribe_backend::auth::otp_send_limit::OtpSendLimit(Arc::new(RegistrationFlowLimit)))).layer(otp_attempt::fixture(200));
    async fn post(app: &axum::Router, path: &str, body: Value) -> axum::response::Response {
        let req = Request::builder()
            .method("POST")
            .uri(path)
            .header("content-type", "application/json")
            .body(Body::from(body.to_string()))
            .unwrap();
        app.clone().oneshot(req).await.unwrap()
    }
    let created = post(
        &app,
        "/api/v2/auth/otp",
        serde_json::json!({"account":"new@example.test","type":"register"}),
    )
    .await;
    assert_eq!(created.status(), 200);
    let body: Value =
        serde_json::from_slice(&created.into_body().collect().await.unwrap().to_bytes()).unwrap();
    let id = body["data"]["verification_id"].as_str().unwrap().to_owned();
    let mut registration = f["base"].clone();
    registration["verification_id"] = Value::String(id.clone());
    assert_eq!(
        post(&app, "/api/v2/auth/registration", registration.clone())
            .await
            .status(),
        422
    );
    let code = mail.code.lock().unwrap().clone();
    let verified=post(&app,"/api/v2/auth/otp/verification",serde_json::json!({"account":"new@example.test","type":"register","verification_id":id,"code":code})).await;
    assert_eq!(verified.status(), 200);
    let result = post(&app, "/api/v2/auth/registration", registration).await;
    assert_eq!(result.status(), 200);
    assert_eq!(result.headers().get_all("set-cookie").iter().count(), 0);
    assert_eq!(store.inserts.load(Ordering::SeqCst), 1);
}
