use crate::{
    db::{
        oracle::{BindMap, DbError},
        tx::OracleTx,
        value::DbValue,
    },
    users::email_change::{EmailChange, EmailChangeData},
};

pub(crate) const EMAIL_IN_USE_SQL: &str =
    "SELECT COUNT(*) AS total FROM n_users WHERE email = :email AND user_id != :user_id";
const CLAIM_SQL:&str="UPDATE n_auth_otp_events SET verified_at = CURRENT_TIMESTAMP, expires_at = CURRENT_TIMESTAMP, verification_code_hash = '!consumed!' WHERE account = :account AND otp_type = 'change_email' AND verification_id = :verification_id AND verification_code_hash = :code_hash AND expires_at > CURRENT_TIMESTAMP";
const UPDATE_SQL:&str="UPDATE n_users SET email = :email, email_verified_at = CURRENT_TIMESTAMP WHERE user_id = :user_id";
const READ_SQL:&str="SELECT email, TO_CHAR(FROM_TZ(email_verified_at, SESSIONTIMEZONE) AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.FF3\"Z\"') AS email_verified_at FROM n_users WHERE user_id = :user_id";

enum TransactionError {
    Database(DbError),
    Conflict,
}
impl From<DbError> for TransactionError {
    fn from(error: DbError) -> Self {
        Self::Database(error)
    }
}
trait Transaction {
    fn execute(&self, sql: &'static str, binds: BindMap) -> Result<u64, TransactionError>;
    fn read(&self, user: i64) -> Result<EmailChangeData, DbError>;
    fn commit(&self) -> Result<(), DbError>;
    fn rollback(&self) -> Result<(), DbError>;
}
struct OracleEmailTransaction<'a> {
    connection: &'a oracle::Connection,
}
impl Transaction for OracleEmailTransaction<'_> {
    fn execute(&self, sql: &'static str, binds: BindMap) -> Result<u64, TransactionError> {
        OracleTx::new(self.connection).execute(sql,binds).map(|r|r.rows_affected).map_err(|e|{
   if sql==UPDATE_SQL&&matches!(&e,DbError::Oracle(error) if error.db_error().is_some_and(|e|e.code()==1)){TransactionError::Conflict}else{TransactionError::Database(e)}
  })
    }
    fn read(&self, user: i64) -> Result<EmailChangeData, DbError> {
        let row = self
            .connection
            .query_row_named(READ_SQL, &[("user_id", &user)])?;
        let email: Option<String> = row.get("EMAIL")?;
        let at: Option<String> = row.get("EMAIL_VERIFIED_AT")?;
        let at =
            chrono::DateTime::parse_from_rfc3339(at.as_deref().ok_or(DbError::SchemaNotReady)?)
                .map_err(|_| DbError::SchemaNotReady)?;
        Ok(EmailChangeData {
            email: email.ok_or(DbError::SchemaNotReady)?,
            email_verified_at: at
                .with_timezone(&chrono::Utc)
                .to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
        })
    }
    fn commit(&self) -> Result<(), DbError> {
        OracleTx::new(self.connection).commit()
    }
    fn rollback(&self) -> Result<(), DbError> {
        OracleTx::new(self.connection).rollback()
    }
}
fn run<T: Transaction>(
    tx: &T,
    user: u64,
    email: &str,
    id: &str,
    hash: &str,
) -> Result<EmailChange, DbError> {
    let user = i64::try_from(user).map_err(|_| DbError::SchemaNotReady)?;
    let result = (|| -> Result<EmailChange, TransactionError> {
        let claimed = tx.execute(
            CLAIM_SQL,
            BindMap::from([
                ("account".into(), DbValue::String(email.into())),
                ("verification_id".into(), DbValue::String(id.into())),
                ("code_hash".into(), DbValue::String(hash.into())),
            ]),
        )?;
        if claimed == 0 {
            return Ok(EmailChange::Expired);
        };
        if claimed != 1 {
            return Err(DbError::SchemaNotReady.into());
        }
        let updated = tx.execute(
            UPDATE_SQL,
            BindMap::from([
                ("email".into(), DbValue::String(email.into())),
                ("user_id".into(), DbValue::I64(user)),
            ]),
        )?;
        if updated == 0 {
            return Ok(EmailChange::UserMissing);
        };
        if updated != 1 {
            return Err(DbError::SchemaNotReady.into());
        }
        let data = tx.read(user)?;
        if data.email != email || data.email_verified_at.is_empty() {
            return Err(DbError::SchemaNotReady.into());
        }
        Ok(EmailChange::Committed(data))
    })();
    match result {
        Ok(outcome @ EmailChange::Committed(_)) => {
            if let Err(error) = tx.commit() {
                let _ = tx.rollback();
                return Err(error);
            }
            Ok(outcome)
        }
        Ok(outcome) => {
            tx.rollback()?;
            Ok(outcome)
        }
        Err(TransactionError::Conflict) => {
            tx.rollback()?;
            Ok(EmailChange::Conflict)
        }
        Err(TransactionError::Database(error)) => {
            tx.rollback()?;
            Err(error)
        }
    }
}
pub(crate) fn execute(
    connection: &oracle::Connection,
    user: u64,
    email: &str,
    id: &str,
    hash: &str,
) -> Result<EmailChange, DbError> {
    run(
        &OracleEmailTransaction { connection },
        user,
        email,
        id,
        hash,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    struct Fake {
        calls: Mutex<Vec<(&'static str, BindMap)>>,
        events: Mutex<Vec<&'static str>>,
        counts: [u64; 2],
        fault: &'static str,
    }
    impl Transaction for Fake {
        fn execute(&self, sql: &'static str, binds: BindMap) -> Result<u64, TransactionError> {
            let mut calls = self.calls.lock().unwrap();
            calls.push((sql, binds));
            let index = calls.len() - 1;
            if (index == 0 && self.fault == "claim") || (index == 1 && self.fault == "update") {
                return Err(DbError::SchemaNotReady.into());
            }
            if index == 1 && self.fault == "unique" {
                return Err(TransactionError::Conflict);
            }
            Ok(self.counts[index])
        }
        fn read(&self, user: i64) -> Result<EmailChangeData, DbError> {
            assert_eq!(user, 42);
            self.events.lock().unwrap().push("read");
            if self.fault == "read" {
                return Err(DbError::SchemaNotReady);
            }
            Ok(EmailChangeData {
                email: if self.fault == "wrong-read" {
                    "wrong"
                } else {
                    "fake';--"
                }
                .into(),
                email_verified_at: "2026-01-02T03:04:05.000Z".into(),
            })
        }
        fn commit(&self) -> Result<(), DbError> {
            self.events.lock().unwrap().push("commit");
            if self.fault == "commit" {
                Err(DbError::SchemaNotReady)
            } else {
                Ok(())
            }
        }
        fn rollback(&self) -> Result<(), DbError> {
            self.events.lock().unwrap().push("rollback");
            if self.fault == "rollback" {
                Err(DbError::SchemaNotReady)
            } else {
                Ok(())
            }
        }
    }
    #[test]
    fn atomic_claim_update_read_commit_or_rollback() {
        for (counts, fault, expected, events) in [
            ([1, 1], "", Some(0), vec!["read", "commit"]),
            ([0, 1], "", Some(1), vec!["rollback"]),
            ([1, 0], "", Some(2), vec!["rollback"]),
            ([2, 1], "", None, vec!["rollback"]),
            ([1, 2], "", None, vec!["rollback"]),
            ([1, 1], "claim", None, vec!["rollback"]),
            ([1, 1], "update", None, vec!["rollback"]),
            ([1, 1], "read", None, vec!["read", "rollback"]),
            ([1, 1], "wrong-read", None, vec!["read", "rollback"]),
            ([1, 1], "unique", Some(3), vec!["rollback"]),
            ([1, 1], "commit", None, vec!["read", "commit", "rollback"]),
            ([0, 1], "rollback", None, vec!["rollback"]),
        ] {
            let fake = Fake {
                calls: Mutex::new(vec![]),
                events: Mutex::new(vec![]),
                counts,
                fault,
            };
            let result = run(&fake, 42, "fake';--", "email_fixture", "private-hash");
            let actual = result.ok().map(|outcome| match outcome {
                EmailChange::Committed(_) => 0,
                EmailChange::Expired => 1,
                EmailChange::UserMissing => 2,
                EmailChange::Conflict => 3,
            });
            assert_eq!(actual, expected, "{fault}");
            assert_eq!(*fake.events.lock().unwrap(), events, "{fault}");
            let calls = fake.calls.lock().unwrap();
            assert_eq!(calls[0].0, CLAIM_SQL);
            assert!(!calls[0].0.contains("fake';--"));
            assert_eq!(calls[0].1["account"], DbValue::String("fake';--".into()));
            assert_eq!(
                calls[0].1["verification_id"],
                DbValue::String("email_fixture".into())
            );
            assert_eq!(
                calls[0].1["code_hash"],
                DbValue::String("private-hash".into())
            );
            if calls.len() > 1 {
                assert_eq!(calls[1].0, UPDATE_SQL);
                assert_eq!(calls[1].1["user_id"], DbValue::I64(42));
                assert_eq!(calls[1].1["email"], DbValue::String("fake';--".into()));
            }
        }
    }
}
