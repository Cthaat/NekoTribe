use crate::{
    auth::{
        session_list::{session_pagination, SessionPage},
        session_repository::{
            nullable_text, profile_date, public_profile_json, row_number, row_text,
            PUBLIC_PROFILE_SQL,
        },
        sessions::NativeState,
        storage_urls::StorageUrlPolicy,
    },
    db::{
        oracle::{BindMap, DbError},
        value::DbValue,
    },
    direct_history::query,
    httpx::errors::ApiError,
};
use axum::{
    extract::{OriginalUri, Path, State},
    http::{header::CACHE_CONTROL, HeaderMap, HeaderValue},
    response::{IntoResponse, Response},
    Json,
};
use serde_json::{json, Value};

pub struct Request {
    pub page: SessionPage,
    pub role: String,
    pub status: String,
}

pub enum Outcome {
    Found(Vec<Value>, u64),
    Forbidden,
    Missing,
    ProfileMissing,
}

const MEMBERS: &str = "WITH group_scope AS (
  SELECT g.group_id, CASE
    WHEN viewer.status='banned' THEN 0
    WHEN viewer.status='active' AND viewer.role IN ('owner','admin','moderator') THEN 2
    WHEN g.privacy='public' OR viewer.status IN ('active','muted') THEN 1
    ELSE 0 END AS access_level
  FROM n_groups g
  LEFT JOIN n_group_members viewer ON viewer.group_id=g.group_id AND viewer.user_id=:viewer_id
  WHERE g.group_id=:group_id AND g.is_active=1 AND g.is_deleted=0
), eligible AS (
  SELECT m.member_id,m.user_id,m.role,m.role_desc,m.status,m.nickname,m.joined_at,
    CASE WHEN s.access_level=2 OR m.user_id=:viewer_id THEN m.mute_until END AS mute_until,
    ROW_NUMBER() OVER (ORDER BY CASE m.role WHEN 'owner' THEN 1 WHEN 'admin' THEN 2
      WHEN 'moderator' THEN 3 ELSE 4 END,m.joined_at ASC,m.member_id ASC) AS rn
  FROM group_scope s
  JOIN v_group_member_details m ON m.group_id=s.group_id
  JOIN v_user_profile_public p ON p.user_id=m.user_id AND p.is_active=1
  WHERE s.access_level>0
    AND (s.access_level=2 OR m.status IN ('active','muted'))
    AND (:role_filter IS NULL OR m.role=:role_filter)
    AND (:status_filter IS NULL OR m.status=:status_filter)
)
SELECT s.access_level,c.total,m.member_id,m.user_id,m.role,m.role_desc,m.status,m.nickname,m.joined_at,m.mute_until
FROM group_scope s
CROSS JOIN (SELECT COUNT(*) AS total FROM eligible) c
LEFT JOIN eligible m ON m.rn BETWEEN :start_row AND :end_row
ORDER BY m.rn";

pub(crate) fn execute(
    conn: &oracle::Connection,
    viewer: u64,
    group: u64,
    request: Request,
    storage: &StorageUrlPolicy,
) -> Result<Outcome, DbError> {
    let bind_id = |id| {
        i64::try_from(id)
            .map(DbValue::I64)
            .map_err(|_| DbError::SchemaNotReady)
    };
    let viewer = bind_id(viewer)?;
    let rows = query(
        conn,
        MEMBERS,
        BindMap::from([
            ("viewer_id".into(), viewer.clone()),
            ("group_id".into(), bind_id(group)?),
            ("role_filter".into(), DbValue::String(request.role)),
            ("status_filter".into(), DbValue::String(request.status)),
            ("start_row".into(), DbValue::F64(request.page.start)),
            ("end_row".into(), DbValue::F64(request.page.end)),
        ]),
    )?;
    let Some(scope) = rows.first() else {
        return Ok(Outcome::Missing);
    };
    if row_number(scope, "ACCESS_LEVEL") == 0 {
        return Ok(Outcome::Forbidden);
    }
    let total = u64::try_from(row_number(scope, "TOTAL")).map_err(|_| DbError::SchemaNotReady)?;
    let mut items = Vec::with_capacity(rows.len());
    for row in &rows {
        let Some(member) = row.get("MEMBER_ID").and_then(DbValue::as_i64) else {
            continue;
        };
        let profiles = query(
            conn,
            PUBLIC_PROFILE_SQL,
            BindMap::from([
                ("viewer_id".into(), viewer.clone()),
                ("user_id".into(), DbValue::I64(row_number(row, "USER_ID"))),
            ]),
        )?;
        let Some(profile) = profiles.first() else {
            return Ok(Outcome::ProfileMissing);
        };
        let mut user = public_profile_json(profile);
        user["avatar_url"] = storage
            .normalize_avatar(user["avatar_url"].as_str().unwrap_or_default())
            .map_err(|_| DbError::SchemaNotReady)?
            .into();
        let date = |key| nullable_text(row, key).map(|value| profile_date(&value));
        items.push(json!({
            "member_id":member,
            "user":user,
            "role":row_text(row,"ROLE"),
            "role_desc":row_text(row,"ROLE_DESC"),
            "status":row_text(row,"STATUS"),
            "nickname":nullable_text(row,"NICKNAME").filter(|v| !v.is_empty()),
            "mute_until":date("MUTE_UNTIL"),
            "joined_at":date("JOINED_AT").unwrap_or_default()
        }));
    }
    Ok(Outcome::Found(items, total))
}

fn parse_request(raw: &str) -> Result<Request, ApiError> {
    let url = reqwest::Url::parse(&format!("http://localhost/?{raw}")).expect("fixed URL");
    let filter = |key: &str, choices: &[&str]| {
        let mut values = url.query_pairs().filter(|(name, _)| name == key);
        let value = values.next().map(|(_, value)| value).unwrap_or_default();
        if values.next().is_some() || (!value.is_empty() && !choices.contains(&value.as_ref())) {
            return Err(ApiError::bad_request(format!("{key} 参数错误")));
        }
        Ok(value.into_owned())
    };
    Ok(Request {
        page: session_pagination(raw),
        role: filter("role", &["owner", "admin", "moderator", "member"])?,
        status: filter("status", &["pending", "active", "muted", "banned"])?,
    })
}

pub(crate) async fn list(
    State(state): State<NativeState>,
    Path(raw_id): Path<String>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
) -> Response {
    let result = async {
        let (viewer, group) = crate::posts::bookmark::interaction_identity(&state, &raw_id, &headers).await?;
        let request = parse_request(uri.query().unwrap_or_default())?;
        let page = request.page;
        let (items, total) = match state.repository.list_group_members(viewer, group, request, &state.storage_urls)
            .await.map_err(|_| ApiError::server_error("服务器内部错误"))? {
            Outcome::Found(items, total) => (items, total),
            Outcome::Forbidden => return Err(ApiError::forbidden("无权查看群组成员")),
            Outcome::Missing => return Err(ApiError::not_found("群组不存在")),
            Outcome::ProfileMissing => return Err(ApiError::not_found("用户不存在")),
        };
        Ok(Json(json!({"code":200, "message":"success", "data":items, "meta":{
            "page":page.page, "page_size":page.page_size, "total":total, "has_next":page.end < total as f64
        }})))
    }.await;
    let mut response = result.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}
