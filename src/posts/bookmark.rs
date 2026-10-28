use crate::{
    auth::{
        sessions::{access_token, NativeState},
        TokenKind,
    },
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    extract::{Path, State},
    http::HeaderMap,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::json;

pub(crate) async fn save(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    set_bookmark(state, raw, headers, true).await
}
pub(crate) async fn remove(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    set_bookmark(state, raw, headers, false).await
}
async fn set_bookmark(
    state: NativeState,
    raw: String,
    headers: HeaderMap,
    saved: bool,
) -> Result<Response, ApiError> {
    let (viewer, id) = interaction_identity(&state, &raw, &headers).await?;
    let visible = state
        .repository
        .set_post_bookmark(viewer, id, saved)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    if !visible {
        return Err(ApiError::not_found("帖子不存在"));
    }
    let mut response = Json(V2Response::ok(
        json!({"post_id": id, "is_bookmarked": saved}),
    ))
    .into_response();
    response.headers_mut().insert(
        axum::http::header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static("private, no-store"),
    );
    Ok(response)
}

pub(crate) async fn remove_like(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let (viewer, id) = interaction_identity(&state, &raw, &headers).await?;
    let count = state
        .repository
        .remove_post_like(viewer, id)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?
        .ok_or_else(|| ApiError::not_found("帖子不存在"))?;
    let mut response = Json(V2Response::ok(
        json!({"post_id":id,"is_liked":false,"likes_count":count}),
    ))
    .into_response();
    response.headers_mut().insert(
        axum::http::header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static("private, no-store"),
    );
    Ok(response)
}

pub(crate) async fn interaction_identity(
    state: &NativeState,
    raw: &str,
    headers: &HeaderMap,
) -> Result<(u64, u64), ApiError> {
    let token = access_token(headers);
    if token.is_empty() {
        return Err(ApiError::unauthorized("请先登录"));
    }
    let claims = state
        .codec
        .verify(&token, TokenKind::Access, (state.clock)())
        .map_err(|_| ApiError::unauthorized("Token无效或已过期"))?;
    if state.repository.touch(&claims).await.unwrap_or(0) != 1 {
        return Err(ApiError::unauthorized("Token无效或已过期"));
    }
    if raw.is_empty() || raw.starts_with('0') || !raw.bytes().all(|b| b.is_ascii_digit()) {
        return Err(ApiError::bad_request("id 参数错误"));
    }
    let id = raw
        .parse::<u64>()
        .ok()
        .filter(|id| *id > 0 && *id <= 9_007_199_254_740_991)
        .ok_or_else(|| ApiError::bad_request("id 参数错误"))?;
    Ok((claims.user_id, id))
}
