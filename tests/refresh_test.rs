use axum::{body::Body, http::Request, Router};
use http_body_util::BodyExt;
use nekotribe_backend::auth::{
    sessions::{
        build_native_router_with_refresh, CorsPolicy, RefreshPolicy, SessionCredential,
        SessionRepository, SessionRotation, SessionStoreError, StoreFuture,
    },
    IssuedToken, TokenClaims, TokenCodec, TokenKind,
};
use sha2::{Digest, Sha256};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

const NOW: u64 = 1_700_000_000;
const ACCESS_KEY: &[u8] = b"test-access-key";
const REFRESH_KEY: &[u8] = b"test-refresh-key";
fn codec() -> TokenCodec {
    TokenCodec::new(ACCESS_KEY, REFRESH_KEY).unwrap()
}
fn digest(s: &str) -> String {
    hex::encode(Sha256::digest(s.as_bytes()))
}
fn signed(kind: TokenKind, jti: &str) -> String {
    codec()
        .sign(&IssuedToken {
            user_id: 42,
            user_name: "kitty".into(),
            session_id: "sess_test".into(),
            kind,
            issued_at: NOW - 20,
            expires_at: NOW + 1000,
            jti: jti.into(),
        })
        .unwrap()
}
struct Row {
    refresh_hash: String,
    access_jti: String,
    revoked: bool,
    expired: bool,
    fail: bool,
    fail_after_write: bool,
    barrier: Option<Arc<tokio::sync::Barrier>>,
    writes: usize,
}
struct Store(Mutex<Row>);
impl SessionRepository for Store {
    fn touch<'a>(&'a self, claims: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async move {
            let r = self.0.lock().unwrap();
            Ok(u64::from(
                !r.revoked
                    && r.access_jti == claims.jti
                    && claims.user_id == 42
                    && claims.session_id == "sess_test",
            ))
        })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_current<'a>(
        &'a self,
        user: u64,
        session: &'a str,
        credential: &'a SessionCredential,
    ) -> StoreFuture<'a, u64> {
        Box::pin(async move {
            let mut r = self.0.lock().unwrap();
            if r.fail {
                return Err(SessionStoreError);
            }
            let matches = match credential {
                SessionCredential::RefreshHash(hash) => r.refresh_hash == *hash,
                SessionCredential::AccessJti(jti) => r.access_jti == *jti,
            };
            if r.revoked || user != 42 || session != "sess_test" || !matches {
                return Ok(0);
            }
            r.revoked = true;
            r.writes += 1;
            if r.fail_after_write {
                return Err(SessionStoreError);
            }
            Ok(1)
        })
    }
    fn rotate<'a>(&'a self, rotation: &'a SessionRotation) -> StoreFuture<'a, u64> {
        Box::pin(async move {
            let barrier = self.0.lock().unwrap().barrier.clone();
            if let Some(barrier) = barrier {
                barrier.wait().await;
            }
            let mut r = self.0.lock().unwrap();
            if r.fail {
                return Err(SessionStoreError);
            }
            if r.revoked
                || r.expired
                || rotation.user_id != 42
                || rotation.session_id != "sess_test"
                || r.refresh_hash != rotation.old_refresh_hash
            {
                return Ok(0);
            }
            r.refresh_hash = rotation.refresh_hash.clone();
            r.access_jti = rotation.access_jti.clone();
            r.writes += 1;
            if r.fail_after_write {
                return Err(SessionStoreError);
            }
            Ok(1)
        })
    }
}
fn setup(secure: bool) -> (Router, Arc<Store>, String, String) {
    let refresh = signed(TokenKind::Refresh, "original-refresh");
    let access = signed(TokenKind::Access, "original-access");
    let store = Arc::new(Store(Mutex::new(Row {
        refresh_hash: digest(&refresh),
        access_jti: "original-access".into(),
        revoked: false,
        expired: false,
        fail: false,
        fail_after_write: false,
        barrier: None,
        writes: 0,
    })));
    let router = build_native_router_with_refresh(
        codec(),
        store.clone(),
        CorsPolicy {
            origins: vec!["https://app.example".into()],
            localhost: false,
        },
        Arc::new(|| NOW),
        RefreshPolicy {
            access_seconds: 60,
            refresh_seconds: 120,
            cookie_secure: secure,
        },
    );
    (router, store, refresh, access)
}
fn request(cookie: Option<&str>, body: &str, content_type: &str) -> Request<Body> {
    let mut r = Request::builder()
        .method("PATCH")
        .uri("/api/v2/auth/tokens/current")
        .header("content-type", content_type);
    if let Some(c) = cookie {
        r = r.header("cookie", c);
    }
    r.body(Body::from(body.to_owned())).unwrap()
}
async fn body(response: axum::response::Response) -> serde_json::Value {
    serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes()).unwrap()
}

fn logout(
    cookie: Option<&str>,
    authorization: Option<&str>,
    payload: &str,
    content_type: &str,
) -> Request<Body> {
    let mut r = Request::builder()
        .method("DELETE")
        .uri("/api/v2/auth/tokens/current")
        .header("content-type", content_type);
    if let Some(v) = cookie {
        r = r.header("cookie", v);
    }
    if let Some(v) = authorization {
        r = r.header("authorization", v);
    }
    r.body(Body::from(payload.to_owned())).unwrap()
}

async fn assert_logout(response: axum::response::Response) {
    assert_eq!(response.status(), 200);
    let cookies: Vec<_> = response
        .headers()
        .get_all("set-cookie")
        .iter()
        .map(|v| v.to_str().unwrap().to_string())
        .collect();
    assert_eq!(cookies.len(), 2);
    for name in ["access_token", "refresh_token"] {
        assert!(cookies.iter().any(|v| v.starts_with(&format!("{name}="))
            && v.contains("Max-Age=0")
            && v.contains("Path=/")));
    }
    assert_eq!(
        body(response).await,
        serde_json::json!({"code":200,"message":"logout success","data":null,"meta":null})
    );
}

#[tokio::test]
async fn logout_by_refresh_or_access_revokes_only_matching_session_and_clears_cookies() {
    for mode in 0..4 {
        let (router, store, refresh, access) = setup(false);
        let cookie = match mode {
            0 => Some(format!("refresh_token={refresh}")),
            2 => Some(format!("access_token={access}")),
            _ => None,
        };
        let bearer = (mode == 3).then(|| format!("Bearer {access}"));
        let payload = if mode == 1 {
            format!("{{\"refresh_token\":\"{refresh}\"}}")
        } else {
            "{}".into()
        };
        let response = router
            .clone()
            .oneshot(logout(
                cookie.as_deref(),
                bearer.as_deref(),
                &payload,
                "application/json",
            ))
            .await
            .unwrap();
        assert_logout(response).await;
        assert!(store.0.lock().unwrap().revoked, "mode {mode}");
        assert_eq!(
            router
                .oneshot(request(
                    None,
                    &format!("{{\"refresh_token\":\"{refresh}\"}}"),
                    "application/json"
                ))
                .await
                .unwrap()
                .status(),
            401
        );
    }
}

#[tokio::test]
async fn logout_precedence_and_stale_credentials_never_revoke_another_session() {
    for mode in 0..8 {
        let (router, store, refresh, access) = setup(false);
        let stale = signed(TokenKind::Refresh, "stale");
        let (cookie, auth, payload): (Option<String>, Option<String>, String) = match mode {
            0 => (
                Some("refresh_token=invalid".into()),
                Some(format!("Bearer {access}")),
                format!("{{\"refresh_token\":\"{refresh}\"}}"),
            ),
            1 => (
                None,
                Some(format!("Bearer {access}")),
                format!("{{\"refresh_token\":\"{stale}\"}}"),
            ),
            2 => (
                Some("access_token=invalid".into()),
                Some(format!("Bearer {access}")),
                "{}".into(),
            ),
            3 => (None, Some(access), "{}".into()),
            4 => (None, None, "{}".into()),
            5 => (Some("refresh_token=invalid".into()), None, "{}".into()),
            6 => (None, Some(format!("Bearer {access} trailing")), "{}".into()),
            _ => (None, Some(format!("Bearer {access} ")), "{}".into()),
        };
        assert_logout(
            router
                .oneshot(logout(
                    cookie.as_deref(),
                    auth.as_deref(),
                    &payload,
                    "application/json",
                ))
                .await
                .unwrap(),
        )
        .await;
        assert!(!store.0.lock().unwrap().revoked, "mode {mode}");
        assert_eq!(store.0.lock().unwrap().writes, 0);
    }
}

#[tokio::test]
async fn logout_refresh_cookie_and_form_priority_and_storage_errors() {
    let (router, store, refresh, access) = setup(false);
    let response = router
        .oneshot(logout(
            Some("refresh_token=%20%20"),
            Some(&format!("Bearer {access}")),
            &format!("{{\"refresh_token\":\"{refresh}\"}}"),
            "application/json",
        ))
        .await
        .unwrap();
    assert_logout(response).await;
    assert!(store.0.lock().unwrap().revoked);
    let (router, store, refresh, _) = setup(false);
    let response = router
        .oneshot(logout(
            None,
            None,
            &format!("refresh_token={refresh}"),
            "application/x-www-form-urlencoded",
        ))
        .await
        .unwrap();
    assert_logout(response).await;
    assert!(store.0.lock().unwrap().revoked);
    let (router, store, refresh, _) = setup(false);
    store.0.lock().unwrap().fail = true;
    let response = router
        .oneshot(logout(
            None,
            None,
            &format!("{{\"refresh_token\":\"{refresh}\"}}"),
            "application/json",
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), 500);
    assert!(response.headers().get("set-cookie").is_none());
    assert!(!body(response).await.to_string().contains(&refresh));
}

#[tokio::test]
async fn logout_accepts_legacy_refresh_without_jti_and_ignores_database_expiry() {
    let (router, store, _, _) = setup(false);
    let token = jsonwebtoken::encode(&jsonwebtoken::Header::new(jsonwebtoken::Algorithm::HS256),
        &serde_json::json!({"userId":42,"userName":"kitty","sessionId":"sess_test","type":"refresh","iat":NOW-1,"exp":NOW+100}),
        &jsonwebtoken::EncodingKey::from_secret(REFRESH_KEY)).unwrap();
    {
        let mut row = store.0.lock().unwrap();
        row.refresh_hash = digest(&token);
        row.expired = true;
    }
    assert_logout(
        router
            .oneshot(logout(
                Some(&format!("refresh_token={token}")),
                None,
                "",
                "application/json",
            ))
            .await
            .unwrap(),
    )
    .await;
    assert!(store.0.lock().unwrap().revoked);
}

#[tokio::test]
async fn valid_refresh_selects_its_session_even_with_a_different_access_identity() {
    let (router, store, refresh, _) = setup(false);
    let other_access = codec()
        .sign(&IssuedToken {
            user_id: 7,
            user_name: "other".into(),
            session_id: "different".into(),
            kind: TokenKind::Access,
            issued_at: NOW - 1,
            expires_at: NOW + 100,
            jti: "other-jti".into(),
        })
        .unwrap();
    let response = router
        .oneshot(logout(
            Some(&format!(
                "refresh_token={refresh}; access_token={other_access}"
            )),
            Some(&format!("Bearer {other_access}")),
            "{}",
            "application/json",
        ))
        .await
        .unwrap();
    assert_logout(response).await;
    assert!(store.0.lock().unwrap().revoked);
}

#[tokio::test]
async fn logout_with_two_accounts_never_revokes_the_unselected_access_session() {
    struct Entry {
        user: u64,
        jti: String,
        hash: String,
        revoked: bool,
    }
    struct TwoSessions(Mutex<std::collections::HashMap<String, Entry>>);
    impl SessionRepository for TwoSessions {
        fn touch<'a>(&'a self, claims: &'a TokenClaims) -> StoreFuture<'a, u64> {
            Box::pin(async move {
                let rows = self.0.lock().unwrap();
                Ok(u64::from(rows.get(&claims.session_id).is_some_and(|row| {
                    !row.revoked && row.user == claims.user_id && row.jti == claims.jti
                })))
            })
        }
        fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
            Box::pin(async { Ok(0) })
        }
        fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
            Box::pin(async { Ok(0) })
        }
        fn revoke_current<'a>(
            &'a self,
            user: u64,
            session: &'a str,
            credential: &'a SessionCredential,
        ) -> StoreFuture<'a, u64> {
            Box::pin(async move {
                let mut rows = self.0.lock().unwrap();
                let Some(row) = rows.get_mut(session) else {
                    return Ok(0);
                };
                let matches = match credential {
                    SessionCredential::AccessJti(jti) => row.jti == *jti,
                    SessionCredential::RefreshHash(hash) => row.hash == *hash,
                };
                if row.user != user || row.revoked || !matches {
                    return Ok(0);
                }
                row.revoked = true;
                Ok(1)
            })
        }
    }
    let refresh = signed(TokenKind::Refresh, "original-refresh");
    let other = codec()
        .sign(&IssuedToken {
            user_id: 7,
            user_name: "other".into(),
            session_id: "different".into(),
            kind: TokenKind::Access,
            issued_at: NOW - 1,
            expires_at: NOW + 100,
            jti: "other-jti".into(),
        })
        .unwrap();
    let store = Arc::new(TwoSessions(Mutex::new(std::collections::HashMap::from([
        (
            "sess_test".into(),
            Entry {
                user: 42,
                jti: "original-access".into(),
                hash: digest(&refresh),
                revoked: false,
            },
        ),
        (
            "different".into(),
            Entry {
                user: 7,
                jti: "other-jti".into(),
                hash: "other-hash".into(),
                revoked: false,
            },
        ),
    ]))));
    let router = build_native_router_with_refresh(
        codec(),
        store.clone(),
        CorsPolicy::default(),
        Arc::new(|| NOW),
        RefreshPolicy::default(),
    );
    assert_logout(
        router
            .clone()
            .oneshot(logout(
                Some(&format!("refresh_token={refresh}; access_token={other}")),
                None,
                "{}",
                "application/json",
            ))
            .await
            .unwrap(),
    )
    .await;
    {
        let rows = store.0.lock().unwrap();
        assert!(rows["sess_test"].revoked);
        assert!(!rows["different"].revoked);
    }
    let protected = router
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/api/v2/auth/sessions/others")
                .header("authorization", format!("Bearer {other}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(protected.status(), 200);
}

#[tokio::test]
async fn stale_logout_after_rotation_cannot_revoke_new_session() {
    let (router, store, old_refresh, old_access) = setup(false);
    let response = router
        .clone()
        .oneshot(request(
            None,
            &format!("{{\"refresh_token\":\"{old_refresh}\"}}"),
            "application/json",
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    let updated = body(response).await;
    let attempts: [(Option<String>, Option<String>, String); 3] = [
        (
            None,
            None,
            format!("{{\"refresh_token\":\"{old_refresh}\"}}"),
        ),
        (None, Some(format!("Bearer {old_access}")), "{}".into()),
        (
            Some("refresh_token=invalid".into()),
            None,
            format!(
                "{{\"refresh_token\":\"{}\"}}",
                updated["data"]["refresh_token"].as_str().unwrap()
            ),
        ),
    ];
    for (cookie, auth, payload) in attempts {
        assert_logout(
            router
                .clone()
                .oneshot(logout(
                    cookie.as_deref(),
                    auth.as_deref(),
                    &payload,
                    "application/json",
                ))
                .await
                .unwrap(),
        )
        .await;
        assert!(!store.0.lock().unwrap().revoked);
    }
    let new_access = updated["data"]["access_token"].as_str().unwrap();
    let protected = router
        .clone()
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/api/v2/auth/sessions/others")
                .header("authorization", format!("Bearer {new_access}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(protected.status(), 200);
    let new_refresh = updated["data"]["refresh_token"].as_str().unwrap();
    assert_logout(
        router
            .oneshot(logout(
                None,
                None,
                &format!("{{\"refresh_token\":\"{new_refresh}\"}}"),
                "application/json",
            ))
            .await
            .unwrap(),
    )
    .await;
    assert!(store.0.lock().unwrap().revoked);
}

#[tokio::test]
async fn logout_rejects_mismatched_identity_and_handles_unknown_commit() {
    for (user_id, session_id) in [(43, "sess_test"), (42, "other_session")] {
        let (router, store, _, _) = setup(false);
        let token = codec()
            .sign(&IssuedToken {
                user_id,
                user_name: "kitty".into(),
                session_id: session_id.into(),
                kind: TokenKind::Refresh,
                issued_at: NOW - 1,
                expires_at: NOW + 100,
                jti: "test".into(),
            })
            .unwrap();
        store.0.lock().unwrap().refresh_hash = digest(&token);
        assert_logout(
            router
                .oneshot(logout(
                    None,
                    None,
                    &format!("{{\"refresh_token\":\"{token}\"}}"),
                    "application/json",
                ))
                .await
                .unwrap(),
        )
        .await;
        assert!(!store.0.lock().unwrap().revoked);
    }
    let (router, store, refresh, _) = setup(false);
    store.0.lock().unwrap().fail_after_write = true;
    let response = router
        .clone()
        .oneshot(logout(
            None,
            None,
            &format!("{{\"refresh_token\":\"{refresh}\"}}"),
            "application/json",
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), 500);
    assert!(response.headers().get("set-cookie").is_none());
    assert!(store.0.lock().unwrap().revoked);
    store.0.lock().unwrap().fail_after_write = false;
    assert_logout(
        router
            .oneshot(logout(
                None,
                None,
                &format!("{{\"refresh_token\":\"{refresh}\"}}"),
                "application/json",
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(store.0.lock().unwrap().writes, 1);
}

#[tokio::test]
async fn logout_cors_preflight_does_not_touch_storage() {
    let (router, store, _, _) = setup(false);
    let response = router
        .oneshot(
            Request::builder()
                .method("OPTIONS")
                .uri("/api/v2/auth/tokens/current")
                .header("origin", "https://app.example")
                .header("access-control-request-method", "DELETE")
                .header("access-control-request-headers", "content-type")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), 204);
    assert_eq!(store.0.lock().unwrap().writes, 0);
}

#[tokio::test]
async fn body_refresh_rotates_tokens_and_invalidates_old_access_and_refresh() {
    let (router, store, old_refresh, old_access) = setup(true);
    let response = router
        .clone()
        .oneshot(request(
            None,
            &format!("{{\"refresh_token\":\" {old_refresh} \"}}"),
            "application/json",
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    let cookies: Vec<_> = response
        .headers()
        .get_all("set-cookie")
        .iter()
        .map(|v| v.to_str().unwrap().to_owned())
        .collect();
    assert_eq!(cookies.len(), 2);
    assert!(cookies.iter().all(|c| c.contains("HttpOnly")
        && c.contains("SameSite=Lax")
        && c.contains("Path=/")
        && c.contains("Secure")));
    let json = body(response).await;
    assert_eq!(json["code"], 200);
    assert_eq!(json["message"], "success");
    assert_eq!(json["meta"], serde_json::Value::Null);
    assert_eq!(json["data"]["session_id"], "sess_test");
    let new_access = json["data"]["access_token"].as_str().unwrap();
    let new_refresh = json["data"]["refresh_token"].as_str().unwrap();
    assert_ne!(new_refresh, old_refresh);
    assert!(
        cookies
            .iter()
            .any(|c| c.starts_with(&format!("access_token={new_access};"))
                && c.contains("Max-Age=60"))
    );
    assert!(cookies
        .iter()
        .any(|c| c.starts_with(&format!("refresh_token={new_refresh};"))
            && c.contains("Max-Age=120")));
    let old_claims = codec().verify(&old_access, TokenKind::Access, NOW).unwrap();
    let new_claims = codec().verify(new_access, TokenKind::Access, NOW).unwrap();
    assert_eq!(store.touch(&old_claims).await.unwrap(), 0);
    assert_eq!(store.touch(&new_claims).await.unwrap(), 1);
    assert_eq!(
        codec()
            .verify(new_refresh, TokenKind::Refresh, NOW)
            .unwrap()
            .expires_at,
        Some((NOW + 120) as f64)
    );
    let replay = router
        .clone()
        .oneshot(request(
            None,
            &format!("{{\"refresh_token\":\"{old_refresh}\"}}"),
            "application/json",
        ))
        .await
        .unwrap();
    assert_eq!(replay.status(), 401);
    assert!(replay.headers().get("set-cookie").is_none());
    let again = router
        .oneshot(request(
            None,
            &format!("{{\"refresh_token\":\"{new_refresh}\"}}"),
            "application/json",
        ))
        .await
        .unwrap();
    assert_eq!(again.status(), 200);
    assert_ne!(body(again).await["data"]["refresh_token"], new_refresh);
}

#[tokio::test]
async fn cookie_priority_form_body_and_invalid_tokens() {
    for case in 0..12 {
        let (router, store, token, _) = setup(false);
        let valid = format!("{{\"refresh_token\":\"{token}\"}}");
        let (cookie, payload, content_type, status) = match case {
            0 => (
                Some(format!("refresh_token={token}")),
                "invalid json".into(),
                "application/json",
                200,
            ),
            1 => (
                Some("refresh_token=invalid".into()),
                valid,
                "application/json",
                401,
            ),
            2 => (
                Some("refresh_token=%20%20".into()),
                valid,
                "application/json",
                401,
            ),
            3 => (
                None,
                format!("refresh_token={token}"),
                "application/x-www-form-urlencoded",
                200,
            ),
            4 => (None, "{".into(), "application/json", 401),
            5 => (
                None,
                "{\"refresh_token\":42}".into(),
                "application/json",
                401,
            ),
            6 => (
                None,
                "{\"refresh_token\":\"garbage\"}".into(),
                "application/json",
                401,
            ),
            7 => {
                store.0.lock().unwrap().revoked = true;
                (None, valid, "application/json", 401)
            }
            8 => {
                store.0.lock().unwrap().expired = true;
                (None, valid, "application/json", 401)
            }
            9 => {
                let invalid = signed(TokenKind::Access, "wrong-type");
                (
                    None,
                    format!("{{\"refresh_token\":\"{invalid}\"}}"),
                    "application/json",
                    401,
                )
            }
            10 => {
                let invalid = TokenCodec::new(ACCESS_KEY, b"another-refresh-key")
                    .unwrap()
                    .sign(&IssuedToken {
                        user_id: 42,
                        user_name: "kitty".into(),
                        session_id: "sess_test".into(),
                        kind: TokenKind::Refresh,
                        issued_at: NOW - 20,
                        expires_at: NOW + 100,
                        jti: "wrong-key".into(),
                    })
                    .unwrap();
                (
                    None,
                    format!("{{\"refresh_token\":\"{invalid}\"}}"),
                    "application/json",
                    401,
                )
            }
            _ => {
                let invalid = codec()
                    .sign(&IssuedToken {
                        user_id: 42,
                        user_name: "kitty".into(),
                        session_id: "sess_test".into(),
                        kind: TokenKind::Refresh,
                        issued_at: NOW - 20,
                        expires_at: NOW,
                        jti: "expired".into(),
                    })
                    .unwrap();
                (
                    None,
                    format!("{{\"refresh_token\":\"{invalid}\"}}"),
                    "application/json",
                    401,
                )
            }
        };
        let response = router
            .oneshot(request(cookie.as_deref(), &payload, content_type))
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), status, "case {case}");
        if status == 401 {
            assert!(response.headers().get("set-cookie").is_none());
            assert_eq!(store.0.lock().unwrap().writes, 0);
        }
    }
}

#[tokio::test]
async fn concurrent_refresh_has_single_winner_and_store_failure_is_safe() {
    let (router, store, token, _) = setup(false);
    store.0.lock().unwrap().barrier = Some(Arc::new(tokio::sync::Barrier::new(2)));
    let payload = format!("{{\"refresh_token\":\"{token}\"}}");
    let (a, b) = tokio::join!(
        router
            .clone()
            .oneshot(request(None, &payload, "application/json")),
        router
            .clone()
            .oneshot(request(None, &payload, "application/json"))
    );
    let mut statuses = [a.unwrap().status().as_u16(), b.unwrap().status().as_u16()];
    statuses.sort();
    assert_eq!(statuses, [200, 401]);
    assert_eq!(store.0.lock().unwrap().writes, 1);
    let (router, store, token, _) = setup(false);
    store.0.lock().unwrap().fail = true;
    let response = router
        .oneshot(request(
            None,
            &format!("{{\"refresh_token\":\"{token}\"}}"),
            "application/json",
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), 500);
    assert!(response.headers().get("set-cookie").is_none());
    assert!(!body(response).await.to_string().contains(&token));
}

#[tokio::test]
async fn refresh_cors_preflight_does_not_use_store() {
    let (router, store, _, _) = setup(false);
    let response = router
        .oneshot(
            Request::builder()
                .method("OPTIONS")
                .uri("/api/v2/auth/tokens/current")
                .header("origin", "https://app.example")
                .header("access-control-request-method", "PATCH")
                .header("access-control-request-headers", "content-type")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), 204);
    assert_eq!(
        response.headers()["access-control-allow-origin"],
        "https://app.example"
    );
    assert_eq!(store.0.lock().unwrap().writes, 0);
}

#[tokio::test]
async fn uncertain_committed_write_never_sends_tokens_or_retries() {
    let (router, store, token, _) = setup(false);
    store.0.lock().unwrap().fail_after_write = true;
    let payload = format!("{{\"refresh_token\":\"{token}\"}}");
    let response = router
        .clone()
        .oneshot(request(None, &payload, "application/json"))
        .await
        .unwrap();
    assert_eq!(response.status(), 500);
    assert!(response.headers().get("set-cookie").is_none());
    assert_eq!(store.0.lock().unwrap().writes, 1);
    store.0.lock().unwrap().fail_after_write = false;
    let replay = router
        .oneshot(request(None, &payload, "application/json"))
        .await
        .unwrap();
    assert_eq!(replay.status(), 401);
    assert_eq!(store.0.lock().unwrap().writes, 1);
}

#[tokio::test]
async fn public_refresh_ignores_stale_access_cookie_and_rejects_mismatched_session() {
    let (router, _, refresh, _) = setup(false);
    let response = router
        .oneshot(request(
            Some("access_token=expired"),
            &format!("{{\"refresh_token\":\"{refresh}\"}}"),
            "application/json",
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    for (user_id, session_id) in [(43, "sess_test"), (42, "another_session")] {
        let (router, store, _, _) = setup(false);
        let refresh = codec()
            .sign(&IssuedToken {
                user_id,
                user_name: "kitty".into(),
                session_id: session_id.into(),
                kind: TokenKind::Refresh,
                issued_at: NOW - 1,
                expires_at: NOW + 100,
                jti: "test".into(),
            })
            .unwrap();
        store.0.lock().unwrap().refresh_hash = digest(&refresh);
        let response = router
            .oneshot(request(
                None,
                &format!("{{\"refresh_token\":\"{refresh}\"}}"),
                "application/json",
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), 401);
        assert_eq!(store.0.lock().unwrap().writes, 0);
    }
}

#[tokio::test]
async fn refresh_accepts_signed_legacy_token_without_jti_but_rejects_text_body() {
    let (router, store, standard_token, _) = setup(false);
    let standard_payload = format!("{{\"refresh_token\":\"{standard_token}\"}}");
    let response = router
        .clone()
        .oneshot(request(None, &standard_payload, "text/plain"))
        .await
        .unwrap();
    assert_eq!(response.status(), 401);
    let token = jsonwebtoken::encode(&jsonwebtoken::Header::new(jsonwebtoken::Algorithm::HS256),
        &serde_json::json!({"userId": 42, "userName": "kitty", "sessionId": "sess_test", "type": "refresh", "iat": NOW - 1, "exp": NOW + 100}),
        &jsonwebtoken::EncodingKey::from_secret(REFRESH_KEY)).unwrap();
    store.0.lock().unwrap().refresh_hash = digest(&token);
    let payload = format!("{{\"refresh_token\":\"{token}\"}}");
    let response = router
        .oneshot(request(None, &payload, "application/json"))
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
}

#[tokio::test]
async fn cookie_refresh_does_not_read_large_body() {
    let (router, _, token, _) = setup(false);
    let response = router
        .oneshot(request(
            Some(&format!("refresh_token={token}")),
            &"x".repeat(2 * 1024 * 1024 + 1),
            "application/json",
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    let (router, store, _, _) = setup(false);
    let response = router
        .oneshot(request(
            None,
            &"x".repeat(1024 * 1024 + 1),
            "application/json",
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), 401);
    assert_eq!(store.0.lock().unwrap().writes, 0);
}
