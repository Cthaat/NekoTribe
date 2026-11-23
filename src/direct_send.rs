use crate::{
    auth::{
        login::{js_trim, request_body, scalar},
        session_repository::row_number,
        sessions::NativeState,
        storage_urls::StorageUrlPolicy,
    },
    db::{
        oracle::{BindMap, DbError},
        tx::{OracleTx, Transaction},
        value::DbValue,
    },
    direct_extras,
    direct_history::{conversation_id, map_message, normalize_author, query},
    direct_read::{self, ReadAdvance},
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    Json,
    body::{Body, to_bytes},
    extract::{Path, State},
    http::{HeaderValue, Request, header::CACHE_CONTROL},
    response::{IntoResponse, Response},
};
use serde_json::{Value, json};
use std::collections::HashSet;

pub enum DirectSend {
    Forbidden,
    PublishForbidden,
    MissingRecipient,
    Blocked,
    StrangersDenied,
    AttachmentMissing,
    InvalidReply,
    Created {
        recipient: u64,
        message: Value,
        push_notice: Option<u64>,
        read_advance: Option<ReadAdvance>,
    },
}

pub struct Input {
    content: String,
    media: Vec<i64>,
    reply: Option<i64>,
}

impl Input {
    pub(crate) fn text(content: &str) -> Self {
        Self {
            content: content.to_owned(),
            media: Vec::new(),
            reply: None,
        }
    }

    fn parse(body: &Value) -> Result<Self, ApiError> {
        let contract = direct_extras::contract();
        let raw_content = scalar(body.get("content"));
        let content = js_trim(&raw_content);
        if content.len() > contract.max_content_bytes {
            return Err(ApiError::bad_request("content 超过最大长度"));
        }
        let media_error = || ApiError::bad_request("media_ids 参数错误");
        let media = match body.get("media_ids") {
            None => Vec::new(),
            Some(value) => {
                let ids = value
                    .as_array()
                    .filter(|ids| ids.len() <= contract.max_media)
                    .ok_or_else(media_error)?;
                let mut unique = HashSet::new();
                ids.iter()
                    .map(|value| {
                        direct_extras::safe_id(value)
                            .filter(|id| unique.insert(*id))
                            .ok_or_else(media_error)
                    })
                    .collect::<Result<Vec<_>, _>>()?
            }
        };
        let reply = body
            .get("reply_to_message_id")
            .filter(|value| !value.is_null())
            .map(|value| {
                direct_extras::safe_id(value)
                    .ok_or_else(|| ApiError::bad_request("reply_to_message_id 参数错误"))
            })
            .transpose()?;
        if content.is_empty() && media.is_empty() {
            return Err(ApiError::bad_request("content 不能为空"));
        }
        Ok(Self {
            content: content.to_owned(),
            media,
            reply,
        })
    }

    fn has_extras(&self) -> bool {
        !self.media.is_empty() || self.reply.is_some()
    }

    pub(crate) fn plain_content(&self) -> Option<&str> {
        (!self.has_extras()).then_some(&self.content)
    }

    fn stored_content(&self) -> &str {
        if self.content.is_empty() {
            " "
        } else {
            self.content.as_str()
        }
    }
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

pub(crate) fn locked_recipient(
    tx: &impl Transaction,
    sender: i64,
    conversation: i64,
) -> Result<Option<u64>, DbError> {
    let rows = tx.query(
        ACCESS,
        BindMap::from([
            ("user_id".into(), DbValue::I64(sender)),
            ("conversation_id".into(), DbValue::I64(conversation)),
        ]),
    )?;
    let Some(member) = rows.first() else {
        return Ok(None);
    };
    let recipient = row_number(member, "RECIPIENT");
    if recipient <= 0
        || recipient == sender
        || recipient as u64 > crate::notification_websocket::MAX_SOCKET_ID
    {
        return Err(DbError::SchemaNotReady);
    }
    Ok(Some(recipient as u64))
}

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
    input: &Input,
    storage: &StorageUrlPolicy,
) -> Result<DirectSend, DbError> {
    let sender = i64::try_from(sender).map_err(|_| DbError::SchemaNotReady)?;
    let conversation = i64::try_from(conversation).map_err(|_| DbError::SchemaNotReady)?;
    let number = |key: &str, value| (key.to_owned(), DbValue::I64(value));
    let text = |key: &str, value: &str| (key.to_owned(), DbValue::String(value.into()));
    let tx = OracleTx::new(connection);
    let result = (|| {
        let Some(recipient) = locked_recipient(&tx, sender, conversation)? else {
            return Ok(DirectSend::Forbidden);
        };
        if let Some(denial) = check_recipient(connection, sender, recipient as i64)? {
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
        let metadata_ready = direct_extras::metadata_ready(connection, !input.has_extras())?;
        if input.has_extras() {
            if let Some(reply) = input.reply {
                if !direct_extras::message_exists(&tx, conversation, reply)? {
                    return Ok(DirectSend::InvalidReply);
                }
            }
            if !direct_extras::lock_assets(&tx, sender, &input.media)? {
                return Ok(DirectSend::AttachmentMissing);
            }
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
                text("content", input.stored_content()),
            ]),
        )?;
        let sql = &direct_extras::contract().sql;
        for (position, media) in input.media.iter().enumerate() {
            execute_one(
                &tx,
                &sql.insert_media,
                BindMap::from([
                    number("message_id", id),
                    number("media_id", *media),
                    number("position", position as i64 + 1),
                ]),
            )?;
        }
        if let Some(reply) = input.reply {
            execute_one(
                &tx,
                &sql.insert_reply,
                BindMap::from([
                    number("message_id", id),
                    number("reply_to_message_id", reply),
                ]),
            )?;
        }
        execute_one(&tx, "UPDATE n_direct_conversations SET last_message_id=:message_id,last_message_at=CURRENT_TIMESTAMP,
            message_count=message_count+1,updated_at=CURRENT_TIMESTAMP WHERE conversation_id=:conversation_id",
            BindMap::from([number("message_id", id), number("conversation_id", conversation)]))?;
        let read_advance =
            direct_read::advance(&tx, sender, conversation, id as u64)?.then_some(ReadAdvance {
                recipient,
                message: id as u64,
            });
        let rows = query(
            connection,
            MESSAGE,
            BindMap::from([number("message_id", id), number("sender_id", sender)]),
        )?;
        let mut message = map_message(rows.first().ok_or(DbError::SchemaNotReady)?, sender);
        if metadata_ready {
            direct_extras::enrich(&tx, sender, std::slice::from_mut(&mut message))?;
        }
        normalize_author(&mut message, storage)?;
        let delivery = query(
            connection,
            DELIVERY,
            BindMap::from([number("target_user_id", recipient as i64)]),
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
                    number("target_user_id", recipient as i64),
                    number("sender_id", sender),
                    number("message_id", id),
                    text("title", &format!("{name} 给你发来私信")),
                    text(
                        "preview",
                        &preview(if input.content.is_empty() {
                            "[附件]"
                        } else {
                            &input.content
                        }),
                    ),
                    text("metadata", &metadata),
                ]),
            )?;
            if row_number(row, "PUSH_ENABLED") != 0 {
                push_notice = Some(notification as u64);
            }
        }
        Ok(DirectSend::Created {
            recipient,
            message,
            push_notice,
            read_advance,
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
    let input = Input::parse(&body)?;
    let outcome = state
        .repository
        .send_direct_message_with_extras(sender, conversation, input, &state.storage_urls)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    let (recipient, message, notice, read_advance) = match outcome {
        DirectSend::Created {
            recipient,
            message,
            push_notice,
            read_advance,
        } => (recipient, message, push_notice, read_advance),
        DirectSend::PublishForbidden => {
            return Err(ApiError::forbidden(
                crate::moderation::publish_policy::message(),
            ));
        }
        DirectSend::Forbidden => return Err(ApiError::forbidden("无权访问该私聊会话")),
        DirectSend::MissingRecipient => return Err(ApiError::not_found("用户不存在")),
        DirectSend::Blocked => return Err(ApiError::forbidden("无法向该用户发送私信")),
        DirectSend::StrangersDenied => return Err(ApiError::forbidden("对方不接收陌生人私信")),
        DirectSend::AttachmentMissing => return Err(ApiError::not_found("附件不存在或不可用")),
        DirectSend::InvalidReply => {
            return Err(ApiError::bad_request("reply_to_message_id 参数错误"));
        }
    };
    if let Some(publisher) = &state.notification_publisher {
        if publisher
            .publish_direct(sender, recipient, &message)
            .await
            .is_err()
        {
            eprintln!("direct message delivery unavailable");
        }
        direct_read::publish(state, sender, conversation, read_advance).await;
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_attachment_only_with_safe_reply_id_and_preserves_order() {
        let input = Input::parse(&json!({"content":" \u{feff}","media_ids":[12,11],"reply_to_message_id":9007199254740991_i64})).unwrap();
        assert_eq!(input.content, "");
        assert_eq!(input.media, [12, 11]);
        assert_eq!(input.reply, Some(9007199254740991));
        assert_eq!(input.stored_content(), " ");
    }

    #[test]
    fn rejects_duplicate_out_of_range_and_malformed_attachment_ids() {
        for ids in [
            json!([1, 1]),
            json!([0]),
            json!([9007199254740992_i64]),
            json!(["1"]),
            json!(null),
        ] {
            assert!(Input::parse(&json!({"content":"body","media_ids":ids})).is_err());
        }
        assert!(Input::parse(&json!({"media_ids":[]})).is_err());
        assert!(Input::parse(&json!({"content":"x","reply_to_message_id":0})).is_err());
        assert!(
            Input::parse(&json!({"content":"x","reply_to_message_id":null}))
                .unwrap()
                .plain_content()
                .is_some()
        );
        assert!(Input::parse(&json!({"content":"你".repeat(1334)})).is_err());
    }
}
