use crate::{
    auth::{
        login::{js_trim, request_body, scalar},
        sessions::NativeState,
    },
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    body::{to_bytes, Body},
    extract::State,
    http::Request,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::{json, Value};

fn required(body: &Value, key: &str) -> Result<String, ApiError> {
    let value = scalar(body.get(key));
    let value = js_trim(&value);
    if value.is_empty() {
        return Err(ApiError::bad_request(format!("{key} 不能为空")));
    };
    Ok(value.to_owned())
}
fn server_error() -> ApiError {
    ApiError::server_error("服务器内部错误")
}
pub(crate) async fn verify_otp(
    State(state): State<NativeState>,
    request: Request<Body>,
) -> Result<Response, ApiError> {
    let (parts, body) = request.into_parts();
    let bytes = to_bytes(body, 1024 * 1024)
        .await
        .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
    let body = request_body(&parts.headers, &bytes)?;
    let account = required(&body, "account")?;
    let kind = required(&body, "type")?;
    if !["register", "password_reset", "change_email"].contains(&kind.as_str()) {
        return Err(ApiError::bad_request("type 参数错误"));
    }
    let id = required(&body, "verification_id")?;
    let code = required(&body, "code")?;
    let hash = state
        .repository
        .otp_lookup(&account, &kind, &id)
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
    let at = state
        .repository
        .otp_verified_at(&id)
        .await
        .map_err(|_| server_error())?
        .unwrap_or_else(|| chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true));
    Ok(Json(V2Response::ok(
        json!({"account":account,"verified":true,"verified_at":at}),
    ))
    .into_response())
}
