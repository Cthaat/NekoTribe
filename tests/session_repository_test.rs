use nekotribe_backend::{
    auth::{
        login::{EncryptedSecret, FactorCompletion, LoginChallenge, LoginDevice, LoginSession},
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
struct RegistrationExecutor {
    calls: Mutex<Vec<(&'static str, BindMap)>>,
}

#[tokio::test]
async fn password_reset_repository_passes_arguments_to_atomic_executor() {
    let repo = OracleSessions {
        executor: RegistrationExecutor::default(),
    };
    assert_eq!(
        repo.reset_password_atomic("fake';--", "otp_fixture", "otp-hash", "synthetic-hash")
            .await
            .unwrap(),
        0
    );
    let calls = repo.executor.calls.lock().unwrap();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].0, "RESET_ATOMIC");
    assert_eq!(calls[0].1["email"], DbValue::String("fake';--".into()));
    assert_eq!(
        calls[0].1["verification_id"],
        DbValue::String("otp_fixture".into())
    );
    assert_eq!(calls[0].1["code_hash"], DbValue::String("otp-hash".into()));
    assert_eq!(
        calls[0].1["password_hash"],
        DbValue::String("synthetic-hash".into())
    );
}
impl SessionExecutor for RegistrationExecutor {
    fn registration_insert<'a>(&'a self, record: &'a nekotribe_backend::auth::registration::RegistrationRecord, verification_id: &'a str) -> StoreFuture<'a, nekotribe_backend::auth::registration::Outcome> {
        Box::pin(async move {
            self.calls.lock().unwrap().push(("REGISTER_ATOMIC", BindMap::from([
                ("account".into(), DbValue::String(record.email.clone())),
                ("verification_id".into(), DbValue::String(verification_id.into())),
                ("password_hash".into(), DbValue::String(record.password_hash.clone())),
            ])));
            Ok(nekotribe_backend::auth::registration::Outcome::Registered)
        })
    }
    fn change_email_atomic<'a>(
        &'a self,
        user: u64,
        email: &'a str,
        id: &'a str,
        hash: &'a str,
    ) -> StoreFuture<'a, nekotribe_backend::users::email_change::EmailChange> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((
                "EMAIL_ATOMIC",
                BindMap::from([
                    ("user_id".into(), DbValue::I64(user as i64)),
                    ("email".into(), DbValue::String(email.into())),
                    ("verification_id".into(), DbValue::String(id.into())),
                    ("code_hash".into(), DbValue::String(hash.into())),
                ]),
            ));
            Ok(nekotribe_backend::users::email_change::EmailChange::Expired)
        })
    }
    fn reset_password_atomic<'a>(
        &'a self,
        email: &'a str,
        id: &'a str,
        otp_hash: &'a str,
        new_hash: &'a str,
    ) -> StoreFuture<'a, u64> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((
                "RESET_ATOMIC",
                BindMap::from([
                    ("email".into(), DbValue::String(email.into())),
                    ("verification_id".into(), DbValue::String(id.into())),
                    ("code_hash".into(), DbValue::String(otp_hash.into())),
                    ("password_hash".into(), DbValue::String(new_hash.into())),
                ]),
            ));
            Ok(0)
        })
    }
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
            if q.contains("n_auth_otp_events") {
                Ok(vec![DbRow::from([(
                    "VERIFIED_AT".into(),
                    DbValue::String("2026-01-02T03:04:05Z".into()),
                )])])
            } else if q.contains("COUNT(*)") {
                Ok(vec![DbRow::from([("TOTAL".into(), DbValue::I64(0))])])
            } else {
                Ok(vec![DbRow::from([("ID".into(), DbValue::I64(123))])])
            }
        })
    }
}

#[tokio::test]
async fn email_change_repository_forwards_identity_and_atomic_arguments() {
    let repo = OracleSessions {
        executor: RegistrationExecutor::default(),
    };
    let _ = repo.email_in_use(42, "fake';--").await.unwrap();
    assert_eq!(
        repo.change_email_atomic(42, "fake';--", "email_fixture", "private-hash")
            .await
            .unwrap(),
        nekotribe_backend::users::email_change::EmailChange::Expired
    );
    let calls = repo.executor.calls.lock().unwrap();
    assert_eq!(calls.len(), 2);
    assert!(calls[0]
        .0
        .contains("email = :email AND user_id != :user_id"));
    assert!(!calls[0].0.contains("fake';--"));
    assert_eq!(calls[0].1["user_id"], DbValue::I64(42));
    assert_eq!(calls[0].1["email"], DbValue::String("fake';--".into()));
    assert_eq!(calls[1].0, "EMAIL_ATOMIC");
    assert_eq!(calls[1].1["user_id"], DbValue::I64(42));
    assert_eq!(
        calls[1].1["verification_id"],
        DbValue::String("email_fixture".into())
    );
    assert_eq!(
        calls[1].1["code_hash"],
        DbValue::String("private-hash".into())
    );
}
#[tokio::test]
async fn registration_repository_binds_otp_duplicate_sequence_and_insert() {
    use nekotribe_backend::auth::registration::RegistrationRecord;
    let repo = OracleSessions {
        executor: RegistrationExecutor::default(),
    };
    assert!(repo
        .registration_otp("fake';--", "otp_fixture")
        .await
        .unwrap());
    assert!(!repo
        .registration_exists("fake';--", "username")
        .await
        .unwrap());
    let id = repo.registration_next_id().await.unwrap();
    assert_eq!(id, 123);
    let record = RegistrationRecord {
        user_id: id,
        email: "fake';--".into(),
        username: "username".into(),
        password_hash: "synthetic-hash".into(),
        display_name: "Test".into(),
        bio: "  retained  ".into(),
        location: String::new(),
        phone: String::new(),
        birth_date: String::new(),
    };
    repo.registration_insert(&record,"otp_fixture").await.unwrap();
    let calls = repo.executor.calls.lock().unwrap();
    assert_eq!(calls.len(), 4);
    assert!(
        calls[0].0.contains("expires_at > CURRENT_TIMESTAMP")
            && calls[0].0.contains("verified_at IS NOT NULL")
    );
    assert!(!calls[0].0.contains("fake';--"));
    assert_eq!(calls[0].1["account"], DbValue::String("fake';--".into()));
    assert_eq!(
        calls[0].1["verification_id"],
        DbValue::String("otp_fixture".into())
    );
    assert_eq!(calls[1].1["username"], DbValue::String("username".into()));
    assert!(calls[2].0.contains("seq_user_id.NEXTVAL"));
    assert_eq!(calls[3].0,"REGISTER_ATOMIC");
    assert_eq!(calls[3].1["verification_id"], DbValue::String("otp_fixture".into()));
    assert_eq!(
        calls[3].1["password_hash"],
        DbValue::String("synthetic-hash".into())
    );
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
            Ok(vec![DbRow::from([
                ("TOTAL".into(), DbValue::I64(2)),
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
    assert_eq!(calls.len(), 1);
    assert!(calls[0].0.contains("revoked_at IS NULL"));
    assert!(calls[0]
        .0
        .contains("ROW_NUMBER() OVER (ORDER BY last_accessed_at DESC, session_id ASC)"));
    assert_eq!(calls[0].1["user_id"], DbValue::I64(42));
    assert_eq!(calls[0].1["start_row"], DbValue::F64(1.5));
    assert_eq!(calls[0].1["end_row"], DbValue::F64(4.5));
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
    fn guarded_login_write(
        &self,
        user: u64,
        verified_hash: String,
        write: (&'static str, BindMap),
        expected_factor: Option<EncryptedSecret>,
        prerequisites: Vec<(&'static str, BindMap)>,
        fingerprint: Option<String>,
    ) -> StoreFuture<'_, Option<nekotribe_backend::auth::login::LoginHistory>> {
        assert_eq!(user, 42);
        let (statement, binds) = write;
        assert_eq!(verified_hash, "synthetic-password-hash");
        Box::pin(async move {
            if let Some(expected) = expected_factor {
                assert_eq!(expected.encrypted, "verified-fixture");
                assert!(expected.enabled);
            }
            self.calls.lock().unwrap().extend(prerequisites);
            assert_eq!(
                fingerprint.is_some(),
                statement.contains("INSERT INTO n_auth_sessions")
            );
            if self.execute(statement, binds).await? != 1 {
                return Err(SessionStoreError);
            }
            Ok(Some(Default::default()))
        })
    }
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
async fn login_reloads_the_account_and_password_after_expiry_recovery() {
    #[derive(Default)]
    struct ExpiryExecutor {
        attempted: Mutex<bool>,
    }
    impl SessionExecutor for ExpiryExecutor {
        fn execute(&self, _: &'static str, _: BindMap) -> StoreFuture<'_, u64> {
            panic!("login account lookup must not execute an independent write")
        }

        fn preflight(&self, _: &'static str) -> StoreFuture<'_, ()> {
            panic!("login account lookup must not run preflight")
        }

        fn query(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
            Box::pin(async move {
                assert!(sql.contains("WHERE email = :account OR username = :account"));
                assert_eq!(binds["account"], DbValue::String("sample".into()));
                let attempted = *self.attempted.lock().unwrap();
                let status = if attempted { "active" } else { "suspended" };
                let password = if attempted { "second-hash" } else { "first-hash" };
                Ok(vec![DbRow::from([
                    ("USER_ID".into(), DbValue::I64(42)),
                    ("USERNAME".into(), DbValue::String("sample".into())),
                    ("PASSWORD_HASH".into(), DbValue::String(password.into())),
                    ("STATUS".into(), DbValue::String(status.into())),
                    ("IS_ACTIVE".into(), DbValue::I64(i64::from(attempted))),
                ])])
            })
        }
        fn restore_expired_ban(&self, user: u64) -> StoreFuture<'_, ()> {
            Box::pin(async move {
                assert_eq!(user, 42);
                let mut attempted = self.attempted.lock().unwrap();
                assert!(!*attempted);
                *attempted = true;
                Ok(())
            })
        }
    }
    let repo = OracleSessions {
        executor: ExpiryExecutor::default(),
    };
    let account = repo.login_account("sample").await.unwrap().unwrap();
    assert!(account.active);
    assert_eq!(account.status, "active");
    assert_eq!(account.password_hash, "second-hash");
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
        verified_password_hash: "synthetic-password-hash".into(),
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
        verified_password_hash: "synthetic-password-hash".into(),
        trusted_device_key: None,
        factor_completion: Some(FactorCompletion {
            challenge_id: "challenge-fixture".into(),
            verified_secret: EncryptedSecret { encrypted: "verified-fixture".into(), iv: "iv".into(), tag: "tag".into(), enabled: true },
            recovery_code_id: Some(0),
            remembered_device: None,
        }),
    };
    repo.login_insert_session(&session).await.unwrap();
    let calls = repo.executor.calls.lock().unwrap();
    assert_eq!(calls.len(), 6);
    assert!(!calls[0].0.contains("untrusted"));
    assert_eq!(
        calls[0].1["account"],
        DbValue::String("untrusted' OR 1=1--".into())
    );
    assert!(calls[1]
        .0
        .contains("INSERT INTO n_auth_two_factor_challenges"));
    assert_eq!(calls[1].1["challenge_id"], DbValue::String("2fa_id".into()));
    assert!(calls[2].0.contains("UPDATE n_auth_two_factor_challenges"));
    assert!(calls[3].0.contains("UPDATE n_user_two_factor_recovery_codes"));
    assert_eq!(calls[3].1["recovery_code_id"], DbValue::I64(0));
    assert!(calls[4].0.contains("INSERT INTO n_auth_sessions"));
    assert_eq!(
        calls[4].1["refresh_token_hash"],
        DbValue::String("hash".into())
    );
    assert!(calls[5].0.contains("UPDATE n_users SET last_login_at"));
    assert_eq!(calls[5].1["user_id"], DbValue::I64(42));
}

#[tokio::test]
async fn trusted_device_claim_uses_account_and_digest_in_guarded_session_write() {
    let repo = OracleSessions {
        executor: Executor::default(),
    };
    let device = LoginDevice {
        fingerprint: "device';--".into(),
        info: "browser".into(),
        ip: "127.0.0.1".into(),
        user_agent: "test".into(),
    };
    let session = LoginSession {
        id: "sess_id".into(),
        user_id: 42,
        access_jti: "jti".into(),
        refresh_hash: "hash".into(),
        device,
        access_expires_at: "2023-11-14T22:28:20.000Z".into(),
        refresh_expires_at: "2023-12-14T22:13:20.000Z".into(),
        verified_password_hash: "synthetic-password-hash".into(),
        trusted_device_key: Some("synthetic-digest".into()),
        factor_completion: None,
    };
    assert!(repo.login_insert_session(&session).await.unwrap().is_some());
    let calls = repo.executor.calls.lock().unwrap();
    let (sql, binds) = &calls[0];
    assert!(sql.starts_with("UPDATE n_user_two_factor_trusted_devices"));
    assert!(sql.contains("revoked_at IS NULL"));
    assert_eq!(binds["user_id"], DbValue::I64(42));
    assert_eq!(
        binds["device_fingerprint"],
        DbValue::String("synthetic-digest".into())
    );
    assert!(calls[1].0.contains("INSERT INTO n_auth_sessions"));
    assert_eq!(calls[1].1["device_fingerprint"], DbValue::String("device';--".into()));
}

struct AlertExecutor {
    email_enabled: bool,
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
                DbRow::from([
                    ("LOGIN_ALERTS".into(), DbValue::I64(i64::from(self.enabled))),
                    (
                        "EMAIL_NOTIFICATION_ENABLED".into(),
                        DbValue::I64(i64::from(self.email_enabled)),
                    ),
                    (
                        "EMAIL".into(),
                        DbValue::String("recipient@example.test".into()),
                    ),
                ])
            } else if sql.contains("type_enabled") {
                DbRow::from([
                    ("TYPE_ENABLED".into(), DbValue::I64(i64::from(self.kind_enabled))),
                    ("PUSH_NOTIFICATION_ENABLED".into(), DbValue::I64(1)),
                ])
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
    for (enabled, kind_enabled, email_enabled) in [
        (false, true, true),
        (true, false, true),
        (true, true, true),
        (true, true, false),
    ] {
        let expected_insert = enabled && kind_enabled;
        let repo = OracleSessions {
            executor: AlertExecutor {
                email_enabled,
                enabled,
                kind_enabled,
                calls: Mutex::new(vec![]),
            },
        };
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
            verified_password_hash: String::new(),
            trusted_device_key: None,
        factor_completion: None,
        };
        let delivery = repo.record_login_alert(&session, "新设备").await.unwrap();
        assert_eq!(
            delivery.email.as_deref(),
            (enabled && email_enabled).then_some("recipient@example.test")
        );
        assert_eq!(delivery.notification_id, expected_insert.then_some(12));
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
    assert!(calls[0].0.contains("u.user_id = n_auth_sessions.user_id"));
    assert!(calls[0].0.contains("u.is_active = 1 AND u.status = 'active'"));
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
        "u.user_id = n_auth_sessions.user_id",
        "u.is_active = 1 AND u.status = 'active'",
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

#[tokio::test]
async fn profile_update_repository_binds_only_allowed_fields() {
    use std::collections::BTreeMap;
    let repo = OracleSessions {
        executor: RegistrationExecutor::default(),
    };
    let fields = BTreeMap::from([
        ("bio".to_owned(), "value';--".to_owned()),
        ("birth_date".to_owned(), String::new()),
        ("user_id".to_owned(), "99".to_owned()),
    ]);
    repo.update_self_profile(42, &fields).await.unwrap();
    let calls = repo.executor.calls.lock().unwrap();
    assert_eq!(calls.len(), 1);
    let (sql, binds) = &calls[0];
    assert!(sql.contains("WHERE user_id = :user_id"));
    assert!(sql.contains("TO_DATE(:birth_date"));
    assert!(!sql.contains("value';--"));
    assert!(!sql.contains("display_name"));
    assert_eq!(binds.len(), 3);
    assert_eq!(binds["user_id"], DbValue::I64(42));
    assert_eq!(binds["bio"], DbValue::String("value';--".into()));
    assert_eq!(binds["birth_date"], DbValue::Null);
}

#[tokio::test]
async fn public_profile_repository_binds_viewer_and_target() {
    let repo = OracleSessions {
        executor: RegistrationExecutor::default(),
    };
    let _ = repo.public_profile(42, 7).await.unwrap();
    let calls = repo.executor.calls.lock().unwrap();
    assert_eq!(calls.len(), 1);
    let (sql, binds) = &calls[0];
    for part in [
        "v_user_profile_public",
        "u.is_active=1",
        "show_online_status",
        "NUMTODSINTERVAL(90,'SECOND')",
        "revoked_at IS NULL",
    ] {
        assert!(sql.contains(part), "{part}")
    }
    assert!(!sql.to_lowercase().contains("email"));
    assert_eq!(binds.len(), 2);
    assert_eq!(binds["viewer_id"], DbValue::I64(42));
    assert_eq!(binds["user_id"], DbValue::I64(7));
}

#[derive(Default)]
struct MediaReadinessExecutor {
    calls: std::sync::atomic::AtomicUsize,
}
impl SessionExecutor for MediaReadinessExecutor {
    fn execute(&self, _: &'static str, _: BindMap) -> StoreFuture<'_, u64> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn preflight(&self, _: &'static str) -> StoreFuture<'_, ()> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn media_readiness_snapshot(&self) -> StoreFuture<'_, serde_json::Value> {
        Box::pin(async move {
            let n = self.calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let data: serde_json::Value =
                serde_json::from_str(include_str!("../contracts/scenarios/media-readiness.json"))
                    .unwrap();
            let mut snapshot = data["baseline"].clone();
            if n > 0 {
                snapshot["tables"]["N_MEDIA_ASSETS"]["columns"][0]["CHAR_LENGTH"] =
                    serde_json::json!(999)
            }
            Ok(snapshot)
        })
    }
}
#[tokio::test]
async fn media_repository_rechecks_snapshot_without_caching() {
    let repo = OracleSessions {
        executor: MediaReadinessExecutor::default(),
    };
    assert!(repo.media_readiness().await.is_ok());
    assert!(repo.media_readiness().await.is_err());
    assert_eq!(
        repo.executor
            .calls
            .load(std::sync::atomic::Ordering::SeqCst),
        2
    );
}

#[derive(Default)]
struct PostExecutor {
    calls: Mutex<Vec<(&'static str, BindMap)>>,
}
impl SessionExecutor for PostExecutor {
    fn preflight(&self, _: &'static str) -> StoreFuture<'_, ()> {
        Box::pin(async { Ok(()) })
    }
    fn query(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((sql, binds));
            if sql.starts_with("SELECT table_name FROM user_tables") {
                Ok(vec![DbRow::from([("TABLE_NAME".into(), DbValue::String("N_RECOMMENDATION_FEEDBACK".into()))])])
            } else if sql.contains("FROM n_tags t LEFT JOIN n_post_tags") {
                Ok(vec![DbRow::from([
                    ("NAME".into(), DbValue::String("C# cats".into())),
                    ("TOTAL_POSTS".into(), DbValue::I64(2)),
                    ("TOTAL_AUTHORS".into(), DbValue::I64(1)),
                    ("TOTAL_VIEWS".into(), DbValue::I64(30)),
                    ("TOTAL_LIKES".into(), DbValue::I64(4)),
                    (
                        "AVG_ENGAGEMENT_SCORE".into(),
                        DbValue::String("2.75".into()),
                    ),
                ])])
            } else if sql.starts_with("SELECT COUNT(*)") {
                Ok(vec![DbRow::from([("TOTAL".into(), DbValue::I64(3))])])
            } else if sql.contains("FROM n_tags") {
                Ok(vec![DbRow::from([
                    ("TOTAL".into(), DbValue::I64(3)),
                    ("TAG_ID".into(), DbValue::I64(17)),
                    ("NAME".into(), DbValue::String("Cat".into())),
                    ("USAGE_COUNT".into(), DbValue::I64(42)),
                    ("TRENDING_SCORE".into(), DbValue::String("12.5".into())),
                    ("IS_TRENDING".into(), DbValue::I64(1)),
                    (
                        "UPDATED_AT".into(),
                        DbValue::String("2026-01-02T03:04:05.000Z".into()),
                    ),
                ])])
            } else if sql.contains("FROM v_post_feed_item") {
                Ok(vec![DbRow::from([
                    ("POST_ID".into(), DbValue::I64(1)),
                    ("AUTHOR_ID".into(), DbValue::I64(7)),
                    ("CONTENT".into(), DbValue::String("synthetic".into())),
                    ("REPLY_TO_POST_ID".into(), DbValue::Null),
                    ("QUOTED_POST_ID".into(), DbValue::String("99".into())),
                    ("VIEWS_COUNT".into(), DbValue::String("10".into())),
                    ("ENGAGEMENT_SCORE".into(), DbValue::String("12.5".into())),
                    ("IS_LIKED".into(), DbValue::I64(1)),
                ])])
            } else if sql.contains("FROM n_post_media") {
                Ok(vec![DbRow::from([
                    ("MEDIA_ID".into(), DbValue::I64(17)),
                    ("WIDTH".into(), DbValue::Null),
                    ("HEIGHT".into(), DbValue::String("600".into())),
                    ("DURATION".into(), DbValue::Null),
                    ("DESCRIPTION".into(), DbValue::String("description".into())),
                ])])
            } else if sql.contains("FROM n_post_tags") {
                Ok(vec![DbRow::from([(
                    "NAME".into(),
                    DbValue::String("cat".into()),
                )])])
            } else {
                Ok(Vec::new())
            }
        })
    }
    fn execute(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, u64> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((sql, binds));
            Ok(1)
        })
    }
}

#[tokio::test]
async fn post_repository_binds_anonymous_viewer_and_maps_nullable_database_values() {
    let repo = OracleSessions {
        executor: PostExecutor::default(),
    };
    let post = repo.read_visible_post(None, 1).await.unwrap().unwrap();
    assert_eq!(post["author"]["user_id"], 7);
    assert!(post["reply_to_post_id"].is_null());
    assert_eq!(post["quoted_post_id"].as_f64(), Some(99.0));
    assert_eq!(post["stats"]["views_count"].as_f64(), Some(10.0));
    assert_eq!(post["stats"]["engagement_score"].as_f64(), Some(12.5));
    assert_eq!(post["viewer_state"]["is_liked"], true);
    assert_eq!(post["viewer_state"]["can_delete"], false);
    let media = repo.read_post_media(1).await.unwrap();
    assert!(media[0]["width"].is_null());
    assert_eq!(media[0]["height"].as_f64(), Some(600.0));
    assert!(media[0]["duration"].is_null());
    assert_eq!(media[0]["description"], "description");
    assert_eq!(repo.read_post_tags(1).await.unwrap(), vec!["cat"]);
    assert!(repo.read_post_mentions(None, 1).await.unwrap().is_empty());
    repo.increment_post_views(1).await.unwrap();
    let calls = repo.executor.calls.lock().unwrap();
    assert_eq!(calls.len(), 5);
    assert!(calls[0]
        .0
        .contains("fn_can_view_post(:viewer_id,v.post_id)"));
    assert_eq!(calls[0].1["viewer_id"], DbValue::Null);
    assert_eq!(calls[0].1["post_id"], DbValue::I64(1));
    assert_eq!(calls[3].1["viewer_id"], DbValue::Null);
    assert_eq!(calls[4].1["post_id"], DbValue::I64(1));
    assert!(calls[4].0.starts_with("UPDATE n_post_stats"));
}

#[tokio::test]
async fn post_list_repository_binds_filters_and_pages_without_interpolation() {
    let repo = OracleSessions {
        executor: PostExecutor::default(),
    };
    let query = nekotribe_backend::posts::list::parse_post_list_query(
        "timeline=following&q=%20%23%23Cat_%25%20&sort=popular&page=2&page_size=1",
    );
    let (posts, total) = repo.list_visible_posts(Some(42), &query).await.unwrap();
    assert_eq!(total, 3);
    assert_eq!(posts.len(), 1);
    assert_eq!(posts[0]["post_id"], 1);
    let calls = repo.executor.calls.lock().unwrap();
    assert_eq!(calls.len(), 2);
    for (sql, binds) in calls.iter() {
        assert!(sql.contains("fn_can_view_post(:viewer_id,v.post_id)=1"));
        assert!(sql.contains("f.status='active'"));
        assert!(sql.contains("t.name_lower LIKE :tag_q"));
        assert!(!sql.contains("cat_%"));
        assert_eq!(binds["viewer_id"], DbValue::I64(42));
        assert_eq!(binds["q"], DbValue::String("%##cat_%%".into()));
        assert_eq!(binds["tag_q"], DbValue::String("%cat_%%".into()));
    }
    assert!(calls[1]
        .0
        .contains("ROW_NUMBER() OVER (ORDER BY v.engagement_score DESC,v.created_at DESC)"));
    assert_eq!(calls[1].1["start_row"], DbValue::F64(2.0));
    assert_eq!(calls[1].1["end_row"], DbValue::F64(2.0));
}

#[tokio::test]
async fn signed_in_feed_uses_feedback_in_count_and_page() {
    let repo = OracleSessions { executor: PostExecutor::default() };
    let mut input = nekotribe_backend::posts::list::parse_post_list_query("timeline=home");
    input.mode = "all".into();
    repo.list_visible_posts(Some(42), &input).await.unwrap();
    let calls = repo.executor.calls.lock().unwrap();
    let sql: serde_json::Value = serde_json::from_str(include_str!("../contracts/requirements/recommendation-feedback.json")).unwrap();
    assert_eq!(calls.len(), 3);
    assert_eq!(Some(calls[0].0), sql["schema"].as_str());
    assert!(calls[1].0.contains(sql["feedFilter"].as_str().unwrap()));
    assert!(calls[2].0.contains(sql["feedFilter"].as_str().unwrap()));
    assert!(calls[2].0.contains(sql["feedOrder"].as_str().unwrap()));
    assert_eq!(calls[1].1["viewer_id"], DbValue::I64(42));
    assert_eq!(calls[2].1["viewer_id"], DbValue::I64(42));
}

#[tokio::test]
async fn post_list_modes_scope_sql_and_like_time_sort() {
    for (mode, sort, filter, order) in [
        (
            "me",
            "newest",
            "v.author_id=:viewer_id",
            "v.created_at DESC",
        ),
        (
            "bookmarks",
            "newest",
            "FROM n_post_bookmarks b",
            "v.created_at DESC",
        ),
        (
            "likes",
            "oldest",
            "FROM n_post_likes l",
            "l.user_id=:viewer_id) ASC",
        ),
        (
            "likes",
            "newest",
            "FROM n_post_likes l",
            "l.user_id=:viewer_id) DESC",
        ),
        (
            "likes",
            "popular",
            "FROM n_post_likes l",
            "v.engagement_score DESC,v.created_at DESC",
        ),
    ] {
        let repo = OracleSessions {
            executor: PostExecutor::default(),
        };
        let mut query =
            nekotribe_backend::posts::list::parse_post_list_query("timeline=mentions&q=cat");
        query.mode = mode.into();
        query.sort = sort.into();
        repo.list_visible_posts(Some(42), &query).await.unwrap();
        let calls = repo.executor.calls.lock().unwrap();
        assert!(calls[0].0.contains(filter));
        assert!(calls[0].0.contains("pm.mentioned_user_id=:viewer_id"));
        assert!(calls[0].0.contains("t.name_lower LIKE :tag_q"));
        assert!(calls[1].0.contains(order));
        assert_eq!(calls[0].1["viewer_id"], DbValue::I64(42));
    }
}

#[tokio::test]
async fn scoped_post_list_binds_targets() {
    for (mode, filter, key, id) in [
        ("user", "v.author_id=:author_id", "author_id", 7),
        ("tag", "t.name_lower=LOWER(:tag_name)", "tag_name", 0),
        (
            "replies",
            "v.reply_to_post_id=:target_post_id",
            "target_post_id",
            9,
        ),
        (
            "retweets",
            "v.repost_of_post_id=:target_post_id",
            "target_post_id",
            9,
        ),
    ] {
        let repo = OracleSessions {
            executor: PostExecutor::default(),
        };
        let mut query =
            nekotribe_backend::posts::list::parse_post_list_query("timeline=following&q=cat");
        query.mode = mode.into();
        query.target_id = Some(id);
        query.tag_name = Some("C# cats".into());
        repo.list_visible_posts(Some(42), &query).await.unwrap();
        let calls = repo.executor.calls.lock().unwrap();
        assert!(calls[0].0.contains(filter));
        assert!(calls[1].0.contains(filter));
        assert!(!calls[1].0.contains("C# cats"));
        assert_eq!(
            calls[0].1[key],
            if mode == "tag" {
                DbValue::String("C# cats".into())
            } else {
                DbValue::I64(id as i64)
            }
        );
    }
}

#[tokio::test]
async fn tag_repository_binds_filters_and_maps_results() {
    for trending in [false, true] {
        let repo = OracleSessions {
            executor: PostExecutor::default(),
        };
        let query = nekotribe_backend::tags::TagListQuery {
            page: nekotribe_backend::auth::session_list::session_pagination("page=2&page_size=1"),
            q: if trending {
                None
            } else {
                Some("%cat_%".into())
            },
            trending,
        };
        let (items, total) = repo.list_tags(&query).await.unwrap();
        assert_eq!(total, 3);
        assert_eq!(items[0]["tag_id"], 17);
        assert_eq!(items[0]["trending_score"].as_f64(), Some(12.5));
        let calls = repo.executor.calls.lock().unwrap();
        assert_eq!(calls.len(), 1);
        assert!(calls[0]
            .0
            .contains("trending_score DESC, usage_count DESC, updated_at DESC, tag_id DESC"));
        assert!(calls[0].0.contains("LEFT JOIN ranked_tags"));
        if trending {
            assert!(calls[0].0.contains("is_trending = 1"));
            assert!(!calls[0].1.contains_key("q"));
        } else {
            assert!(!calls[0].0.contains("cat_%"));
            assert_eq!(calls[0].1["q"], DbValue::String("%cat_%".into()));
        }
    }
}

#[tokio::test]
async fn tag_repository_binds_null_for_empty_search() {
    let repo = OracleSessions {
        executor: PostExecutor::default(),
    };
    let query = nekotribe_backend::tags::TagListQuery {
        page: nekotribe_backend::auth::session_list::session_pagination(""),
        q: None,
        trending: false,
    };
    repo.list_tags(&query).await.unwrap();
    let calls = repo.executor.calls.lock().unwrap();
    assert_eq!(calls[0].1["q"], DbValue::Null);
}

#[tokio::test]
async fn tag_analytics_repository_filters_and_binds_viewer() {
    let repo = OracleSessions {
        executor: PostExecutor::default(),
    };
    let row = repo
        .read_tag_analytics(42, "C# cats")
        .await
        .unwrap()
        .unwrap();
    assert_eq!(row["total_posts"].as_f64(), Some(2.0));
    assert_eq!(row["engagement_score"].as_f64(), Some(2.75));
    let calls = repo.executor.calls.lock().unwrap();
    let (sql, binds) = &calls[0];
    for part in [
        "p.is_deleted=0",
        "fn_can_view_post(:viewer_id,p.post_id)=1",
        "COUNT(DISTINCT p.post_id)",
        "LOWER(:name)",
    ] {
        assert!(sql.contains(part));
    }
    assert!(!sql.contains("C# cats"));
    assert_eq!(binds["viewer_id"], DbValue::I64(42));
    assert_eq!(binds["name"], DbValue::String("C# cats".into()));
}
