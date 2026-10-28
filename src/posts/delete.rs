#[derive(Debug, PartialEq, Eq)]
pub enum PostDelete {
    Missing,
    NotOwner,
    Deleted,
}

use crate::{
    auth::{
        session_repository::SessionExecutor,
        sessions::{NativeState, SessionStoreError},
    },
    db::{oracle::BindMap, value::DbValue},
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    extract::{OriginalUri, State},
    http::{header, HeaderMap, HeaderValue},
    response::{IntoResponse, Response},
    Json,
};

pub(crate) async fn remove(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
) -> Response {
    let result = async {
        let actor = crate::posts::bookmark::interaction_actor(&state, &headers).await?;
        let raw = uri.path().strip_prefix("/api/v2/posts/").unwrap_or("");
        let id = crate::posts::create_request::parse_repost_id(raw)?;
        match state
            .repository
            .delete_post(actor, id)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?
        {
            PostDelete::Missing => Err(ApiError::not_found("帖子不存在")),
            PostDelete::NotOwner => Err(ApiError::unprocessable("只能删除自己的帖子")),
            PostDelete::Deleted => Ok(Json(V2Response::null("post deleted")).into_response()),
        }
    }
    .await;
    let mut response = result.into_response();
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("private, no-store"),
    );
    response
}

pub(crate) async fn remove_from_store<E: SessionExecutor>(
    executor: &E,
    actor: u64,
    id: u64,
) -> Result<PostDelete, SessionStoreError> {
    let actor = i64::try_from(actor).map_err(|_| SessionStoreError)?;
    let id = i64::try_from(id).map_err(|_| SessionStoreError)?;
    let rows = executor
        .query(
            "SELECT author_id FROM n_posts WHERE post_id=:post_id AND is_deleted=0",
            BindMap::from([("post_id".into(), DbValue::I64(id))]),
        )
        .await?;
    let Some(row) = rows.first() else {
        return Ok(PostDelete::Missing);
    };
    let owner = row
        .get("AUTHOR_ID")
        .and_then(DbValue::as_i64)
        .ok_or(SessionStoreError)?;
    if owner != actor {
        return Ok(PostDelete::NotOwner);
    }
    let changed=executor.execute("UPDATE n_posts SET is_deleted=1 WHERE post_id=:post_id AND author_id=:user_id AND is_deleted=0",BindMap::from([("post_id".into(),DbValue::I64(id)),("user_id".into(),DbValue::I64(actor))])).await?;
    match changed {
        0 => Ok(PostDelete::Missing),
        1 => Ok(PostDelete::Deleted),
        _ => Err(SessionStoreError),
    }
}
