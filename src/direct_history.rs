use crate::{
    auth::{
        session_list::{session_pagination, SessionPage},
        session_repository::{
            nullable_text, profile_date, public_profile_json, row_number, row_text,
        },
        sessions::NativeState,
    },
    db::{
        oracle::{bind_refs, bind_values, BindMap, DbError},
        row::{oracle_row_to_db_row, DbRow},
        tx::OracleTx,
        value::DbValue,
    },
    httpx::errors::ApiError,
};
use axum::{
    extract::{OriginalUri, Path, State},
    http::{header::CACHE_CONTROL, HeaderMap, HeaderValue},
    response::{IntoResponse, Response},
    Json,
};
use serde_json::{json, Value};

pub type DirectHistory = Option<(Vec<Value>, u64)>;

const ACCESS: &str = "SELECT conversation_id FROM n_direct_conversations
WHERE conversation_id=:conversation_id AND is_deleted=0
AND (user_low_id=:user_id OR user_high_id=:user_id) FOR UPDATE";
const COUNT: &str = "SELECT COUNT(*) AS total FROM n_direct_messages
WHERE conversation_id=:conversation_id AND is_deleted=0";
const PAGE: &str = "SELECT * FROM (
    SELECT dm.message_id,dm.conversation_id,dm.sender_id AS user_id,dm.content,dm.is_deleted,
        dm.created_at,dm.updated_at,dm.edited_at,dm.deleted_at,
        u.username,u.avatar_url,u.display_name,u.bio,u.location,u.website,u.is_verified,
        u.followers_count,u.following_count,u.posts_count,u.likes_count,
        fn_get_user_relationship(:viewer_id,u.user_id) AS relation,
        ROW_NUMBER() OVER (ORDER BY dm.created_at DESC,dm.message_id DESC) AS rn
    FROM n_direct_messages dm JOIN v_user_profile_public u ON u.user_id=dm.sender_id
    WHERE dm.conversation_id=:conversation_id AND dm.is_deleted=0
) WHERE rn BETWEEN :start_row AND :end_row ORDER BY created_at ASC,message_id ASC";
pub(crate) const MARK: &str = "MERGE INTO n_direct_conversation_reads r
USING (SELECT :conversation_id AS conversation_id,:user_id AS user_id,
       :message_id AS message_id FROM dual) src
ON (r.conversation_id=src.conversation_id AND r.user_id=src.user_id)
WHEN MATCHED THEN UPDATE SET
  r.last_read_message_id=GREATEST(NVL(r.last_read_message_id,0),src.message_id),
  r.last_read_at=CURRENT_TIMESTAMP
WHEN NOT MATCHED THEN INSERT (conversation_id,user_id,last_read_message_id,last_read_at)
VALUES (src.conversation_id,src.user_id,src.message_id,CURRENT_TIMESTAMP)";

pub(crate) fn query(
    connection: &oracle::Connection,
    sql: &str,
    binds: BindMap,
) -> Result<Vec<DbRow>, DbError> {
    let values = bind_values(binds);
    let refs = bind_refs(&values);
    connection
        .query_named(sql, &refs)?
        .map(|row| oracle_row_to_db_row(&row?))
        .collect()
}

pub(crate) fn map_message(row: &DbRow, viewer: i64) -> Value {
    let date = |column| nullable_text(row, column).map(|value| profile_date(&value));
    json!({
        "message_id": row_number(row, "MESSAGE_ID"),
        "conversation_id": row_number(row, "CONVERSATION_ID"),
        "content": row_text(row, "CONTENT"),
        "author": public_profile_json(row),
        "is_deleted": row_number(row, "IS_DELETED") == 1,
        "can_delete": row_number(row, "USER_ID") == viewer,
        "created_at": date("CREATED_AT").unwrap_or_default(),
        "updated_at": date("UPDATED_AT").unwrap_or_default(),
        "edited_at": date("EDITED_AT"),
        "deleted_at": date("DELETED_AT"),
    })
}

pub(crate) fn execute(
    connection: &oracle::Connection,
    viewer: u64,
    conversation: u64,
    page: SessionPage,
) -> Result<DirectHistory, DbError> {
    let viewer = i64::try_from(viewer).map_err(|_| DbError::SchemaNotReady)?;
    let conversation = i64::try_from(conversation).map_err(|_| DbError::SchemaNotReady)?;
    let conversation_bind =
        || BindMap::from([("conversation_id".into(), DbValue::I64(conversation))]);
    let actor_binds = || {
        let mut binds = conversation_bind();
        binds.insert("user_id".into(), DbValue::I64(viewer));
        binds
    };
    let tx = OracleTx::new(connection);
    let result = (|| {
        if query(connection, ACCESS, actor_binds())?.is_empty() {
            return Ok(None);
        }
        let count = query(connection, COUNT, conversation_bind())?;
        let total = count
            .first()
            .map(|row| row_number(row, "TOTAL"))
            .and_then(|n| u64::try_from(n).ok())
            .ok_or(DbError::SchemaNotReady)?;
        let mut binds = conversation_bind();
        binds.extend([
            ("viewer_id".into(), DbValue::I64(viewer)),
            ("start_row".into(), DbValue::F64(page.start)),
            ("end_row".into(), DbValue::F64(page.end)),
        ]);
        let rows = query(connection, PAGE, binds)?;
        if page.page == 1.0 {
            if let Some(last) = rows.last() {
                let id = row_number(last, "MESSAGE_ID");
                if id <= 0 {
                    return Err(DbError::SchemaNotReady);
                }
                let mut binds = actor_binds();
                binds.insert("message_id".into(), DbValue::I64(id));
                tx.execute(MARK, binds)?;
            }
        }
        Ok(Some((
            rows.iter().map(|row| map_message(row, viewer)).collect(),
            total,
        )))
    })();
    match result {
        Ok(Some(history)) => match tx.commit() {
            Ok(()) => Ok(Some(history)),
            Err(error) => {
                let _ = tx.rollback();
                Err(error)
            }
        },
        other => {
            tx.rollback()?;
            other
        }
    }
}

pub(crate) async fn list(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
) -> Response {
    let mut response = list_inner(&state, &raw, uri.query().unwrap_or_default(), &headers)
        .await
        .into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}

async fn list_inner(
    state: &NativeState,
    raw: &str,
    query: &str,
    headers: &HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let user = crate::posts::bookmark::interaction_actor(state, headers).await?;
    let conversation = conversation_id(raw)?;
    let page = session_pagination(query);
    let internal_error = || ApiError::server_error("服务器内部错误");
    let (mut messages, total) = state
        .repository
        .list_direct_history(user, conversation, page)
        .await
        .map_err(|_| internal_error())?
        .ok_or_else(|| ApiError::forbidden("无权访问该私聊会话"))?;
    for message in &mut messages {
        normalize_author(message, &state.storage_urls).map_err(|_| internal_error())?;
    }
    Ok(Json(json!({
        "code": 200, "message": "success", "data": messages,
        "meta": {"page": page.page, "page_size": page.page_size, "total": total, "has_next": page.end < total as f64}
    })))
}

pub(crate) fn conversation_id(raw: &str) -> Result<u64, ApiError> {
    raw.parse::<u64>()
        .ok()
        .filter(|id| {
            *id > 0
                && *id <= crate::notification_websocket::MAX_SOCKET_ID
                && !raw.starts_with('0')
                && raw.bytes().all(|b| b.is_ascii_digit())
        })
        .ok_or_else(|| ApiError::bad_request("conversation_id 参数错误"))
}

pub(crate) fn normalize_author(
    message: &mut Value,
    storage: &crate::auth::storage_urls::StorageUrlPolicy,
) -> Result<(), DbError> {
    let author = message["author"]
        .as_object_mut()
        .ok_or(DbError::SchemaNotReady)?;
    let avatar = author
        .get("avatar_url")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let normalized = storage
        .normalize_avatar(avatar)
        .map_err(|_| DbError::SchemaNotReady)?;
    author.insert("avatar_url".into(), normalized.into());
    Ok(())
}
