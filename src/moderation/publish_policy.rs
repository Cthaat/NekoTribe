use crate::{
    auth::session_repository::row_number,
    db::{
        oracle::{BindMap, DbError},
        row::DbRow,
        value::DbValue,
    },
};
use serde::Deserialize;
use std::{collections::HashMap, sync::OnceLock};

#[derive(Deserialize)]
struct Policy {
    message: String,
    sql: HashMap<String, String>,
}

fn policy() -> &'static Policy {
    static SPEC: OnceLock<Policy> = OnceLock::new();
    SPEC.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../../contracts/requirements/moderation-publish-policy.json"
        ))
        .expect("valid moderation publishing policy")
    })
}

pub(crate) fn message() -> &'static str {
    &policy().message
}

/// The moderation transaction and publishing writers lock the same account row.
pub fn allowed(
    user: i64,
    mut query: impl FnMut(&str, BindMap) -> Result<Vec<DbRow>, DbError>,
) -> Result<bool, DbError> {
    let sql = &policy().sql;
    let binds = BindMap::from([("user_id".into(), DbValue::I64(user))]);
    if query(&sql["lock"], binds.clone())?.is_empty() {
        return Ok(false);
    }
    Ok(query(&sql["allowed"], binds)?
        .first()
        .is_some_and(|row| row_number(row, "ALLOWED") == 1))
}

pub fn queries() -> (&'static str, &'static str) {
    (&policy().sql["lock"], &policy().sql["allowed"])
}
