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
    UserMissing,
    SettingsMissing,
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
        SettingsRead::UserMissing => return Err(ApiError::not_found("用户不存在")),
        SettingsRead::SettingsMissing => return Err(ApiError::not_found("用户设置不存在")),
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
    fn lock_user(&self, user: i64) -> Result<bool, ()>;
    fn ensure(&self, user: i64) -> Result<(), ()>;
    fn update(
        &self,
        user: i64,
        patch: &crate::users::settings_patch::SettingsPatch,
    ) -> Result<(), ()>;
    fn read(&self, user: i64) -> Result<Option<DbRow>, ()>;
    fn commit(&self) -> Result<(), ()>;
    fn rollback(&self) -> Result<(), ()>;
}

fn run(
    tx: &impl Transaction,
    user: i64,
    patch: Option<&crate::users::settings_patch::SettingsPatch>,
) -> Result<SettingsRead, ()> {
    if user <= 0 {
        return Err(());
    }
    if tx.check_schema().is_err() {
        return Ok(SettingsRead::SchemaUnavailable);
    }
    let result = (|| {
        if !tx.lock_user(user)? { return Ok(SettingsRead::UserMissing); }
        tx.ensure(user)?;
        if let Some(patch) = patch { tx.update(user, patch)?; }
        let Some(row) = tx.read(user)? else { return Ok(SettingsRead::SettingsMissing); };
        if crate::auth::session_repository::row_number(&row, "USER_ID") != user { return Err(()); }
        Ok(SettingsRead::Ready(map_settings(&row)))
    })();
    let value = match result {
        Ok(value) => value,
        Err(()) => {
            tx.rollback()?;
            return Err(());
        }
    };
    if !matches!(value, SettingsRead::Ready(_)) {
        tx.rollback()?;
        return Ok(value);
    }
    if tx.commit().is_err() {
        tx.rollback()?;
        return Err(());
    }
    Ok(value)
}

fn map_settings(row: &DbRow) -> serde_json::Value {
    use crate::auth::session_repository::{nullable_text, profile_date, row_number, row_text};
    // Oracle rows are represented as strings; preserve fractions until after
    // boolean/range checks instead of using the generic integer conversion.
    let number = |key: &str| match row.get(key) {
        Some(DbValue::I64(value)) => Some(*value as f64),
        Some(DbValue::F64(value)) => Some(*value),
        Some(DbValue::String(value)) => value.parse::<f64>().ok(),
        _ => None,
    };
    let flag = |key| number(key) == Some(1.0);
    let top = number("AI_SENTIMENT_TOP_K").filter(|value| value.is_finite() && (1.0..=10.0).contains(value)).map(|value| value as i64).unwrap_or(3);
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
        "ai_sentiment_top_k":top, "updated_at":nullable_text(row,"UPDATED_AT").map(|s|profile_date(&s)).unwrap_or_default()
    })
}

struct OracleSettings<'a>(&'a oracle::Connection);
impl Transaction for OracleSettings<'_> {
    fn check_schema(&self) -> Result<(), ()> {
        let snapshot = readiness::collect_user_settings_snapshot(self.0).map_err(|_| ())?;
        readiness::validate_feature_snapshot(&snapshot, "user-settings").map_err(|_| ())
    }
    fn lock_user(&self, user: i64) -> Result<bool, ()> {
        let values = bind_values(BindMap::from([("user_id".into(), DbValue::I64(user))]));
        let refs = bind_refs(&values);
        let id = match self
            .0
            .query_row_as_named::<i64>(
                "SELECT user_id FROM n_users WHERE user_id=:user_id FOR UPDATE",
                &refs,
            )
        {
            Ok(id) => id,
            Err(error) if error.kind() == oracle::ErrorKind::NoDataFound => return Ok(false),
            Err(_) => return Err(()),
        };
        if id != user {
            return Err(());
        }
        Ok(true)
    }
    fn ensure(&self, user: i64) -> Result<(), ()> {
        OracleTx::new(self.0).execute("MERGE INTO n_user_settings s USING (SELECT :user_id AS user_id FROM dual) src ON (s.user_id = src.user_id) WHEN NOT MATCHED THEN INSERT (user_id) VALUES (src.user_id)", BindMap::from([("user_id".into(), DbValue::I64(user))])).map(|_| ()).map_err(|_| ())
    }
    fn update(
        &self,
        user: i64,
        patch: &crate::users::settings_patch::SettingsPatch,
    ) -> Result<(), ()> {
        if let Some((query, binds)) = crate::users::settings_patch::update_statement(user, patch) {
            OracleTx::new(self.0)
                .execute(&query, binds)
                .map_err(|_| ())?;
        }
        Ok(())
    }
    fn read(&self, user: i64) -> Result<Option<DbRow>, ()> {
        let values = bind_values(BindMap::from([("user_id".into(), DbValue::I64(user))]));
        let refs = bind_refs(&values);
        let mut rows = self.0.query_named("SELECT user_id,two_factor_enabled,login_alerts,profile_visibility,show_online_status,allow_dm_from_strangers,push_notification_enabled,email_notification_enabled,ai_sentiment_enabled,ai_sentiment_model_id,ai_sentiment_return_probabilities,ai_sentiment_include_metadata,ai_sentiment_top_k,updated_at FROM n_user_settings WHERE user_id=:user_id", &refs).map_err(|_| ())?;
        let Some(row) = rows.next() else { return Ok(None); };
        let row = row.map_err(|_| ())?;
        let value = oracle_row_to_db_row(&row).map_err(|_| ())?;
        if rows.next().is_some() {
            return Err(());
        }
        Ok(Some(value))
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
    run(&OracleSettings(connection), user, None).map_err(|_| DbError::SchemaNotReady)
}

pub(crate) fn execute_patch(
    connection: &oracle::Connection,
    user: u64,
    patch: &crate::users::settings_patch::SettingsPatch,
) -> Result<SettingsRead, DbError> {
    let user = i64::try_from(user).map_err(|_| DbError::SchemaNotReady)?;
    run(&OracleSettings(connection), user, Some(patch)).map_err(|_| DbError::SchemaNotReady)
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
        fn lock_user(&self, _: i64) -> Result<bool, ()> {
            self.call("lock")?;
            Ok(self.fail != "missing-user")
        }
        fn ensure(&self, _: i64) -> Result<(), ()> {
            self.call("ensure")
        }
        fn update(
            &self,
            _: i64,
            _: &crate::users::settings_patch::SettingsPatch,
        ) -> Result<(), ()> {
            self.call("update")
        }
        fn read(&self, _: i64) -> Result<Option<DbRow>, ()> {
            self.call("read")?;
            if self.fail == "missing-settings" { return Ok(None); }
            Ok(Some(DbRow::from([
                ("USER_ID".into(), DbValue::I64(42)),
                ("LOGIN_ALERTS".into(), DbValue::I64(1)),
                ("AI_SENTIMENT_RETURN_PROBABILITIES".into(), DbValue::Null),
            ])))
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
            if self.fail.split('+').any(|failure| failure == name) {
                Err(())
            } else {
                Ok(())
            }
        }
    }
    #[test]
    fn transaction_maps_and_rolls_back_errors() {
        for mode in ["", "schema", "lock", "ensure", "read", "commit"] {
            let fake = Fake {
                fail: mode,
                calls: RefCell::new(vec![]),
            };
            let result = run(&fake, 42, None);
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
            if mode.is_empty() {
                assert_eq!(
                    &*fake.calls.borrow(),
                    &["schema", "lock", "ensure", "read", "commit"]
                );
            }
            assert_eq!(
                fake.calls.borrow().contains(&"rollback"),
                mode == "lock" || mode == "ensure" || mode == "read" || mode == "commit"
            );
        }
    }

    #[test]
    fn patch_update_and_read_share_rollback_boundary() {
        for mode in ["", "update", "read", "commit"] {
            let fake = Fake {
                fail: mode,
                calls: RefCell::new(vec![]),
            };
            let result = run(
                &fake,
                42,
                Some(&crate::users::settings_patch::SettingsPatch::default()),
            );
            assert_eq!(result.is_ok(), mode.is_empty());
            assert_eq!(
                fake.calls.borrow().contains(&"rollback"),
                mode == "update" || mode == "read" || mode == "commit"
            );
            assert!(fake.calls.borrow().contains(&"update"));
        }
    }

    #[test]
    fn shared_number_mapping() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!("../../contracts/scenarios/user-settings-native.json")).unwrap();
        for case in fixture["mappingCases"].as_array().unwrap() {
            let number = |key: &str| case[key].as_f64().map(DbValue::F64).unwrap_or(DbValue::Null);
            let row = DbRow::from([
                ("USER_ID".into(), DbValue::I64(42)),
                ("TWO_FACTOR_ENABLED".into(), number("flag")),
                ("LOGIN_ALERTS".into(), number("flag")),
                ("AI_SENTIMENT_RETURN_PROBABILITIES".into(), number("flag")),
                ("AI_SENTIMENT_TOP_K".into(), number("top")),
            ]);
            let value = map_settings(&row);
            assert_eq!(value["two_factor_enabled"], case["expectedFlag"], "{case}");
            assert_eq!(value["login_alerts"], case["expectedFlag"], "{case}");
            assert_eq!(value["ai_sentiment_return_probabilities"], case["expectedProbabilities"], "{case}");
            assert_eq!(value["ai_sentiment_top_k"], case["expectedTop"], "{case}");
            let string_row: DbRow = row.into_iter().map(|(key, value)| (key, match value {
                DbValue::F64(value) => DbValue::String(value.to_string()),
                other => other,
            })).collect();
            assert_eq!(map_settings(&string_row), value, "Oracle NUMBER string {case}");
        }
    }

    #[test]
    fn missing_rows_roll_back_without_committing() {
        for mode in ["missing-user", "missing-settings"] {
            for patch in [None, Some(crate::users::settings_patch::SettingsPatch::default())] {
                let fake = Fake {fail: mode, calls: RefCell::new(vec![])};
                let result = run(&fake, 42, patch.as_ref()).unwrap();
                assert!(matches!((&result, mode), (SettingsRead::UserMissing, "missing-user") | (SettingsRead::SettingsMissing, "missing-settings")));
                let calls = fake.calls.borrow();
                assert!(calls.contains(&"rollback"));
                assert!(!calls.contains(&"commit"));
                if mode == "missing-user" { assert!(!calls.contains(&"ensure")); }
            }
        }
    }

    #[test]
    fn rollback_failure_never_returns_a_settings_snapshot() {
        for mode in ["read+rollback", "commit+rollback"] {
            let fake = Fake {fail: mode, calls: RefCell::new(vec![])};
            assert!(run(&fake, 42, None).is_err());
            assert!(fake.calls.borrow().contains(&"rollback"));
        }
    }
}
