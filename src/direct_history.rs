use crate::{
    auth::{
        session_list::{SessionPage, session_pagination},
        session_repository::{
            nullable_text, profile_date, public_profile_json, row_number, row_text,
        },
        sessions::NativeState,
    },
    chat_message_search::{Scope, Search},
    db::{
        oracle::{BindMap, DbError, bind_refs, bind_values},
        row::{DbRow, oracle_row_to_db_row},
        tx::OracleTx,
        value::DbValue,
    },
    direct_read::{self, ReadAdvance},
    httpx::errors::ApiError,
};
use axum::{
    Json,
    extract::{OriginalUri, Path, State},
    http::{HeaderMap, HeaderValue, header::CACHE_CONTROL},
    response::{IntoResponse, Response},
};
use serde_json::{Value, json};

pub struct HistoryPage {
    pub messages: Vec<Value>,
    pub total: u64,
    pub advance: Option<ReadAdvance>,
}

pub type DirectHistory = Option<HistoryPage>;
const COUNT: &str = "SELECT COUNT(*) AS total FROM n_direct_messages dm
JOIN v_user_profile_public u ON u.user_id=dm.sender_id
WHERE dm.conversation_id=:conversation_id AND dm.is_deleted=0{search}";
const PAGE: &str = "SELECT * FROM (
    SELECT dm.message_id,dm.conversation_id,dm.sender_id AS user_id,dm.content,dm.is_deleted,
        dm.created_at,dm.updated_at,dm.edited_at,dm.deleted_at,
        u.username,u.avatar_url,u.display_name,u.bio,u.location,u.website,u.is_verified,
        u.followers_count,u.following_count,u.posts_count,u.likes_count,
        fn_get_user_relationship(:viewer_id,u.user_id) AS relation,
        ROW_NUMBER() OVER (ORDER BY dm.created_at DESC,dm.message_id DESC) AS rn
    FROM n_direct_messages dm JOIN v_user_profile_public u ON u.user_id=dm.sender_id
    WHERE dm.conversation_id=:conversation_id AND dm.is_deleted=0{search}
) WHERE rn BETWEEN :start_row AND :end_row ORDER BY created_at ASC,message_id ASC";

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
    let content = row_text(row, "CONTENT");
    json!({
        "message_id": row_number(row, "MESSAGE_ID"),
        "conversation_id": row_number(row, "CONVERSATION_ID"),
        "content": crate::direct_extras::visible_content(&content),
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
    mark_read: bool,
    search: &Search,
) -> Result<DirectHistory, DbError> {
    let viewer = i64::try_from(viewer).map_err(|_| DbError::SchemaNotReady)?;
    let conversation = i64::try_from(conversation).map_err(|_| DbError::SchemaNotReady)?;
    let tx = OracleTx::new(connection);
    let result = (|| {
        let Some(recipient) = crate::direct_send::locked_recipient(&tx, viewer, conversation)?
        else {
            return Ok(None);
        };
        let mut binds = BindMap::from([("conversation_id".into(), DbValue::I64(conversation))]);
        let predicates = search.predicates(Scope::Direct, &mut binds);
        let count = query(
            connection,
            &COUNT.replace("{search}", &predicates),
            binds.clone(),
        )?;
        let total = count
            .first()
            .map(|row| row_number(row, "TOTAL"))
            .and_then(|n| u64::try_from(n).ok())
            .ok_or(DbError::SchemaNotReady)?;
        binds.extend([
            ("viewer_id".into(), DbValue::I64(viewer)),
            ("start_row".into(), DbValue::F64(page.start)),
            ("end_row".into(), DbValue::F64(page.end)),
        ]);
        let rows = query(connection, &PAGE.replace("{search}", &predicates), binds)?;
        let mut messages: Vec<_> = rows.iter().map(|row| map_message(row, viewer)).collect();
        if !messages.is_empty() && crate::direct_extras::metadata_ready(connection, true)? {
            crate::direct_extras::enrich(&tx, viewer, &mut messages)?;
        }
        let mut advance = None;
        if mark_read && search.is_empty() && page.page == 1.0 {
            if let Some(last) = rows.last() {
                let message = u64::try_from(row_number(last, "MESSAGE_ID"))
                    .map_err(|_| DbError::SchemaNotReady)?;
                if direct_read::advance(&tx, viewer, conversation, message)? {
                    advance = Some(ReadAdvance { recipient, message });
                }
            }
        }
        Ok(Some(HistoryPage {
            messages,
            total,
            advance,
        }))
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
    let search = Search::parse(query)?;
    let mark_read = mark_read_option(query)? && search.is_empty();
    let HistoryPage {
        mut messages,
        total,
        advance,
    } = state
        .repository
        .list_direct_history(user, conversation, page, mark_read, search)
        .await
        .map_err(|_| internal_error())?
        .ok_or_else(|| ApiError::forbidden("无权访问该私聊会话"))?;
    direct_read::publish(state, user, conversation, advance).await;
    for message in &mut messages {
        normalize_author(message, &state.storage_urls).map_err(|_| internal_error())?;
    }
    Ok(Json(json!({
        "code": 200, "message": "success", "data": messages,
        "meta": {"page": page.page, "page_size": page.page_size, "total": total, "has_next": page.end < total as f64}
    })))
}

fn mark_read_option(query: &str) -> Result<bool, ApiError> {
    let invalid = || ApiError::bad_request("mark_read 参数错误");
    let uri = reqwest::Url::parse(&format!("http://localhost/?{query}")).map_err(|_| invalid())?;
    let mut options = uri.query_pairs().filter(|(key, _)| key == "mark_read");
    let value = match options.next().as_ref().map(|(_, value)| value.as_ref()) {
        None | Some("true") => true,
        Some("false") => false,
        _ => return Err(invalid()),
    };
    if options.next().is_some() {
        return Err(invalid());
    }
    Ok(value)
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

#[cfg(test)]
mod tests {
    use super::mark_read_option;

    #[test]
    fn legacy_history_marks_unless_explicitly_disabled() {
        assert!(mark_read_option("page=1").unwrap());
        assert!(mark_read_option("mark_read=true").unwrap());
        assert!(!mark_read_option("mark_read=false&page=1").unwrap());
        assert!(mark_read_option("mark_read=invalid").is_err());
        assert!(mark_read_option("mark_read=false&mark_read=true").is_err());
    }
}
