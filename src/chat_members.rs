use crate::{
    auth::{
        session_repository::{nullable_text, profile_date, row_text},
        sessions::NativeState,
        storage_urls::StorageUrlPolicy,
    },
    db::{
        oracle::{BindMap, DbError},
        row::DbRow,
        value::DbValue,
    },
    direct_history::query,
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    extract::{Path, State},
    http::{header::CACHE_CONTROL, HeaderMap, HeaderValue},
    response::{IntoResponse, Response},
    Json,
};
use serde_json::{json, Value};

const MEMBERS: &str = "SELECT gm.user_id,gm.username,COALESCE(gm.nickname,gm.display_name,gm.username) AS display_name,
gm.avatar_url,gm.role,gm.status,
CASE WHEN NVL(us.show_online_status,1)=0 THEN 'hidden'
 WHEN EXISTS (SELECT 1 FROM n_auth_sessions s WHERE s.user_id=gm.user_id
 AND s.revoked_at IS NULL AND s.last_accessed_at>=CURRENT_TIMESTAMP-NUMTODSINTERVAL(90,'SECOND')) THEN 'online'
 ELSE 'offline' END AS online_status,
CASE WHEN NVL(us.show_online_status,1)=0 THEN NULL ELSE
 (SELECT MAX(s.last_accessed_at) FROM n_auth_sessions s WHERE s.user_id=gm.user_id AND s.revoked_at IS NULL)
 END AS last_seen_at
FROM n_group_members viewer
JOIN n_groups g ON g.group_id=viewer.group_id AND g.is_active=1 AND g.is_deleted=0
LEFT JOIN v_group_member_details gm ON gm.group_id=g.group_id AND gm.status IN ('active','muted')
LEFT JOIN n_user_settings us ON us.user_id=gm.user_id
WHERE viewer.group_id=:group_id AND viewer.user_id=:user_id AND viewer.status IN ('active','muted')
ORDER BY CASE gm.role WHEN 'owner' THEN 1 WHEN 'admin' THEN 2 WHEN 'moderator' THEN 3 ELSE 4 END,
gm.joined_at ASC,gm.user_id ASC";

fn map_member(row: &DbRow, storage: &StorageUrlPolicy) -> Result<Option<Value>, DbError> {
    let Some(id) = row.get("USER_ID").and_then(DbValue::as_i64) else {
        return Ok(None);
    };
    let online = match row_text(row, "ONLINE_STATUS").as_str() {
        "online" => "online",
        "hidden" => "hidden",
        _ => "offline",
    };
    let seen = if online == "hidden" {
        None
    } else {
        nullable_text(row, "LAST_SEEN_AT").map(|value| profile_date(&value))
    };
    let avatar = nullable_text(row, "AVATAR_URL")
        .filter(|value| !value.is_empty())
        .map(|value| {
            storage
                .normalize_avatar(&value)
                .map_err(|_| DbError::SchemaNotReady)
        })
        .transpose()?;
    Ok(Some(json!({
        "user_id":id,"username":row_text(row,"USERNAME"),"display_name":row_text(row,"DISPLAY_NAME"),
        "avatar_url":avatar,"role":row_text(row,"ROLE"),"status":row_text(row,"STATUS"),
        "online_status":online,"last_seen_at":seen
    })))
}

pub(crate) fn execute(
    conn: &oracle::Connection,
    user: u64,
    group: u64,
    storage: &StorageUrlPolicy,
) -> Result<Option<Vec<Value>>, DbError> {
    let bind = |id| {
        i64::try_from(id)
            .map(DbValue::I64)
            .map_err(|_| DbError::SchemaNotReady)
    };
    let rows = query(
        conn,
        MEMBERS,
        BindMap::from([
            ("group_id".into(), bind(group)?),
            ("user_id".into(), bind(user)?),
        ]),
    )?;
    if rows.is_empty() {
        return Ok(None);
    }
    let mut members = Vec::with_capacity(rows.len());
    for row in &rows {
        if let Some(member) = map_member(row, storage)? {
            members.push(member);
        }
    }
    Ok(Some(members))
}

pub(crate) async fn list(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
) -> Response {
    let result = async {
        let (user, group) =
            crate::posts::bookmark::interaction_identity(&state, &raw, &headers).await?;
        let items = state
            .repository
            .list_chat_members(user, group, &state.storage_urls)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?
            .ok_or_else(|| ApiError::forbidden("无权访问该群组聊天"))?;
        Ok::<_, ApiError>(Json(V2Response::ok(items)))
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
    fn hides_last_seen_even_when_supplied_and_skips_empty_member_rows() {
        let storage = StorageUrlPolicy::default();
        let row = DbRow::from([
            ("USER_ID".into(), DbValue::I64(7)),
            ("ONLINE_STATUS".into(), DbValue::String("hidden".into())),
            (
                "LAST_SEEN_AT".into(),
                DbValue::String("2026-11-13T08:00:00Z".into()),
            ),
        ]);
        let member = map_member(&row, &storage).unwrap().unwrap();
        assert_eq!(member["online_status"], "hidden");
        assert_eq!(member["last_seen_at"], Value::Null);
        assert!(map_member(&DbRow::new(), &storage).unwrap().is_none());
    }
}
