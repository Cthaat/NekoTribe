use crate::{
    auth::{
        login::request_body,
        otp::required,
        otp_attempt_limit::{require_otp_attempt, OtpAttemptLimit},
        sessions::{access_token, NativeState},
        TokenKind,
    },
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    body::{to_bytes, Body},
    extract::{Extension, State},
    http::Request,
    response::{IntoResponse, Response},
    Json,
};

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct EmailChangeData {
    pub email: String,
    pub email_verified_at: String,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EmailChange {
    Committed(EmailChangeData),
    Expired,
    UserMissing,
    Conflict,
}

pub(crate) async fn change_email(
    State(state): State<NativeState>,
    limiter: Option<Extension<OtpAttemptLimit>>,
    request: Request<Body>,
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
    let bytes = to_bytes(body, 1024 * 1024)
        .await
        .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
    let body = request_body(&parts.headers, &bytes)?;
    let email = required(&body, "new_email")?;
    let id = required(&body, "verification_id")?;
    let code = required(&body, "code")?;
    crate::auth::input::require_new_email(&email)?;
    if state
        .repository
        .email_in_use(claims.user_id, &email)
        .await
        .map_err(|_| server_error())?
    {
        return Err(ApiError::conflict("邮箱已被使用"));
    }
    let hash = state
        .repository
        .otp_lookup(&email, "change_email", &id)
        .await
        .map_err(|_| server_error())?
        .ok_or_else(|| ApiError::bad_request("验证码不存在或已过期"))?;
    require_otp_attempt(limiter, &id).await?;
    let compare_hash = hash.clone();
    let valid =
        tokio::task::spawn_blocking(move || bcrypt::verify(code, &compare_hash).unwrap_or(false))
            .await
            .map_err(|_| server_error())?;
    if !valid {
        return Err(ApiError::unauthorized("验证码错误"));
    }
    match state
        .repository
        .change_email_atomic(claims.user_id, &email, &id, &hash)
        .await
        .map_err(|_| server_error())?
    {
        EmailChange::Committed(data) => Ok(Json(V2Response::ok(data)).into_response()),
        EmailChange::Expired => Err(ApiError::bad_request("验证码不存在或已过期")),
        EmailChange::UserMissing => Err(ApiError::not_found("用户不存在")),
        EmailChange::Conflict => Err(ApiError::conflict("邮箱已被使用")),
    }
}
fn server_error() -> ApiError {
    ApiError::server_error("服务器内部错误")
}
