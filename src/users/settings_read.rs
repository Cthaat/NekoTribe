use crate::{
    auth::readiness,
    db::{
        oracle::{bind_refs, bind_values, BindMap, DbError},
        row::{oracle_row_to_db_row, DbRow},
        tx::OracleTx,
        value::DbValue,
    },
};

#[derive(Debug)]
pub enum SettingsRead {
    Ready(serde_json::Value),
    SchemaUnavailable,
}

pub(crate) async fn get(
    axum::extract::State(state): axum::extract::State<crate::auth::sessions::NativeState>,
    headers: axum::http::HeaderMap,
) -> Result<axum::response::Response, crate::httpx::errors::ApiError> {
    use crate::httpx::{errors::ApiError, response::V2Response};
    use axum::response::IntoResponse;
    let user = crate::posts::bookmark::interaction_actor(&state, &headers).await?;
    let result = state
        .repository
        .get_user_settings(user)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    let value = match result {
        SettingsRead::Ready(value) => value,
        SettingsRead::SchemaUnavailable => {
            return Err(ApiError::new(
                axum::http::StatusCode::SERVICE_UNAVAILABLE,
                50301,
                "服务暂不可用，请稍后重试。",
            ))
        }
    };
    let mut response = axum::Json(V2Response::ok(value)).into_response();
    response.headers_mut().insert(
        axum::http::header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static("private, no-store"),
    );
    Ok(response)
}

trait Transaction {
    fn check_schema(&self) -> Result<(), ()>;
    fn ensure(&self, user: i64) -> Result<(), ()>;
    fn read(&self, user: i64) -> Result<DbRow, ()>;
    fn commit(&self) -> Result<(), ()>;
    fn rollback(&self) -> Result<(), ()>;
}

fn run(tx: &impl Transaction, user: i64) -> Result<SettingsRead, ()> {
    if user <= 0 {
        return Err(());
    }
    if tx.check_schema().is_err() {
        return Ok(SettingsRead::SchemaUnavailable);
    }
    let result = tx
        .ensure(user)
        .and_then(|()| tx.read(user))
        .map(|row| map_settings(&row));
    let value = match result {
        Ok(value) => value,
        Err(()) => {
            tx.rollback()?;
            return Err(());
        }
    };
    tx.commit()?;
    Ok(SettingsRead::Ready(value))
}

fn map_settings(row: &DbRow) -> serde_json::Value {
    use crate::auth::session_repository::{nullable_text, profile_date, row_number, row_text};
    let flag = |key| row_number(row, key) == 1;
    let top = row_number(row, "AI_SENTIMENT_TOP_K");
    let return_probabilities = if row
        .get("AI_SENTIMENT_RETURN_PROBABILITIES")
        .is_none_or(|v| matches!(v, DbValue::Null))
    {
        true
    } else {
        flag("AI_SENTIMENT_RETURN_PROBABILITIES")
    };
    serde_json::json!({
        "user_id":row_number(row,"USER_ID"), "two_factor_enabled":flag("TWO_FACTOR_ENABLED"),
        "login_alerts":flag("LOGIN_ALERTS"), "profile_visibility":row_text(row,"PROFILE_VISIBILITY"),
        "show_online_status":flag("SHOW_ONLINE_STATUS"), "allow_dm_from_strangers":flag("ALLOW_DM_FROM_STRANGERS"),
        "push_notification_enabled":flag("PUSH_NOTIFICATION_ENABLED"), "email_notification_enabled":flag("EMAIL_NOTIFICATION_ENABLED"),
        "ai_sentiment_enabled":flag("AI_SENTIMENT_ENABLED"), "ai_sentiment_model_id":nullable_text(row,"AI_SENTIMENT_MODEL_ID"),
        "ai_sentiment_return_probabilities":return_probabilities, "ai_sentiment_include_metadata":flag("AI_SENTIMENT_INCLUDE_METADATA"),
        "ai_sentiment_top_k":if (1..=10).contains(&top) {top} else {3}, "updated_at":nullable_text(row,"UPDATED_AT").map(|s|profile_date(&s)).unwrap_or_default()
    })
}

struct OracleSettings<'a>(&'a oracle::Connection);
impl Transaction for OracleSettings<'_> {
    fn check_schema(&self) -> Result<(), ()> {
        let snapshot = readiness::collect_user_settings_snapshot(self.0).map_err(|_| ())?;
        readiness::validate_feature_snapshot(&snapshot, "user-settings").map_err(|_| ())
    }
    fn ensure(&self, user: i64) -> Result<(), ()> {
        OracleTx::new(self.0).execute("MERGE INTO n_user_settings s USING (SELECT :user_id AS user_id FROM dual) src ON (s.user_id = src.user_id) WHEN NOT MATCHED THEN INSERT (user_id) VALUES (src.user_id)", BindMap::from([("user_id".into(), DbValue::I64(user))])).map(|_| ()).map_err(|_| ())
    }
    fn read(&self, user: i64) -> Result<DbRow, ()> {
        let values = bind_values(BindMap::from([("user_id".into(), DbValue::I64(user))]));
        let refs = bind_refs(&values);
        let mut rows = self.0.query_named("SELECT user_id,two_factor_enabled,login_alerts,profile_visibility,show_online_status,allow_dm_from_strangers,push_notification_enabled,email_notification_enabled,ai_sentiment_enabled,ai_sentiment_model_id,ai_sentiment_return_probabilities,ai_sentiment_include_metadata,ai_sentiment_top_k,updated_at FROM n_user_settings WHERE user_id=:user_id", &refs).map_err(|_| ())?;
        let row = rows.next().ok_or(())?.map_err(|_| ())?;
        let value = oracle_row_to_db_row(&row).map_err(|_| ())?;
        if rows.next().is_some() {
            return Err(());
        }
        Ok(value)
    }
    fn commit(&self) -> Result<(), ()> {
        OracleTx::new(self.0).commit().map_err(|_| ())
    }
    fn rollback(&self) -> Result<(), ()> {
        OracleTx::new(self.0).rollback().map_err(|_| ())
    }
}

pub(crate) fn execute(connection: &oracle::Connection, user: u64) -> Result<SettingsRead, DbError> {
    let user = i64::try_from(user).map_err(|_| DbError::SchemaNotReady)?;
    run(&OracleSettings(connection), user).map_err(|_| DbError::SchemaNotReady)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    struct Fake {
        fail: &'static str,
        calls: RefCell<Vec<&'static str>>,
    }
    impl Transaction for Fake {
        fn check_schema(&self) -> Result<(), ()> {
            self.call("schema")
        }
        fn ensure(&self, _: i64) -> Result<(), ()> {
            self.call("ensure")
        }
        fn read(&self, _: i64) -> Result<DbRow, ()> {
            self.call("read")?;
            Ok(DbRow::from([
                ("USER_ID".into(), DbValue::I64(42)),
                ("LOGIN_ALERTS".into(), DbValue::I64(1)),
                ("AI_SENTIMENT_RETURN_PROBABILITIES".into(), DbValue::Null),
            ]))
        }
        fn commit(&self) -> Result<(), ()> {
            self.call("commit")
        }
        fn rollback(&self) -> Result<(), ()> {
            self.call("rollback")
        }
    }
    impl Fake {
        fn call(&self, name: &'static str) -> Result<(), ()> {
            self.calls.borrow_mut().push(name);
            if self.fail == name {
                Err(())
            } else {
                Ok(())
            }
        }
    }
    #[test]
    fn transaction_maps_and_rolls_back_errors() {
        for mode in ["", "schema", "ensure", "read", "commit"] {
            let fake = Fake {
                fail: mode,
                calls: RefCell::new(vec![]),
            };
            let result = run(&fake, 42);
            match mode {
                "" => match result {
                    Ok(SettingsRead::Ready(value)) => {
                        assert_eq!(value["user_id"], 42);
                        assert_eq!(value["login_alerts"], true);
                        assert_eq!(value["ai_sentiment_return_probabilities"], true);
                        assert_eq!(value["ai_sentiment_top_k"], 3);
                    }
                    _ => panic!("expected settings"),
                },
                "schema" => assert!(matches!(result, Ok(SettingsRead::SchemaUnavailable))),
                _ => assert!(result.is_err()),
            }
            assert_eq!(
                fake.calls.borrow().contains(&"rollback"),
                mode == "ensure" || mode == "read"
            );
        }
    }
}
