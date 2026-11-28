use crate::auth::login::{EncryptedSecret, LoginHistory};
use crate::db::{
    oracle::{BindMap, DbError},
    tx::OracleTx,
};

const LOCK_USER: &str = "SELECT user_id FROM n_users WHERE user_id = :user_id FOR UPDATE";
const CURRENT_HASH: &str =
    "SELECT password_hash FROM n_users WHERE user_id = :user_id AND is_active = 1 AND status = 'active'";
const LOCK_FACTOR: &str = "SELECT user_id FROM n_user_two_factor_secrets WHERE user_id = :user_id FOR UPDATE";
const CURRENT_FACTOR: &str = "SELECT user_id FROM n_user_two_factor_secrets
WHERE user_id=:user_id AND enabled_at IS NOT NULL
AND secret_encrypted=:old_encrypted AND secret_iv=:old_iv AND secret_auth_tag=:old_tag";

pub(crate) fn execute(
    connection: &oracle::Connection,
    user: u64,
    verified_hash: &str,
    write: (&'static str, BindMap),
    expected_factor: Option<EncryptedSecret>,
    prerequisites: Vec<(&'static str, BindMap)>,
    fingerprint: Option<String>,
) -> Result<Option<LoginHistory>, DbError> {
    let (statement, binds) = write;
    if verified_hash.is_empty() {
        return Ok(None);
    }
    let user = i64::try_from(user).map_err(|_| DbError::SchemaNotReady)?;
    let tx = OracleTx::new(connection);
    let result = (|| {
        let user_bind: [(&str, &dyn oracle::sql_type::ToSql); 1] = [("user_id", &user)];
        if connection
            .query_named(LOCK_USER, &user_bind)?
            .next()
            .transpose()?
            .is_none()
        {
            return Ok(None);
        }
        let mut current = connection.query_named(CURRENT_HASH, &user_bind)?;
        let hash = current
            .next()
            .transpose()?
            .map(|row| row.get::<_, Option<String>>(0))
            .transpose()?
            .flatten();
        if hash.as_deref() != Some(verified_hash) {
            return Ok(None);
        }
        drop(current);
        if let Some(factor) = expected_factor {
            if connection.query_named(LOCK_FACTOR, &user_bind)?.next().transpose()?.is_none() {
                return Ok(None);
            }
            let factor_binds: [(&str, &dyn oracle::sql_type::ToSql); 4] = [
                ("user_id", &user), ("old_encrypted", &factor.encrypted),
                ("old_iv", &factor.iv), ("old_tag", &factor.tag),
            ];
            if connection.query_named(CURRENT_FACTOR, &factor_binds)?.next().transpose()?.is_none() {
                return Ok(None);
            }
        }
        // The per-account lock orders this snapshot with all session issuers.
        let history = if let Some(fingerprint) = fingerprint {
            let row = connection.query_row_as_named::<(u8, Option<String>)>(
                "SELECT CASE WHEN EXISTS (SELECT 1 FROM n_auth_sessions WHERE user_id=:user_id
                 AND device_fingerprint=:fingerprint) THEN 1 ELSE 0 END,
                 (SELECT ip_address FROM n_auth_sessions WHERE user_id=:user_id
                 ORDER BY created_at DESC,session_id ASC FETCH FIRST 1 ROW ONLY) FROM dual",
                &[("user_id", &user), ("fingerprint", &fingerprint)],
            )?;
            LoginHistory {
                known_device: row.0 != 0,
                previous_ip: row.1,
            }
        } else {
            LoginHistory::default()
        };
        for (statement, binds) in prerequisites {
            match tx.execute(statement, binds)?.rows_affected {
                0 => return Ok(None),
                1 => {}
                _ => return Err(DbError::SchemaNotReady),
            }
        }
        let count = tx.execute(statement, binds)?.rows_affected;
        if count != 1 {
            return Err(DbError::SchemaNotReady);
        }
        tx.commit()?;
        Ok(Some(history))
    })();
    if !matches!(result, Ok(Some(_))) {
        tx.rollback()?;
    }
    result
}
