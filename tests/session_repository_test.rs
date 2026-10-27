use nekotribe_backend::{
    auth::{
        session_repository::{OracleSessions, SessionExecutor},
        sessions::{SessionRepository, SessionStoreError, StoreFuture},
        TokenClaims, TokenKind,
    },
    db::{oracle::BindMap, value::DbValue},
};
use std::sync::Mutex;
#[derive(Default)]
struct Executor {
    calls: Mutex<Vec<(&'static str, BindMap)>>,
    fail: bool,
}
impl SessionExecutor for Executor {
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
