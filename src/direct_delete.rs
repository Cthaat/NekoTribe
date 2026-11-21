use crate::{
    auth::{session_repository::row_number, sessions::NativeState},
    db::{
        oracle::{BindMap, DbError},
        tx::OracleTx,
        value::DbValue,
    },
    direct_history::{conversation_id, query},
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    extract::{Path, State},
    http::HeaderMap,
    Json,
};
use serde_json::Value;
use std::sync::OnceLock;

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct Statements {
    lock_conversation: String,
    lock_message: String,
    delete_message: String,
    refresh_conversation: String,
    redact_notification: String,
}

pub enum DirectDelete {
    Deleted { recipient: u64 },
    AlreadyDeleted,
    ConversationForbidden,
    MessageForbidden,
    MessageMissing,
}

pub(crate) fn execute(
    connection: &oracle::Connection,
    user: u64,
    conversation: u64,
    message: u64,
) -> Result<DirectDelete, DbError> {
    static STATEMENTS: OnceLock<Statements> = OnceLock::new();
    let sql = STATEMENTS.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../contracts/requirements/direct-message-delete.json"
        ))
        .expect("valid direct message delete contract")
    });
    let bind = |name: &str, value: u64| (name.to_owned(), DbValue::I64(value as i64));
    let actor = || bind("user_id", user);
    let conversation = || bind("conversation_id", conversation);
    let message = || bind("message_id", message);
    let tx = OracleTx::new(connection);
    let action = (|| {
        let members = query(
            connection,
            &sql.lock_conversation,
            BindMap::from([conversation(), actor()]),
        )?;
        let Some(member) = members.first() else {
            return Ok(DirectDelete::ConversationForbidden);
        };
        let recipient = row_number(member, "RECIPIENT");
        if recipient <= 0
            || recipient as u64 == user
            || recipient as u64 > crate::notification_websocket::MAX_SOCKET_ID
        {
            return Err(DbError::SchemaNotReady);
        }
        let rows = query(
            connection,
            &sql.lock_message,
            BindMap::from([conversation(), message()]),
        )?;
        let Some(row) = rows.first() else {
            return Ok(DirectDelete::MessageMissing);
        };
        if row_number(row, "SENDER_ID") != user as i64 {
            return Ok(DirectDelete::MessageForbidden);
        }
        if row_number(row, "IS_DELETED") == 1 {
            return Ok(DirectDelete::AlreadyDeleted);
        }
        if tx
            .execute(
                &sql.delete_message,
                BindMap::from([conversation(), message(), actor()]),
            )?
            .rows_affected
            != 1
            || tx
                .execute(&sql.refresh_conversation, BindMap::from([conversation()]))?
                .rows_affected
                != 1
        {
            return Err(DbError::SchemaNotReady);
        }
        tx.execute(
            &sql.redact_notification,
            BindMap::from([message(), actor()]),
        )?;
        Ok(DirectDelete::Deleted {
            recipient: recipient as u64,
        })
    })();
    match action {
        Ok(deleted @ DirectDelete::Deleted { .. }) => {
            if let Err(error) = tx.commit() {
                let _ = tx.rollback();
                return Err(error);
            }
            Ok(deleted)
        }
        other => {
            tx.rollback()?;
            other
        }
    }
}

pub(crate) async fn remove(
    State(state): State<NativeState>,
    Path((conversation, message)): Path<(String, String)>,
    headers: HeaderMap,
) -> Result<Json<V2Response<Value>>, ApiError> {
    let user = crate::posts::bookmark::interaction_actor(&state, &headers).await?;
    let conversation = conversation_id(&conversation)?;
    let message =
        conversation_id(&message).map_err(|_| ApiError::bad_request("message_id 参数错误"))?;
    let result = state
        .repository
        .delete_direct_message(user, conversation, message)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    if let DirectDelete::Deleted { recipient } = &result {
        if let Some(publisher) = &state.notification_publisher {
            if publisher
                .publish_direct_deleted(user, *recipient, conversation, message)
                .await
                .is_err()
            {
                tracing::warn!("direct deletion delivery unavailable");
            }
        }
    }
    match result {
        DirectDelete::Deleted { .. } | DirectDelete::AlreadyDeleted => Ok(Json(
            V2Response::ok_with_message(Value::Null, "direct message deleted"),
        )),
        DirectDelete::ConversationForbidden => Err(ApiError::forbidden("无权访问该私聊会话")),
        DirectDelete::MessageForbidden => Err(ApiError::forbidden("无权删除该私信")),
        DirectDelete::MessageMissing => Err(ApiError::not_found("私信不存在")),
    }
}
