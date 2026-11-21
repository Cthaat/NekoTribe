use crate::{
    auth::{
        login::{js_trim, request_body, scalar},
        session_repository::row_number,
        sessions::NativeState,
        storage_urls::StorageUrlPolicy,
    },
    db::{
        oracle::{BindMap, DbError},
        tx::OracleTx,
        value::DbValue,
    },
    direct_history::{conversation_id, map_message, normalize_author, query, MARK},
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    body::{to_bytes, Body},
    extract::{Path, State},
    http::{header::CACHE_CONTROL, HeaderValue, Request},
    response::{IntoResponse, Response},
    Json,
};
use serde_json::{json, Value};

pub enum DirectSend {
    Forbidden,
    PublishForbidden,
    MissingRecipient,
    Blocked,
    StrangersDenied,
    Created {
        recipient: u64,
        message: Value,
        push_notice: Option<u64>,
    },
}

const ACCESS: &str =
    "SELECT CASE WHEN user_low_id=:user_id THEN user_high_id ELSE user_low_id END AS recipient
FROM n_direct_conversations WHERE conversation_id=:conversation_id AND is_deleted=0
AND (user_low_id=:user_id OR user_high_id=:user_id) FOR UPDATE";
const RECIPIENT: &str = "SELECT NVL(us.allow_dm_from_strangers,0) AS allow_strangers,
fn_get_user_relationship(:sender_id,u.user_id) AS relation,
(SELECT COUNT(*) FROM n_group_members sender
 JOIN n_group_members recipient ON recipient.group_id=sender.group_id
 JOIN n_groups g ON g.group_id=sender.group_id
 WHERE sender.user_id=:sender_id AND recipient.user_id=u.user_id
 AND sender.status IN ('active','muted') AND recipient.status IN ('active','muted')
 AND g.is_active=1 AND g.is_deleted=0) AS shared_groups
FROM n_users u LEFT JOIN n_user_settings us ON us.user_id=u.user_id
WHERE u.user_id=:target_user_id AND u.is_active=1";
const MESSAGE: &str = "SELECT dm.message_id,dm.conversation_id,dm.sender_id AS user_id,dm.content,dm.is_deleted,
dm.created_at,dm.updated_at,dm.edited_at,dm.deleted_at,u.username,u.avatar_url,u.display_name,u.bio,u.location,u.website,
u.is_verified,u.followers_count,u.following_count,u.posts_count,u.likes_count,'self' AS relation
FROM n_direct_messages dm JOIN v_user_profile_public u ON u.user_id=dm.sender_id
WHERE dm.message_id=:message_id AND dm.sender_id=:sender_id";
const DELIVERY: &str = "SELECT NVL(us.push_notification_enabled,1) AS push_enabled,NVL(np.is_enabled,1) AS type_enabled
FROM n_users u LEFT JOIN n_user_settings us ON us.user_id=u.user_id
LEFT JOIN n_notification_preferences np ON np.user_id=u.user_id AND np.notification_type='direct_message'
WHERE u.user_id=:target_user_id AND u.is_active=1";
const NOTICE: &str = "INSERT INTO n_notifications
(notification_id,user_id,actor_id,type,title,message,resource_type,resource_id,priority,metadata_json)
VALUES (:notification_id,:target_user_id,:sender_id,'direct_message',:title,:preview,'direct_message',:message_id,'normal',:metadata)";

pub(crate) fn next_id(connection: &oracle::Connection, sql: &str) -> Result<i64, DbError> {
    query(connection, sql, BindMap::new())?
        .first()
        .map(|row| row_number(row, "ID"))
        .filter(|id| *id > 0 && *id as u64 <= crate::notification_websocket::MAX_SOCKET_ID)
        .ok_or(DbError::SchemaNotReady)
}

#[derive(Debug, PartialEq, Eq)]
pub enum RecipientDenial {
    Missing,
    Blocked,
    Strangers,
}

pub(crate) fn check_recipient(
    connection: &oracle::Connection,
    sender: i64,
    recipient: i64,
) -> Result<Option<RecipientDenial>, DbError> {
    let rows = query(
        connection,
        RECIPIENT,
        BindMap::from([
            ("sender_id".into(), DbValue::I64(sender)),
            ("target_user_id".into(), DbValue::I64(recipient)),
        ]),
    )?;
    let Some(row) = rows.first() else {
        return Ok(Some(RecipientDenial::Missing));
    };
    Ok(match row.get("RELATION").and_then(DbValue::as_str) {
        Some("blocking" | "blocked_by") => Some(RecipientDenial::Blocked),
        Some("mutual_follow" | "followed_by") => None,
        _ if row_number(row, "ALLOW_STRANGERS") != 1 && row_number(row, "SHARED_GROUPS") == 0 => {
            Some(RecipientDenial::Strangers)
        }
        _ => None,
    })
}

fn execute_one(tx: &OracleTx<'_>, sql: &str, binds: BindMap) -> Result<(), DbError> {
    if tx.execute(sql, binds)?.rows_affected != 1 {
        return Err(DbError::SchemaNotReady);
    }
    Ok(())
}

fn preview(content: &str) -> String {
    let normalized = content
        .split(|ch: char| {
            let mut buffer = [0; 4];
            js_trim(ch.encode_utf8(&mut buffer)).is_empty()
        })
        .filter(|word| !word.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    let mut units = 0;
    for (offset, ch) in normalized.char_indices() {
        units += ch.len_utf16();
        if units > 80 {
            return format!("{}...", &normalized[..offset]);
        }
    }
    normalized
}

pub(crate) fn execute(
    connection: &oracle::Connection,
    sender: u64,
    conversation: u64,
    content: &str,
    storage: &StorageUrlPolicy,
) -> Result<DirectSend, DbError> {
    let sender = i64::try_from(sender).map_err(|_| DbError::SchemaNotReady)?;
    let conversation = i64::try_from(conversation).map_err(|_| DbError::SchemaNotReady)?;
    let number = |key: &str, value| (key.to_owned(), DbValue::I64(value));
    let text = |key: &str, value: &str| (key.to_owned(), DbValue::String(value.into()));
    let tx = OracleTx::new(connection);
    let result = (|| {
        let membership = query(
            connection,
            ACCESS,
            BindMap::from([
                number("user_id", sender),
                number("conversation_id", conversation),
            ]),
        )?;
        let Some(member) = membership.first() else {
            return Ok(DirectSend::Forbidden);
        };
        let recipient = row_number(member, "RECIPIENT");
        if recipient <= 0
            || recipient == sender
            || recipient as u64 > crate::notification_websocket::MAX_SOCKET_ID
        {
            return Err(DbError::SchemaNotReady);
        }
        if let Some(denial) = check_recipient(connection, sender, recipient)? {
            return Ok(match denial {
                RecipientDenial::Missing => DirectSend::MissingRecipient,
                RecipientDenial::Blocked => DirectSend::Blocked,
                RecipientDenial::Strangers => DirectSend::StrangersDenied,
            });
        }
        if !crate::moderation::publish_policy::allowed(sender, |sql, binds| {
            query(connection, sql, binds)
        })? {
            return Ok(DirectSend::PublishForbidden);
        }
        let id = next_id(
            connection,
            "SELECT seq_direct_message_id.NEXTVAL AS id FROM dual",
        )?;
        execute_one(
            &tx,
            "INSERT INTO n_direct_messages (message_id,conversation_id,sender_id,content)
            VALUES (:message_id,:conversation_id,:sender_id,:content)",
            BindMap::from([
                number("message_id", id),
                number("conversation_id", conversation),
                number("sender_id", sender),
                text("content", content),
            ]),
        )?;
        execute_one(&tx, "UPDATE n_direct_conversations SET last_message_id=:message_id,last_message_at=CURRENT_TIMESTAMP,
            message_count=message_count+1,updated_at=CURRENT_TIMESTAMP WHERE conversation_id=:conversation_id",
            BindMap::from([number("message_id", id), number("conversation_id", conversation)]))?;
        execute_one(
            &tx,
            MARK,
            BindMap::from([
                number("message_id", id),
                number("conversation_id", conversation),
                number("user_id", sender),
            ]),
        )?;
        let rows = query(
            connection,
            MESSAGE,
            BindMap::from([number("message_id", id), number("sender_id", sender)]),
        )?;
        let mut message = map_message(rows.first().ok_or(DbError::SchemaNotReady)?, sender);
        normalize_author(&mut message, storage)?;
        let delivery = query(
            connection,
            DELIVERY,
            BindMap::from([number("target_user_id", recipient)]),
        )?;
        let mut push_notice = None;
        if let Some(row) = delivery
            .first()
            .filter(|row| row_number(row, "TYPE_ENABLED") != 0)
        {
            let notification = next_id(
                connection,
                "SELECT seq_notification_id.NEXTVAL AS id FROM dual",
            )?;
            let author = &message["author"];
            let name = ["display_name", "username"]
                .into_iter()
                .filter_map(|field| author[field].as_str())
                .find(|value| !value.is_empty())
                .unwrap_or("有人");
            let metadata = json!({"conversation_id":conversation,"event":"direct_message_created"})
                .to_string();
            execute_one(
                &tx,
                NOTICE,
                BindMap::from([
                    number("notification_id", notification),
                    number("target_user_id", recipient),
                    number("sender_id", sender),
                    number("message_id", id),
                    text("title", &format!("{name} 给你发来私信")),
                    text("preview", &preview(content)),
                    text("metadata", &metadata),
                ]),
            )?;
            if row_number(row, "PUSH_ENABLED") != 0 {
                push_notice = Some(notification as u64);
            }
        }
        Ok(DirectSend::Created {
            recipient: recipient as u64,
            message,
            push_notice,
        })
    })();
    match result {
        Ok(created @ DirectSend::Created { .. }) => match tx.commit() {
            Ok(()) => Ok(created),
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

pub(crate) async fn send(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    request: Request<Body>,
) -> Response {
    let mut response = send_inner(&state, &raw, request).await.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}

async fn send_inner(
    state: &NativeState,
    raw: &str,
    request: Request<Body>,
) -> Result<Json<V2Response<Value>>, ApiError> {
    let (parts, body) = request.into_parts();
    let sender = crate::posts::bookmark::interaction_actor(state, &parts.headers).await?;
    let conversation = conversation_id(raw)?;
    let bytes = to_bytes(body, 1024 * 1024)
        .await
        .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
    let body = request_body(&parts.headers, &bytes)?;
    let raw_content = scalar(body.get("content"));
    let content = js_trim(&raw_content);
    if content.is_empty() {
        return Err(ApiError::bad_request("content 不能为空"));
    }
    if content.len() > 4000 {
        return Err(ApiError::bad_request("content 超过最大长度"));
    }
    let outcome = state
        .repository
        .send_direct_message(sender, conversation, content, &state.storage_urls)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    let (recipient, message, notice) = match outcome {
        DirectSend::Created {
            recipient,
            message,
            push_notice,
        } => (recipient, message, push_notice),
        DirectSend::PublishForbidden => {
            return Err(ApiError::forbidden(
                crate::moderation::publish_policy::message(),
            ))
        }
        DirectSend::Forbidden => return Err(ApiError::forbidden("无权访问该私聊会话")),
        DirectSend::MissingRecipient => return Err(ApiError::not_found("用户不存在")),
        DirectSend::Blocked => return Err(ApiError::forbidden("无法向该用户发送私信")),
        DirectSend::StrangersDenied => return Err(ApiError::forbidden("对方不接收陌生人私信")),
    };
    if let Some(publisher) = &state.notification_publisher {
        if publisher
            .publish_direct(sender, recipient, &message)
            .await
            .is_err()
        {
            eprintln!("direct message delivery unavailable");
        }
        if let Some(id) = notice {
            let result = async {
                let mut item = state
                    .repository
                    .direct_notification(recipient, id)
                    .await
                    .ok()
                    .flatten()?;
                crate::notifications::hydrate_notification(state, recipient, &mut item)
                    .await
                    .ok()?;
                let data = json!({"notification":item,"notification_type":"direct_message"});
                publisher
                    .publish(recipient, "notification_created", data.as_object()?)
                    .await
                    .ok()
            }
            .await;
            if result.is_none() {
                eprintln!("notification delivery unavailable");
            }
        }
    }
    Ok(Json(V2Response::ok_with_message(
        message,
        "direct message created",
    )))
}
