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
use serde_json::Value;

pub(crate) async fn get_public(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let token = access_token(&headers);
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
    if raw.is_empty() || raw.starts_with('0') || !raw.bytes().all(|c| c.is_ascii_digit()) {
        return Err(ApiError::bad_request("id 参数错误"));
    }
    let target = raw
        .parse::<u64>()
        .ok()
        .filter(|n| *n > 0 && *n <= 9_007_199_254_740_991)
        .ok_or_else(|| ApiError::bad_request("id 参数错误"))?;
    let mut profile = state
        .repository
        .public_profile(claims.user_id, target)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?
        .ok_or_else(|| ApiError::not_found("用户不存在"))?;
    let avatar = profile
        .get("avatar_url")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let avatar = state
        .storage_urls
        .normalize_avatar(avatar)
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    profile
        .as_object_mut()
        .ok_or_else(|| ApiError::server_error("服务器内部错误"))?
        .insert("avatar_url".into(), Value::String(avatar));
    let mut response = Json(V2Response::ok(profile)).into_response();
    response.headers_mut().insert(
        axum::http::header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static("private, no-store"),
    );
    Ok(response)
}
