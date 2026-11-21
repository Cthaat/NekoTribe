use crate::{
    auth::{
        login::request_body,
        otp::required,
        sessions::{access_token, NativeState},
        TokenKind,
    },
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    body::{to_bytes, Body},
    extract::State,
    http::{header::SET_COOKIE, HeaderValue, Request},
    response::{IntoResponse, Response},
    Json,
};
use serde_json::json;
pub(crate) async fn delete(
    State(state): State<NativeState>,
    request: Request<Body>,
) -> Result<Response, ApiError> {
    let fail = || ApiError::server_error("服务器内部错误");
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
    let bytes = to_bytes(body, 1024 * 1024)
        .await
        .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
    let body = request_body(&parts.headers, &bytes)?;
    let me = state
        .repository
        .login_profile(claims.user_id)
        .await
        .map_err(|_| fail())?
        .ok_or_else(|| ApiError::not_found("用户不存在"))?;
    let password = required(&body, "password")?;
    let confirmation = required(&body, "confirmation")?;
    if me["username"].as_str() != Some(&confirmation) && confirmation.to_uppercase() != "DELETE" {
        return Err(ApiError::bad_request("确认内容不匹配"));
    }
    let account = state
        .repository
        .account_credential(claims.user_id)
        .await
        .map_err(|_| fail())?
        .ok_or_else(|| ApiError::not_found("用户不存在"))?;
    if !account.active || account.status != "active" {
        return Err(ApiError::forbidden("账号不可用"));
    }
    let old_hash = account.password_hash;
    let compared = old_hash.clone();
    if !tokio::task::spawn_blocking(move || bcrypt::verify(password, &compared).unwrap_or(false))
        .await
        .map_err(|_| fail())?
    {
        return Err(ApiError::unauthorized("密码错误"));
    }
    let mut random = [0u8; 32];
    getrandom::fill(&mut random).map_err(|_| fail())?;
    let secret = hex::encode(random);
    let hash = tokio::task::spawn_blocking(move || bcrypt::hash(secret, 10))
        .await
        .map_err(|_| fail())?
        .map_err(|_| fail())?;
    if !state
        .repository
        .delete_account_atomic(claims.user_id, &old_hash, &hash)
        .await
        .map_err(|_| fail())?
    {
        return Err(ApiError::conflict("账号已变更，请重新验证"));
    }
    if let Ok(presence) = state.repository.user_presence(claims.user_id).await {
        if let (Some(data), Some(publisher)) =
            (presence.as_object(), state.notification_publisher.as_ref())
        {
            if publisher.publish_presence(data).await.is_err() {
                eprintln!("presence delivery unavailable");
            }
        }
    }
    let mut response = Json(V2Response::ok(
        json!({"deleted":true,"user_id":claims.user_id}),
    ))
    .into_response();
    for cookie in [
        "access_token=; Max-Age=0; Path=/",
        "refresh_token=; Max-Age=0; Path=/",
    ] {
        response
            .headers_mut()
            .append(SET_COOKIE, HeaderValue::from_static(cookie));
    }
    response.headers_mut().insert(
        "cache-control",
        HeaderValue::from_static("private, no-store"),
    );
    Ok(response)
}
