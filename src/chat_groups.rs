use crate::{
    auth::{
        session_list::{session_pagination, SessionPage},
        session_repository::{nullable_text, profile_date, row_number, row_text},
        sessions::NativeState,
    },
    db::{
        oracle::{BindMap, DbError},
        value::DbValue,
    },
    direct_history::query,
    httpx::errors::ApiError,
};
use axum::{
    extract::{OriginalUri, State},
    http::{header::CACHE_CONTROL, HeaderMap, HeaderValue},
    response::{IntoResponse, Response},
    Json,
};
use serde_json::{json, Value};

const MEMBERSHIP: &str = " FROM n_group_members gm JOIN n_groups g ON g.group_id=gm.group_id
WHERE gm.user_id=:user_id AND gm.status IN ('active','muted') AND g.is_active=1 AND g.is_deleted=0";
const VISIBLE: &str = "c.group_id=r.group_id AND c.is_deleted=0
AND (c.is_private=0 OR r.role IN ('owner','admin','moderator'))";

pub(crate) fn execute(
    connection: &oracle::Connection,
    viewer: u64,
    page: SessionPage,
) -> Result<(Vec<Value>, u64), DbError> {
    let viewer = i64::try_from(viewer).map_err(|_| DbError::SchemaNotReady)?;
    let mut binds = BindMap::from([("user_id".into(), DbValue::I64(viewer))]);
    let sql = format!("WITH ranked AS (
        SELECT g.group_id,g.name,g.avatar_url,g.member_count,gm.role,gm.status,gm.joined_at,
        ROW_NUMBER() OVER (ORDER BY g.member_count DESC,g.created_at DESC,g.group_id DESC) AS rn
        {MEMBERSHIP})
        SELECT r.*, CASE WHEN r.role IN ('owner','admin','moderator') THEN 1 ELSE 0 END AS can_manage,
        (SELECT COUNT(*) FROM n_chat_channels c WHERE {VISIBLE}) AS channel_count,
        (SELECT COUNT(*) FROM n_chat_messages m JOIN n_chat_channels c ON c.channel_id=m.channel_id
         LEFT JOIN n_chat_channel_reads cr ON cr.channel_id=c.channel_id AND cr.user_id=:user_id
         WHERE {VISIBLE} AND m.is_deleted=0 AND m.message_id>NVL(cr.last_read_message_id,0)) AS unread_count,
        t.total FROM (SELECT COUNT(*) AS total FROM ranked) t
        LEFT JOIN ranked r ON r.rn BETWEEN :start_row AND :end_row ORDER BY r.rn");
    binds.extend([
        ("start_row".into(), DbValue::F64(page.start)),
        ("end_row".into(), DbValue::F64(page.end)),
    ]);
    let rows = query(connection, &sql, binds)?;
    let total = rows
        .first()
        .and_then(|row| row.get("TOTAL"))
        .and_then(DbValue::as_i64)
        .and_then(|n| u64::try_from(n).ok())
        .ok_or(DbError::SchemaNotReady)?;
    let items = rows.iter().filter(|row| row_number(row, "GROUP_ID") > 0).map(|row| json!({
        "group_id":row_number(row,"GROUP_ID"),"name":row_text(row,"NAME"),"avatar_url":nullable_text(row,"AVATAR_URL"),
        "member_count":row_number(row,"MEMBER_COUNT"),"channel_count":row_number(row,"CHANNEL_COUNT"),
        "unread_count":row_number(row,"UNREAD_COUNT"),
        "membership":{"is_member":true,"role":row_text(row,"ROLE"),"status":row_text(row,"STATUS"),
            "joined_at":nullable_text(row,"JOINED_AT").map(|value| profile_date(&value)),
            "can_manage":row_number(row,"CAN_MANAGE")==1}
    })).collect();
    Ok((items, total))
}

pub(crate) async fn list(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
) -> Response {
    let result = async {
        let viewer = crate::posts::bookmark::interaction_actor(&state, &headers).await?;
        let page = session_pagination(uri.query().unwrap_or_default());
        let (data, total) = state.repository.list_chat_groups(viewer, page).await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?;
        Ok::<_, ApiError>(Json(json!({"code":200,"message":"success","data":data,
            "meta":{"page":page.page,"page_size":page.page_size,"total":total,"has_next":page.end < total as f64}})))
    }.await;
    let mut response = result.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}
