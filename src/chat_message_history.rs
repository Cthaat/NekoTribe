use crate::{
    auth::{
        session_list::{session_pagination, SessionPage},
        session_repository::{
            media_json, nullable_text, profile_date, public_profile_json, row_number, row_text,
        },
        sessions::NativeState,
        storage_urls::StorageUrlPolicy,
    },
    chat_channel_status::{lock_channel_access, MERGE_READ},
    chat_message_search::{Scope, Search},
    db::{
        oracle::{BindMap, DbError},
        row::DbRow,
        tx::OracleTx,
        value::DbValue,
    },
    direct_history::{normalize_author, query},
    httpx::errors::ApiError,
};
use axum::{
    extract::{OriginalUri, Path, State},
    http::{header::CACHE_CONTROL, HeaderMap, HeaderValue},
    response::{IntoResponse, Response},
    Json,
};
use serde_json::{json, Value};
use std::collections::HashMap;

pub type History = Option<(Vec<Value>, u64)>;

const COUNT: &str = "SELECT COUNT(*) AS total FROM n_chat_messages m
JOIN v_user_profile_public u ON u.user_id=m.author_id
WHERE m.channel_id=:channel_id AND m.is_deleted=0{search}";
const PAGE: &str = "SELECT * FROM (
  SELECT m.message_id,m.channel_id,m.group_id,m.author_id AS user_id,m.message_type,m.content,
m.is_pinned,m.is_deleted,m.created_at,m.updated_at,m.edited_at,m.deleted_at,
u.username,u.avatar_url,u.display_name,u.bio,u.location,u.website,u.is_verified,
u.followers_count,u.following_count,u.posts_count,u.likes_count,
fn_get_user_relationship(:viewer_id,u.user_id) AS relation,
rm.message_id AS reply_id,rm.content AS reply_content,COALESCE(ru.display_name,ru.username) AS reply_author_name,
  ROW_NUMBER() OVER (ORDER BY m.created_at DESC,m.message_id DESC) AS rn
  FROM n_chat_messages m
  JOIN v_user_profile_public u ON u.user_id=m.author_id
  LEFT JOIN n_chat_messages rm ON rm.message_id=m.reply_to_message_id AND rm.channel_id=m.channel_id AND rm.is_deleted=0
  LEFT JOIN n_users ru ON ru.user_id=rm.author_id
  WHERE m.channel_id=:channel_id AND m.is_deleted=0{search}
) WHERE rn BETWEEN :start_row AND :end_row
ORDER BY created_at ASC,message_id ASC";
pub(crate) const BY_ID: &str = "SELECT m.message_id,m.channel_id,m.group_id,m.author_id AS user_id,m.message_type,m.content,
m.is_pinned,m.is_deleted,m.created_at,m.updated_at,m.edited_at,m.deleted_at,
u.username,u.avatar_url,u.display_name,u.bio,u.location,u.website,u.is_verified,
u.followers_count,u.following_count,u.posts_count,u.likes_count,
fn_get_user_relationship(:viewer_id,u.user_id) AS relation,
rm.message_id AS reply_id,rm.content AS reply_content,COALESCE(ru.display_name,ru.username) AS reply_author_name
  FROM n_chat_messages m
  JOIN v_user_profile_public u ON u.user_id=m.author_id
  LEFT JOIN n_chat_messages rm ON rm.message_id=m.reply_to_message_id AND rm.channel_id=m.channel_id AND rm.is_deleted=0
  LEFT JOIN n_users ru ON ru.user_id=rm.author_id
WHERE m.channel_id=:channel_id AND m.message_id=:message_id AND m.is_deleted=0";
const ACCESS: &str = "SELECT CASE WHEN gm.role IN ('owner','admin','moderator') THEN 1 ELSE 0 END AS can_manage
FROM n_chat_channels c JOIN n_groups g ON g.group_id=c.group_id
JOIN n_group_members gm ON gm.group_id=c.group_id AND gm.user_id=:user_id
WHERE c.channel_id=:channel_id AND c.is_deleted=0 AND g.is_active=1 AND g.is_deleted=0
AND gm.status IN ('active','muted') AND (c.is_private=0 OR gm.role IN ('owner','admin','moderator'))";
const MEDIA: &str = "SELECT a.message_id,ma.media_id,ma.media_type,ma.file_name,ma.public_url,ma.file_size,ma.mime_type,
ma.width,ma.height,ma.duration,ma.thumbnail_url,ma.alt_text,ma.description,ma.status,ma.created_at
FROM n_chat_message_media a JOIN n_media_assets ma ON ma.media_id=a.media_id
WHERE a.message_id IN (%s) ORDER BY a.message_id,a.position,a.chat_message_media_id";
const REACTIONS: &str = "SELECT message_id,emoji,COUNT(*) AS reaction_count,
MAX(CASE WHEN user_id=:viewer_id THEN 1 ELSE 0 END) AS reacted_by_me
FROM n_chat_message_reactions WHERE message_id IN (%s)
GROUP BY message_id,emoji ORDER BY message_id,reaction_count DESC,emoji ASC";

pub(crate) fn message_json(row: &DbRow, viewer: i64, manage: bool) -> Result<Value, DbError> {
    let kind = row_text(row, "MESSAGE_TYPE");
    if !matches!(kind.as_str(), "text" | "system") {
        return Err(DbError::SchemaNotReady);
    }
    let date = |key| nullable_text(row, key).map(|value| profile_date(&value));
    let reply = row.get("REPLY_ID").and_then(DbValue::as_i64).map(|id| json!({
        "message_id": id, "content": row_text(row, "REPLY_CONTENT"), "author_name": row_text(row, "REPLY_AUTHOR_NAME")
    }));
    Ok(json!({
        "message_id":row_number(row,"MESSAGE_ID"), "channel_id":row_number(row,"CHANNEL_ID"),
        "group_id":row_number(row,"GROUP_ID"), "message_type":kind, "content":row_text(row,"CONTENT"),
        "author":public_profile_json(row), "reply_to":reply, "media":[], "reactions":[],
        "is_pinned":row_number(row,"IS_PINNED")==1, "is_deleted":row_number(row,"IS_DELETED")==1,
        "can_delete":manage || row_number(row,"USER_ID")==viewer, "can_pin":manage,
        "created_at":date("CREATED_AT").unwrap_or_default(), "updated_at":date("UPDATED_AT").unwrap_or_default(),
        "edited_at":date("EDITED_AT"), "deleted_at":date("DELETED_AT"),
    }))
}

pub(crate) fn append_details(
    conn: &oracle::Connection,
    viewer: i64,
    rows: &[DbRow],
    messages: &mut [Value],
    storage: &StorageUrlPolicy,
) -> Result<(), DbError> {
    let mut binds = BindMap::new();
    let mut keys = Vec::new();
    let mut indexes = HashMap::new();
    for (index, row) in rows.iter().enumerate() {
        let id = row_number(row, "MESSAGE_ID");
        let key = format!("message_{index}");
        binds.insert(key.clone(), DbValue::I64(id));
        keys.push(format!(":{key}"));
        indexes.insert(id, index);
    }
    let keys = keys.join(",");
    for row in query(conn, &MEDIA.replace("%s", &keys), binds.clone())? {
        let index = *indexes
            .get(&row_number(&row, "MESSAGE_ID"))
            .ok_or(DbError::SchemaNotReady)?;
        let mut media = media_json(&row);
        crate::media::normalize_attachment_urls(storage, &mut media)
            .map_err(|_| DbError::SchemaNotReady)?;
        messages[index]["media"]
            .as_array_mut()
            .ok_or(DbError::SchemaNotReady)?
            .push(media);
    }
    binds.insert("viewer_id".into(), DbValue::I64(viewer));
    for row in query(conn, &REACTIONS.replace("%s", &keys), binds)? {
        let index = *indexes
            .get(&row_number(&row, "MESSAGE_ID"))
            .ok_or(DbError::SchemaNotReady)?;
        messages[index]["reactions"]
            .as_array_mut()
            .ok_or(DbError::SchemaNotReady)?
            .push(json!({
                "emoji":row_text(&row,"EMOJI"), "count":row_number(&row,"REACTION_COUNT"),
                "reacted_by_me":row_number(&row,"REACTED_BY_ME")==1,
            }));
    }
    Ok(())
}

pub(crate) fn execute(
    conn: &oracle::Connection,
    viewer: u64,
    channel: u64,
    page: SessionPage,
    search: &Search,
    storage: &StorageUrlPolicy,
) -> Result<History, DbError> {
    let viewer = i64::try_from(viewer).map_err(|_| DbError::SchemaNotReady)?;
    let channel = i64::try_from(channel).map_err(|_| DbError::SchemaNotReady)?;
    let tx = OracleTx::new(conn);
    let result = (|| {
        if !lock_channel_access(conn, viewer, channel)? {
            return Ok(None);
        }
        let actor = || {
            BindMap::from([
                ("channel_id".into(), DbValue::I64(channel)),
                ("user_id".into(), DbValue::I64(viewer)),
            ])
        };
        let access = query(conn, ACCESS, actor())?;
        let Some(access) = access.first() else {
            return Ok(None);
        };
        let manage = row_number(access, "CAN_MANAGE") == 1;
        let mut binds = BindMap::from([("channel_id".into(), DbValue::I64(channel))]);
        let predicates = search.predicates(Scope::Channel, &mut binds);
        let count = query(conn, &COUNT.replace("{search}", &predicates), binds.clone())?;
        let total = count
            .first()
            .and_then(|row| row.get("TOTAL"))
            .and_then(DbValue::as_i64)
            .and_then(|n| u64::try_from(n).ok())
            .ok_or(DbError::SchemaNotReady)?;
        binds.extend([
            ("viewer_id".into(), DbValue::I64(viewer)),
            ("start_row".into(), DbValue::F64(page.start)),
            ("end_row".into(), DbValue::F64(page.end)),
        ]);
        let rows = query(conn, &PAGE.replace("{search}", &predicates), binds)?;
        let mut messages = rows
            .iter()
            .map(|row| {
                let mut message = message_json(row, viewer, manage)?;
                normalize_author(&mut message, storage)?;
                Ok::<_, DbError>(message)
            })
            .collect::<Result<Vec<_>, _>>()?;
        if let Some(last) = rows.last() {
            append_details(conn, viewer, &rows, &mut messages, storage)?;
            if search.is_empty() && page.page == 1.0 {
                let mut binds = actor();
                binds.insert(
                    "message_id".into(),
                    DbValue::I64(row_number(last, "MESSAGE_ID")),
                );
                tx.execute(MERGE_READ, binds)?;
            }
        }
        Ok(Some((messages, total)))
    })();
    match result {
        Ok(Some(page)) => match tx.commit() {
            Ok(()) => Ok(Some(page)),
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

pub(crate) async fn list(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
) -> Response {
    let result = async {
        let (viewer, channel) = crate::posts::bookmark::interaction_identity(&state, &raw, &headers).await?;
        let raw_query = uri.query().unwrap_or_default();
        let page = session_pagination(raw_query);
        let search = Search::parse(raw_query)?;
        let (messages,total) = state.repository.list_chat_messages(viewer,channel,page,search,&state.storage_urls).await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?
            .ok_or_else(|| ApiError::forbidden("无权访问该聊天频道"))?;
        Ok::<_,ApiError>(Json(json!({
            "code":200,"message":"success","data":messages,
            "meta":{"page":page.page,"page_size":page.page_size,"total":total,"has_next":page.end<total as f64}
        })))
    }.await;
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
    fn history_message_keeps_empty_collections_and_hides_unavailable_replies() {
        let row = DbRow::from([
            ("MESSAGE_TYPE".into(), DbValue::String("text".into())),
            ("USER_ID".into(), DbValue::I64(42)),
            ("REPLY_CONTENT".into(), DbValue::String("stale".into())),
        ]);
        let message = message_json(&row, 42, false).unwrap();
        assert_eq!(message["reply_to"], Value::Null);
        assert_eq!(message["media"], json!([]));
        assert_eq!(message["reactions"], json!([]));
        assert_eq!(message["can_delete"], true);
        assert_eq!(message["can_pin"], false);
    }
}
