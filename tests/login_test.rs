use axum::{body::Body, http::Request};
use http_body_util::BodyExt;
use nekotribe_backend::auth::{
    login::{
        ChallengeRow, EncryptedSecret, LoginAccount, LoginChallenge, LoginDevice, LoginSession,
        RecoveryCode,
    },
    sessions::{
        build_native_router, CorsPolicy, SessionRepository, SessionStoreError, StoreFuture,
    },
    TokenClaims, TokenCodec,
};
use std::{
    collections::HashSet,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, Mutex,
    },
};
use tower::ServiceExt;

struct Unavailable;
impl SessionRepository for Unavailable {
    fn touch<'a>(&'a self, _: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
}

#[derive(Default)]
struct SecondReadinessFails {
    checks: AtomicUsize,
    writes: AtomicUsize,
    secret_reads: AtomicUsize,
}
impl SessionRepository for SecondReadinessFails {
    fn touch<'a>(&'a self, _: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn two_factor_readiness<'a>(&'a self) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            if self.checks.fetch_add(1, Ordering::SeqCst) == 0 {
                Ok(())
            } else {
                Err(SessionStoreError)
            }
        })
    }
    fn login_account<'a>(&'a self, _: &'a str) -> StoreFuture<'a, Option<LoginAccount>> {
        Box::pin(async {
            Ok(Some(LoginAccount {
                user_id: 1,
                username: "test".into(),
                password_hash: "$2b$04$OJWTcv5D1yfCJ2aUI/L8beKZveutMxfKeV2DaIORCbtM4pJEKuwVK"
                    .into(),
                status: "active".into(),
                active: true,
            }))
        })
    }
    fn login_two_factor<'a>(&'a self, _: u64) -> StoreFuture<'a, bool> {
        Box::pin(async { Ok(true) })
    }
    fn login_trusted_device<'a>(&'a self, _: u64, _: &'a LoginDevice) -> StoreFuture<'a, bool> {
        Box::pin(async { Ok(false) })
    }
    fn login_challenge<'a>(&'a self, _: &'a LoginChallenge) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            self.writes.fetch_add(1, Ordering::SeqCst);
            Ok(())
        })
    }
    fn challenge_lookup<'a>(&'a self, _: &'a str) -> StoreFuture<'a, Option<ChallengeRow>> {
        Box::pin(async {
            Ok(Some(ChallengeRow {
                user_id: 1,
                username: "test".into(),
                remember: false,
                device: LoginDevice {
                    fingerprint: "unknown".into(),
                    info: "unknown".into(),
                    ip: "unknown".into(),
                    user_agent: "unknown".into(),
                },
            }))
        })
    }
    fn two_factor_secret<'a>(&'a self, _: u64) -> StoreFuture<'a, Option<EncryptedSecret>> {
        Box::pin(async move {
            self.secret_reads.fetch_add(1, Ordering::SeqCst);
            Ok(None)
        })
    }
}

#[tokio::test]
async fn second_readiness_failure_does_not_create_or_consume_credentials() {
    for (path, body) in [
        (
            "/api/v2/auth/tokens",
            r#"{"account":"test","password":"correct-password"}"#,
        ),
        (
            "/api/v2/auth/two-factor/challenges",
            r#"{"challenge_id":"2fa-test","code":"123456"}"#,
        ),
    ] {
        let store = Arc::new(SecondReadinessFails::default());
        let app = build_native_router(
            TokenCodec::new(b"access", b"refresh").unwrap(),
            store.clone(),
            CorsPolicy::default(),
            Arc::new(|| 1700000000),
        );
        let request = Request::builder()
            .method("POST")
            .uri(path)
            .header("content-type", "application/json")
            .body(Body::from(body))
            .unwrap();
        let response = app.oneshot(request).await.unwrap();
        assert_eq!(response.status(), 503, "{path}");
        assert_eq!(response.headers().get_all("set-cookie").iter().count(), 0);
        assert_eq!(store.checks.load(Ordering::SeqCst), 2);
        assert_eq!(store.writes.load(Ordering::SeqCst), 0);
        assert_eq!(store.secret_reads.load(Ordering::SeqCst), 0);
    }
}

struct LoginStore {
    two_factor: bool,
    profile_fails: bool,
    schema_fails: bool,
    trusted: bool,
    remember: bool,
    trust_calls: AtomicUsize,
    sessions: Mutex<Vec<(String, String)>>,
    challenges: Mutex<Vec<String>>,
    consumed: Mutex<HashSet<String>>,
    recovery_used: Mutex<bool>,
    recovery_attempts: AtomicUsize,
    barrier: Option<Arc<tokio::sync::Barrier>>,
}
impl SessionRepository for LoginStore {
    fn touch<'a>(&'a self, _: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn login_account<'a>(&'a self, account: &'a str) -> StoreFuture<'a, Option<LoginAccount>> {
        Box::pin(async move {
            Ok(
                (account == "test" || account == "disabled").then(|| LoginAccount {
                    user_id: 1,
                    username: "test".into(),
                    password_hash: "$2b$04$OJWTcv5D1yfCJ2aUI/L8beKZveutMxfKeV2DaIORCbtM4pJEKuwVK"
                        .into(),
                    status: "active".into(),
                    active: account != "disabled",
                }),
            )
        })
    }
    fn login_two_factor<'a>(&'a self, _: u64) -> StoreFuture<'a, bool> {
        Box::pin(async move { Ok(self.two_factor) })
    }
    fn two_factor_readiness<'a>(&'a self) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            if self.schema_fails {
                Err(SessionStoreError)
            } else {
                Ok(())
            }
        })
    }
    fn login_trusted_device<'a>(&'a self, _: u64, _: &'a LoginDevice) -> StoreFuture<'a, bool> {
        Box::pin(async move { Ok(self.trusted) })
    }
    fn login_challenge<'a>(&'a self, c: &'a LoginChallenge) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            self.challenges.lock().unwrap().push(c.id.clone());
            Ok(())
        })
    }
    fn login_insert_session<'a>(&'a self, s: &'a LoginSession) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            self.sessions
                .lock()
                .unwrap()
                .push((s.id.clone(), s.refresh_hash.clone()));
            Ok(())
        })
    }
    fn known_login_device<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, bool> {
        Box::pin(async { Ok(false) })
    }
    fn record_login_alert<'a>(&'a self, _: &'a LoginSession) -> StoreFuture<'a, ()> {
        Box::pin(async { Ok(()) })
    }
    fn login_profile<'a>(&'a self, _: u64) -> StoreFuture<'a, Option<serde_json::Value>> {
        Box::pin(async move {
            if self.profile_fails {
                Err(SessionStoreError)
            } else {
                Ok(Some(serde_json::json!({"user_id":1,"username":"test"})))
            }
        })
    }
    fn challenge_lookup<'a>(&'a self, id: &'a str) -> StoreFuture<'a, Option<ChallengeRow>> {
        Box::pin(async move {
            let exists = !self.consumed.lock().unwrap().contains(id)
                && self.challenges.lock().unwrap().iter().any(|x| x == id);
            if let Some(b) = &self.barrier {
                b.wait().await;
            }
            Ok(exists.then(|| ChallengeRow {
                user_id: 1,
                username: "test".into(),
                remember: self.remember,
                device: LoginDevice {
                    fingerprint: "unknown".into(),
                    info: "unknown".into(),
                    ip: "unknown".into(),
                    user_agent: "unknown".into(),
                },
            }))
        })
    }
    fn two_factor_secret<'a>(&'a self, _: u64) -> StoreFuture<'a, Option<EncryptedSecret>> {
        Box::pin(async move {
            use aes_gcm::{aead::Aead, Aes256Gcm, KeyInit};
            use base64::{engine::general_purpose::STANDARD, Engine};
            use sha2::{Digest, Sha256};
            let key = Sha256::digest(b"refresh");
            let nonce = [0u8; 12];
            let cipher = Aes256Gcm::new_from_slice(&key).unwrap();
            let mut encrypted = cipher
                .encrypt(
                    aes_gcm::Nonce::from_slice(&nonce),
                    b"JBSWY3DPEHPK3PXP".as_slice(),
                )
                .unwrap();
            let tag = encrypted.split_off(encrypted.len() - 16);
            Ok(Some(EncryptedSecret {
                encrypted: STANDARD.encode(encrypted),
                iv: STANDARD.encode(nonce),
                tag: STANDARD.encode(tag),
                enabled: true,
            }))
        })
    }
    fn recovery_codes<'a>(&'a self, _: u64) -> StoreFuture<'a, Vec<RecoveryCode>> {
        Box::pin(async move {
            let rows = if *self.recovery_used.lock().unwrap() {
                vec![]
            } else {
                vec![RecoveryCode {
                    id: 1,
                    hash: "$2b$04$taTerm9Nj3kAnlCnkvFiFeNHtUaEcAfyrRW0xhFDzzJspHngSWO5a".into(),
                }]
            };
            if let Some(barrier) = &self.barrier {
                barrier.wait().await;
            }
            Ok(rows)
        })
    }
    fn consume_recovery<'a>(&'a self, _: u64) -> StoreFuture<'a, u64> {
        Box::pin(async move {
            self.recovery_attempts.fetch_add(1, Ordering::SeqCst);
            let mut x = self.recovery_used.lock().unwrap();
            if *x {
                Ok(0)
            } else {
                *x = true;
                Ok(1)
            }
        })
    }
    fn consume_challenge<'a>(&'a self, id: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async move {
            Ok(u64::from(
                self.consumed.lock().unwrap().insert(id.to_owned()),
            ))
        })
    }
    fn trust_challenge_device<'a>(
        &'a self,
        _: &'a ChallengeRow,
        _: &'a str,
    ) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            self.trust_calls.fetch_add(1, Ordering::SeqCst);
            Ok(())
        })
    }
}

#[tokio::test]
async fn password_login_issues_persisted_session_and_challenge_never_issues_tokens() {
    for two_factor in [false, true] {
        let store = Arc::new(LoginStore {
            two_factor,
            profile_fails: false,
            schema_fails: false,
            trusted: false,
            remember: false,
            trust_calls: AtomicUsize::new(0),
            sessions: Mutex::new(vec![]),
            challenges: Mutex::new(vec![]),
            consumed: Mutex::new(HashSet::new()),
            recovery_used: Mutex::new(false),
            recovery_attempts: AtomicUsize::new(0),
            barrier: None,
        });
        let codec = TokenCodec::new(b"access", b"refresh").unwrap();
        let app = build_native_router(
            codec,
            store.clone(),
            CorsPolicy::default(),
            Arc::new(|| 1700000000),
        );
        let request = Request::builder()
            .method("POST")
            .uri("/api/v2/auth/tokens")
            .header("content-type", "application/json")
            .body(Body::from(
                r#"{"account":"test","password":"correct-password"}"#,
            ))
            .unwrap();
        let response = app.oneshot(request).await.unwrap();
        assert_eq!(response.status(), 200);
        assert_eq!(
            response.headers().get_all("set-cookie").iter().count(),
            if two_factor { 0 } else { 2 }
        );
        let body: serde_json::Value =
            serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes())
                .unwrap();
        assert_eq!(body["data"]["two_factor_required"], two_factor);
        assert_eq!(
            store.sessions.lock().unwrap().len(),
            usize::from(!two_factor)
        );
        assert_eq!(
            store.challenges.lock().unwrap().len(),
            usize::from(two_factor)
        );
        if !two_factor {
            use sha2::{Digest, Sha256};
            let refresh = body["data"]["tokens"]["refresh_token"].as_str().unwrap();
            let recorded = store.sessions.lock().unwrap();
            assert_eq!(
                recorded[0].1,
                hex::encode(Sha256::digest(refresh.as_bytes()))
            );
        }
    }
}

#[tokio::test]
async fn failed_profile_does_not_send_cookies_even_if_session_was_inserted() {
    let store = Arc::new(LoginStore {
        two_factor: false,
        profile_fails: true,
        schema_fails: false,
        trusted: false,
        remember: false,
        trust_calls: AtomicUsize::new(0),
        sessions: Mutex::new(vec![]),
        challenges: Mutex::new(vec![]),
        consumed: Mutex::new(HashSet::new()),
        recovery_used: Mutex::new(false),
        recovery_attempts: AtomicUsize::new(0),
        barrier: None,
    });
    let app = build_native_router(
        TokenCodec::new(b"access", b"refresh").unwrap(),
        store.clone(),
        CorsPolicy::default(),
        Arc::new(|| 1700000000),
    );
    let request = Request::builder()
        .method("POST")
        .uri("/api/v2/auth/tokens")
        .header("content-type", "application/json")
        .body(Body::from(
            r#"{"account":"test","password":"correct-password"}"#,
        ))
        .unwrap();
    let response = app.oneshot(request).await.unwrap();
    assert_eq!(response.status(), 500);
    assert_eq!(response.headers().get_all("set-cookie").iter().count(), 0);
    assert_eq!(store.sessions.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn missing_two_factor_schema_fails_closed_even_when_user_has_no_2fa() {
    let store = Arc::new(LoginStore {
        two_factor: false,
        profile_fails: false,
        schema_fails: true,
        trusted: false,
        remember: false,
        trust_calls: AtomicUsize::new(0),
        sessions: Mutex::new(vec![]),
        challenges: Mutex::new(vec![]),
        consumed: Mutex::new(HashSet::new()),
        recovery_used: Mutex::new(false),
        recovery_attempts: AtomicUsize::new(0),
        barrier: None,
    });
    let app = build_native_router(
        TokenCodec::new(b"access", b"refresh").unwrap(),
        store.clone(),
        CorsPolicy::default(),
        Arc::new(|| 1700000000),
    );
    let request = Request::builder()
        .method("POST")
        .uri("/api/v2/auth/tokens")
        .header("content-type", "application/json")
        .body(Body::from(
            r#"{"account":"test","password":"correct-password"}"#,
        ))
        .unwrap();
    let response = app.oneshot(request).await.unwrap();
    assert_eq!(response.status(), 503);
    assert_eq!(response.headers().get_all("set-cookie").iter().count(), 0);
    assert!(store.sessions.lock().unwrap().is_empty());
}

#[tokio::test]
async fn two_factor_challenge_accepts_totp_and_recovery_once() {
    for code in ["324550", "ABCDE-FGHIJ-KLMNO"] {
        let store = Arc::new(LoginStore {
            two_factor: true,
            profile_fails: false,
            schema_fails: false,
            trusted: false,
            remember: false,
            trust_calls: AtomicUsize::new(0),
            sessions: Mutex::new(vec![]),
            challenges: Mutex::new(vec!["2fa_test".into()]),
            consumed: Mutex::new(HashSet::new()),
            recovery_used: Mutex::new(false),
            recovery_attempts: AtomicUsize::new(0),
            barrier: None,
        });
        let app = build_native_router(
            TokenCodec::new(b"access", b"refresh").unwrap(),
            store.clone(),
            CorsPolicy::default(),
            Arc::new(|| 1700000000),
        );
        let request = || {
            Request::builder()
                .method("POST")
                .uri("/api/v2/auth/two-factor/challenges")
                .header("content-type", "application/json")
                .body(Body::from(format!(
                    r#"{{"challenge_id":"2fa_test","code":"{code}"}}"#
                )))
                .unwrap()
        };
        let ok = app.clone().oneshot(request()).await.unwrap();
        assert_eq!(ok.status(), 200);
        assert_eq!(ok.headers().get_all("set-cookie").iter().count(), 2);
        let replay = app.oneshot(request()).await.unwrap();
        assert_eq!(replay.status(), 401);
        assert_eq!(replay.headers().get_all("set-cookie").iter().count(), 0);
        assert_eq!(store.sessions.lock().unwrap().len(), 1);
    }
}

#[tokio::test]
async fn concurrent_same_challenge_or_shared_recovery_issues_at_most_one_session() {
    for (first_id, second_id, code) in [
        ("2fa_a", "2fa_a", "324550"),
        ("2fa_a", "2fa_b", "ABCDE-FGHIJ-KLMNO"),
    ] {
        let store = Arc::new(LoginStore {
            two_factor: true,
            profile_fails: false,
            schema_fails: false,
            trusted: false,
            remember: false,
            trust_calls: AtomicUsize::new(0),
            sessions: Mutex::new(vec![]),
            challenges: Mutex::new(vec!["2fa_a".into(), "2fa_b".into()]),
            consumed: Mutex::new(HashSet::new()),
            recovery_used: Mutex::new(false),
            recovery_attempts: AtomicUsize::new(0),
            barrier: Some(Arc::new(tokio::sync::Barrier::new(2))),
        });
        let app = build_native_router(
            TokenCodec::new(b"access", b"refresh").unwrap(),
            store.clone(),
            CorsPolicy::default(),
            Arc::new(|| 1700000000),
        );
        let request = |id| {
            Request::builder()
                .method("POST")
                .uri("/api/v2/auth/two-factor/challenges")
                .header("content-type", "application/json")
                .body(Body::from(format!(
                    r#"{{"challenge_id":"{id}","code":"{code}"}}"#
                )))
                .unwrap()
        };
        let (a, b) = tokio::join!(
            app.clone().oneshot(request(first_id)),
            app.clone().oneshot(request(second_id))
        );
        let responses = [a.unwrap(), b.unwrap()];
        let mut status = responses
            .iter()
            .map(|r| r.status().as_u16())
            .collect::<Vec<_>>();
        status.sort();
        assert_eq!(status, vec![200, 401]);
        assert_eq!(
            responses
                .iter()
                .find(|r| r.status() == 401)
                .unwrap()
                .headers()
                .get_all("set-cookie")
                .iter()
                .count(),
            0
        );
        assert_eq!(store.sessions.lock().unwrap().len(), 1);
        if first_id != second_id {
            assert_eq!(store.recovery_attempts.load(Ordering::SeqCst), 2);
        }
    }
}

#[tokio::test]
async fn login_uses_javascript_whitespace_for_account_and_password() {
    let store = Arc::new(LoginStore {
        two_factor: false,
        profile_fails: false,
        schema_fails: false,
        trusted: false,
        remember: false,
        trust_calls: AtomicUsize::new(0),
        sessions: Mutex::new(vec![]),
        challenges: Mutex::new(vec![]),
        consumed: Mutex::new(HashSet::new()),
        recovery_used: Mutex::new(false),
        recovery_attempts: AtomicUsize::new(0),
        barrier: None,
    });
    let app = build_native_router(
        TokenCodec::new(b"access", b"refresh").unwrap(),
        store,
        CorsPolicy::default(),
        Arc::new(|| 1700000000),
    );
    for (account, password, status) in [
        (
            "\u{feff}test\u{feff}",
            "\u{feff}correct-password\u{feff}",
            200,
        ),
        ("\u{0085}test\u{0085}", "correct-password", 401),
        ("test", "\u{0085}correct-password\u{0085}", 401),
    ] {
        let body = serde_json::json!({"account":account,"password":password}).to_string();
        let request = Request::builder()
            .method("POST")
            .uri("/api/v2/auth/tokens")
            .header("content-type", "application/json")
            .body(Body::from(body))
            .unwrap();
        assert_eq!(app.clone().oneshot(request).await.unwrap().status(), status);
    }
}

#[tokio::test]
async fn wrong_credentials_inactive_and_trusted_device_follow_login_decisions() {
    for (account, password, two_factor, trusted, status, challenge) in [
        ("missing", "correct-password", false, false, 401, false),
        ("test", "wrong", false, false, 401, false),
        ("disabled", "wrong", false, false, 403, false),
        ("test", "correct-password", true, true, 200, false),
        ("test", "correct-password", true, false, 200, true),
    ] {
        let store = Arc::new(LoginStore {
            two_factor,
            profile_fails: false,
            schema_fails: false,
            trusted,
            remember: false,
            trust_calls: AtomicUsize::new(0),
            sessions: Mutex::new(vec![]),
            challenges: Mutex::new(vec![]),
            consumed: Mutex::new(HashSet::new()),
            recovery_used: Mutex::new(false),
            recovery_attempts: AtomicUsize::new(0),
            barrier: None,
        });
        let app = build_native_router(
            TokenCodec::new(b"access", b"refresh").unwrap(),
            store.clone(),
            CorsPolicy::default(),
            Arc::new(|| 1700000000),
        );
        let body = serde_json::json!({"account":account,"password":password}).to_string();
        let req = Request::builder()
            .method("POST")
            .uri("/api/v2/auth/tokens")
            .header("content-type", "application/json")
            .body(Body::from(body))
            .unwrap();
        let response = app.oneshot(req).await.unwrap();
        assert_eq!(response.status(), status);
        assert_eq!(
            store.challenges.lock().unwrap().len(),
            usize::from(challenge)
        );
        assert_eq!(
            store.sessions.lock().unwrap().len(),
            usize::from(status == 200 && !challenge)
        );
    }
}

#[tokio::test]
async fn invalid_challenge_or_code_fails_and_remembered_device_is_recorded() {
    let store = Arc::new(LoginStore {
        two_factor: true,
        profile_fails: false,
        schema_fails: false,
        trusted: false,
        remember: true,
        trust_calls: AtomicUsize::new(0),
        sessions: Mutex::new(vec![]),
        challenges: Mutex::new(vec!["2fa_valid".into()]),
        consumed: Mutex::new(HashSet::new()),
        recovery_used: Mutex::new(false),
        recovery_attempts: AtomicUsize::new(0),
        barrier: None,
    });
    let app = build_native_router(
        TokenCodec::new(b"access", b"refresh").unwrap(),
        store.clone(),
        CorsPolicy::default(),
        Arc::new(|| 1700000000),
    );
    for (id, code, status) in [
        ("missing", "324550", 401),
        ("2fa_valid", "111111", 401),
        ("2fa_valid", "324550", 200),
    ] {
        let body = serde_json::json!({"challenge_id":id,"code":code}).to_string();
        let req = Request::builder()
            .method("POST")
            .uri("/api/v2/auth/two-factor/challenges")
            .header("content-type", "application/json")
            .body(Body::from(body))
            .unwrap();
        let response = app.clone().oneshot(req).await.unwrap();
        assert_eq!(response.status(), status);
        if status != 200 {
            assert_eq!(response.headers().get_all("set-cookie").iter().count(), 0);
        }
    }
    assert_eq!(store.trust_calls.load(Ordering::SeqCst), 1);
    assert_eq!(store.sessions.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn login_requires_input_and_fails_closed_if_store_is_unavailable() {
    let app = build_native_router(
        TokenCodec::new(b"access", b"refresh").unwrap(),
        Arc::new(Unavailable),
        CorsPolicy::default(),
        Arc::new(|| 1700000000),
    );
    for (body, status) in [("{}", 400), (r#"{"account":"a","password":"p"}"#, 500)] {
        let request = Request::builder()
            .method("POST")
            .uri("/api/v2/auth/tokens")
            .header("content-type", "application/json")
            .body(Body::from(body))
            .unwrap();
        let response = app.clone().oneshot(request).await.unwrap();
        assert_eq!(response.status().as_u16(), status);
        assert!(response
            .headers()
            .get_all("set-cookie")
            .iter()
            .next()
            .is_none());
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        assert!(!String::from_utf8_lossy(&bytes).contains("password"));
    }
}

#[test]
fn bcrypt_accepts_shared_nuxt_vectors_including_72_byte_truncation() {
    let vectors: serde_json::Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-bcrypt.json")).unwrap();
    for case in vectors["cases"].as_array().unwrap() {
        let password = case["password"].as_str().unwrap();
        let hash = case["hash"].as_str().unwrap();
        assert_eq!(
            bcrypt::verify(password, hash).unwrap_or(false),
            case["valid"].as_bool().unwrap(),
            "{}",
            case["id"]
        );
    }
}
