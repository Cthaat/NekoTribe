use crate::db::{
    oracle::{BindMap, DbError},
    tx::OracleTx,
    value::DbValue,
};
pub(crate) const POSTS:&str="UPDATE n_posts SET is_deleted = 1, updated_at = CURRENT_TIMESTAMP WHERE author_id = :user_id AND is_deleted = 0";
pub(crate) const COMMENTS:&str="UPDATE n_comments SET is_deleted = 1, updated_at = CURRENT_TIMESTAMP WHERE user_id = :user_id AND is_deleted = 0";
pub(crate) const SESSIONS:&str="UPDATE n_auth_sessions SET revoked_at = CURRENT_TIMESTAMP WHERE user_id = :user_id AND revoked_at IS NULL";
pub(crate) const USER:&str="UPDATE n_users SET email = :email, username = :username, password_hash = :password_hash, display_name = '已注销用户', bio = NULL, location = NULL, website = NULL, phone = NULL, avatar_url = NULL, avatar_media_id = NULL, is_active = 0, status = 'disabled', updated_at = CURRENT_TIMESTAMP WHERE user_id = :user_id AND password_hash = :old_hash AND is_active = 1 AND status = 'active'";
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
fn run(tx: &impl Transaction, user: u64, old_hash: &str, new_hash: &str) -> Result<bool, DbError> {
    let id = i64::try_from(user).map_err(|_| DbError::SchemaNotReady)?;
    let result = (|| {
        for sql in [POSTS, COMMENTS, SESSIONS] {
            tx.execute(sql, BindMap::from([("user_id".into(), DbValue::I64(id))]))?;
        }
        let count = tx.execute(
            USER,
            BindMap::from([
                ("user_id".into(), DbValue::I64(id)),
                (
                    "email".into(),
                    DbValue::String(format!("deleted_{id}@deleted.local")),
                ),
                ("username".into(), DbValue::String(format!("deleted_{id}"))),
                ("password_hash".into(), DbValue::String(new_hash.into())),
                ("old_hash".into(), DbValue::String(old_hash.into())),
            ]),
        )?;
        if count > 1 {
            return Err(DbError::SchemaNotReady);
        }
        Ok(count == 1)
    })();
    match result {
        Ok(true) => match tx.commit() {
            Ok(()) => Ok(true),
            Err(e) => {
                let _ = tx.rollback();
                Err(e)
            }
        },
        Ok(false) => {
            tx.rollback()?;
            Ok(false)
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
    old_hash: &str,
    new_hash: &str,
) -> Result<bool, DbError> {
    run(&OracleTx::new(connection), user, old_hash, new_hash)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    struct Tx {
        fault: usize,
        zero: bool,
        steps: RefCell<usize>,
        commits: RefCell<usize>,
        rollbacks: RefCell<usize>,
    }
    impl Transaction for Tx {
        fn execute(&self, sql: &'static str, b: BindMap) -> Result<u64, DbError> {
            let mut n = self.steps.borrow_mut();
            *n += 1;
            assert!(b.contains_key("user_id"));
            if *n == self.fault {
                return Err(DbError::SchemaNotReady);
            }
            if sql == USER {
                assert!(b.contains_key("old_hash"));
                assert!(b.contains_key("password_hash"));
            }
            Ok(if sql == USER && self.zero { 0 } else { 1 })
        }
        fn commit(&self) -> Result<(), DbError> {
            *self.commits.borrow_mut() += 1;
            if self.fault == 5 {
                Err(DbError::SchemaNotReady)
            } else {
                Ok(())
            }
        }
        fn rollback(&self) -> Result<(), DbError> {
            *self.rollbacks.borrow_mut() += 1;
            Ok(())
        }
    }
    #[test]
    fn transaction_failure_and_changed_user_roll_back() {
        for fault in 0..=5 {
            for zero in [false, true] {
                let tx = Tx {
                    fault,
                    zero,
                    steps: RefCell::new(0),
                    commits: RefCell::new(0),
                    rollbacks: RefCell::new(0),
                };
                let result = run(&tx, 42, "old", "new");
                if fault == 0 && !zero {
                    assert_eq!(result.unwrap(), true);
                    assert_eq!(*tx.commits.borrow(), 1);
                    assert_eq!(*tx.rollbacks.borrow(), 0)
                } else {
                    assert!(result.is_err() || zero);
                    assert_eq!(*tx.rollbacks.borrow(), 1)
                }
            }
        }
    }
}
