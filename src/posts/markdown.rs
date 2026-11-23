use crate::{
    auth::{login::js_trim, readiness},
    db::{
        oracle::{BindMap, DbError},
        tx::{OracleTx, Transaction},
        value::DbValue,
    },
    httpx::errors::ApiError,
};
use axum::http::StatusCode;
use serde::Deserialize;
use std::sync::OnceLock;

#[derive(Deserialize)]
struct Contract {
    max_markdown_bytes: usize,
    sql: Sql,
}

#[derive(Deserialize)]
struct Sql {
    insert: String,
    read: String,
    update: String,
    remove: String,
    present: String,
}

fn contract() -> &'static Contract {
    static CONTRACT: OnceLock<Contract> = OnceLock::new();
    CONTRACT.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../../contracts/requirements/post-markdown.json"
        ))
        .expect("valid post Markdown contract")
    })
}

fn invalid() -> ApiError {
    ApiError::bad_request("markdown 必须为非空正文且不超过 16 KiB")
}

pub(crate) fn unavailable() -> ApiError {
    ApiError::new(
        StatusCode::SERVICE_UNAVAILABLE,
        50301,
        "服务暂不可用，请稍后重试。",
    )
}

pub(super) fn not_allowed() -> ApiError {
    ApiError::bad_request("只有普通帖支持 Markdown 长文")
}

pub(crate) fn validate(body: &str) -> Result<(), ApiError> {
    if body.len() > contract().max_markdown_bytes || js_trim(body).is_empty() {
        return Err(invalid());
    }
    Ok(())
}

pub(super) fn parse_raw(raw: &str) -> Result<String, ApiError> {
    let body: String = serde_json::from_str(raw).map_err(|_| invalid())?;
    validate(&body)?;
    Ok(body)
}

pub(crate) fn parse_value(value: &serde_json::Value) -> Result<String, ApiError> {
    let body = value.as_str().ok_or_else(invalid)?;
    validate(body)?;
    Ok(body.to_owned())
}

pub(crate) fn require_schema(tx: &impl Transaction) -> Result<(), DbError> {
    let snapshot = readiness::collect_feature_with("post-markdown", |sql, binds| {
        tx.query(sql, binds)?
            .iter()
            .map(|row| serde_json::to_value(row).map_err(|_| DbError::SchemaNotReady))
            .collect()
    })?;
    readiness::validate_feature_snapshot(&snapshot, "post-markdown")
        .map_err(|_| DbError::SchemaNotReady)
}

#[derive(Clone, Copy)]
pub(crate) enum Source {
    Post(i64),
    GroupPost(i64),
}

pub(crate) fn attach(tx: &impl Transaction, source: Source, markdown: &str) -> Result<(), DbError> {
    let (regular, group) = match source {
        Source::Post(id) => (DbValue::I64(id), DbValue::Null),
        Source::GroupPost(id) => (DbValue::Null, DbValue::I64(id)),
    };
    let binds = BindMap::from([("post_id".into(), regular), ("group_post_id".into(), group)]);
    if tx.execute_clob(&contract().sql.insert, binds, "markdown_body", markdown)? != 1 {
        return Err(DbError::SchemaNotReady);
    }
    Ok(())
}

pub(super) fn update(
    tx: &impl Transaction,
    post_id: i64,
    markdown: Option<&str>,
) -> Result<(), DbError> {
    let sql = &contract().sql;
    let binds = BindMap::from([("post_id".into(), DbValue::I64(post_id))]);
    if let Some(markdown) = markdown {
        match tx.execute_clob(&sql.update, binds, "markdown_body", markdown)? {
            0 => attach(tx, Source::Post(post_id), markdown),
            1 => Ok(()),
            _ => Err(DbError::SchemaNotReady),
        }
    } else {
        match tx.execute(&sql.remove, binds)? {
            0 | 1 => Ok(()),
            _ => Err(DbError::SchemaNotReady),
        }
    }
}

const OWNER_SCHEMA: &str = "SELECT 1 FROM dual WHERE USER=SYS_CONTEXT('USERENV','CURRENT_SCHEMA')";

pub(crate) fn read(tx: &impl Transaction, source: Source) -> Result<Option<String>, DbError> {
    let (id, group) = match source {
        Source::Post(id) => (id, 0),
        Source::GroupPost(id) => (id, 1),
    };
    let sql = &contract().sql;
    let rows = tx.query(
        &sql.read,
        BindMap::from([
            ("post_id".into(), DbValue::I64(id)),
            ("is_group".into(), DbValue::I64(group)),
        ]),
    );
    let rows = match rows {
        Ok(rows) => rows,
        Err(DbError::Oracle(error))
            if error.db_error().is_some_and(|error| error.code() == 942) =>
        {
            if !tx.query(OWNER_SCHEMA, BindMap::new())?.is_empty()
                && tx.query(&sql.present, BindMap::new())?.is_empty()
            {
                return Ok(None);
            }
            return Err(DbError::SchemaNotReady);
        }
        Err(error) => return Err(error),
    };
    rows.first()
        .map(|row| {
            row.get("MARKDOWN_BODY")
                .and_then(DbValue::as_str)
                .map(str::to_owned)
                .ok_or(DbError::SchemaNotReady)
        })
        .transpose()
}

pub enum History {
    Ready(Vec<Option<String>>),
    Unavailable,
}

pub(crate) fn read_post_history(
    connection: &oracle::Connection,
    ids: Vec<u64>,
) -> Result<History, DbError> {
    let tx = OracleTx::new(connection);
    match ids
        .into_iter()
        .map(|id| read(&tx, Source::Post(id as i64)))
        .collect()
    {
        Ok(markdown) => Ok(History::Ready(markdown)),
        Err(DbError::SchemaNotReady) => Ok(History::Unavailable),
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod tests;
