use crate::{
    auth::factor_management::{FactorAction, FactorMutation, FactorOutcome},
    db::{
        oracle::{BindMap, DbError},
        tx::OracleTx,
        value::DbValue,
    },
};
const SETUP:&str="MERGE INTO n_user_two_factor_secrets target USING (SELECT :user_id AS user_id FROM dual) src ON (target.user_id = src.user_id) WHEN MATCHED THEN UPDATE SET secret_encrypted = :secret_encrypted, secret_iv = :secret_iv, secret_auth_tag = :secret_auth_tag, confirmed_at = NULL, enabled_at = NULL, updated_at = CURRENT_TIMESTAMP WHERE target.enabled_at IS NULL WHEN NOT MATCHED THEN INSERT (user_id, secret_encrypted, secret_iv, secret_auth_tag) VALUES (:user_id, :secret_encrypted, :secret_iv, :secret_auth_tag)";
const CONFIRM:&str="UPDATE n_user_two_factor_secrets SET confirmed_at = CURRENT_TIMESTAMP, enabled_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP WHERE user_id = :user_id AND secret_encrypted = :old_encrypted AND secret_iv = :old_iv AND secret_auth_tag = :old_tag AND enabled_at IS NULL";
const DISABLE:&str="UPDATE n_user_two_factor_secrets SET enabled_at = NULL, updated_at = CURRENT_TIMESTAMP WHERE user_id = :user_id AND secret_encrypted = :old_encrypted AND secret_iv = :old_iv AND secret_auth_tag = :old_tag AND enabled_at IS NOT NULL";
const CLEAR_CODES: &str = "DELETE FROM n_user_two_factor_recovery_codes WHERE user_id = :user_id";
const CLEAR_DEVICES: &str =
    "DELETE FROM n_user_two_factor_trusted_devices WHERE user_id = :user_id";
const SETTINGS:&str="MERGE INTO n_user_settings target USING (SELECT :user_id AS user_id FROM dual) src ON (target.user_id = src.user_id) WHEN MATCHED THEN UPDATE SET two_factor_enabled = :enabled, updated_at = CURRENT_TIMESTAMP WHEN NOT MATCHED THEN INSERT (user_id, two_factor_enabled) VALUES (:user_id, :enabled)";
const RECOVERY:&str="INSERT INTO n_user_two_factor_recovery_codes (recovery_code_id, user_id, code_hash) VALUES (seq_2fa_recovery_code_id.NEXTVAL, :user_id, :code_hash)";
trait Transaction {
    fn execute(&self, sql: &'static str, binds: BindMap) -> Result<u64, DbError>;
    fn commit(&self) -> Result<(), DbError>;
    fn rollback(&self) -> Result<(), DbError>;
}
impl Transaction for OracleTx<'_> {
    fn execute(&self, sql: &'static str, binds: BindMap) -> Result<u64, DbError> {
        Ok(OracleTx::execute(self, sql, binds)?.rows_affected)
    }
    fn commit(&self) -> Result<(), DbError> {
        OracleTx::commit(self)
    }
    fn rollback(&self) -> Result<(), DbError> {
        OracleTx::rollback(self)
    }
}
fn bind_user(user: i64) -> BindMap {
    BindMap::from([("user_id".into(), DbValue::I64(user))])
}
fn run(tx: &impl Transaction, user: u64, m: &FactorMutation) -> Result<FactorOutcome, DbError> {
    let user = i64::try_from(user).map_err(|_| DbError::SchemaNotReady)?;
    if m.action == FactorAction::Confirm && m.recovery_hashes.len() != 10 {
        return Err(DbError::SchemaNotReady);
    }
    let result = (|| {
        let mut binds = bind_user(user);
        let sql = if m.action == FactorAction::Setup {
            let s = m.new_secret.as_ref().ok_or(DbError::SchemaNotReady)?;
            binds.extend([
                (
                    "secret_encrypted".into(),
                    DbValue::String(s.encrypted.clone()),
                ),
                ("secret_iv".into(), DbValue::String(s.iv.clone())),
                ("secret_auth_tag".into(), DbValue::String(s.tag.clone())),
            ]);
            SETUP
        } else {
            binds.extend([
                (
                    "old_encrypted".into(),
                    DbValue::String(m.expected.encrypted.clone()),
                ),
                ("old_iv".into(), DbValue::String(m.expected.iv.clone())),
                ("old_tag".into(), DbValue::String(m.expected.tag.clone())),
            ]);
            if m.action == FactorAction::Confirm {
                CONFIRM
            } else {
                DISABLE
            }
        };
        let changed = tx.execute(sql, binds)?;
        if changed == 0 {
            return Ok(FactorOutcome::Changed);
        };
        if changed != 1 {
            return Err(DbError::SchemaNotReady);
        }
        if let Some(id) = m.recovery_id {
            let id = i64::try_from(id).map_err(|_| DbError::SchemaNotReady)?;
            let mut binds = bind_user(user);
            binds.insert("recovery_code_id".into(), DbValue::I64(id));
            let count = tx.execute("UPDATE n_user_two_factor_recovery_codes SET used_at=CURRENT_TIMESTAMP WHERE recovery_code_id=:recovery_code_id AND user_id=:user_id AND used_at IS NULL", binds)?;
            if count == 0 {
                return Ok(FactorOutcome::RecoveryUsed);
            };
            if count != 1 {
                return Err(DbError::SchemaNotReady);
            }
        }
        tx.execute(CLEAR_CODES, bind_user(user))?;
        if m.action == FactorAction::Confirm {
            for hash in &m.recovery_hashes {
                let mut b = bind_user(user);
                b.insert("code_hash".into(), DbValue::String(hash.clone()));
                if tx.execute(RECOVERY, b)? != 1 {
                    return Err(DbError::SchemaNotReady);
                }
            }
        } else {
            tx.execute(CLEAR_DEVICES, bind_user(user))?;
        }
        let mut b = bind_user(user);
        let sql = if m.action == FactorAction::Disable {
            "UPDATE n_user_settings SET two_factor_enabled = 0, updated_at = CURRENT_TIMESTAMP WHERE user_id = :user_id"
        } else {
            b.insert(
                "enabled".into(),
                DbValue::I64(i64::from(m.action == FactorAction::Confirm)),
            );
            SETTINGS
        };
        let count = tx.execute(sql, b)?;
        if m.action != FactorAction::Disable && count != 1 {
            return Err(DbError::SchemaNotReady);
        }
        Ok(FactorOutcome::Applied)
    })();
    match result {
        Ok(FactorOutcome::Applied) => match tx.commit() {
            Ok(()) => Ok(FactorOutcome::Applied),
            Err(e) => {
                let _ = tx.rollback();
                Err(e)
            }
        },
        Ok(outcome) => {
            tx.rollback()?;
            Ok(outcome)
        }
        Err(e) => {
            tx.rollback()?;
            Err(e)
        }
    }
}
pub(crate) fn execute(
    connection: &oracle::Connection,
    user: u64,
    m: &FactorMutation,
) -> Result<FactorOutcome, DbError> {
    run(&OracleTx::new(connection), user, m)
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::login::EncryptedSecret;
    use std::cell::Cell;
    struct Tx {
        step: Cell<usize>,
        fail: usize,
        zero: usize,
        commits: Cell<usize>,
        rollbacks: Cell<usize>,
    }
    impl Transaction for Tx {
        fn execute(&self, _: &'static str, _: BindMap) -> Result<u64, DbError> {
            let n = self.step.get() + 1;
            self.step.set(n);
            if n == self.fail {
                return Err(DbError::SchemaNotReady);
            }
            Ok(u64::from(n != self.zero))
        }
        fn commit(&self) -> Result<(), DbError> {
            self.commits.set(self.commits.get() + 1);
            if self.fail == 99 {
                Err(DbError::SchemaNotReady)
            } else {
                Ok(())
            }
        }
        fn rollback(&self) -> Result<(), DbError> {
            self.rollbacks.set(self.rollbacks.get() + 1);
            Ok(())
        }
    }
    fn secret() -> EncryptedSecret {
        EncryptedSecret {
            encrypted: "cipher".into(),
            iv: "iv".into(),
            tag: "tag".into(),
            enabled: false,
        }
    }
    #[test]
    fn all_factor_writes_and_conflicts_rollback() {
        for (action, last) in [
            (FactorAction::Setup, 4),
            (FactorAction::Confirm, 13),
            (FactorAction::Disable, 5),
        ] {
            let m = FactorMutation {
                action,
                expected: secret(),
                new_secret: Some(secret()),
                recovery_hashes: vec!["hash".into(); 10],
                recovery_id: if action == FactorAction::Disable {
                    Some(1)
                } else {
                    None
                },
            };
            for fail in (0..=last).chain([99]) {
                let tx = Tx {
                    step: Cell::new(0),
                    fail,
                    zero: 0,
                    commits: Cell::new(0),
                    rollbacks: Cell::new(0),
                };
                let result = run(&tx, 42, &m);
                if fail == 0 {
                    assert!(matches!(result, Ok(FactorOutcome::Applied)));
                    assert_eq!(tx.commits.get(), 1);
                    assert_eq!(tx.rollbacks.get(), 0)
                } else {
                    assert!(result.is_err());
                    assert_eq!(tx.rollbacks.get(), 1);
                }
            }
            for zero in [
                1,
                if action == FactorAction::Disable {
                    2
                } else {
                    1
                },
            ] {
                let tx = Tx {
                    step: Cell::new(0),
                    fail: 0,
                    zero,
                    commits: Cell::new(0),
                    rollbacks: Cell::new(0),
                };
                assert!(matches!(
                    run(&tx, 42, &m),
                    Ok(FactorOutcome::Changed | FactorOutcome::RecoveryUsed)
                ));
                assert_eq!(tx.commits.get(), 0);
                assert_eq!(tx.rollbacks.get(), 1);
            }
        }
    }
}
