use crate::{
    auth::session_repository::{RESET_CLAIM_SQL, RESET_PASSWORD_SQL, RESET_REVOKE_SQL},
    db::{
        oracle::{BindMap, DbError},
        tx::OracleTx,
        value::DbValue,
    },
};

pub(crate) const RESET_COMMITTED: u64 = 0;
pub(crate) const RESET_EXPIRED: u64 = 1;
pub(crate) const RESET_USER_MISSING: u64 = 2;

trait ResetTransaction {
    fn execute(&self, sql: &'static str, binds: BindMap) -> Result<u64, DbError>;
    fn commit(&self) -> Result<(), DbError>;
    fn rollback(&self) -> Result<(), DbError>;
}
impl ResetTransaction for OracleTx<'_> {
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

fn run<T: ResetTransaction>(
    tx: &T,
    email: &str,
    id: &str,
    otp_hash: &str,
    new_hash: &str,
) -> Result<u64, DbError> {
    let result = (|| {
        let claimed = tx.execute(
            RESET_CLAIM_SQL,
            BindMap::from([
                ("account".into(), DbValue::String(email.into())),
                ("verification_id".into(), DbValue::String(id.into())),
                ("code_hash".into(), DbValue::String(otp_hash.into())),
            ]),
        )?;
        if claimed == 0 {
            return Ok(RESET_EXPIRED);
        }
        if claimed != 1 {
            return Err(DbError::SchemaNotReady);
        }
        let updated = tx.execute(
            RESET_PASSWORD_SQL,
            BindMap::from([
                ("password_hash".into(), DbValue::String(new_hash.into())),
                ("email".into(), DbValue::String(email.into())),
            ]),
        )?;
        if updated == 0 {
            return Ok(RESET_USER_MISSING);
        }
        if updated != 1 {
            return Err(DbError::SchemaNotReady);
        }
        tx.execute(
            RESET_REVOKE_SQL,
            BindMap::from([("email".into(), DbValue::String(email.into()))]),
        )?;
        Ok(RESET_COMMITTED)
    })();
    match result {
        Ok(RESET_COMMITTED) => match tx.commit() {
            Ok(()) => Ok(RESET_COMMITTED),
            Err(error) => {
                let _ = tx.rollback();
                Err(error)
            }
        },
        Ok(outcome) => {
            tx.rollback()?;
            Ok(outcome)
        }
        Err(error) => {
            tx.rollback()?;
            Err(error)
        }
    }
}

pub(crate) fn execute(
    connection: &oracle::Connection,
    email: &str,
    id: &str,
    otp_hash: &str,
    new_hash: &str,
) -> Result<u64, DbError> {
    run(&OracleTx::new(connection), email, id, otp_hash, new_hash)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    struct Fake {
        calls: Mutex<Vec<(&'static str, BindMap)>>,
        events: Mutex<Vec<&'static str>>,
        counts: [u64; 3],
        fail_at: usize,
        fail_commit: bool,
    }
    impl ResetTransaction for Fake {
        fn execute(&self, sql: &'static str, binds: BindMap) -> Result<u64, DbError> {
            let mut calls = self.calls.lock().unwrap();
            calls.push((sql, binds));
            if calls.len() == self.fail_at {
                return Err(DbError::SchemaNotReady);
            }
            Ok(self.counts[calls.len() - 1])
        }
        fn commit(&self) -> Result<(), DbError> {
            self.events.lock().unwrap().push("commit");
            if self.fail_commit {
                Err(DbError::SchemaNotReady)
            } else {
                Ok(())
            }
        }
        fn rollback(&self) -> Result<(), DbError> {
            self.events.lock().unwrap().push("rollback");
            Ok(())
        }
    }
    #[test]
    fn claims_and_updates_or_rolls_back_as_one_unit() {
        for (counts, fail_at, expected, event, calls) in [
            ([1, 1, 2], 0, Some(0), "commit", 3),
            ([0, 1, 2], 0, Some(1), "rollback", 1),
            ([1, 0, 2], 0, Some(2), "rollback", 2),
            ([2, 1, 2], 0, None, "rollback", 1),
            ([1, 2, 2], 0, None, "rollback", 2),
            ([1, 1, 2], 1, None, "rollback", 1),
            ([1, 1, 2], 2, None, "rollback", 2),
            ([1, 1, 2], 3, None, "rollback", 3),
        ] {
            let fake = Fake {
                calls: Mutex::new(Vec::new()),
                events: Mutex::new(Vec::new()),
                counts,
                fail_at,
                fail_commit: false,
            };
            let result = run(&fake, "fake';--", "otp_fixture", "otp-hash", "new-hash");
            assert_eq!(result.ok(), expected);
            assert_eq!(*fake.events.lock().unwrap(), vec![event]);
            let actual = fake.calls.lock().unwrap();
            assert_eq!(actual.len(), calls);
            assert!(!actual[0].0.contains("fake';--"));
            assert!(actual[0]
                .0
                .contains("verification_code_hash = '!consumed!'"));
            assert!(actual[0].0.contains("verification_code_hash = :code_hash"));
            assert_eq!(actual[0].1["account"], DbValue::String("fake';--".into()));
            assert_eq!(
                actual[0].1["verification_id"],
                DbValue::String("otp_fixture".into())
            );
            assert_eq!(actual[0].1["code_hash"], DbValue::String("otp-hash".into()));
            if actual.len() > 1 {
                assert_eq!(actual[1].1["email"], DbValue::String("fake';--".into()));
                assert_eq!(
                    actual[1].1["password_hash"],
                    DbValue::String("new-hash".into())
                );
            }
            if actual.len() > 2 {
                assert_eq!(actual[2].1["email"], DbValue::String("fake';--".into()));
            }
        }
    }

    #[test]
    fn commit_failure_is_not_reported_as_success() {
        let fake = Fake {
            calls: Mutex::new(Vec::new()),
            events: Mutex::new(Vec::new()),
            counts: [1, 1, 2],
            fail_at: 0,
            fail_commit: true,
        };
        assert!(run(
            &fake,
            "fake@example.test",
            "otp_fixture",
            "otp-hash",
            "new-hash"
        )
        .is_err());
        assert_eq!(*fake.events.lock().unwrap(), vec!["commit", "rollback"]);
    }
}
