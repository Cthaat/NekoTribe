use crate::{
    auth::{
        sessions::{SessionRepository, SessionStoreError, StoreFuture},
        TokenClaims,
    },
    db::{oracle::BindMap, pool::OraclePool, value::DbValue},
};

pub const TOUCH_SQL:&str="UPDATE n_auth_sessions SET last_accessed_at = CURRENT_TIMESTAMP WHERE user_id = :user_id AND session_id = :session_id AND access_jti = :access_jti AND revoked_at IS NULL AND access_token_expires_at > CURRENT_TIMESTAMP";
pub const REVOKE_SQL:&str="UPDATE n_auth_sessions SET revoked_at = CURRENT_TIMESTAMP WHERE user_id = :user_id AND session_id = :session_id AND revoked_at IS NULL";
pub const REVOKE_OTHERS_SQL:&str="UPDATE n_auth_sessions SET revoked_at = CURRENT_TIMESTAMP WHERE user_id = :user_id AND session_id <> :session_id AND revoked_at IS NULL";
pub const PREFLIGHT_SQL:&str="SELECT user_id, session_id, access_jti, access_token_expires_at, revoked_at, last_accessed_at FROM n_auth_sessions WHERE 1 = 0";

pub trait SessionExecutor: Send + Sync {
    fn execute(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, u64>;
    fn preflight(&self, sql: &'static str) -> StoreFuture<'_, ()>;
}
pub struct OracleSessions<E> {
    pub executor: E,
}
impl<E: SessionExecutor> OracleSessions<E> {
    pub async fn preflight(&self) -> Result<(), SessionStoreError> {
        self.executor.preflight(PREFLIGHT_SQL).await
    }
}
impl<E: SessionExecutor> SessionRepository for OracleSessions<E> {
    fn touch<'a>(&'a self, claims: &'a TokenClaims) -> StoreFuture<'a, u64> {
        let mut binds = session_binds(claims.user_id, &claims.session_id);
        binds.insert("access_jti".into(), DbValue::String(claims.jti.clone()));
        self.executor.execute(TOUCH_SQL, binds)
    }
    fn revoke<'a>(&'a self, user_id: u64, id: &'a str) -> StoreFuture<'a, u64> {
        self.executor
            .execute(REVOKE_SQL, session_binds(user_id, id))
    }
    fn revoke_others<'a>(&'a self, user_id: u64, current: &'a str) -> StoreFuture<'a, u64> {
        self.executor
            .execute(REVOKE_OTHERS_SQL, session_binds(user_id, current))
    }
}
fn session_binds(user: u64, id: &str) -> BindMap {
    BindMap::from([
        ("user_id".into(), DbValue::I64(user as i64)),
        ("session_id".into(), DbValue::String(id.into())),
    ])
}
impl SessionExecutor for OraclePool {
    fn execute(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, u64> {
        Box::pin(async move {
            OraclePool::execute(self, sql, binds)
                .await
                .map(|r| r.rows_affected)
                .map_err(|_| SessionStoreError)
        })
    }
    fn preflight(&self, sql: &'static str) -> StoreFuture<'_, ()> {
        Box::pin(async move {
            self.query_rows(sql, BindMap::new())
                .await
                .map(|_| ())
                .map_err(|_| SessionStoreError)
        })
    }
}
