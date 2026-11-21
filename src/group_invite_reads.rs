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
    group_detail::{self, GroupDetail, GroupLookup},
    httpx::errors::ApiError,
};
use axum::{
    extract::{OriginalUri, Path, State},
    http::{header::CACHE_CONTROL, HeaderMap, HeaderValue},
    response::{IntoResponse, Response},
    Json,
};
use serde_json::{json, Value};

pub enum Request {
    List(u64, SessionPage, String),
    Inbox(SessionPage, u64),
    Preview(String),
}

pub enum Outcome {
    List(Vec<Value>, u64),
    Preview(Value),
    GroupMissing,
    UserMissing,
    Forbidden,
    CodeMissing,
    CodeInvalid,
}

const LIST:&str="WITH invite_scope AS (
 SELECT g.group_id,g.description,
 CASE WHEN m.status='active' AND m.role IN ('owner','admin','moderator') THEN 1 ELSE 0 END AS allowed
 FROM n_groups g LEFT JOIN n_group_members m ON m.group_id=g.group_id AND m.user_id=:viewer_id
 WHERE g.group_id=:group_id AND g.is_active=1 AND g.is_deleted=0
), eligible AS (
 SELECT v.invite_id,v.invite_code,v.status,v.message,v.max_uses,v.used_count,v.expires_at,v.created_at,
 v.group_id,v.group_name,v.group_slug,s.description AS group_description,v.group_avatar_url,v.group_privacy,
 v.group_member_count,v.inviter_id,v.invitee_id,v.is_valid,
 ROW_NUMBER() OVER (ORDER BY v.created_at DESC,v.invite_id DESC) AS rn
 FROM invite_scope s JOIN v_group_invite_details v ON v.group_id=s.group_id
 WHERE s.allowed=1 AND (:status_filter IS NULL OR v.status=:status_filter)
)
SELECT s.allowed,t.total,e.invite_id,e.invite_code,e.status,e.message,e.max_uses,e.used_count,
 e.expires_at,e.created_at,e.group_id,e.group_name,e.group_slug,e.group_description,e.group_avatar_url,
 e.group_privacy,e.group_member_count,e.inviter_id,e.invitee_id,e.is_valid
FROM invite_scope s CROSS JOIN (SELECT COUNT(*) AS total FROM eligible) t
LEFT JOIN eligible e ON e.rn BETWEEN :start_row AND :end_row
ORDER BY e.rn";
const INBOX: &str = "WITH eligible AS (\n SELECT v.invite_id,v.invite_code,v.status,v.message,v.max_uses,v.used_count,v.expires_at,v.created_at,\n v.group_id,v.group_name,v.group_slug,g.description AS group_description,v.group_avatar_url,v.group_privacy,\n v.group_member_count,v.inviter_id,v.invitee_id,1 AS is_valid,\n ROW_NUMBER() OVER (ORDER BY v.created_at DESC,v.invite_id DESC) AS rn\n FROM v_group_invite_details v JOIN n_groups g ON g.group_id=v.group_id\n WHERE v.invitee_id=:viewer_id AND v.status='pending' AND g.is_active=1 AND g.is_deleted=0\n AND (:invite_id=0 OR v.invite_id=:invite_id)\n AND (v.max_uses IS NULL OR NVL(v.used_count,0)<v.max_uses)\n AND (v.expires_at IS NULL OR v.expires_at>=SYSTIMESTAMP)\n)\nSELECT 1 AS allowed,t.total,e.invite_id,e.invite_code,e.status,e.message,e.max_uses,e.used_count,\n e.expires_at,e.created_at,e.group_id,e.group_name,e.group_slug,e.group_description,e.group_avatar_url,\n e.group_privacy,e.group_member_count,e.inviter_id,e.invitee_id,e.is_valid\nFROM (SELECT COUNT(*) AS total FROM eligible) t\nLEFT JOIN eligible e ON e.rn BETWEEN :start_row AND :end_row\nORDER BY e.rn";
const PREVIEW: &str = "SELECT v.group_id,v.inviter_id,v.message,
 CASE WHEN g.is_active=1 AND g.is_deleted=0 THEN v.is_valid ELSE 0 END AS is_valid
FROM v_group_invite_details v JOIN n_groups g ON g.group_id=v.group_id
WHERE v.invite_code=:invite_code AND (v.invitee_id IS NULL OR v.invitee_id=:viewer_id)
ORDER BY v.invite_id ASC FETCH FIRST 2 ROWS ONLY";

fn profile(
    conn: &oracle::Connection,
    viewer: i64,
    user: i64,
    storage: &StorageUrlPolicy,
) -> Result<Option<Value>, DbError> {
    let rows = query(
        conn,
        PUBLIC_PROFILE_SQL,
        BindMap::from([
            ("viewer_id".into(), DbValue::I64(viewer)),
            ("user_id".into(), DbValue::I64(user)),
        ]),
    )?;
    rows.first()
        .map(|row| {
            let mut profile = public_profile_json(row);
            let avatar = storage
                .normalize_avatar(profile["avatar_url"].as_str().unwrap_or_default())
                .map_err(|_| DbError::SchemaNotReady)?;
            profile["avatar_url"] = Value::String(avatar);
            Ok(profile)
        })
        .transpose()
}

fn map_list(
    conn: &oracle::Connection,
    actor: i64,
    rows: Vec<crate::db::row::DbRow>,
    storage: &StorageUrlPolicy,
) -> Result<Outcome, DbError> {
    let Some(scope) = rows.first() else {
        return Ok(Outcome::GroupMissing);
    };
    if row_number(scope, "ALLOWED") != 1 {
        return Ok(Outcome::Forbidden);
    }
    let count = u64::try_from(row_number(scope, "TOTAL")).map_err(|_| DbError::SchemaNotReady)?;
    let mut items = Vec::with_capacity(rows.len());
    for row in &rows {
        let Some(id) = row.get("INVITE_ID").and_then(DbValue::as_i64) else {
            continue;
        };
        let Some(inviter) = profile(conn, actor, row_number(row, "INVITER_ID"), storage)? else {
            return Ok(Outcome::UserMissing);
        };
        let invitee = if let Some(invitee) = row.get("INVITEE_ID").and_then(DbValue::as_i64) {
            let Some(value) = profile(conn, actor, invitee, storage)? else {
                return Ok(Outcome::UserMissing);
            };
            Some(value)
        } else {
            None
        };
        let date = |key| nullable_text(row, key).map(|d| profile_date(&d));
        items.push(json!({
            "invite_id":id,"invite_code":nullable_text(row,"INVITE_CODE"),"status":row_text(row,"STATUS"),
            "message":nullable_text(row,"MESSAGE"),"max_uses":row.get("MAX_USES").and_then(DbValue::as_i64),
            "used_count":row_number(row,"USED_COUNT"),"expires_at":date("EXPIRES_AT"),
            "created_at":date("CREATED_AT").unwrap_or_default(),
            "group":{"group_id":row_number(row,"GROUP_ID"),"name":row_text(row,"GROUP_NAME"),
                "slug":row_text(row,"GROUP_SLUG"),"description":row_text(row,"GROUP_DESCRIPTION"),
                "avatar_url":nullable_text(row,"GROUP_AVATAR_URL"),"privacy":row_text(row,"GROUP_PRIVACY"),
                "member_count":row_number(row,"GROUP_MEMBER_COUNT")},
            "inviter":inviter,"invitee":invitee,"is_valid":row_number(row,"IS_VALID")==1
        }));
    }
    Ok(Outcome::List(items, count))
}

pub(crate) fn execute(
    conn: &oracle::Connection,
    viewer: u64,
    request: Request,
    storage: &StorageUrlPolicy,
) -> Result<Outcome, DbError> {
    let actor = i64::try_from(viewer).map_err(|_| DbError::SchemaNotReady)?;
    let mut binds = BindMap::from([("viewer_id".into(), DbValue::I64(actor))]);
    match request {
        Request::List(group, page, status) => {
            binds.extend([
                (
                    "group_id".into(),
                    DbValue::I64(i64::try_from(group).map_err(|_| DbError::SchemaNotReady)?),
                ),
                ("start_row".into(), DbValue::F64(page.start)),
                ("status_filter".into(), DbValue::String(status)),
                ("end_row".into(), DbValue::F64(page.end)),
            ]);
            let rows = query(conn, LIST, binds)?;
            map_list(conn, actor, rows, storage)
        }
        Request::Inbox(page, invite_id) => {
            binds.extend([
                (
                    "invite_id".into(),
                    DbValue::I64(i64::try_from(invite_id).map_err(|_| DbError::SchemaNotReady)?),
                ),
                ("start_row".into(), DbValue::F64(page.start)),
                ("end_row".into(), DbValue::F64(page.end)),
            ]);
            map_list(conn, actor, query(conn, INBOX, binds)?, storage)
        }
        Request::Preview(code) => {
            binds.insert("invite_code".into(), DbValue::String(code));
            let rows = query(conn, PREVIEW, binds)?;
            let Some(row) = rows.first() else {
                return Ok(Outcome::CodeMissing);
            };
            if rows.len() != 1 || row_number(row, "IS_VALID") != 1 {
                return Ok(Outcome::CodeInvalid);
            }
            let group =
                u64::try_from(row_number(row, "GROUP_ID")).map_err(|_| DbError::SchemaNotReady)?;
            let group = match group_detail::execute(conn, viewer, GroupLookup::Id(group), storage)?
            {
                GroupDetail::Found(group) => group,
                GroupDetail::Missing => return Ok(Outcome::GroupMissing),
                GroupDetail::OwnerMissing => return Ok(Outcome::UserMissing),
            };
            if group["is_active"] != 1 {
                return Ok(Outcome::CodeInvalid);
            }
            let Some(inviter) = profile(conn, actor, row_number(row, "INVITER_ID"), storage)?
            else {
                return Ok(Outcome::UserMissing);
            };
            Ok(Outcome::Preview(
                json!({"is_valid":true,"group":group,"inviter":inviter,"message":nullable_text(row,"MESSAGE")}),
            ))
        }
    }
}

async fn read(state: &NativeState, viewer: u64, request: Request) -> Result<Json<Value>, ApiError> {
    let page = match &request {
        Request::List(_, page, _) | Request::Inbox(page, _) => Some(*page),
        _ => None,
    };
    match state
        .repository
        .read_group_invites(viewer, request, &state.storage_urls)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?
    {
        Outcome::List(items, total) => {
            let page = page.ok_or_else(|| ApiError::server_error("服务器内部错误"))?;
            Ok(Json(
                json!({"code":200,"message":"success","data":items,"meta":{
                    "page":page.page,"page_size":page.page_size,"total":total,"has_next":page.end < total as f64
                }}),
            ))
        }
        Outcome::Preview(value) => Ok(Json(
            json!({"code":200,"message":"success","data":value,"meta":null}),
        )),
        Outcome::GroupMissing => Err(ApiError::not_found("群组不存在")),
        Outcome::UserMissing => Err(ApiError::not_found("用户不存在")),
        Outcome::Forbidden => Err(ApiError::unprocessable("无权查看群组邀请")),
        Outcome::CodeMissing => Err(ApiError::not_found("邀请码不存在")),
        Outcome::CodeInvalid => Err(ApiError::unprocessable("邀请码无效或已过期")),
    }
}

fn no_store(result: Result<Json<Value>, ApiError>) -> Response {
    let mut response = result.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}

pub(crate) async fn list(
    State(state): State<NativeState>,
    Path(id): Path<String>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
) -> Response {
    no_store(
        async {
            let (viewer, group) =
                crate::posts::bookmark::interaction_identity(&state, &id, &headers).await?;
            let raw = uri.query().unwrap_or_default();
            let url = reqwest::Url::parse(&format!("http://localhost/?{raw}")).expect("fixed URL");
            let mut statuses = url.query_pairs().filter(|(name, _)| name == "status");
            let status = statuses.next().map(|(_, value)| value).unwrap_or_default();
            if statuses.next().is_some()
                || !matches!(
                    status.as_ref(),
                    "" | "pending" | "accepted" | "rejected" | "expired"
                )
            {
                return Err(ApiError::bad_request("status 参数错误"));
            }
            read(
                &state,
                viewer,
                Request::List(group, session_pagination(raw), status.into_owned()),
            )
            .await
        }
        .await,
    )
}

pub(crate) async fn preview(
    State(state): State<NativeState>,
    Path(code): Path<String>,
    headers: HeaderMap,
) -> Response {
    no_store(
        async {
            let viewer = crate::posts::bookmark::interaction_actor(&state, &headers).await?;
            let code = code
                .trim_matches(|c: char| (c.is_whitespace() && c != '\u{0085}') || c == '\u{feff}');
            if code.is_empty()
                || code.len() > 32
                || !code.bytes().all(|b| b.is_ascii_alphanumeric())
            {
                return Err(ApiError::bad_request("code 参数错误"));
            }
            read(&state, viewer, Request::Preview(code.to_ascii_uppercase())).await
        }
        .await,
    )
}

pub(crate) async fn inbox(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
) -> Response {
    no_store(
        async {
            let viewer = crate::posts::bookmark::interaction_actor(&state, &headers).await?;
            let raw_query = uri.query().unwrap_or_default();
            let page = session_pagination(raw_query);
            let mut url = reqwest::Url::parse("http://localhost/").expect("fixed URL");
            url.set_query(Some(raw_query));
            let mut ids = url.query_pairs().filter(|(key, _)| key == "invite_id");
            let invite = match (ids.next(), ids.next()) {
                (None, _) => 0,
                (Some((_, value)), None) => value
                    .parse::<u64>()
                    .ok()
                    .filter(|id| {
                        *id > 0
                            && *id <= crate::notification_websocket::MAX_SOCKET_ID
                            && id.to_string() == value
                    })
                    .ok_or_else(|| ApiError::bad_request("invite_id 参数错误"))?,
                _ => return Err(ApiError::bad_request("invite_id 参数错误")),
            };
            read(&state, viewer, Request::Inbox(page, invite)).await
        }
        .await,
    )
}
