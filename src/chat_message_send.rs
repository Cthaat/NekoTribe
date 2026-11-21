use crate::{
    auth::{
        session_repository::{row_number, row_text},
        sessions::NativeState,
        storage_urls::StorageUrlPolicy,
    },
    chat_channel_status::lock_channel_access,
    chat_message_history::{append_details, message_json, BY_ID},
    db::{
        oracle::{BindMap, DbError},
        tx::OracleTx,
        value::DbValue,
    },
    direct_history::{normalize_author, query},
    httpx::{errors::ApiError, response::V2Response},
    media::private_bind::{self, Target},
};
use axum::{
    body::{to_bytes, Body},
    extract::{Path, State},
    http::{header::CACHE_CONTROL, HeaderMap, HeaderValue},
    response::{IntoResponse, Response},
    Json,
};
use serde_json::Value;
use std::collections::HashSet;

pub struct Input {
    pub content: String,
    pub reply: Option<i64>,
    pub media: Vec<i64>,
}

pub enum Outcome {
    Created(Value),
    Forbidden,
    PublishForbidden,
    CannotSpeak,
    Unsupported,
    InvalidReply,
    InvalidMedia,
}

pub(crate) const ACCESS: &str = "SELECT c.group_id,c.channel_type,gm.status,
CASE WHEN gm.role IN ('owner','admin','moderator') THEN 1 ELSE 0 END AS can_manage
FROM n_chat_channels c JOIN n_group_members gm ON gm.group_id=c.group_id
WHERE c.channel_id=:channel_id AND gm.user_id=:user_id";
const REPLY: &str = "SELECT message_id FROM n_chat_messages
WHERE message_id=:message_id AND channel_id=:channel_id AND is_deleted=0 FOR UPDATE";
const MEDIA: &str = "SELECT media_id,storage_key FROM n_media_assets
WHERE media_id=:media_id AND owner_user_id=:user_id AND status='ready' FOR UPDATE";
const INSERT: &str = "INSERT INTO n_chat_messages
(message_id,channel_id,group_id,author_id,message_type,content,reply_to_message_id)
VALUES (:message_id,:channel_id,:group_id,:user_id,'text',:content,:reply)";
const ATTACH: &str =
    "INSERT INTO n_chat_message_media (chat_message_media_id,message_id,media_id,position)
VALUES (seq_chat_message_media_id.NEXTVAL,:message_id,:media_id,:position)";
const SUMMARY: &str = "UPDATE n_chat_channels SET last_message_id=:message_id,
last_message_at=CURRENT_TIMESTAMP,message_count=message_count+1,updated_at=CURRENT_TIMESTAMP
WHERE channel_id=:channel_id AND is_deleted=0";

pub(crate) fn execute(
    conn: &oracle::Connection,
    user: u64,
    channel: u64,
    input: Input,
    storage: &StorageUrlPolicy,
) -> Result<Outcome, DbError> {
    let user = i64::try_from(user).map_err(|_| DbError::SchemaNotReady)?;
    let channel = i64::try_from(channel).map_err(|_| DbError::SchemaNotReady)?;
    let tx = OracleTx::new(conn);
    let result = (|| {
        if !lock_channel_access(conn, user, channel)? {
            return Ok(Outcome::Forbidden);
        }
        let mut access = query(
            conn,
            ACCESS,
            BindMap::from([
                ("channel_id".into(), DbValue::I64(channel)),
                ("user_id".into(), DbValue::I64(user)),
            ]),
        )?;
        let access = access.pop().ok_or(DbError::SchemaNotReady)?;
        let group = row_number(&access, "GROUP_ID");
        let kind = row_text(&access, "CHANNEL_TYPE");
        let manage = row_number(&access, "CAN_MANAGE") == 1;
        if row_text(&access, "STATUS") != "active" || kind == "announcement" && !manage {
            return Ok(Outcome::CannotSpeak);
        }
        if !matches!(kind.as_str(), "text" | "announcement") {
            return Ok(Outcome::Unsupported);
        }
        if !crate::moderation::publish_policy::allowed(user, |sql, binds| query(conn, sql, binds))?
        {
            return Ok(Outcome::PublishForbidden);
        }
        if let Some(reply) = input.reply {
            if query(
                conn,
                REPLY,
                BindMap::from([
                    ("message_id".into(), DbValue::I64(reply)),
                    ("channel_id".into(), DbValue::I64(channel)),
                ]),
            )?
            .is_empty()
            {
                return Ok(Outcome::InvalidReply);
            }
        }
        let mut media_locks = input.media.clone();
        media_locks.sort_unstable();
        for media in media_locks {
            let rows = query(
                conn,
                MEDIA,
                BindMap::from([
                    ("media_id".into(), DbValue::I64(media)),
                    ("user_id".into(), DbValue::I64(user)),
                ]),
            )?;
            let Some(row) = rows.first() else {
                return Ok(Outcome::InvalidMedia);
            };
            if !private_bind::can_attach(&tx, row, DbValue::I64(media), Target::Chat)? {
                return Ok(Outcome::InvalidMedia);
            }
        }
        let ids = query(
            conn,
            "SELECT seq_chat_message_id.NEXTVAL AS id FROM dual",
            BindMap::new(),
        )?;
        let id = ids
            .first()
            .map(|row| row_number(row, "ID"))
            .filter(|id| (1..=9_007_199_254_740_991).contains(id))
            .ok_or(DbError::SchemaNotReady)?;
        let channel_message = || {
            BindMap::from([
                ("message_id".into(), DbValue::I64(id)),
                ("channel_id".into(), DbValue::I64(channel)),
            ])
        };
        let mut binds = channel_message();
        binds.extend([
            ("group_id".into(), DbValue::I64(group)),
            ("user_id".into(), DbValue::I64(user)),
            ("content".into(), DbValue::String(input.content)),
            (
                "reply".into(),
                input.reply.map_or(DbValue::Null, DbValue::I64),
            ),
        ]);
        write_one(&tx, INSERT, binds)?;
        for (index, media) in input.media.into_iter().enumerate() {
            write_one(
                &tx,
                ATTACH,
                BindMap::from([
                    ("message_id".into(), DbValue::I64(id)),
                    ("media_id".into(), DbValue::I64(media)),
                    ("position".into(), DbValue::I64((index + 1) as i64)),
                ]),
            )?;
        }
        write_one(&tx, SUMMARY, channel_message())?;
        let message = read_message(conn, user, channel, id, manage, storage)?;
        Ok(Outcome::Created(message))
    })();
    match result {
        Ok(outcome @ Outcome::Created(_)) => match tx.commit() {
            Ok(()) => Ok(outcome),
            Err(err) => {
                let _ = tx.rollback();
                Err(err)
            }
        },
        result => {
            tx.rollback()?;
            result
        }
    }
}

pub(crate) fn write_one(tx: &OracleTx<'_>, sql: &str, binds: BindMap) -> Result<(), DbError> {
    if tx.execute(sql, binds)?.rows_affected != 1 {
        return Err(DbError::SchemaNotReady);
    }
    Ok(())
}

pub(crate) fn read_message(
    conn: &oracle::Connection,
    user: i64,
    channel: i64,
    id: i64,
    manage: bool,
    storage: &StorageUrlPolicy,
) -> Result<Value, DbError> {
    let rows = query(
        conn,
        BY_ID,
        BindMap::from([
            ("message_id".into(), DbValue::I64(id)),
            ("channel_id".into(), DbValue::I64(channel)),
            ("viewer_id".into(), DbValue::I64(user)),
        ]),
    )?;
    let row = rows.first().ok_or(DbError::SchemaNotReady)?;
    let mut message = message_json(row, user, manage)?;
    normalize_author(&mut message, storage)?;
    append_details(
        conn,
        user,
        &rows,
        std::slice::from_mut(&mut message),
        storage,
    )?;
    Ok(message)
}

fn parse(raw: &[u8]) -> Result<Input, ApiError> {
    let body: Value =
        serde_json::from_slice(raw).map_err(|_| ApiError::bad_request("请求体格式错误"))?;
    let body = body
        .as_object()
        .ok_or_else(|| ApiError::bad_request("请求体格式错误"))?;
    let content = match body.get("content") {
        None | Some(Value::Null) => "",
        Some(value) => value
            .as_str()
            .ok_or_else(|| ApiError::bad_request("content 参数错误"))?,
    }
    .trim_matches(|c: char| (c.is_whitespace() && c != '\u{0085}') || c == '\u{feff}');
    if content.len() > 4000 {
        return Err(ApiError::bad_request("content 超过最大长度"));
    }
    let id = |value: &Value| {
        value
            .as_f64()
            .filter(|v| (1.0..=9_007_199_254_740_991.0).contains(v) && v.fract() == 0.0)
            .map(|v| v as i64)
    };
    let reply = body
        .get("reply_to_message_id")
        .filter(|v| !v.is_null())
        .map(|v| id(v).ok_or_else(|| ApiError::bad_request("reply_to_message_id 参数错误")))
        .transpose()?;
    let mut media = Vec::new();
    if let Some(value) = body.get("media_ids") {
        let invalid = || ApiError::bad_request("media_ids 参数错误");
        let items = value
            .as_array()
            .filter(|items| items.len() <= 32)
            .ok_or_else(invalid)?;
        let mut seen = HashSet::new();
        for value in items {
            let id = id(value)
                .filter(|id| seen.insert(*id))
                .ok_or_else(invalid)?;
            media.push(id);
        }
    }
    if content.is_empty() && media.is_empty() {
        return Err(ApiError::bad_request("消息内容或附件不能为空"));
    }
    Ok(Input {
        content: content.to_owned(),
        reply,
        media,
    })
}

pub(crate) async fn send(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    let result = async {
        let (user, channel) =
            crate::posts::bookmark::interaction_identity(&state, &raw, &headers).await?;
        let bytes = to_bytes(body, 1 << 20)
            .await
            .map_err(|_| ApiError::bad_request("请求体格式错误"))?;
        let outcome = state
            .repository
            .send_chat_message(user, channel, parse(&bytes)?, &state.storage_urls)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?;
        let message = match outcome {
            Outcome::Created(message) => message,
            Outcome::PublishForbidden => {
                return Err(ApiError::forbidden(
                    crate::moderation::publish_policy::message(),
                ))
            }
            Outcome::Forbidden => return Err(ApiError::forbidden("无权访问该聊天频道")),
            Outcome::CannotSpeak => return Err(ApiError::forbidden("当前群组状态不允许发送消息")),
            Outcome::Unsupported => {
                return Err(ApiError::bad_request("该频道类型暂不支持文字消息"))
            }
            Outcome::InvalidReply => return Err(ApiError::bad_request("回复消息不存在")),
            Outcome::InvalidMedia => return Err(ApiError::bad_request("附件不存在或无权使用")),
        };
        if let Some(publisher) = &state.notification_publisher {
            if publisher
                .publish_chat_message(channel, &message)
                .await
                .is_err()
            {
                tracing::warn!("chat message delivery unavailable");
            }
        }
        Ok(Json(V2Response::ok_with_message(
            message,
            "chat message created",
        )))
    }
    .await;
    let mut response = result.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_attachment_only_and_rejects_duplicate_or_invalid_ids() {
        assert_eq!(parse(br#"{"media_ids":[8,7]}"#).unwrap().media, vec![8, 7]);
        for input in [
            br#"{"media_ids":[8,8]}"#.as_slice(),
            br#"{"content":"hi","reply_to_message_id":1.5}"#,
            br#"{"content":" "}"#,
        ] {
            assert!(parse(input).is_err());
        }
    }
}
