use crate::{
    auth::{
        login::{request_body, scalar},
        otp::required,
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

#[derive(Clone)]
pub struct RegistrationRecord {
    pub user_id: u64,
    pub email: String,
    pub username: String,
    pub password_hash: String,
    pub display_name: String,
    pub bio: String,
    pub location: String,
    pub phone: String,
    pub birth_date: String,
}
fn server_error() -> ApiError {
    ApiError::server_error("服务器内部错误")
}
pub(crate) async fn register(
    State(state): State<NativeState>,
    request: Request<Body>,
) -> Result<Response, ApiError> {
    let (parts, body) = request.into_parts();
    let bytes = to_bytes(body, 1024 * 1024)
        .await
        .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
    let body = request_body(&parts.headers, &bytes)?;
    let email = required(&body, "email")?;
    let username = required(&body, "username")?;
    let password = required(&body, "password")?;
    let confirm = required(&body, "confirm_password")?;
    let display_name = required(&body, "display_name")?;
    let verification_id = required(&body, "verification_id")?;
    if body.get("agree_to_terms") != Some(&Value::Bool(true)) {
        return Err(ApiError::bad_request("必须同意服务条款"));
    }
    if password != confirm {
        return Err(ApiError::bad_request("两次输入的密码不一致"));
    }
    if !state
        .repository
        .registration_otp(&email, &verification_id)
        .await
        .map_err(|_| server_error())?
    {
        return Err(ApiError::unprocessable("请先完成验证码校验"));
    }
    if state
        .repository
        .registration_exists(&email, &username)
        .await
        .map_err(|_| server_error())?
    {
        return Err(ApiError::conflict("邮箱或用户名已被注册"));
    }
    let user_id = state
        .repository
        .registration_next_id()
        .await
        .map_err(|_| server_error())?;
    let password_hash = tokio::task::spawn_blocking(move || bcrypt::hash(password, 10))
        .await
        .map_err(|_| server_error())?
        .map_err(|_| server_error())?;
    let record = RegistrationRecord {
        user_id,
        email,
        username,
        password_hash,
        display_name,
        bio: scalar(body.get("bio")),
        location: scalar(body.get("location")),
        phone: scalar(body.get("phone")),
        birth_date: scalar(body.get("birth_date")),
    };
    state
        .repository
        .registration_insert(&record)
        .await
        .map_err(|_| server_error())?;
    let mut profile = state
        .repository
        .login_profile(user_id)
        .await
        .map_err(|_| server_error())?
        .ok_or_else(|| ApiError::not_found("用户不存在"))?;
    let avatar = profile
        .get("avatar_url")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let avatar = state
        .storage_urls
        .normalize_avatar(avatar)
        .map_err(|_| server_error())?;
    profile
        .as_object_mut()
        .ok_or_else(server_error)?
        .insert("avatar_url".into(), Value::String(avatar));
    Ok(Json(V2Response::ok_with_message(
        json!({"user":profile}),
        "registration success",
    ))
    .into_response())
}
