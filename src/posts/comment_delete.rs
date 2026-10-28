use crate::{
    auth::sessions::NativeState,
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    extract::{Path, State},
    http::HeaderMap,
    response::{IntoResponse, Response},
    Json,
};

#[derive(Debug, PartialEq, Eq)]
pub enum CommentDelete {
    Missing,
    NotOwner,
    Deleted,
}

pub(crate) async fn remove(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
) -> Response {
    let mut response = remove_inner(state, raw, headers).await.into_response();
    response.headers_mut().insert(
        axum::http::header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static("private, no-store"),
    );
    response
}
async fn remove_inner(
    state: NativeState,
    raw: String,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let (user, id) = crate::posts::bookmark::interaction_identity(&state, &raw, &headers).await?;
    match state
        .repository
        .delete_post_comment(user, id)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?
    {
        CommentDelete::Missing => Err(ApiError::not_found("评论不存在")),
        CommentDelete::NotOwner => Err(ApiError::unprocessable("只能删除自己的评论")),
        CommentDelete::Deleted => Ok(Json(V2Response::null("comment deleted")).into_response()),
    }
}
