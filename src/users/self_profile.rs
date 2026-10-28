use crate::{
    auth::{
        sessions::{access_token, NativeState},
        TokenKind,
    },
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    extract::State,
    http::HeaderMap,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::Value;

pub(crate) async fn get_me(
    State(state): State<NativeState>,
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
    read_profile(&state, claims.user_id).await
}

async fn read_profile(state: &NativeState, user_id: u64) -> Result<Response, ApiError> {
    let mut profile = state
        .repository
        .login_profile(user_id)
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

pub(crate) const PROFILE_KEYS: [&str; 6] = [
    "display_name",
    "bio",
    "location",
    "website",
    "phone",
    "birth_date",
];

pub(crate) async fn patch_me(
    State(state): State<NativeState>,
    request: axum::http::Request<axum::body::Body>,
) -> Result<Response, ApiError> {
    let (parts, body) = request.into_parts();
    let token = access_token(&parts.headers);
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
    let bytes = axum::body::to_bytes(body, 1024 * 1024)
        .await
        .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
    let body = crate::auth::login::request_body(&parts.headers, &bytes)?;
    let mut fields = std::collections::BTreeMap::new();
    for key in PROFILE_KEYS {
        if let Some(value) = body.get(key) {
            fields.insert(key.to_owned(), crate::auth::login::scalar(Some(value)));
        }
    }
    if !fields.is_empty() {
        state
            .repository
            .update_self_profile(claims.user_id, &fields)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    }
    read_profile(&state, claims.user_id).await
}
