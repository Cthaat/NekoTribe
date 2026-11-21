use crate::{
    auth::{
        session_list::{session_pagination, SessionPage},
        session_repository::{nullable_text, profile_date, row_number, row_text},
        sessions::NativeState,
        storage_urls::StorageUrlPolicy,
    },
    chat_message_send::write_one,
    db::{
        oracle::{BindMap, DbError},
        tx::OracleTx,
        value::DbValue,
    },
    direct_history::query,
    group_content::user,
    group_post_write::{number, LOCK},
    httpx::errors::ApiError,
};
use axum::{
    body::{to_bytes, Body},
    extract::{OriginalUri, Path, State},
    http::{header::CACHE_CONTROL, HeaderMap, HeaderValue},
    response::{IntoResponse, Response},
    Json,
};
use serde_json::{json, Value};
use std::collections::{hash_map::Entry, HashMap};

#[derive(Clone, Copy)]
pub enum Operation {
    ReadPreference,
    WritePreference(bool),
    Audit(SessionPage),
}

pub enum Outcome {
    Preference(Value),
    Audit(Vec<Value>, i64),
    MissingGroup,
    Forbidden(&'static str),
}

const PREFERENCE: &str =
    "SELECT g.group_id, m.user_id AS member_id, COALESCE(p.is_enabled,1) AS is_enabled,
  p.updated_at
FROM n_groups g
LEFT JOIN n_group_members m ON m.group_id=g.group_id AND m.user_id=:user_id AND m.status='active'
LEFT JOIN n_group_notification_preferences p ON p.group_id=g.group_id AND p.user_id=m.user_id
WHERE g.group_id=:group_id AND g.is_active=1 AND g.is_deleted=0";
const MERGE: &str = "MERGE INTO n_group_notification_preferences p
USING (SELECT :user_id AS user_id,:group_id AS group_id,:is_enabled AS is_enabled FROM dual) src
ON (p.user_id=src.user_id AND p.group_id=src.group_id)
WHEN MATCHED THEN UPDATE SET p.is_enabled=src.is_enabled,p.updated_at=SYSTIMESTAMP
WHEN NOT MATCHED THEN INSERT (user_id,group_id,is_enabled) VALUES (src.user_id,src.group_id,src.is_enabled)";
const AUDIT: &str = "WITH active_group AS (
  SELECT group_id FROM n_groups WHERE group_id=:group_id AND is_active=1 AND is_deleted=0
), allowed_group AS (
  SELECT g.group_id FROM active_group g
  JOIN n_group_members m ON m.group_id=g.group_id AND m.user_id=:user_id
  WHERE m.status='active' AND m.role IN ('owner','admin','moderator')
), ranked AS (
  SELECT l.log_id,l.group_id,l.actor_id,l.target_user_id,l.target_post_id,l.target_comment_id,l.action,l.details,l.ip_address,l.created_at,
    ROW_NUMBER() OVER (ORDER BY l.created_at DESC,l.log_id DESC) AS rn
  FROM allowed_group g JOIN n_group_audit_logs l ON l.group_id=g.group_id
)
SELECT (SELECT COUNT(*) FROM active_group) AS group_exists,
  (SELECT COUNT(*) FROM allowed_group) AS scope_allowed,t.total,
  r.log_id,r.group_id,r.actor_id,r.target_user_id,r.target_post_id,r.target_comment_id,r.action,r.details,r.ip_address,r.created_at
FROM (SELECT COUNT(*) AS total FROM ranked) t
LEFT JOIN ranked r ON r.rn BETWEEN :start_row AND :end_row
ORDER BY r.rn";

fn preference(
    conn: &oracle::Connection,
    viewer: i64,
    group: i64,
    denied: &'static str,
) -> Result<Outcome, DbError> {
    let rows = query(
        conn,
        PREFERENCE,
        BindMap::from([number("user_id", viewer), number("group_id", group)]),
    )?;
    let Some(row) = rows.first() else {
        return Ok(Outcome::MissingGroup);
    };
    if row.get("MEMBER_ID").and_then(DbValue::as_i64).is_none() {
        return Ok(Outcome::Forbidden(denied));
    }
    let updated = nullable_text(row, "UPDATED_AT")
        .map(|s| profile_date(&s))
        .unwrap_or_default();
    Ok(Outcome::Preference(
        json!({"user_id":viewer,"group_id":group,"is_enabled":row_number(row,"IS_ENABLED")==1,"updated_at":updated}),
    ))
}

fn update(
    conn: &oracle::Connection,
    viewer: i64,
    group: i64,
    enabled: bool,
) -> Result<Outcome, DbError> {
    let tx = OracleTx::new(conn);
    let result = (|| {
        let group_rows = query(conn, LOCK, BindMap::from([number("group_id", group)]))?;
        if group_rows.is_empty() {
            return Ok(Outcome::MissingGroup);
        }
        let denied = "只有群组成员可以修改通知设置";
        let current = preference(conn, viewer, group, denied)?;
        if !matches!(current, Outcome::Preference(_)) {
            return Ok(current);
        }
        write_one(
            &tx,
            MERGE,
            BindMap::from([
                number("user_id", viewer),
                number("group_id", group),
                number("is_enabled", i64::from(enabled)),
            ]),
        )?;
        let Outcome::Preference(saved) = preference(conn, viewer, group, denied)? else {
            return Err(DbError::SchemaNotReady);
        };
        if saved["is_enabled"].as_bool() != Some(enabled) {
            return Err(DbError::SchemaNotReady);
        }
        tx.commit()?;
        Ok(Outcome::Preference(saved))
    })();
    if !matches!(result, Ok(Outcome::Preference(_))) {
        tx.rollback()?;
    }
    result
}

fn audit(
    conn: &oracle::Connection,
    viewer: i64,
    group: i64,
    page: SessionPage,
    storage: &StorageUrlPolicy,
) -> Result<Outcome, DbError> {
    let rows = query(
        conn,
        AUDIT,
        BindMap::from([
            number("user_id", viewer),
            number("group_id", group),
            ("start_row".into(), DbValue::F64(page.start)),
            ("end_row".into(), DbValue::F64(page.end)),
        ]),
    )?;
    let first = rows.first().ok_or(DbError::SchemaNotReady)?;
    if row_number(first, "GROUP_EXISTS") != 1 {
        return Ok(Outcome::MissingGroup);
    }
    if row_number(first, "SCOPE_ALLOWED") != 1 {
        return Ok(Outcome::Forbidden("无权查看审计日志"));
    }
    let total = row_number(first, "TOTAL");
    let mut profiles = HashMap::new();
    let mut profile = |id: Option<i64>| -> Result<Option<Value>, DbError> {
        let Some(id) = id else {
            return Ok(None);
        };
        let value = match profiles.entry(id) {
            Entry::Occupied(entry) => entry.into_mut(),
            Entry::Vacant(entry) => entry.insert(user(conn, viewer, id, storage)?),
        };
        Ok(value.clone())
    };
    let mut logs = Vec::new();
    for row in &rows {
        let id = |key| row.get(key).and_then(DbValue::as_i64);
        let Some(log) = id("LOG_ID") else {
            continue;
        };
        let actor = id("ACTOR_ID");
        let target = id("TARGET_USER_ID");
        let details = nullable_text(row, "DETAILS")
            .filter(|s| !s.is_empty())
            .map(|s| serde_json::from_str(&s).unwrap_or(Value::String(s)));
        logs.push(json!({
            "log_id":log,"group_id":group,"actor_id":actor,"actor":profile(actor)?,
            "target_user_id":target,"target_user":profile(target)?,
            "target_post_id":id("TARGET_POST_ID"),"target_comment_id":id("TARGET_COMMENT_ID"),
            "action":row_text(row,"ACTION"),"details":details,
            "ip_address":nullable_text(row,"IP_ADDRESS").filter(|s|!s.is_empty()),
            "created_at":nullable_text(row,"CREATED_AT").map(|s|profile_date(&s)).unwrap_or_default()
        }));
    }
    Ok(Outcome::Audit(logs, total))
}

pub(crate) fn execute(
    conn: &oracle::Connection,
    viewer: u64,
    group: u64,
    operation: Operation,
    storage: &StorageUrlPolicy,
) -> Result<Outcome, DbError> {
    let id = |value| i64::try_from(value).map_err(|_| DbError::SchemaNotReady);
    let (viewer, group) = (id(viewer)?, id(group)?);
    match operation {
        Operation::ReadPreference => {
            let mut result = preference(conn, viewer, group, "只有群组成员可以查看通知设置")?;
            if let Outcome::Preference(value) = &mut result {
                if value["updated_at"].as_str() == Some("") {
                    value["updated_at"] = chrono::Utc::now()
                        .to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
                        .into();
                }
            }
            Ok(result)
        }
        Operation::WritePreference(enabled) => update(conn, viewer, group, enabled),
        Operation::Audit(page) => audit(conn, viewer, group, page, storage),
    }
}

enum Input {
    ReadPreference,
    WritePreference(Body),
    Audit(SessionPage),
}

async fn route(state: NativeState, headers: HeaderMap, group: String, input: Input) -> Response {
    let result=async{
        let (viewer,group)=crate::posts::bookmark::interaction_identity(&state,&group,&headers).await?;
        let operation=match input {
            Input::ReadPreference=>Operation::ReadPreference,
            Input::Audit(page)=>Operation::Audit(page),
            Input::WritePreference(body)=>{
                let bad=||ApiError::bad_request("请求体必须是 JSON 对象");
                let bytes=to_bytes(body,1<<20).await.map_err(|_|bad())?;
                let value:Value=serde_json::from_slice(&bytes).map_err(|_|bad())?;
                let object=value.as_object().ok_or_else(bad)?;
                let enabled = match object.get("is_enabled") {
                    Some(Value::Bool(value)) => *value,
                    Some(Value::Number(value)) => value.as_f64() == Some(1.0),
                    Some(Value::String(value)) => ["1", "true", "yes"].iter()
                        .any(|option| value.eq_ignore_ascii_case(option)),
                    _ => false,
                };
                Operation::WritePreference(enabled)
            }
        };
        let outcome=state.repository.group_administration(viewer,group,operation,&state.storage_urls).await
            .map_err(|_|ApiError::server_error("服务器内部错误"))?;
        let body=match outcome{
            Outcome::Preference(value)=>{
                let message=if matches!(operation,Operation::WritePreference(_)){"group notification preference updated"}else{"success"};
                json!({"code":200,"message":message,"data":value,"meta":null})
            }
            Outcome::Audit(logs,total)=>{
                let Operation::Audit(page)=operation else{return Err(ApiError::server_error("服务器内部错误"));};
                json!({"code":200,"message":"success","data":logs,"meta":{
                    "page":page.page,"page_size":page.page_size,"total":total,"has_next":page.end<total as f64
                }})
            }
            Outcome::MissingGroup=>return Err(ApiError::not_found("群组不存在")),
            Outcome::Forbidden(message)=>return Err(ApiError::unprocessable(message)),
        };
        Ok::<_,ApiError>(Json(body))
    }.await;
    let mut response = result.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}

pub(crate) async fn get_preference(
    State(state): State<NativeState>,
    Path(group): Path<String>,
    headers: HeaderMap,
) -> Response {
    route(state, headers, group, Input::ReadPreference).await
}
pub(crate) async fn put_preference(
    State(state): State<NativeState>,
    Path(group): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    route(state, headers, group, Input::WritePreference(body)).await
}
pub(crate) async fn audit_logs(
    State(state): State<NativeState>,
    Path(group): Path<String>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
) -> Response {
    route(
        state,
        headers,
        group,
        Input::Audit(session_pagination(uri.query().unwrap_or_default())),
    )
    .await
}
