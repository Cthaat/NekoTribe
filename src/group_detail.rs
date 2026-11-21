use crate::{
    auth::{
        session_repository::{
            nullable_text, profile_date, public_profile_json, row_number, row_text,
            PUBLIC_PROFILE_SQL,
        },
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

pub enum GroupLookup {
    Id(u64),
    Slug(String),
}
pub enum GroupDetail {
    Found(Value),
    Missing,
    OwnerMissing,
}

pub(crate) const GROUP_COLUMNS: &str = "SELECT g.group_id,g.group_name,g.slug,g.description,g.group_avatar_url,g.cover_url,g.category,g.owner_id,
g.privacy,g.privacy_desc,g.join_approval,g.post_permission,g.member_count,g.post_count,g.is_active,
g.created_at,g.updated_at,m.user_id AS member_id,m.role AS member_role,m.status AS member_status,m.joined_at";
pub(crate) const GROUP_FROM: &str = "FROM v_group_details g LEFT JOIN n_group_members m ON m.group_id=g.group_id AND m.user_id=:viewer_id";
const TAGS: &str =
    "SELECT tag FROM n_group_tags WHERE group_id=:group_id ORDER BY created_at ASC,tag_lower ASC";

pub(crate) fn execute(
    conn: &oracle::Connection,
    viewer: u64,
    key: GroupLookup,
    storage: &StorageUrlPolicy,
) -> Result<GroupDetail, DbError> {
    let viewer = DbValue::I64(i64::try_from(viewer).map_err(|_| DbError::SchemaNotReady)?);
    let (predicate, name, value) = match key {
        GroupLookup::Id(id) => (
            "g.group_id=:group_id",
            "group_id",
            DbValue::I64(i64::try_from(id).map_err(|_| DbError::SchemaNotReady)?),
        ),
        GroupLookup::Slug(slug) => ("g.slug=:slug", "slug", DbValue::String(slug)),
    };
    let rows = query(
        conn,
        &format!("{GROUP_COLUMNS} {GROUP_FROM} WHERE g.is_deleted=0 AND {predicate}"),
        BindMap::from([("viewer_id".into(), viewer.clone()), (name.into(), value)]),
    )?;
    let Some(row) = rows.first() else {
        return Ok(GroupDetail::Missing);
    };
    hydrate(conn, viewer, row, storage)
}

pub(crate) fn hydrate(
    conn: &oracle::Connection,
    viewer: DbValue,
    row: &DbRow,
    storage: &StorageUrlPolicy,
) -> Result<GroupDetail, DbError> {
    let id = row_number(row, "GROUP_ID");
    let tags = query(
        conn,
        TAGS,
        BindMap::from([("group_id".into(), DbValue::I64(id))]),
    )?
    .iter()
    .map(|row| row_text(row, "TAG"))
    .collect::<Vec<_>>();
    let owner = query(
        conn,
        PUBLIC_PROFILE_SQL,
        BindMap::from([
            ("viewer_id".into(), viewer),
            ("user_id".into(), DbValue::I64(row_number(row, "OWNER_ID"))),
        ]),
    )?;
    let Some(owner) = owner.first() else {
        return Ok(GroupDetail::OwnerMissing);
    };
    let normalize = |value: &str| {
        storage
            .normalize_avatar(value)
            .map_err(|_| DbError::SchemaNotReady)
    };
    let mut owner = public_profile_json(owner);
    owner["avatar_url"] = normalize(owner["avatar_url"].as_str().unwrap_or_default())?.into();
    let asset = |key| {
        nullable_text(row, key)
            .filter(|x| !x.is_empty())
            .map(|x| normalize(&x))
            .transpose()
    };
    let date = |key| nullable_text(row, key).map(|value| profile_date(&value));
    Ok(GroupDetail::Found(json!({
        "group_id":id,"name":row_text(row,"GROUP_NAME"),"slug":row_text(row,"SLUG"),
        "description":row_text(row,"DESCRIPTION"),"avatar_url":asset("GROUP_AVATAR_URL")?,
        "cover_url":asset("COVER_URL")?,"category":nullable_text(row,"CATEGORY"),"tags":tags,"owner":owner,
        "privacy":row_text(row,"PRIVACY"),"privacy_desc":row_text(row,"PRIVACY_DESC"),
        "join_approval":row_number(row,"JOIN_APPROVAL")==1,"post_permission":row_text(row,"POST_PERMISSION"),
        "member_count":row_number(row,"MEMBER_COUNT"),"post_count":row_number(row,"POST_COUNT"),"is_active":row_number(row,"IS_ACTIVE"),
        "membership":{"is_member":row.get("MEMBER_ID").and_then(DbValue::as_i64).is_some(),
            "role":nullable_text(row,"MEMBER_ROLE"),"status":nullable_text(row,"MEMBER_STATUS"),"joined_at":date("JOINED_AT")},
        "created_at":date("CREATED_AT").unwrap_or_default(),"updated_at":date("UPDATED_AT").unwrap_or_default()
    })))
}

async fn route(state: NativeState, raw: String, headers: HeaderMap, by_slug: bool) -> Response {
    let result = async {
        let (viewer, key) = if by_slug {
            let viewer = crate::posts::bookmark::interaction_actor(&state, &headers).await?;
            if raw.is_empty() {
                return Err(ApiError::bad_request("slug 参数错误"));
            }
            (viewer, GroupLookup::Slug(raw))
        } else {
            let (viewer, id) =
                crate::posts::bookmark::interaction_identity(&state, &raw, &headers).await?;
            (viewer, GroupLookup::Id(id))
        };
        let group = state
            .repository
            .group_detail(viewer, key, &state.storage_urls)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?;
        match group {
            GroupDetail::Found(value) => Ok(Json(V2Response::ok(value))),
            GroupDetail::Missing => Err(ApiError::not_found("群组不存在")),
            GroupDetail::OwnerMissing => Err(ApiError::not_found("用户不存在")),
        }
    }
    .await;
    let mut response = result.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}

pub(crate) async fn by_id(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
) -> Response {
    route(state, raw, headers, false).await
}
pub(crate) async fn by_slug(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
) -> Response {
    route(state, raw, headers, true).await
}
