use crate::{
    auth::{login::request_body, otp::required, sessions::NativeState},
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    body::{to_bytes, Body},
    extract::State,
    http::Request,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::Value;

fn server_error() -> ApiError {
    ApiError::server_error("服务器内部错误")
}

pub(crate) async fn password_reset(
    State(state): State<NativeState>,
    request: Request<Body>,
) -> Result<Response, ApiError> {
    let (parts, body) = request.into_parts();
    let bytes = to_bytes(body, 1024 * 1024)
        .await
        .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
    let body = request_body(&parts.headers, &bytes)?;
    let email = required(&body, "email")?;
    let id = required(&body, "verification_id")?;
    let code = required(&body, "code")?;
    let password = required(&body, "new_password")?;
    let hash = state
        .repository
        .otp_lookup(&email, "password_reset", &id)
        .await
        .map_err(|_| server_error())?
        .ok_or_else(|| ApiError::bad_request("验证码不存在或已过期"))?;
    let valid = tokio::task::spawn_blocking(move || bcrypt::verify(code, &hash).unwrap_or(false))
        .await
        .map_err(|_| server_error())?;
    if !valid {
        return Err(ApiError::unauthorized("验证码错误"));
    }
    state
        .repository
        .otp_mark(&id)
        .await
        .map_err(|_| server_error())?;
    state
        .repository
        .otp_verified_at(&id)
        .await
        .map_err(|_| server_error())?;
    let new_hash = tokio::task::spawn_blocking(move || bcrypt::hash(password, 10))
        .await
        .map_err(|_| server_error())?
        .map_err(|_| server_error())?;
    let updated = state
        .repository
        .reset_password(&email, &new_hash)
        .await
        .map_err(|_| server_error())?;
    if updated == 0 {
        return Err(ApiError::not_found("用户不存在"));
    }
    Ok(Json(V2Response::ok_with_message(
        Value::Null,
        "password reset success",
    ))
    .into_response())
}
