use axum::{body::Body, http::Request};
use http_body_util::BodyExt;
use nekotribe_backend::auth::{
    otp::{MailFuture, OtpEvent, OtpMailer},
    sessions::{
        build_native_router_with_mail, CorsPolicy, RefreshPolicy, SessionRepository,
        SessionStoreError, StoreFuture,
    },
    storage_urls::StorageUrlPolicy,
    TokenClaims, TokenCodec,
};
use serde_json::Value;
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc, Mutex,
};
use tower::ServiceExt;
struct Store {
    event: Mutex<Option<OtpEvent>>,
    inserts: AtomicUsize,
    fault: String,
    updates: AtomicUsize,
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
    fn otp_next_id<'a>(&'a self) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(123) })
    }
    fn otp_insert<'a>(&'a self, event: &'a OtpEvent) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            if self.fault == "insert" {
                return Err(SessionStoreError);
            };
            *self.event.lock().unwrap() = Some(event.clone());
            self.inserts.fetch_add(1, Ordering::SeqCst);
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
            let item = self.event.lock().unwrap();
            Ok(item
                .as_ref()
                .filter(|e| e.account == account && e.kind == kind && e.id == id)
                .map(|e| e.hash.clone()))
        })
    }
    fn otp_mark<'a>(&'a self, _: &'a str) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            self.updates.fetch_add(1, Ordering::SeqCst);
            Ok(())
        })
    }
    fn otp_verified_at<'a>(&'a self, _: &'a str) -> StoreFuture<'a, Option<String>> {
        Box::pin(async { Ok(Some("2026-01-02T03:04:05.000Z".into())) })
    }
}
struct Mail {
    store: Arc<Store>,
    sends: AtomicUsize,
    code: Mutex<String>,
    fault: String,
}
impl OtpMailer for Mail {
    fn send<'a>(&'a self, _: &'a str, code: &'a str) -> MailFuture<'a> {
        Box::pin(async move {
            assert_eq!(self.store.inserts.load(Ordering::SeqCst), 1);
            self.sends.fetch_add(1, Ordering::SeqCst);
            *self.code.lock().unwrap() = code.into();
            if self.fault == "mail" {
                return Err(());
            };
            Ok(())
        })
    }
}
#[tokio::test]
async fn shared_otp_creation() {
    let f: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/auth-otp-creation.json"
    ))
    .unwrap();
    let cases = f["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 12);
    for case in cases {
        let fault = case["fault"].as_str().unwrap_or("").to_owned();
        let store = Arc::new(Store {
            event: Mutex::new(None),
            inserts: AtomicUsize::new(0),
            fault: fault.clone(),
            updates: AtomicUsize::new(0),
        });
        let mail = Arc::new(Mail {
            store: store.clone(),
            sends: AtomicUsize::new(0),
            code: Mutex::new(String::new()),
            fault,
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
        );
        let before = chrono::Utc::now();
        let req = Request::builder()
            .method("POST")
            .uri("/api/v2/auth/otp")
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
        assert_eq!(
            store.inserts.load(Ordering::SeqCst),
            case["inserts"].as_u64().unwrap() as usize
        );
        assert_eq!(
            mail.sends.load(Ordering::SeqCst),
            case["sends"].as_u64().unwrap() as usize
        );
        if case["status"] == 200 {
            let data: Value = serde_json::from_str(&text).unwrap();
            let item = store.event.lock().unwrap();
            let event = item.as_ref().unwrap();
            let code = mail.code.lock().unwrap();
            assert_eq!(data["data"]["account"], "fake@example.test");
            assert_eq!(data["data"]["verification_id"], event.id);
            assert!(event.id.starts_with("otp_"));
            assert_eq!(code.len(), 6);
            assert!(code.bytes().all(|c| c.is_ascii_digit()));
            assert!(bcrypt::verify(&*code, &event.hash).unwrap());
            assert!(!text.contains(&*code));
            let expiry =
                chrono::DateTime::parse_from_rfc3339(data["data"]["expires_at"].as_str().unwrap())
                    .unwrap()
                    .to_utc();
            // Wall-clock synchronization can move time slightly while the test runs.
            assert!(expiry >= before + chrono::Duration::seconds(295));
            let after = chrono::Utc::now();
            assert!(
                expiry <= after + chrono::Duration::seconds(305),
                "expiry={expiry} before={before} after={after}"
            );
            let verify=serde_json::json!({"account":event.account,"type":event.kind,"verification_id":event.id,"code":*code}).to_string();
            drop(code);
            drop(item);
            let req = Request::builder()
                .method("POST")
                .uri("/api/v2/auth/otp/verification")
                .header("content-type", "application/json")
                .body(Body::from(verify))
                .unwrap();
            let response = app.oneshot(req).await.unwrap();
            assert_eq!(response.status(), 200);
            assert_eq!(store.updates.load(Ordering::SeqCst), 1);
        }
    }
}
