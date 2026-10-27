use crate::{
    auth::{
        sessions::{
            SessionCredential, SessionRepository, SessionRotation, SessionStoreError, StoreFuture,
        },
        TokenClaims,
    },
    db::{oracle::BindMap, pool::OraclePool, value::DbValue},
};

pub const TOUCH_SQL:&str="UPDATE n_auth_sessions SET last_accessed_at = CURRENT_TIMESTAMP WHERE user_id = :user_id AND session_id = :session_id AND access_jti = :access_jti AND revoked_at IS NULL AND access_token_expires_at > CURRENT_TIMESTAMP";
pub const REVOKE_SQL:&str="UPDATE n_auth_sessions SET revoked_at = CURRENT_TIMESTAMP WHERE user_id = :user_id AND session_id = :session_id AND revoked_at IS NULL";
pub const REVOKE_OTHERS_SQL:&str="UPDATE n_auth_sessions SET revoked_at = CURRENT_TIMESTAMP WHERE user_id = :user_id AND session_id <> :session_id AND revoked_at IS NULL";
pub const LOGOUT_ACCESS_SQL: &str = "UPDATE n_auth_sessions SET revoked_at = CURRENT_TIMESTAMP WHERE session_id = :session_id AND user_id = :user_id AND revoked_at IS NULL AND access_jti = :access_jti";
pub const LOGOUT_REFRESH_SQL: &str = "UPDATE n_auth_sessions SET revoked_at = CURRENT_TIMESTAMP WHERE session_id = :session_id AND user_id = :user_id AND revoked_at IS NULL AND refresh_token_hash = :refresh_token_hash";
pub const PREFLIGHT_SQL:&str="SELECT user_id, session_id, access_jti, access_token_expires_at, refresh_token_hash, refresh_token_expires_at, last_refresh_at, revoked_at, last_accessed_at FROM n_auth_sessions WHERE 1 = 0";
pub const ROTATE_SQL: &str = "UPDATE n_auth_sessions SET access_jti = :access_jti, refresh_token_hash = :refresh_token_hash, access_token_expires_at = CAST(TO_TIMESTAMP_TZ(:access_expires_at, 'YYYY-MM-DD\"T\"HH24:MI:SS.FF3TZH:TZM') AT LOCAL AS TIMESTAMP), refresh_token_expires_at = CAST(TO_TIMESTAMP_TZ(:refresh_expires_at, 'YYYY-MM-DD\"T\"HH24:MI:SS.FF3TZH:TZM') AT LOCAL AS TIMESTAMP), last_refresh_at = CURRENT_TIMESTAMP, last_accessed_at = CURRENT_TIMESTAMP WHERE session_id = :session_id AND user_id = :user_id AND refresh_token_hash = :old_refresh_hash AND revoked_at IS NULL AND refresh_token_expires_at > CURRENT_TIMESTAMP";

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
    fn revoke_current<'a>(
        &'a self,
        user_id: u64,
        session: &'a str,
        credential: &'a SessionCredential,
    ) -> StoreFuture<'a, u64> {
        let mut binds = session_binds(user_id, session);
        let sql = match credential {
            SessionCredential::AccessJti(jti) => {
                binds.insert("access_jti".into(), DbValue::String(jti.clone()));
                LOGOUT_ACCESS_SQL
            }
            SessionCredential::RefreshHash(hash) => {
                binds.insert("refresh_token_hash".into(), DbValue::String(hash.clone()));
                LOGOUT_REFRESH_SQL
            }
        };
        self.executor.execute(sql, binds)
    }
    fn rotate<'a>(&'a self, rotation: &'a SessionRotation) -> StoreFuture<'a, u64> {
        let mut binds = session_binds(rotation.user_id, &rotation.session_id);
        for (key, value) in [
            ("access_jti", &rotation.access_jti),
            ("refresh_token_hash", &rotation.refresh_hash),
            ("old_refresh_hash", &rotation.old_refresh_hash),
        ] {
            binds.insert(key.into(), DbValue::String(value.clone()));
        }
        for (key, value) in [
            ("access_expires_at", &rotation.access_expires_at),
            ("refresh_expires_at", &rotation.refresh_expires_at),
        ] {
            binds.insert(
                key.into(),
                DbValue::String(value.trim_end_matches('Z').to_owned() + "+00:00"),
            );
        }
        self.executor.execute(ROTATE_SQL, binds)
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
