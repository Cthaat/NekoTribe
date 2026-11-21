use crate::{
    auth::{
        session_repository::{row_number, row_text},
        sessions::NativeState,
        storage_urls::StorageUrlPolicy,
    },
    chat_channel_status::lock_channel_access,
    chat_message_send::{read_message, write_one, ACCESS},
    db::{
        oracle::{BindMap, DbError},
        tx::OracleTx,
        value::DbValue,
    },
    direct_history::query,
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    body::{to_bytes, Body},
    extract::{Path, State},
    http::{header::CACHE_CONTROL, HeaderMap, HeaderValue},
    response::{IntoResponse, Response},
    Json,
};
use serde_json::Value;

pub enum Change {
    Edit(String),
    Delete,
    Pin(bool),
    Reaction { emoji: String, add: bool },
}

pub enum Outcome {
    Changed { channel: u64, message: Value },
    Missing,
    Forbidden,
    PublishForbidden,
}

const CHANNEL: &str =
    "SELECT channel_id FROM n_chat_messages WHERE message_id=:message_id AND is_deleted=0";
const REACT: &str = "MERGE INTO n_chat_message_reactions r
USING (SELECT :message_id AS message_id,:user_id AS user_id,:emoji AS emoji FROM dual) src
ON (r.message_id=src.message_id AND r.user_id=src.user_id AND r.emoji=src.emoji)
WHEN NOT MATCHED THEN INSERT (message_id,user_id,emoji) VALUES (src.message_id,src.user_id,src.emoji)";
const UNREACT: &str = "DELETE FROM n_chat_message_reactions WHERE message_id=:message_id AND user_id=:user_id AND emoji=:emoji";
const TARGET: &str = "SELECT author_id,message_type FROM n_chat_messages
WHERE message_id=:message_id AND channel_id=:channel_id AND is_deleted=0 FOR UPDATE";
const EDIT: &str = "UPDATE n_chat_messages SET content=:content,edited_at=CURRENT_TIMESTAMP,updated_at=CURRENT_TIMESTAMP
WHERE message_id=:message_id AND is_deleted=0";
const PIN: &str = "UPDATE n_chat_messages SET is_pinned=:is_pinned,updated_at=CURRENT_TIMESTAMP
WHERE message_id=:message_id AND is_deleted=0";
const DELETE: &str = "UPDATE n_chat_messages SET is_deleted=1,deleted_by=:user_id,deleted_at=CURRENT_TIMESTAMP,updated_at=CURRENT_TIMESTAMP
WHERE message_id=:message_id AND is_deleted=0";
const SUMMARY: &str = "UPDATE n_chat_channels c
SET message_count=GREATEST(c.message_count-1,0),
last_message_id=CASE WHEN c.last_message_id=:message_id THEN
 (SELECT MAX(m.message_id) FROM n_chat_messages m WHERE m.channel_id=c.channel_id AND m.is_deleted=0)
 ELSE c.last_message_id END,
last_message_at=CASE WHEN c.last_message_id=:message_id THEN
 (SELECT MAX(m.created_at) KEEP (DENSE_RANK LAST ORDER BY m.message_id) FROM n_chat_messages m
  WHERE m.channel_id=c.channel_id AND m.is_deleted=0)
 ELSE c.last_message_at END,
updated_at=CURRENT_TIMESTAMP WHERE c.channel_id=:channel_id AND c.is_deleted=0";

pub(crate) fn execute(
    conn: &oracle::Connection,
    user: u64,
    id: u64,
    change: Change,
    storage: &StorageUrlPolicy,
) -> Result<Outcome, DbError> {
    let user = i64::try_from(user).map_err(|_| DbError::SchemaNotReady)?;
    let id = i64::try_from(id).map_err(|_| DbError::SchemaNotReady)?;
    let tx = OracleTx::new(conn);
    let result = (|| {
        let message = || BindMap::from([("message_id".into(), DbValue::I64(id))]);
        let rows = query(conn, CHANNEL, message())?;
        let Some(row) = rows.first() else {
            return Ok(Outcome::Missing);
        };
        let channel = row_number(row, "CHANNEL_ID");
        if !lock_channel_access(conn, user, channel)? {
            return Ok(Outcome::Forbidden);
        }
        let rows = query(
            conn,
            ACCESS,
            BindMap::from([
                ("channel_id".into(), DbValue::I64(channel)),
                ("user_id".into(), DbValue::I64(user)),
            ]),
        )?;
        let access = rows.first().ok_or(DbError::SchemaNotReady)?;
        let manage = row_number(access, "CAN_MANAGE") == 1;
        let status = row_text(access, "STATUS");
        let mut channel_message = message();
        channel_message.insert("channel_id".into(), DbValue::I64(channel));
        let rows = query(conn, TARGET, channel_message.clone())?;
        let Some(target) = rows.first() else {
            return Ok(Outcome::Missing);
        };
        let author = row_number(target, "AUTHOR_ID");
        let deleted = matches!(change, Change::Delete);
        let reaction = matches!(change, Change::Reaction { .. });
        let mut binds = message();
        let sql = match change {
            Change::Edit(content) => {
                if row_text(target, "MESSAGE_TYPE") != "text" {
                    return Ok(Outcome::Missing);
                }
                if author != user || status != "active" {
                    return Ok(Outcome::Forbidden);
                }
                if !crate::moderation::publish_policy::allowed(user, |sql, binds| {
                    query(conn, sql, binds)
                })? {
                    return Ok(Outcome::PublishForbidden);
                }
                binds.insert("content".into(), DbValue::String(content));
                EDIT
            }
            Change::Delete => {
                if author != user && !manage {
                    return Ok(Outcome::Forbidden);
                }
                binds.insert("user_id".into(), DbValue::I64(user));
                DELETE
            }
            Change::Pin(pinned) => {
                if !manage {
                    return Ok(Outcome::Forbidden);
                }
                binds.insert("is_pinned".into(), DbValue::I64(i64::from(pinned)));
                PIN
            }
            Change::Reaction { emoji, add } => {
                binds.insert("user_id".into(), DbValue::I64(user));
                binds.insert("emoji".into(), DbValue::String(emoji));
                if add {
                    REACT
                } else {
                    UNREACT
                }
            }
        };
        if reaction {
            tx.execute(sql, binds)?;
        } else {
            write_one(&tx, sql, binds)?;
        }
        let message = if deleted {
            write_one(&tx, SUMMARY, channel_message)?;
            Value::Null
        } else {
            read_message(conn, user, channel, id, manage, storage)?
        };
        Ok(Outcome::Changed {
            channel: u64::try_from(channel).map_err(|_| DbError::SchemaNotReady)?,
            message,
        })
    })();
    match result {
        Ok(outcome @ Outcome::Changed { .. }) => match tx.commit() {
            Ok(()) => Ok(outcome),
            Err(err) => {
                let _ = tx.rollback();
                Err(err)
            }
        },
        other => {
            tx.rollback()?;
            other
        }
    }
}

#[derive(Clone, Copy)]
enum Kind {
    Edit,
    Delete,
    Pin,
    Reaction(bool),
}

fn parse(kind: Kind, bytes: &[u8]) -> Result<Change, ApiError> {
    if matches!(kind, Kind::Delete) {
        return Ok(Change::Delete);
    }
    let invalid = || ApiError::bad_request("请求体格式错误");
    let body: Value = serde_json::from_slice(bytes).map_err(|_| invalid())?;
    let body = body.as_object().ok_or_else(invalid)?;
    if let Kind::Reaction(add) = kind {
        let emoji = body
            .get("emoji")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim_matches(|c: char| (c.is_whitespace() && c != '\u{0085}') || c == '\u{feff}');
        if emoji.is_empty() || emoji.len() > 32 || emoji.encode_utf16().count() > 16 {
            return Err(ApiError::bad_request("emoji 参数错误"));
        }
        return Ok(Change::Reaction {
            emoji: emoji.to_owned(),
            add,
        });
    }
    if matches!(kind, Kind::Pin) {
        return Ok(Change::Pin(
            body.get("is_pinned")
                .is_some_and(crate::chat_channel_write::channel_boolean),
        ));
    }
    let content = body
        .get("content")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim_matches(|c: char| (c.is_whitespace() && c != '\u{0085}') || c == '\u{feff}');
    if content.is_empty() || content.len() > 4000 {
        return Err(ApiError::bad_request("content 参数错误"));
    }
    Ok(Change::Edit(content.to_owned()))
}

async fn route(
    state: NativeState,
    raw: String,
    headers: HeaderMap,
    kind: Kind,
    body: Body,
) -> Response {
    let result = async {
        let (user, id) =
            crate::posts::bookmark::interaction_identity(&state, &raw, &headers).await?;
        let bytes = if matches!(kind, Kind::Delete) {
            axum::body::Bytes::new()
        } else {
            to_bytes(body, 1 << 20)
                .await
                .map_err(|_| ApiError::bad_request("请求体格式错误"))?
        };
        let change = parse(kind, &bytes)?;
        let outcome = state
            .repository
            .mutate_chat_message(user, id, change, &state.storage_urls)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?;
        let (channel, message) = match outcome {
            Outcome::Changed { channel, message } => (channel, message),
            Outcome::Missing => return Err(ApiError::not_found("聊天消息不存在")),
            Outcome::PublishForbidden => {
                return Err(ApiError::forbidden(
                    crate::moderation::publish_policy::message(),
                ))
            }
            Outcome::Forbidden => return Err(ApiError::forbidden("无权操作该聊天消息")),
        };
        let (event, label) = match kind {
            Kind::Delete => ("chat_message_deleted", "chat message deleted"),
            Kind::Edit => ("chat_message_updated", "chat message updated"),
            Kind::Pin => ("chat_message_updated", "chat message pin status updated"),
            Kind::Reaction(true) => ("chat_reaction_updated", "chat reaction created"),
            Kind::Reaction(false) => ("chat_reaction_updated", "chat reaction deleted"),
        };
        if let Some(publisher) = &state.notification_publisher {
            if publisher
                .publish_chat_room_event(channel, event, id, &message)
                .await
                .is_err()
            {
                tracing::warn!("chat message delivery unavailable");
            }
        }
        Ok(Json(V2Response::ok_with_message(message, label)))
    }
    .await;
    let mut response = result.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}

pub(crate) async fn edit(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    route(state, raw, headers, Kind::Edit, body).await
}
pub(crate) async fn remove(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
) -> Response {
    route(state, raw, headers, Kind::Delete, Body::empty()).await
}
pub(crate) async fn pin(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    route(state, raw, headers, Kind::Pin, body).await
}

pub(crate) async fn react(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    route(state, raw, headers, Kind::Reaction(true), body).await
}

pub(crate) async fn unreact(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    route(state, raw, headers, Kind::Reaction(false), body).await
}
