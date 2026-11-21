use crate::{
    auth::{session_repository::row_number, sessions::NativeState},
    chat_channels::LOCK,
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
use serde_json::{json, Value};

pub enum Operation {
    Read(Option<u64>),
    Mute(bool),
}

pub enum Outcome {
    Updated(Value),
    Forbidden,
    InvalidMessage,
}

pub(crate) const ACCESS: &str = "SELECT 1 FROM n_chat_channels c
JOIN n_groups g ON g.group_id=c.group_id
JOIN n_group_members gm ON gm.group_id=c.group_id AND gm.user_id=:user_id
WHERE c.channel_id=:channel_id AND c.is_deleted=0 AND g.is_active=1 AND g.is_deleted=0
AND gm.status IN ('active','muted') AND (c.is_private=0 OR gm.role IN ('owner','admin','moderator'))";

const TARGET: &str = "SELECT MAX(message_id) AS message_id FROM n_chat_messages
WHERE channel_id=:channel_id AND is_deleted=0 AND (:target=0 OR message_id=:target)";
pub(crate) const MERGE_READ: &str = "MERGE INTO n_chat_channel_reads r USING
(SELECT :channel_id AS channel_id,:user_id AS user_id,:message_id AS message_id FROM dual) src
ON (r.channel_id=src.channel_id AND r.user_id=src.user_id)
WHEN MATCHED THEN UPDATE SET r.last_read_message_id=CASE
 WHEN NVL(src.message_id,0)>NVL(r.last_read_message_id,0) THEN src.message_id ELSE r.last_read_message_id END,
 r.last_read_at=CURRENT_TIMESTAMP
WHEN NOT MATCHED THEN INSERT (channel_id,user_id,last_read_message_id,last_read_at)
VALUES (src.channel_id,src.user_id,src.message_id,CURRENT_TIMESTAMP)";
const READ_RESULT: &str = "SELECT r.last_read_message_id,
(SELECT COUNT(*) FROM n_chat_messages m WHERE m.channel_id=r.channel_id
 AND m.is_deleted=0 AND m.message_id>NVL(r.last_read_message_id,0)) AS unread_count
FROM n_chat_channel_reads r WHERE r.channel_id=:channel_id AND r.user_id=:user_id";
const MERGE_MUTE: &str = "MERGE INTO n_chat_channel_mutes m USING
(SELECT :channel_id AS channel_id,:user_id AS user_id FROM dual) src
ON (m.channel_id=src.channel_id AND m.user_id=src.user_id)
WHEN NOT MATCHED THEN INSERT (channel_id,user_id) VALUES (src.channel_id,src.user_id)";
const DELETE_MUTE: &str =
    "DELETE FROM n_chat_channel_mutes WHERE channel_id=:channel_id AND user_id=:user_id";

pub(crate) fn lock_channel_access(
    conn: &oracle::Connection,
    user: i64,
    channel: i64,
) -> Result<bool, DbError> {
    let channel_binds = BindMap::from([("channel_id".into(), DbValue::I64(channel))]);
    let mut member_binds = channel_binds.clone();
    member_binds.insert("user_id".into(), DbValue::I64(user));
    if query(conn, ACCESS, member_binds.clone())?.is_empty() {
        return Ok(false);
    }
    let groups = query(
        conn,
        "SELECT group_id FROM n_chat_channels WHERE channel_id=:channel_id AND is_deleted=0",
        channel_binds.clone(),
    )?;
    let Some(group) = groups.first() else {
        return Ok(false);
    };
    let group_binds = BindMap::from([(
        "group_id".into(),
        DbValue::I64(row_number(group, "GROUP_ID")),
    )]);
    if query(conn, LOCK, group_binds)?.is_empty()
        || query(
            conn,
            &format!("{ACCESS} FOR UPDATE OF gm.role"),
            member_binds.clone(),
        )?
        .is_empty()
    {
        return Ok(false);
    }

    Ok(true)
}

fn change(
    conn: &oracle::Connection,
    tx: &OracleTx<'_>,
    user: u64,
    channel: u64,
    operation: Operation,
) -> Result<Outcome, DbError> {
    let number = |id| {
        i64::try_from(id)
            .map(DbValue::I64)
            .map_err(|_| DbError::SchemaNotReady)
    };
    let channel_binds = BindMap::from([("channel_id".into(), number(channel)?)]);
    let mut member_binds = channel_binds.clone();
    member_binds.insert("user_id".into(), number(user)?);

    if !lock_channel_access(
        conn,
        i64::try_from(user).map_err(|_| DbError::SchemaNotReady)?,
        i64::try_from(channel).map_err(|_| DbError::SchemaNotReady)?,
    )? {
        return Ok(Outcome::Forbidden);
    }

    let data = match operation {
        Operation::Read(target) => {
            let mut binds = channel_binds;
            binds.insert("target".into(), number(target.unwrap_or(0))?);
            let rows = query(conn, TARGET, binds)?;
            let candidate = rows
                .first()
                .and_then(|row| row.get("MESSAGE_ID"))
                .and_then(DbValue::as_i64);
            if target.is_some() && candidate.is_none() {
                return Ok(Outcome::InvalidMessage);
            }
            let mut binds = member_binds.clone();
            binds.insert(
                "message_id".into(),
                candidate.map_or(DbValue::Null, DbValue::I64),
            );
            tx.execute(MERGE_READ, binds)?;
            let rows = query(conn, READ_RESULT, member_binds)?;
            let row = rows.first().ok_or(DbError::SchemaNotReady)?;
            json!({
                "channel_id": channel,
                "last_read_message_id": row.get("LAST_READ_MESSAGE_ID").and_then(DbValue::as_i64),
                "unread_count": row_number(row, "UNREAD_COUNT")
            })
        }
        Operation::Mute(mute) => {
            tx.execute(if mute { MERGE_MUTE } else { DELETE_MUTE }, member_binds)?;
            json!({"channel_id":channel,"is_muted":mute})
        }
    };
    Ok(Outcome::Updated(data))
}

pub(crate) fn execute(
    conn: &oracle::Connection,
    user: u64,
    channel: u64,
    operation: Operation,
) -> Result<Outcome, DbError> {
    let tx = OracleTx::new(conn);
    match change(conn, &tx, user, channel, operation) {
        Ok(outcome @ Outcome::Updated(_)) => match tx.commit() {
            Ok(()) => Ok(outcome),
            Err(error) => {
                let _ = tx.rollback();
                Err(error)
            }
        },
        result => {
            tx.rollback()?;
            result
        }
    }
}

fn parse(raw: &[u8], read: bool) -> Result<Operation, ApiError> {
    if read && raw.iter().all(u8::is_ascii_whitespace) {
        return Ok(Operation::Read(None));
    }
    let value: Value =
        serde_json::from_slice(raw).map_err(|_| ApiError::bad_request("请求体格式错误"))?;
    if read && value.is_null() {
        return Ok(Operation::Read(None));
    }
    let body = value
        .as_object()
        .ok_or_else(|| ApiError::bad_request("请求体格式错误"))?;
    if !read {
        return Ok(Operation::Mute(
            body.get("is_muted")
                .is_some_and(crate::chat_channel_write::channel_boolean),
        ));
    }
    let Some(id) = body.get("last_read_message_id").filter(|v| !v.is_null()) else {
        return Ok(Operation::Read(None));
    };
    let id = id
        .as_f64()
        .filter(|v| (1.0..=9_007_199_254_740_991.0).contains(v) && v.fract() == 0.0)
        .ok_or_else(|| ApiError::bad_request("last_read_message_id 参数错误"))?;
    Ok(Operation::Read(Some(id as u64)))
}

async fn route(
    state: NativeState,
    raw: String,
    headers: HeaderMap,
    body: Body,
    read: bool,
) -> Response {
    let result = async {
        let (user, id) =
            crate::posts::bookmark::interaction_identity(&state, &raw, &headers).await?;
        let bytes = to_bytes(body, 1 << 20)
            .await
            .map_err(|_| ApiError::bad_request("请求体格式错误"))?;
        let operation = parse(&bytes, read)?;
        let outcome = state
            .repository
            .set_chat_channel_status(user, id, operation)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?;
        let data = match outcome {
            Outcome::Updated(data) => data,
            Outcome::Forbidden => return Err(ApiError::forbidden("无权访问该聊天频道")),
            Outcome::InvalidMessage => {
                return Err(ApiError::bad_request("已读消息不存在或不属于该频道"))
            }
        };
        let message = if read {
            "chat read status updated"
        } else {
            "chat channel mute status updated"
        };
        Ok(Json(V2Response::ok_with_message(data, message)))
    }
    .await;
    let mut response = result.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}

pub(crate) async fn read(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    route(state, raw, headers, body, true).await
}

pub(crate) async fn mute(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    route(state, raw, headers, body, false).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_optional_latest_cursor_and_rejects_unsafe_ids() {
        assert!(matches!(parse(b"", true).unwrap(), Operation::Read(None)));
        assert!(matches!(
            parse(br#"{"last_read_message_id":7}"#, true).unwrap(),
            Operation::Read(Some(7))
        ));
        for raw in [
            br#"{"last_read_message_id":1.5}"#.as_slice(),
            br#"{"last_read_message_id":9007199254740992}"#,
        ] {
            assert!(parse(raw, true).is_err());
        }
        assert!(matches!(
            parse(br#"{"is_muted":false}"#, false).unwrap(),
            Operation::Mute(false)
        ));
    }
}
