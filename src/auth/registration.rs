use crate::{
    auth::{
        login::{request_body, scalar},
        otp::required,
        sessions::NativeState,
    },
    db::{
        oracle::{BindMap, DbError},
        tx::OracleTx,
        value::DbValue,
    },
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    body::{to_bytes, Body},
    extract::State,
    http::Request,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::{json, Value};

#[derive(Clone)]
pub struct RegistrationRecord {
    pub user_id: u64,
    pub email: String,
    pub username: String,
    pub password_hash: String,
    pub display_name: String,
    pub bio: String,
    pub location: String,
    pub phone: String,
    pub birth_date: String,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    Registered,
    MissingOtp,
    PossibleDuplicate,
}

pub(crate) const CHECK_OTP: &str = "SELECT verified_at FROM n_auth_otp_events
WHERE account = :account AND otp_type = 'register' AND verification_id = :verification_id
  AND expires_at > CURRENT_TIMESTAMP AND expires_at > created_at AND verified_at IS NOT NULL";
const CLAIM_OTP: &str = "UPDATE n_auth_otp_events SET expires_at = created_at
WHERE account = :account AND otp_type = 'register' AND verification_id = :verification_id
  AND expires_at > CURRENT_TIMESTAMP AND expires_at > created_at AND verified_at IS NOT NULL";
const INSERT: &str = "INSERT INTO n_users
(user_id,email,username,password_hash,display_name,bio,location,phone,birth_date,email_verified_at,status)
VALUES (:user_id,:email,:username,:password_hash,:display_name,:bio,:location,:phone,
CASE WHEN :birth_date IS NULL THEN NULL ELSE TO_DATE(:birth_date, 'YYYY-MM-DD') END,CURRENT_TIMESTAMP,'active')";

trait RegistrationTransaction {
    fn execute(&self, sql: &str, binds: BindMap) -> Result<u64, DbError>;
    fn commit(&self) -> Result<(), DbError>;
    fn rollback(&self) -> Result<(), DbError>;
}

impl RegistrationTransaction for OracleTx<'_> {
    fn execute(&self, sql: &str, binds: BindMap) -> Result<u64, DbError> {
        Ok(OracleTx::execute(self, sql, binds)?.rows_affected)
    }
    fn commit(&self) -> Result<(), DbError> {
        OracleTx::commit(self)
    }
    fn rollback(&self) -> Result<(), DbError> {
        OracleTx::rollback(self)
    }
}

fn insert(
    tx: &impl RegistrationTransaction,
    record: &RegistrationRecord,
    verification_id: &str,
) -> Result<Outcome, DbError> {
    let text = |s: &str| DbValue::String(s.into());
    let nullable = |s: &str| if s.is_empty() { DbValue::Null } else { text(s) };
    let user = i64::try_from(record.user_id).map_err(|_| DbError::SchemaNotReady)?;
    let result = (|| {
        let claimed = tx.execute(
            CLAIM_OTP,
            BindMap::from([
                ("account".into(), text(&record.email)),
                ("verification_id".into(), text(verification_id)),
            ]),
        )?;
        if claimed == 0 {
            return Ok(Outcome::MissingOtp);
        }
        if claimed != 1 {
            return Err(DbError::SchemaNotReady);
        }
        let inserted = tx.execute(
            INSERT,
            BindMap::from([
                ("user_id".into(), DbValue::I64(user)),
                ("email".into(), text(&record.email)),
                ("username".into(), text(&record.username)),
                ("password_hash".into(), text(&record.password_hash)),
                ("display_name".into(), text(&record.display_name)),
                ("bio".into(), nullable(&record.bio)),
                ("location".into(), nullable(&record.location)),
                ("phone".into(), nullable(&record.phone)),
                ("birth_date".into(), nullable(&record.birth_date)),
            ]),
        );
        match inserted {
            Ok(1) => {}
            Err(DbError::Oracle(error))
                if error.db_error().is_some_and(|error| error.code() == 1) =>
            {
                return Ok(Outcome::PossibleDuplicate);
            }
            Err(error) => return Err(error),
            Ok(_) => return Err(DbError::SchemaNotReady),
        }
        tx.commit()?;
        Ok(Outcome::Registered)
    })();
    if !matches!(result, Ok(Outcome::Registered)) {
        tx.rollback()?;
    }
    result
}

pub(crate) fn execute(
    connection: &oracle::Connection,
    record: &RegistrationRecord,
    verification_id: &str,
) -> Result<Outcome, DbError> {
    insert(&OracleTx::new(connection), record, verification_id)
}

#[cfg(test)]
mod transaction_tests {
    use super::*;
    use std::cell::RefCell;

    struct Transaction {
        claimed: u64,
        inserted: u64,
        calls: RefCell<Vec<&'static str>>,
    }

    impl RegistrationTransaction for Transaction {
        fn execute(&self, sql: &str, binds: BindMap) -> Result<u64, DbError> {
            if sql == CLAIM_OTP {
                self.calls.borrow_mut().push("claim");
                assert_eq!(
                    binds["account"],
                    DbValue::String("fixture@example.test".into())
                );
                assert_eq!(
                    binds["verification_id"],
                    DbValue::String("otp_fixture".into())
                );
                return Ok(self.claimed);
            }
            assert_eq!(sql, INSERT);
            assert_eq!(binds["birth_date"], DbValue::Null);
            self.calls.borrow_mut().push("insert");
            Ok(self.inserted)
        }
        fn commit(&self) -> Result<(), DbError> {
            self.calls.borrow_mut().push("commit");
            Ok(())
        }
        fn rollback(&self) -> Result<(), DbError> {
            self.calls.borrow_mut().push("rollback");
            Ok(())
        }
    }

    #[test]
    fn registration_claim_and_insert_share_a_transaction() {
        let record = RegistrationRecord {
            user_id: 42,
            email: "fixture@example.test".into(),
            username: "fixture".into(),
            password_hash: "synthetic".into(),
            display_name: "Fixture".into(),
            bio: String::new(),
            location: String::new(),
            phone: String::new(),
            birth_date: String::new(),
        };
        for (claimed, inserted, trace, outcome) in [
            (
                1,
                1,
                vec!["claim", "insert", "commit"],
                Some(Outcome::Registered),
            ),
            (0, 1, vec!["claim", "rollback"], Some(Outcome::MissingOtp)),
            (1, 0, vec!["claim", "insert", "rollback"], None),
        ] {
            let tx = Transaction {
                claimed,
                inserted,
                calls: RefCell::new(vec![]),
            };
            assert_eq!(insert(&tx, &record, "otp_fixture").ok(), outcome);
            assert_eq!(tx.calls.into_inner(), trace);
        }
    }
}

fn server_error() -> ApiError {
    ApiError::server_error("服务器内部错误")
}
pub(crate) async fn register(
    State(state): State<NativeState>,
    request: Request<Body>,
) -> Result<Response, ApiError> {
    let (parts, body) = request.into_parts();
    let bytes = to_bytes(body, 1024 * 1024)
        .await
        .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
    let body = request_body(&parts.headers, &bytes)?;
    let email = required(&body, "email")?;
    let username = required(&body, "username")?;
    let password = required(&body, "password")?;
    let confirm = required(&body, "confirm_password")?;
    let display_name = required(&body, "display_name")?;
    let verification_id = required(&body, "verification_id")?;
    if body.get("agree_to_terms") != Some(&Value::Bool(true)) {
        return Err(ApiError::bad_request("必须同意服务条款"));
    }
    if password != confirm {
        return Err(ApiError::bad_request("两次输入的密码不一致"));
    }
    crate::auth::input::require_new_password(&password)?;
    crate::auth::input::require_new_email(&email)?;
    crate::auth::input::require_registration_name(&username, "用户名至少需要2个字符")?;
    crate::auth::input::require_registration_name(&display_name, "昵称至少需要2个字符")?;
    if !state
        .repository
        .registration_otp(&email, &verification_id)
        .await
        .map_err(|_| server_error())?
    {
        return Err(ApiError::unprocessable("请先完成验证码校验"));
    }
    if state
        .repository
        .registration_exists(&email, &username)
        .await
        .map_err(|_| server_error())?
    {
        return Err(ApiError::conflict("邮箱或用户名已被注册"));
    }
    let user_id = state
        .repository
        .registration_next_id()
        .await
        .map_err(|_| server_error())?;
    let password_hash = tokio::task::spawn_blocking(move || bcrypt::hash(password, 10))
        .await
        .map_err(|_| server_error())?
        .map_err(|_| server_error())?;
    let record = RegistrationRecord {
        user_id,
        email,
        username,
        password_hash,
        display_name,
        bio: scalar(body.get("bio")),
        location: scalar(body.get("location")),
        phone: scalar(body.get("phone")),
        birth_date: scalar(body.get("birth_date")),
    };
    let outcome = state
        .repository
        .registration_insert(&record, &verification_id)
        .await
        .map_err(|_| server_error())?;
    match outcome {
        Outcome::Registered => {}
        Outcome::MissingOtp => return Err(ApiError::unprocessable("请先完成验证码校验")),
        Outcome::PossibleDuplicate => {
            if state
                .repository
                .registration_exists(&record.email, &record.username)
                .await
                .map_err(|_| server_error())?
            {
                return Err(ApiError::conflict("邮箱或用户名已被注册"));
            }
            return Err(server_error());
        }
    }
    let mut profile = state
        .repository
        .login_profile(user_id)
        .await
        .map_err(|_| server_error())?
        .ok_or_else(|| ApiError::not_found("用户不存在"))?;
    let avatar = profile
        .get("avatar_url")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let avatar = state
        .storage_urls
        .normalize_avatar(avatar)
        .map_err(|_| server_error())?;
    profile
        .as_object_mut()
        .ok_or_else(server_error)?
        .insert("avatar_url".into(), Value::String(avatar));
    Ok(Json(V2Response::ok_with_message(
        json!({"user":profile}),
        "registration success",
    ))
    .into_response())
}
