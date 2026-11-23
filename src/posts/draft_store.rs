use super::{
    create_transaction::{self, PostCreation},
    draft_input::{parse_payload, Post},
    markdown,
};
use crate::{
    auth::{readiness, storage_urls::StorageUrlPolicy},
    chat_message_send::write_one,
    db::{
        oracle::{BindMap, DbError},
        row::DbRow,
        tx::{OracleTx, Transaction},
        value::DbValue,
    },
    group_post_write::{self, Creation, Outcome as GroupOutcome},
    httpx::errors::ApiError,
    moderation::publish_policy,
};
use axum::http::StatusCode;
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::OnceLock;

pub use super::draft_input::{DraftPayload, ListQuery};

#[derive(Deserialize)]
pub(super) struct Contract {
    pub(super) sweep_interval_seconds: u64,
    sweep_batch_size: usize,
    pub(super) default_list_limit: usize,
    pub(super) max_list_limit: usize,
    pub(super) max_payload_bytes: usize,
    sql: Sql,
}

#[derive(Deserialize)]
struct Sql {
    list: String,
    read: String,
    lock_owner: String,
    insert: String,
    edit: String,
    remove: String,
    schedule: String,
    unschedule: String,
    candidates: String,
    lock_due: String,
    published: String,
    failed: String,
}

pub(super) fn contract() -> &'static Contract {
    static SPEC: OnceLock<Contract> = OnceLock::new();
    SPEC.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../../contracts/requirements/post-drafts.json"
        ))
        .expect("valid post drafts contract")
    })
}

pub enum Operation {
    List(ListQuery),
    Create(DraftPayload),
    Edit(u64, DraftPayload),
    Remove(u64),
    Schedule(u64, String),
    Unschedule(u64),
    Publish(u64),
}

pub enum Outcome {
    Saved(Value, Option<Notice>),
    Rejected(ApiError),
}

pub struct Notice {
    pub(super) owner: u64,
    pub(super) post_id: u64,
    pub(super) post: Post,
}

const NEXT_ID: &str = "SELECT seq_post_draft_id.NEXTVAL AS id FROM dual";
const SAVEPOINT: &str = "SAVEPOINT draft_publication";
const ROLLBACK_PUBLICATION: &str = "ROLLBACK TO SAVEPOINT draft_publication";
const MAX_ID: i64 = 9_007_199_254_740_991;

pub(super) fn unavailable() -> ApiError {
    ApiError::new(
        StatusCode::SERVICE_UNAVAILABLE,
        50301,
        "服务暂不可用，请稍后重试。",
    )
}

fn missing() -> ApiError {
    ApiError::not_found("草稿不存在")
}

fn immutable() -> ApiError {
    ApiError::conflict("草稿已发布")
}

fn require_schema(tx: &impl Transaction) -> Result<(), DbError> {
    let snapshot = readiness::collect_feature_with("post-drafts", |sql, binds| {
        tx.query(sql, binds)?
            .iter()
            .map(|row| serde_json::to_value(row).map_err(|_| DbError::SchemaNotReady))
            .collect()
    })?;
    readiness::validate_feature_snapshot(&snapshot, "post-drafts")
        .map_err(|_| DbError::SchemaNotReady)
}

fn number(key: &str, id: u64) -> (String, DbValue) {
    (key.into(), DbValue::I64(id as i64))
}

fn text(key: &str, value: impl Into<String>) -> (String, DbValue) {
    (key.into(), DbValue::String(value.into()))
}

fn nullable_id(id: Option<u64>) -> DbValue {
    id.map_or(DbValue::Null, |id| DbValue::I64(id as i64))
}

fn draft_key(owner: u64, id: u64) -> BindMap {
    BindMap::from([number("owner_id", owner), number("draft_id", id)])
}

fn row_id(row: &DbRow, key: &str) -> Result<u64, DbError> {
    row.get(key)
        .and_then(DbValue::as_i64)
        .filter(|id| (1..=MAX_ID).contains(id))
        .map(|id| id as u64)
        .ok_or_else(|| DbError::ExpectedNumber(key.into()))
}

fn row_str<'a>(row: &'a DbRow, key: &str) -> Option<&'a str> {
    row.get(key).and_then(DbValue::as_str)
}

fn stored_payload(row: &DbRow) -> Result<DraftPayload, DbError> {
    let raw = row_str(row, "PAYLOAD_JSON").ok_or(DbError::SchemaNotReady)?;
    let payload = parse_payload(raw.as_bytes()).map_err(|_| DbError::SchemaNotReady)?;
    let stored_group = match row.get("GROUP_ID") {
        None | Some(DbValue::Null) => None,
        _ => Some(row_id(row, "GROUP_ID")?),
    };
    if payload.group_id() != stored_group {
        return Err(DbError::SchemaNotReady);
    }
    Ok(payload)
}

fn dto(row: &DbRow) -> Result<Value, DbError> {
    let payload = stored_payload(row)?;
    let published = match row.get("PUBLISHED_POST_ID") {
        None | Some(DbValue::Null) => None,
        _ => Some(row_id(row, "PUBLISHED_POST_ID")?),
    };
    Ok(json!({
        "draft_id": row_id(row, "DRAFT_ID")?, "payload": payload,
        "status": row_str(row, "STATUS").ok_or(DbError::SchemaNotReady)?,
        "scheduled_at": row_str(row, "SCHEDULED_AT"), "published_post_id": published,
        "last_error": row_str(row, "LAST_ERROR"), "updated_at": row_str(row, "UPDATED_AT").ok_or(DbError::SchemaNotReady)?,
    }))
}

fn receipt(tx: &impl Transaction, owner: u64, id: u64) -> Result<Value, DbError> {
    let rows = tx.query(&contract().sql.read, draft_key(owner, id))?;
    dto(rows.first().ok_or(DbError::SchemaNotReady)?)
}

fn write_payload(
    tx: &impl Transaction,
    owner: u64,
    id: u64,
    payload: DraftPayload,
    sql: &str,
) -> Result<(), DbError> {
    let group_id = payload.group_id();
    let serialized = serde_json::to_string(&payload).map_err(|_| DbError::SchemaNotReady)?;
    if serialized.len() > contract().max_payload_bytes {
        return Err(DbError::SchemaNotReady);
    }
    let mut binds = draft_key(owner, id);
    binds.insert("group_id".into(), nullable_id(group_id));
    if tx.execute_clob(sql, binds, "payload_json", &serialized)? != 1 {
        return Err(DbError::SchemaNotReady);
    }
    Ok(())
}

fn list(tx: &impl Transaction, owner: u64, query: ListQuery) -> Result<Outcome, DbError> {
    let rows = tx.query(
        &contract().sql.list,
        BindMap::from([
            number("owner_id", owner),
            number("fetch_limit", query.limit as u64 + 1),
            ("before_id".into(), nullable_id(query.before_id)),
            ("group_scope".into(), nullable_id(query.group_scope)),
        ]),
    )?;
    let items = rows
        .iter()
        .take(query.limit)
        .map(dto)
        .collect::<Result<Vec<_>, _>>()?;
    let next = if rows.len() > query.limit {
        items.last().and_then(|item| item["draft_id"].as_u64())
    } else {
        None
    };
    Ok(Outcome::Saved(
        json!({ "items": items, "next_before_id": next }),
        None,
    ))
}

pub(crate) fn execute(
    connection: &oracle::Connection,
    owner: u64,
    operation: Operation,
    storage: &StorageUrlPolicy,
) -> Result<Outcome, DbError> {
    let tx = OracleTx::new(connection);
    if require_schema(&tx).is_err() {
        return Ok(Outcome::Rejected(unavailable()));
    }
    if let Operation::List(query) = operation {
        return list(&tx, owner, query);
    }
    let outcome = mutate(&tx, owner, operation, storage, |sql, id, payload| {
        write_payload(&tx, owner, id, payload, sql)
    });
    complete(&tx, outcome)
}

fn complete(tx: &impl Transaction, outcome: Result<Outcome, DbError>) -> Result<Outcome, DbError> {
    match outcome {
        Ok(saved @ Outcome::Saved(..)) => {
            if let Err(error) = tx.commit() {
                let _ = tx.rollback();
                return Err(error);
            }
            Ok(saved)
        }
        result => {
            tx.rollback()?;
            result
        }
    }
}

fn mutate(
    tx: &impl Transaction,
    owner: u64,
    operation: Operation,
    storage: &StorageUrlPolicy,
    persist: impl FnOnce(&str, u64, DraftPayload) -> Result<(), DbError>,
) -> Result<Outcome, DbError> {
    let sql = &contract().sql;
    let id = match operation {
        Operation::Create(payload) => {
            let rows = tx.query(NEXT_ID, BindMap::new())?;
            let id = row_id(rows.first().ok_or(DbError::SchemaNotReady)?, "ID")?;
            persist(&sql.insert, id, payload)?;
            return Ok(Outcome::Saved(receipt(tx, owner, id)?, None));
        }
        Operation::Remove(id) => {
            return match tx.execute(&sql.remove, draft_key(owner, id))? {
                0 => Ok(Outcome::Rejected(missing())),
                1 => Ok(Outcome::Saved(Value::Null, None)),
                _ => Err(DbError::SchemaNotReady),
            };
        }
        Operation::Edit(id, _)
        | Operation::Schedule(id, _)
        | Operation::Unschedule(id)
        | Operation::Publish(id) => id,
        Operation::List(_) => return Err(DbError::SchemaNotReady),
    };
    let rows = tx.query(&sql.lock_owner, draft_key(owner, id))?;
    let Some(row) = rows.first() else {
        return Ok(Outcome::Rejected(missing()));
    };
    if row_str(row, "STATUS") == Some("published") {
        return if matches!(operation, Operation::Publish(_)) {
            Ok(Outcome::Saved(dto(row)?, None))
        } else {
            Ok(Outcome::Rejected(immutable()))
        };
    }
    match operation {
        Operation::Edit(_, payload) => persist(&sql.edit, id, payload)?,
        Operation::Unschedule(_) => write_one(tx, &sql.unschedule, draft_key(owner, id))?,
        Operation::Schedule(_, scheduled_at) => {
            let post = match stored_payload(row)?.post() {
                Ok(post) => post,
                Err(error) => return Ok(Outcome::Rejected(error)),
            };
            if post
                .poll()
                .is_some_and(|poll| poll.cutoff() <= scheduled_at.as_str())
            {
                return Ok(Outcome::Rejected(ApiError::bad_request(
                    "投票截止时间必须晚于定时发布时间",
                )));
            }
            if let Some(error) = check_permission(tx, owner, &post)? {
                return Ok(Outcome::Rejected(error));
            }
            if post.poll().is_some() && super::polls::require_schema(tx).is_err() {
                return Ok(Outcome::Rejected(unavailable()));
            }
            if post.has_markdown() && markdown::require_schema(tx).is_err() {
                return Ok(Outcome::Rejected(markdown::unavailable()));
            }
            let mut binds = draft_key(owner, id);
            binds.extend([text("scheduled_at", scheduled_at)]);
            match tx.execute(&sql.schedule, binds)? {
                0 => {
                    return Ok(Outcome::Rejected(ApiError::bad_request(
                        "定时发布时间必须晚于当前时间",
                    )))
                }
                1 => {}
                _ => return Err(DbError::SchemaNotReady),
            }
        }
        Operation::Publish(_) => {
            return publish_locked(tx, owner, id, row, false, |post| {
                publish_post(tx, owner, post, storage)
            })
        }
        _ => return Err(DbError::SchemaNotReady),
    }
    Ok(Outcome::Saved(receipt(tx, owner, id)?, None))
}

fn account_forbidden() -> ApiError {
    ApiError::forbidden(publish_policy::message())
}

fn group_error(outcome: GroupOutcome) -> Result<ApiError, DbError> {
    match outcome {
        GroupOutcome::MissingGroup => Ok(ApiError::not_found("群组不存在")),
        GroupOutcome::Forbidden(message) => Ok(ApiError::unprocessable(message)),
        GroupOutcome::PublishForbidden => Ok(account_forbidden()),
        GroupOutcome::MissingMedia => Ok(ApiError::bad_request("群组附件不存在或已删除")),
        GroupOutcome::InvalidMedia => Ok(ApiError::bad_request("media_urls 参数错误")),
        GroupOutcome::PollUnavailable => Ok(unavailable()),
        GroupOutcome::PollCutoff => Ok(ApiError::bad_request("投票截止时间必须晚于当前时间")),
        GroupOutcome::MarkdownUnavailable => Ok(markdown::unavailable()),
        _ => Err(DbError::SchemaNotReady),
    }
}

fn check_permission(
    tx: &impl Transaction,
    owner: u64,
    post: &Post,
) -> Result<Option<ApiError>, DbError> {
    match post {
        Post::Regular(_) => {
            Ok(
                (!publish_policy::allowed(owner as i64, |sql, binds| tx.query(sql, binds))?)
                    .then(account_forbidden),
            )
        }
        Post::Group { group, input } => group_post_write::check_create_permissions(
            tx,
            owner as i64,
            *group as i64,
            input.announcement,
        )?
        .map(group_error)
        .transpose(),
    }
}

fn publish_post(
    tx: &impl Transaction,
    owner: u64,
    post: &Post,
    storage: &StorageUrlPolicy,
) -> Result<Result<u64, ApiError>, DbError> {
    let outcome = match post {
        Post::Regular(input) => {
            match create_transaction::create_in_transaction(tx, owner, input)? {
                PostCreation::Created(post) => Ok(post),
                PostCreation::ContentEmpty => Err(ApiError::bad_request("content 不能为空")),
                PostCreation::MediaUnavailable => Err(ApiError::bad_request("媒体不存在或不可用")),
                PostCreation::ReferenceUnavailable => Err(ApiError::not_found("帖子不存在")),
                PostCreation::Invalid => Err(ApiError::bad_request("草稿内容参数错误")),
                PostCreation::PublishForbidden => Err(account_forbidden()),
                PostCreation::PollUnavailable => Err(unavailable()),
                PostCreation::MarkdownUnavailable => Err(markdown::unavailable()),
                PostCreation::PollCutoff => {
                    Err(ApiError::bad_request("投票截止时间必须晚于当前时间"))
                }
            }
        }
        Post::Group { group, input } => match group_post_write::create_in_transaction(
            tx,
            owner as i64,
            *group as i64,
            input.clone(),
            storage,
        )? {
            Creation::Created(post) => Ok(post as u64),
            Creation::Rejected(reason) => Err(group_error(reason)?),
        },
    };
    Ok(outcome)
}

fn publish_locked(
    tx: &impl Transaction,
    owner: u64,
    id: u64,
    row: &DbRow,
    due: bool,
    publish: impl FnOnce(&Post) -> Result<Result<u64, ApiError>, DbError>,
) -> Result<Outcome, DbError> {
    if due {
        tx.execute(SAVEPOINT, BindMap::new())?;
    }
    let publication = match stored_payload(row)?.post() {
        Ok(post) => publish(&post)?.map(|post_id| Notice {
            owner,
            post_id,
            post,
        }),
        Err(error) => Err(error),
    };
    match publication {
        Ok(notice) => {
            let mut binds = draft_key(owner, id);
            binds.extend([number("post_id", notice.post_id)]);
            write_one(tx, &contract().sql.published, binds)?;
            Ok(Outcome::Saved(receipt(tx, owner, id)?, Some(notice)))
        }
        Err(error) => {
            let reason = match error.status() {
                StatusCode::BAD_REQUEST => "content_unavailable",
                StatusCode::FORBIDDEN
                | StatusCode::NOT_FOUND
                | StatusCode::UNPROCESSABLE_ENTITY => "permission_denied",
                _ => return Ok(Outcome::Rejected(error)),
            };
            if !due {
                return Ok(Outcome::Rejected(error));
            }
            tx.execute(ROLLBACK_PUBLICATION, BindMap::new())?;
            let mut binds = draft_key(owner, id);
            binds.extend([text("reason", reason)]);
            write_one(tx, &contract().sql.failed, binds)?;
            Ok(Outcome::Saved(Value::Null, None))
        }
    }
}

pub(super) fn candidates(connection: &oracle::Connection) -> Result<Vec<u64>, DbError> {
    let tx = OracleTx::new(connection);
    if require_schema(&tx).is_err() {
        return Ok(Vec::new());
    }
    tx.query(&contract().sql.candidates, BindMap::new())?
        .iter()
        .take(contract().sweep_batch_size)
        .map(|row| row_id(row, "DRAFT_ID"))
        .collect()
}

pub(super) fn publish_due(
    connection: &oracle::Connection,
    id: u64,
    storage: &StorageUrlPolicy,
) -> Result<Option<Notice>, DbError> {
    let tx = OracleTx::new(connection);
    claim_due(&tx, id, |owner, post| {
        publish_post(&tx, owner, post, storage)
    })
}

fn claim_due(
    tx: &impl Transaction,
    id: u64,
    publish: impl FnOnce(u64, &Post) -> Result<Result<u64, ApiError>, DbError>,
) -> Result<Option<Notice>, DbError> {
    let outcome = (|| {
        let rows = tx.query(
            &contract().sql.lock_due,
            BindMap::from([number("draft_id", id)]),
        )?;
        let Some(row) = rows.first() else {
            return Ok(Outcome::Saved(Value::Null, None));
        };
        let owner = row_id(row, "OWNER_ID")?;
        publish_locked(tx, owner, id, row, true, |post| publish(owner, post))
    })();
    match complete(tx, outcome)? {
        Outcome::Saved(_, notice) => Ok(notice),
        Outcome::Rejected(_) => Ok(None),
    }
}

#[cfg(test)]
mod tests;
