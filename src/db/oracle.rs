use std::collections::BTreeMap;

use oracle::sql_type::ToSql;

use crate::{config::env::OracleConfig, db::value::DbValue};

pub type BindMap = BTreeMap<String, DbValue>;

#[derive(Debug, thiserror::Error)]
pub enum DbError {
    #[error(transparent)]
    Oracle(#[from] oracle::Error),
    #[error("blocking task failed: {0}")]
    Join(#[from] tokio::task::JoinError),
    #[error("database concurrency limiter closed")]
    SemaphoreClosed,
    #[error("expected numeric value for column {0}")]
    ExpectedNumber(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExecuteResult {
    pub rows_affected: u64,
}

#[derive(Debug)]
pub enum OracleBindValue {
    NullString(Option<String>),
    String(String),
    I64(i64),
    F64(f64),
    BoolNumber(i32),
}

impl OracleBindValue {
    pub fn as_to_sql(&self) -> &dyn ToSql {
        match self {
            Self::NullString(value) => value,
            Self::String(value) => value,
            Self::I64(value) => value,
            Self::F64(value) => value,
            Self::BoolNumber(value) => value,
        }
    }
}

pub fn connect(config: &OracleConfig) -> Result<oracle::Connection, DbError> {
    Ok(oracle::Connection::connect(
        &config.user,
        &config.password,
        config.connect_string(),
    )?)
}

pub fn bind_values(binds: BindMap) -> Vec<(String, OracleBindValue)> {
    binds
        .into_iter()
        .map(|(key, value)| {
            let bind = match value {
                DbValue::Null => OracleBindValue::NullString(None),
                DbValue::String(value)
                | DbValue::JsonString(value)
                | DbValue::TimestampString(value) => OracleBindValue::String(value),
                DbValue::I64(value) => OracleBindValue::I64(value),
                DbValue::F64(value) => OracleBindValue::F64(value),
                DbValue::BoolNumber(value) => OracleBindValue::BoolNumber(i32::from(value)),
            };
            (key.trim_start_matches(':').to_string(), bind)
        })
        .collect()
}

pub fn bind_refs(values: &[(String, OracleBindValue)]) -> Vec<(&str, &dyn ToSql)> {
    values
        .iter()
        .map(|(key, value)| (key.as_str(), value.as_to_sql()))
        .collect()
}
