use crate::{
    auth::{
        login::request_body,
        session_list::{session_pagination, SessionPage},
        session_repository::{
            nullable_text, profile_date, public_profile_json, row_number, row_text,
        },
        sessions::NativeState,
        storage_urls::StorageUrlPolicy,
    },
    db::{
        oracle::{BindMap, DbError},
        row::DbRow,
        tx::OracleTx,
        value::DbValue,
    },
    direct_history::{conversation_id, query},
    direct_send::{check_recipient, next_id, RecipientDenial},
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    body::{to_bytes, Body},
    extract::{OriginalUri, State},
    http::{header::CACHE_CONTROL, HeaderMap, HeaderValue, Request},
    response::{IntoResponse, Response},
    Json,
};
use serde_json::{json, Value};

pub enum ConversationCreation {
    Ready(Value),
    Denied(RecipientDenial),
    Deleted,
}

const PROJECTION: &str = "SELECT c.conversation_id,c.created_at,c.updated_at,
p.user_id,p.username,p.avatar_url,p.display_name,p.bio,p.location,p.website,p.is_verified,
p.followers_count,p.following_count,p.posts_count,p.likes_count,
fn_get_user_relationship(:viewer_id,p.user_id) AS relation,
lm.message_id AS last_message_id,lm.content AS last_message_content,
COALESCE(lu.display_name,lu.username) AS last_message_author,lm.created_at AS last_message_at,
(SELECT COUNT(*) FROM n_direct_messages dm
 LEFT JOIN n_direct_conversation_reads r ON r.conversation_id=dm.conversation_id AND r.user_id=:viewer_id
 WHERE dm.conversation_id=c.conversation_id AND dm.sender_id<>:viewer_id
 AND dm.is_deleted=0 AND dm.message_id>NVL(r.last_read_message_id,0)) AS unread_count";
const FROM: &str = " FROM n_direct_conversations c
JOIN v_user_profile_public p ON p.user_id=CASE WHEN c.user_low_id=:viewer_id THEN c.user_high_id ELSE c.user_low_id END
LEFT JOIN n_direct_messages lm ON lm.message_id=c.last_message_id AND lm.is_deleted=0
LEFT JOIN n_users lu ON lu.user_id=lm.sender_id
WHERE c.is_deleted=0 AND (c.user_low_id=:viewer_id OR c.user_high_id=:viewer_id)";
const PAIR: &str = "SELECT conversation_id,is_deleted FROM n_direct_conversations
WHERE user_low_id=:low_id AND user_high_id=:high_id";

fn map_conversation(row: &DbRow, storage: &StorageUrlPolicy) -> Result<Value, DbError> {
    let date = |key| {
        nullable_text(row, key)
            .map(|value| profile_date(&value))
            .unwrap_or_default()
    };
    let mut participant = public_profile_json(row);
    let avatar = storage
        .normalize_avatar(participant["avatar_url"].as_str().unwrap_or_default())
        .map_err(|_| DbError::SchemaNotReady)?;
    participant["avatar_url"] = avatar.into();
    let last = row_number(row, "LAST_MESSAGE_ID");
    let last_message = if last > 0 {
        json!({"message_id":last,"content":crate::direct_extras::visible_content(&row_text(row,"LAST_MESSAGE_CONTENT")),
            "author_name":row_text(row,"LAST_MESSAGE_AUTHOR"),"created_at":date("LAST_MESSAGE_AT")})
    } else {
        Value::Null
    };
    Ok(
        json!({"conversation_id":row_number(row,"CONVERSATION_ID"),"participant":participant,
        "unread_count":row_number(row,"UNREAD_COUNT"),"last_message":last_message,
        "created_at":date("CREATED_AT"),"updated_at":date("UPDATED_AT")}),
    )
}

pub(crate) fn list_rows(
    connection: &oracle::Connection,
    viewer: u64,
    conversation: u64,
    page: SessionPage,
    storage: &StorageUrlPolicy,
) -> Result<(Vec<Value>, u64), DbError> {
    let viewer = i64::try_from(viewer).map_err(|_| DbError::SchemaNotReady)?;
    let conversation = i64::try_from(conversation).map_err(|_| DbError::SchemaNotReady)?;
    let sql = format!(
        "WITH ranked AS ({PROJECTION},ROW_NUMBER() OVER
        (ORDER BY NVL(lm.created_at,c.updated_at) DESC,c.conversation_id DESC) AS rn{FROM}
        AND (:conversation_id=0 OR c.conversation_id=:conversation_id))
        SELECT r.*, t.total FROM (SELECT COUNT(*) AS total FROM ranked) t
        LEFT JOIN ranked r ON r.rn BETWEEN :start_row AND :end_row ORDER BY r.rn"
    );
    let rows = query(
        connection,
        &sql,
        BindMap::from([
            ("viewer_id".into(), DbValue::I64(viewer)),
            ("conversation_id".into(), DbValue::I64(conversation)),
            ("start_row".into(), DbValue::F64(page.start)),
            ("end_row".into(), DbValue::F64(page.end)),
        ]),
    )?;
    let total = rows
        .first()
        .and_then(|row| row.get("TOTAL"))
        .and_then(DbValue::as_i64)
        .and_then(|n| u64::try_from(n).ok())
        .ok_or(DbError::SchemaNotReady)?;
    let items = rows
        .iter()
        .filter(|row| row_number(row, "CONVERSATION_ID") > 0)
        .map(|row| map_conversation(row, storage))
        .collect::<Result<Vec<_>, _>>()?;
    Ok((items, total))
}

pub(crate) fn create_row(
    connection: &oracle::Connection,
    sender: u64,
    target: u64,
    storage: &StorageUrlPolicy,
) -> Result<ConversationCreation, DbError> {
    let sender = i64::try_from(sender).map_err(|_| DbError::SchemaNotReady)?;
    let target = i64::try_from(target).map_err(|_| DbError::SchemaNotReady)?;
    let tx = OracleTx::new(connection);
    let result = (|| {
        if let Some(denial) = check_recipient(connection, sender, target)? {
            return Ok(ConversationCreation::Denied(denial));
        }
        let pair = BindMap::from([
            ("low_id".into(), DbValue::I64(sender.min(target))),
            ("high_id".into(), DbValue::I64(sender.max(target))),
        ]);
        let read_pair = || -> Result<Option<(i64, bool)>, DbError> {
            let rows = query(connection, PAIR, pair.clone())?;
            Ok(rows.first().map(|row| {
                (
                    row_number(row, "CONVERSATION_ID"),
                    row_number(row, "IS_DELETED") != 0,
                )
            }))
        };
        let (id, deleted) = if let Some(existing) = read_pair()? {
            existing
        } else {
            let id = next_id(
                connection,
                "SELECT seq_direct_conversation_id.NEXTVAL AS id FROM dual",
            )?;
            let mut binds = pair.clone();
            binds.extend([
                ("conversation_id".into(), DbValue::I64(id)),
                ("sender_id".into(), DbValue::I64(sender)),
            ]);
            match tx.execute("INSERT INTO n_direct_conversations (conversation_id,user_low_id,user_high_id,created_by)
                VALUES (:conversation_id,:low_id,:high_id,:sender_id)", binds) {
                Ok(result) if result.rows_affected == 1 => (id, false),
                Ok(_) => return Err(DbError::SchemaNotReady),
                Err(error) if matches!(&error, DbError::Oracle(e) if e.db_error().is_some_and(|e| e.code() == 1)) =>
                    read_pair()?.ok_or(error)?,
                Err(error) => return Err(error),
            }
        };
        if deleted {
            return Ok(ConversationCreation::Deleted);
        }
        let sql = format!("{PROJECTION}{FROM} AND c.conversation_id=:conversation_id");
        let rows = query(
            connection,
            &sql,
            BindMap::from([
                ("viewer_id".into(), DbValue::I64(sender)),
                ("conversation_id".into(), DbValue::I64(id)),
            ]),
        )?;
        Ok(ConversationCreation::Ready(map_conversation(
            rows.first().ok_or(DbError::SchemaNotReady)?,
            storage,
        )?))
    })();
    match result {
        Ok(ready @ ConversationCreation::Ready(_)) => match tx.commit() {
            Ok(()) => Ok(ready),
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

fn private(response: impl IntoResponse) -> Response {
    let mut response = response.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}

pub(crate) async fn list(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
) -> Response {
    private(list_inner(&state, &headers, uri.query().unwrap_or_default()).await)
}

async fn list_inner(
    state: &NativeState,
    headers: &HeaderMap,
    raw_query: &str,
) -> Result<Json<Value>, ApiError> {
    let viewer = crate::posts::bookmark::interaction_actor(state, headers).await?;
    let page = session_pagination(raw_query);
    let conversation = conversation_filter(raw_query)?;
    let (data, total) = state
        .repository
        .list_direct_conversations(viewer, conversation, page, &state.storage_urls)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    Ok(Json(json!({"code":200,"message":"success","data":data,
        "meta":{"page":page.page,"page_size":page.page_size,"total":total,"has_next":page.end < total as f64}})))
}

fn conversation_filter(raw_query: &str) -> Result<u64, ApiError> {
    let url = reqwest::Url::parse(&format!("http://localhost/?{raw_query}")).expect("fixed URL");
    let mut ids = url.query_pairs().filter(|(key, _)| key == "conversation_id");
    match (ids.next(), ids.next()) {
        (None, _) => Ok(0),
        (Some((_, value)), None) => conversation_id(&value),
        _ => Err(ApiError::bad_request("conversation_id 参数错误")),
    }
}

#[test]
fn direct_conversation_filter_accepts_exactly_one_canonical_id() {
    assert_eq!(conversation_filter("page=2").unwrap(), 0);
    assert_eq!(conversation_filter("conversation_id=%37").unwrap(), 7);
    for query in ["conversation_id", "conversation_id=07", "conversation_id=7&conversation_id=7",
        "conversation_id=9007199254740992"] {
        assert!(conversation_filter(query).is_err());
    }
}

pub(crate) async fn create(State(state): State<NativeState>, request: Request<Body>) -> Response {
    private(create_inner(&state, request).await)
}

async fn create_inner(
    state: &NativeState,
    request: Request<Body>,
) -> Result<Json<V2Response<Value>>, ApiError> {
    let (parts, body) = request.into_parts();
    let viewer = crate::posts::bookmark::interaction_actor(state, &parts.headers).await?;
    let bytes = to_bytes(body, 1024 * 1024)
        .await
        .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
    let input = request_body(&parts.headers, &bytes)?;
    let target = match &input["target_user_id"] {
        Value::Number(number) => number
            .as_f64()
            .filter(|n| {
                *n >= 1.0
                    && *n <= crate::notification_websocket::MAX_SOCKET_ID as f64
                    && n.fract() == 0.0
            })
            .map(|n| n as u64),
        Value::String(raw) => conversation_id(raw).ok(),
        _ => None,
    }
    .ok_or_else(|| ApiError::bad_request("target_user_id 参数错误"))?;
    if viewer == target {
        return Err(ApiError::bad_request("不能给自己发送私信"));
    }
    match state
        .repository
        .create_direct_conversation(viewer, target, &state.storage_urls)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?
    {
        ConversationCreation::Ready(data) => Ok(Json(V2Response::ok_with_message(
            data,
            "direct conversation ready",
        ))),
        ConversationCreation::Deleted => Err(ApiError::conflict("私聊会话已删除")),
        ConversationCreation::Denied(RecipientDenial::Missing) => {
            Err(ApiError::not_found("用户不存在"))
        }
        ConversationCreation::Denied(RecipientDenial::Blocked) => {
            Err(ApiError::forbidden("无法向该用户发送私信"))
        }
        ConversationCreation::Denied(RecipientDenial::Strangers) => {
            Err(ApiError::forbidden("对方不接收陌生人私信"))
        }
    }
}
