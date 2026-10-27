use nekotribe_backend::{
    auth::{
        login::{LoginChallenge, LoginDevice, LoginSession},
        session_repository::{OracleSessions, SessionExecutor},
        sessions::{
            SessionCredential, SessionRepository, SessionRotation, SessionStoreError, StoreFuture,
        },
        TokenClaims, TokenKind,
    },
    db::{oracle::BindMap, row::DbRow, value::DbValue},
};
use std::sync::Mutex;
#[derive(Default)]
struct Executor {
    calls: Mutex<Vec<(&'static str, BindMap)>>,
    fail: bool,
}

#[derive(Default)]
struct OtpExecutor {
    calls: Mutex<Vec<(&'static str, BindMap)>>,
}
impl SessionExecutor for OtpExecutor {
    fn execute(&self, q: &'static str, b: BindMap) -> StoreFuture<'_, u64> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((q, b));
            Ok(1)
        })
    }
    fn preflight(&self, _: &'static str) -> StoreFuture<'_, ()> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn query(&self, q: &'static str, b: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((q, b));
            if q.contains("seq_otp_event_id.NEXTVAL") {
                Ok(vec![DbRow::from([("ID".into(), DbValue::I64(123))])])
            } else if q.contains("verification_code_hash") {
                Ok(vec![DbRow::from([(
                    "VERIFICATION_CODE_HASH".into(),
                    DbValue::String("synthetic-hash".into()),
                )])])
            } else {
                Ok(vec![DbRow::from([(
                    "VERIFIED_AT".into(),
                    DbValue::String("2026-01-02T11:04:05+08:00".into()),
                )])])
            }
        })
    }
}
#[tokio::test]
async fn otp_creation_repository_uses_sequence_and_bound_insert() {
    use nekotribe_backend::auth::otp::OtpEvent;
    let repo = OracleSessions {
        executor: OtpExecutor::default(),
    };
    let id = repo.otp_next_id().await.unwrap();
    assert_eq!(id, 123);
    let event = OtpEvent {
        sequence: id,
        account: "fake';--".into(),
        kind: "register".into(),
        channel: "email".into(),
        hash: "synthetic-hash".into(),
        id: "otp_fixture".into(),
        expires: "2026-01-02T03:09:05.000Z".into(),
    };
    repo.otp_insert(&event).await.unwrap();
    let calls = repo.executor.calls.lock().unwrap();
    assert_eq!(calls.len(), 2);
    assert!(calls[0].0.contains("seq_otp_event_id.NEXTVAL"));
    assert!(!calls[1].0.contains("fake';--"));
    for (key, value) in [
        ("account", DbValue::String("fake';--".into())),
        ("otp_type", DbValue::String("register".into())),
        ("send_channel", DbValue::String("email".into())),
        (
            "verification_code_hash",
            DbValue::String("synthetic-hash".into()),
        ),
        ("verification_id", DbValue::String("otp_fixture".into())),
        (
            "expires_at",
            DbValue::String("2026-01-02T03:09:05.000+00:00".into()),
        ),
        ("otp_event_id", DbValue::I64(123)),
    ] {
        assert_eq!(calls[1].1[key], value);
    }
}
#[tokio::test]
async fn otp_repository_binds_values_and_maps_date() {
    let repo = OracleSessions {
        executor: OtpExecutor::default(),
    };
    assert_eq!(
        repo.otp_lookup("fake';--", "register", "otp_fixture")
            .await
            .unwrap()
            .as_deref(),
        Some("synthetic-hash")
    );
    repo.otp_mark("otp_fixture").await.unwrap();
    assert_eq!(
        repo.otp_verified_at("otp_fixture")
            .await
            .unwrap()
            .as_deref(),
        Some("2026-01-02T03:04:05.000Z")
    );
    let calls = repo.executor.calls.lock().unwrap();
    assert_eq!(calls.len(), 3);
    assert!(calls[0].0.contains("expires_at > CURRENT_TIMESTAMP"));
    assert!(!calls[0].0.contains("fake';--"));
    assert_eq!(calls[0].1["account"], DbValue::String("fake';--".into()));
    assert_eq!(calls[0].1["otp_type"], DbValue::String("register".into()));
    for call in calls.iter() {
        assert_eq!(
            call.1["verification_id"],
            DbValue::String("otp_fixture".into())
        );
    }
    assert!(calls[1]
        .0
        .starts_with("UPDATE n_auth_otp_events SET verified_at"));
}

#[derive(Default)]
struct ListExecutor {
    calls: Mutex<Vec<(&'static str, BindMap)>>,
}
impl SessionExecutor for ListExecutor {
    fn execute(&self, _: &'static str, _: BindMap) -> StoreFuture<'_, u64> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn preflight(&self, _: &'static str) -> StoreFuture<'_, ()> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn query(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((sql, binds));
            if sql.contains("COUNT(*)") {
                return Ok(vec![DbRow::from([("TOTAL".into(), DbValue::I64(2))])]);
            }
            Ok(vec![DbRow::from([
                ("SESSION_ID".into(), DbValue::String("a".into())),
                ("DEVICE_INFO".into(), DbValue::Null),
                ("IP_ADDRESS".into(), DbValue::String("127.0.0.1".into())),
                (
                    "LAST_ACCESSED_AT".into(),
                    DbValue::String("2026-01-01T08:00:00+08:00".into()),
                ),
                ("CREATED_AT".into(), DbValue::Null),
            ])])
        })
    }
}
#[tokio::test]
async fn list_session_repository_binds_identity_pagination_and_maps_rows() {
    use nekotribe_backend::auth::session_list::SessionPage;
    let repo = OracleSessions {
        executor: ListExecutor::default(),
    };
    let (items, total) = repo
        .list_sessions(
            42,
            SessionPage {
                page: 1.0,
                page_size: 1.0,
                start: 1.5,
                end: 4.5,
            },
        )
        .await
        .unwrap();
    assert_eq!(total, 2);
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].session_id, "a");
    assert_eq!(items[0].device_info, "");
    assert_eq!(items[0].last_accessed_at, "2026-01-01T00:00:00.000Z");
    assert_eq!(items[0].created_at, "");
    let calls = repo.executor.calls.lock().unwrap();
    assert_eq!(calls.len(), 2);
    assert!(calls[0].0.contains("revoked_at IS NULL"));
    assert!(calls[1]
        .0
        .contains("ROW_NUMBER() OVER (ORDER BY last_accessed_at DESC)"));
    assert_eq!(calls[1].1["user_id"], DbValue::I64(42));
    assert_eq!(calls[1].1["start_row"], DbValue::F64(1.5));
    assert_eq!(calls[1].1["end_row"], DbValue::F64(4.5));
}

#[tokio::test]
async fn logout_repository_binds_exact_user_session_and_current_credential() {
    let repo = OracleSessions {
        executor: Executor::default(),
    };
    assert_eq!(
        repo.revoke_current(
            42,
            "session';--",
            &SessionCredential::AccessJti("old-jti".into())
        )
        .await
        .unwrap(),
        1
    );
    assert_eq!(
        repo.revoke_current(
            42,
            "session';--",
            &SessionCredential::RefreshHash("old-hash".into())
        )
        .await
        .unwrap(),
        1
    );
    let calls = repo.executor.calls.lock().unwrap();
    for (sql, binds) in calls.iter() {
        assert!(sql.contains("session_id = :session_id"));
        assert!(sql.contains("user_id = :user_id"));
        assert!(sql.contains("revoked_at IS NULL"));
        assert!(!sql.contains("expires_at"));
        assert!(!sql.contains("session';--"));
        assert_eq!(binds["user_id"], DbValue::I64(42));
        assert_eq!(binds["session_id"], DbValue::String("session';--".into()));
    }
    assert!(calls[0].0.contains("access_jti = :access_jti"));
    assert_eq!(calls[0].1["access_jti"], DbValue::String("old-jti".into()));
    assert!(calls[1]
        .0
        .contains("refresh_token_hash = :refresh_token_hash"));
    assert_eq!(
        calls[1].1["refresh_token_hash"],
        DbValue::String("old-hash".into())
    );
}
impl SessionExecutor for Executor {
    fn readiness_snapshot(&self) -> StoreFuture<'_, serde_json::Value> {
        Box::pin(async move {
            if self.fail {
                return Err(SessionStoreError);
            }
            let fixture: serde_json::Value = serde_json::from_str(include_str!(
                "../contracts/scenarios/two-factor-readiness.json"
            ))
            .unwrap();
            Ok(fixture["baseline"].clone())
        })
    }
    fn query(&self, q: &'static str, b: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((q, b));
            if self.fail {
                Err(SessionStoreError)
            } else {
                Ok(vec![])
            }
        })
    }
    fn execute(&self, q: &'static str, b: BindMap) -> StoreFuture<'_, u64> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((q, b));
            if self.fail {
                Err(SessionStoreError)
            } else {
                Ok(1)
            }
        })
    }
    fn preflight(&self, q: &'static str) -> StoreFuture<'_, ()> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((q, BindMap::new()));
            if self.fail {
                Err(SessionStoreError)
            } else {
                Ok(())
            }
        })
    }
}

#[tokio::test]
async fn two_factor_readiness_requires_a_valid_metadata_snapshot() {
    let repo = OracleSessions {
        executor: Executor::default(),
    };
    repo.two_factor_readiness().await.unwrap();
    let broken = OracleSessions {
        executor: Executor {
            fail: true,
            ..Default::default()
        },
    };
    assert!(broken.two_factor_readiness().await.is_err());
}

#[tokio::test]
async fn native_login_queries_and_writes_use_named_binds_and_independent_operations() {
    let repo = OracleSessions {
        executor: Executor::default(),
    };
    assert!(repo
        .login_account("untrusted' OR 1=1--")
        .await
        .unwrap()
        .is_none());
    let device = || LoginDevice {
        fingerprint: "device".into(),
        info: "browser".into(),
        ip: "127.0.0.1".into(),
        user_agent: "test".into(),
    };
    let challenge = LoginChallenge {
        id: "2fa_id".into(),
        user_id: 42,
        remember: true,
        device: device(),
        expires_at: "2023-11-14T22:18:20.000Z".into(),
    };
    repo.login_challenge(&challenge).await.unwrap();
    let session = LoginSession {
        id: "sess_id".into(),
        user_id: 42,
        access_jti: "jti".into(),
        refresh_hash: "hash".into(),
        device: device(),
        access_expires_at: "2023-11-14T22:28:20.000Z".into(),
        refresh_expires_at: "2023-12-14T22:13:20.000Z".into(),
    };
    repo.login_insert_session(&session).await.unwrap();
    let calls = repo.executor.calls.lock().unwrap();
    assert_eq!(calls.len(), 4);
    assert!(!calls[0].0.contains("untrusted"));
    assert_eq!(
        calls[0].1["account"],
        DbValue::String("untrusted' OR 1=1--".into())
    );
    assert!(calls[1]
        .0
        .contains("INSERT INTO n_auth_two_factor_challenges"));
    assert_eq!(calls[1].1["challenge_id"], DbValue::String("2fa_id".into()));
    assert!(calls[2].0.contains("INSERT INTO n_auth_sessions"));
    assert_eq!(
        calls[2].1["refresh_token_hash"],
        DbValue::String("hash".into())
    );
    assert!(calls[3].0.contains("UPDATE n_users SET last_login_at"));
    assert_eq!(calls[3].1["user_id"], DbValue::I64(42));
}

#[tokio::test]
async fn trusted_device_lookup_requires_unexpired_and_unrevoked_owner_match() {
    let repo = OracleSessions {
        executor: Executor::default(),
    };
    let device = LoginDevice {
        fingerprint: "device';--".into(),
        info: "browser".into(),
        ip: "127.0.0.1".into(),
        user_agent: "test".into(),
    };
    assert!(!repo.login_trusted_device(42, &device).await.unwrap());
    let calls = repo.executor.calls.lock().unwrap();
    let (sql, binds) = &calls[0];
    assert!(sql.contains("user_id = :user_id"));
    assert!(sql.contains("expires_at > CURRENT_TIMESTAMP"));
    assert!(sql.contains("revoked_at IS NULL"));
    assert!(!sql.contains("device';--"));
    assert_eq!(binds["user_id"], DbValue::I64(42));
    assert_eq!(
        binds["device_fingerprint"],
        DbValue::String("device';--".into())
    );
}

struct AlertExecutor {
    enabled: bool,
    kind_enabled: bool,
    calls: Mutex<Vec<(&'static str, BindMap)>>,
}
impl SessionExecutor for AlertExecutor {
    fn preflight(&self, _: &'static str) -> StoreFuture<'_, ()> {
        Box::pin(async { Ok(()) })
    }
    fn execute(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, u64> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((sql, binds));
            Ok(1)
        })
    }
    fn query(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((sql, binds));
            let row = if sql.contains("COUNT(*)") {
                DbRow::from([("TOTAL".into(), DbValue::I64(0))])
            } else if sql.contains("login_alerts") {
                DbRow::from([("LOGIN_ALERTS".into(), DbValue::I64(i64::from(self.enabled)))])
            } else if sql.contains("type_enabled") {
                DbRow::from([(
                    "TYPE_ENABLED".into(),
                    DbValue::I64(i64::from(self.kind_enabled)),
                )])
            } else if sql.contains("NEXTVAL") {
                DbRow::from([("ID".into(), DbValue::I64(12))])
            } else {
                return Err(SessionStoreError);
            };
            Ok(vec![row])
        })
    }
}

#[tokio::test]
async fn login_alert_honors_device_history_and_both_preference_gates() {
    for (enabled, kind_enabled, expected_insert) in [
        (false, true, false),
        (true, false, false),
        (true, true, true),
    ] {
        let repo = OracleSessions {
            executor: AlertExecutor {
                enabled,
                kind_enabled,
                calls: Mutex::new(vec![]),
            },
        };
        assert!(!repo.known_login_device(42, "dev").await.unwrap());
        let session = LoginSession {
            id: "sess_1".into(),
            user_id: 42,
            access_jti: "jti".into(),
            refresh_hash: "hash".into(),
            device: LoginDevice {
                fingerprint: "dev".into(),
                info: "browser".into(),
                ip: "127.0.0.1".into(),
                user_agent: "test".into(),
            },
            access_expires_at: "".into(),
            refresh_expires_at: "".into(),
        };
        repo.record_login_alert(&session).await.unwrap();
        let calls = repo.executor.calls.lock().unwrap();
        let insert = calls
            .iter()
            .find(|(sql, _)| sql.starts_with("INSERT INTO n_notifications"));
        assert_eq!(insert.is_some(), expected_insert);
        if let Some((sql, binds)) = insert {
            assert!(!sql.contains("sess_1"));
            assert_eq!(binds["user_id"], DbValue::I64(42));
            assert_eq!(binds["type"], DbValue::String("login_alert".into()));
            assert!(binds["metadata_json"].as_str().unwrap().contains("sess_1"));
        }
    }
}
#[tokio::test]
async fn production_repository_uses_named_binds_and_independent_executor_calls() {
    let r = OracleSessions {
        executor: Executor::default(),
    };
    let c = TokenClaims {
        user_id: 42,
        user_name: None,
        session_id: "opaque';--".into(),
        kind: TokenKind::Access,
        issued_at: None,
        expires_at: None,
        jti: "jti".into(),
    };
    assert_eq!(r.touch(&c).await.unwrap(), 1);
    assert_eq!(r.revoke(42, "opaque';--").await.unwrap(), 1);
    assert_eq!(r.revoke_others(42, "current").await.unwrap(), 1);
    r.preflight().await.unwrap();
    let calls = r.executor.calls.lock().unwrap();
    assert_eq!(calls.len(), 4);
    for (q, b) in calls.iter().take(3) {
        assert!(q.contains("user_id = :user_id"));
        assert!(q.contains("revoked_at IS NULL"));
        assert!(!q.contains("opaque"));
        assert_eq!(b["user_id"], DbValue::I64(42))
    }
    assert!(calls[0].0.contains("last_accessed_at = CURRENT_TIMESTAMP"));
    assert!(calls[0]
        .0
        .contains("access_token_expires_at > CURRENT_TIMESTAMP"));
    assert!(calls[0].0.contains("access_jti = :access_jti"));
    assert_eq!(calls[0].1["access_jti"], DbValue::String("jti".into()));
    assert_eq!(
        calls[0].1["session_id"],
        DbValue::String("opaque';--".into())
    );
    assert!(calls[2].0.contains("session_id <> :session_id"));
    assert!(calls[3].0.contains("WHERE 1 = 0"));
    assert!(calls[3].1.is_empty())
}
#[tokio::test]
async fn production_repository_errors_are_safe() {
    let r = OracleSessions {
        executor: Executor {
            fail: true,
            ..Default::default()
        },
    };
    assert_eq!(
        r.revoke(42, "peer").await.unwrap_err().to_string(),
        "session store unavailable"
    );
    assert!(r.preflight().await.is_err())
}

#[tokio::test]
async fn rotation_uses_one_atomic_conditional_update_with_bound_values() {
    let r = OracleSessions {
        executor: Executor::default(),
    };
    let rotation = SessionRotation {
        user_id: 42,
        session_id: "sess_test".into(),
        old_refresh_hash: "old".into(),
        refresh_hash: "new".into(),
        access_jti: "new-jti".into(),
        access_expires_at: "2026-10-27T12:00:00.000Z".into(),
        refresh_expires_at: "2026-11-27T12:00:00.000Z".into(),
    };
    assert_eq!(r.rotate(&rotation).await.unwrap(), 1);
    let calls = r.executor.calls.lock().unwrap();
    assert_eq!(calls.len(), 1);
    let (sql, binds) = &calls[0];
    for clause in [
        "refresh_token_hash = :old_refresh_hash",
        "user_id = :user_id",
        "session_id = :session_id",
        "revoked_at IS NULL",
        "refresh_token_expires_at > CURRENT_TIMESTAMP",
        "last_refresh_at = CURRENT_TIMESTAMP",
    ] {
        assert!(sql.contains(clause), "{clause}");
    }
    assert_eq!(binds["old_refresh_hash"], DbValue::String("old".into()));
    assert_eq!(binds["refresh_token_hash"], DbValue::String("new".into()));
    assert_eq!(
        binds["access_expires_at"],
        DbValue::String("2026-10-27T12:00:00.000+00:00".into())
    );
}
