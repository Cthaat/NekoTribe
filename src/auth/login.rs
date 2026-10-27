//! Native password login. Database operations remain separate commits to match
//! the existing Nuxt session model; failures must never bypass two-factor.
use crate::{
    auth::{sessions::NativeState, IssuedToken, TokenKind},
    httpx::{errors::ApiError, response::V2Response},
};
use aes_gcm::{
    aead::{Aead, Payload},
    Aes256Gcm, KeyInit,
};
use axum::{
    body::{to_bytes, Body},
    extract::State,
    http::{HeaderMap, HeaderValue, Request},
    response::{IntoResponse, Response},
    Json,
};
use base64::{engine::general_purpose::STANDARD, Engine};
use hmac::{Hmac, Mac};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

pub struct LoginAccount {
    pub user_id: u64,
    pub username: String,
    pub password_hash: String,
    pub status: String,
    pub active: bool,
}
pub struct LoginDevice {
    pub fingerprint: String,
    pub info: String,
    pub ip: String,
    pub user_agent: String,
}
pub struct LoginChallenge {
    pub id: String,
    pub user_id: u64,
    pub remember: bool,
    pub device: LoginDevice,
    pub expires_at: String,
}
pub struct LoginSession {
    pub id: String,
    pub user_id: u64,
    pub access_jti: String,
    pub refresh_hash: String,
    pub device: LoginDevice,
    pub access_expires_at: String,
    pub refresh_expires_at: String,
}
pub struct ChallengeRow {
    pub user_id: u64,
    pub username: String,
    pub remember: bool,
    pub device: LoginDevice,
}
pub struct EncryptedSecret {
    pub encrypted: String,
    pub iv: String,
    pub tag: String,
    pub enabled: bool,
}
pub struct RecoveryCode {
    pub id: u64,
    pub hash: String,
}

fn scalar(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Bool(b)) => b.to_string(),
        Some(Value::Number(n)) => n.to_string(),
        _ => String::new(),
    }
}
fn js_trim(value: &str) -> &str {
    value.trim_matches(|c: char| (c.is_whitespace() && c != '\u{0085}') || c == '\u{feff}')
}
fn timestamp(seconds: u64) -> Option<String> {
    chrono::DateTime::from_timestamp(i64::try_from(seconds).ok()?, 0)
        .map(|t| t.to_rfc3339_opts(chrono::SecondsFormat::Millis, true))
}
fn header(headers: &HeaderMap, name: &str) -> String {
    headers
        .get(name)
        .and_then(|h| h.to_str().ok())
        .filter(|s| !s.is_empty())
        .unwrap_or("unknown")
        .to_owned()
}
fn device_header(headers: &HeaderMap, name: &str) -> String {
    headers
        .get(name)
        .and_then(|h| h.to_str().ok())
        .unwrap_or("unknown")
        .to_owned()
}
fn client_ip(headers: &HeaderMap, extensions: &http::Extensions) -> String {
    let trusted = std::env::var("TRUST_PROXY").ok().is_some_and(|v| {
        matches!(
            v.trim().to_lowercase().as_str(),
            "1" | "true" | "yes" | "on"
        )
    });
    if trusted {
        if let Some(value) = headers
            .get("x-forwarded-for")
            .and_then(|h| h.to_str().ok())
            .and_then(|s| s.split(',').next())
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            return value.to_owned();
        }
    }
    extensions
        .get::<axum::extract::ConnectInfo<std::net::SocketAddr>>()
        .map(|c| c.0.ip().to_string())
        .unwrap_or_else(|| "unknown".to_owned())
}
fn server_error() -> ApiError {
    ApiError::server_error("服务器内部错误")
}
fn request_body(headers: &HeaderMap, bytes: &[u8]) -> Result<Value, ApiError> {
    let content_type = headers
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default()
        .split(';')
        .next()
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase();
    let bad = || ApiError::bad_request("请求体必须是 JSON 对象");
    if content_type.starts_with("text/") {
        return Err(bad());
    }
    if content_type == "application/x-www-form-urlencoded" {
        let text = std::str::from_utf8(bytes).map_err(|_| bad())?;
        let mut url = reqwest::Url::parse("http://localhost/").map_err(|_| bad())?;
        url.set_query(Some(text));
        let mut result = serde_json::Map::new();
        for (key, value) in url.query_pairs() {
            let key = key.into_owned();
            let value = Value::String(value.into_owned());
            if let Some(old) = result.remove(&key) {
                let mut values = match old {
                    Value::Array(v) => v,
                    other => vec![other],
                };
                values.push(value);
                result.insert(key, Value::Array(values));
            } else {
                result.insert(key, value);
            }
        }
        return Ok(Value::Object(result));
    }
    let body: Value = serde_json::from_slice(bytes).map_err(|_| bad())?;
    if body.is_object() {
        Ok(body)
    } else {
        Err(bad())
    }
}

pub(crate) async fn login(
    State(state): State<NativeState>,
    request: Request<Body>,
) -> Result<Response, ApiError> {
    let (parts, body) = request.into_parts();
    let bytes = to_bytes(body, 1024 * 1024)
        .await
        .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
    let body = request_body(&parts.headers, &bytes)?;
    let account_raw = scalar(body.get("account"));
    let account = js_trim(&account_raw).to_owned();
    if account.is_empty() {
        return Err(ApiError::bad_request("account 不能为空"));
    }
    let password_raw = scalar(body.get("password"));
    let password = js_trim(&password_raw).to_owned();
    if password.is_empty() {
        return Err(ApiError::bad_request("password 不能为空"));
    }
    let account_row = state
        .repository
        .login_account(&account)
        .await
        .map_err(|_| server_error())?
        .ok_or_else(|| ApiError::unauthorized("账号或密码错误"))?;
    if !account_row.active || account_row.status != "active" {
        return Err(ApiError::forbidden("账号不可用"));
    }
    let hash = account_row.password_hash;
    let matched =
        tokio::task::spawn_blocking(move || bcrypt::verify(password, &hash).unwrap_or(false))
            .await
            .map_err(|_| server_error())?;
    if !matched {
        return Err(ApiError::unauthorized("账号或密码错误"));
    }
    state.repository.two_factor_readiness().await.map_err(|_| {
        ApiError::new(
            http::StatusCode::SERVICE_UNAVAILABLE,
            50301,
            "服务暂不可用，请稍后重试。",
        )
    })?;
    let ip = client_ip(&parts.headers, &parts.extensions);
    let headers = parts.headers;
    let device = LoginDevice {
        fingerprint: device_header(&headers, "x-device-fingerprint"),
        info: device_header(&headers, "x-device-info"),
        ip,
        user_agent: header(&headers, "user-agent"),
    };
    let two_factor = state
        .repository
        .login_two_factor(account_row.user_id)
        .await
        .map_err(|_| server_error())?;
    if two_factor
        && !state
            .repository
            .login_trusted_device(account_row.user_id, &device)
            .await
            .map_err(|_| server_error())?
    {
        let now = (state.clock)();
        let expiry =
            timestamp(now.checked_add(300).ok_or_else(server_error)?).ok_or_else(server_error)?;
        let challenge = LoginChallenge {
            id: format!("2fa_{}", uuid::Uuid::new_v4()),
            user_id: account_row.user_id,
            remember: body.get("remember_me") == Some(&Value::Bool(true)),
            device,
            expires_at: expiry.clone(),
        };
        state
            .repository
            .login_challenge(&challenge)
            .await
            .map_err(|_| server_error())?;
        return Ok(Json(V2Response::ok_with_message(json!({"two_factor_required":true,"challenge_id":challenge.id,"account":account,"expires_at":expiry}), "two factor required")).into_response());
    }
    issue_session(&state, account_row.user_id, account_row.username, device).await
}

fn decrypted_secret(key: &[u8; 32], secret: &EncryptedSecret) -> Option<String> {
    let mut ciphertext = STANDARD.decode(&secret.encrypted).ok()?;
    let tag = STANDARD.decode(&secret.tag).ok()?;
    let iv = STANDARD.decode(&secret.iv).ok()?;
    if iv.len() != 12 || tag.len() != 16 {
        return None;
    }
    ciphertext.extend(tag);
    let cipher = Aes256Gcm::new_from_slice(key).ok()?;
    let plain = cipher
        .decrypt(
            aes_gcm::Nonce::from_slice(&iv),
            Payload {
                msg: &ciphertext,
                aad: &[],
            },
        )
        .ok()?;
    String::from_utf8(plain).ok()
}
fn totp_valid(secret: &str, code: &str, now: u64) -> Result<bool, ApiError> {
    if code.len() != 6 || !code.bytes().all(|b| b.is_ascii_digit()) {
        return Ok(false);
    }
    let normalized: String = secret
        .trim_end_matches('=')
        .chars()
        .filter(|c| !((c.is_whitespace() && *c != '\u{0085}') || *c == '\u{feff}'))
        .flat_map(char::to_uppercase)
        .collect();
    let mut key = Vec::new();
    let mut bits = 0u8;
    let mut value = 0u32;
    for ch in normalized.bytes() {
        let index = match ch {
            b'A'..=b'Z' => ch - b'A',
            b'2'..=b'7' => ch - b'2' + 26,
            _ => return Err(ApiError::bad_request("双因素密钥格式错误")),
        };
        value = (value << 5) | u32::from(index);
        bits += 5;
        if bits >= 8 {
            bits -= 8;
            key.push((value >> bits) as u8);
        }
    }
    for delta in [-1i64, 0, 1] {
        let counter = (now as i64 / 30 + delta).max(0) as u64;
        let Ok(mut mac) = <Hmac<sha1::Sha1> as Mac>::new_from_slice(&key) else {
            return Err(server_error());
        };
        mac.update(&counter.to_be_bytes());
        let bytes = mac.finalize().into_bytes();
        let offset = (bytes[19] & 15) as usize;
        let n = u32::from_be_bytes([
            bytes[offset],
            bytes[offset + 1],
            bytes[offset + 2],
            bytes[offset + 3],
        ]) & 0x7fff_ffff;
        let expected = format!("{:06}", n % 1_000_000);
        if bool::from(expected.as_bytes().ct_eq(code.as_bytes())) {
            return Ok(true);
        }
    }
    Ok(false)
}
pub(crate) async fn complete_challenge(
    State(state): State<NativeState>,
    request: Request<Body>,
) -> Result<Response, ApiError> {
    let (parts, body) = request.into_parts();
    let bytes = to_bytes(body, 1024 * 1024)
        .await
        .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
    let body = request_body(&parts.headers, &bytes)?;
    let path_id = parts
        .uri
        .path()
        .strip_prefix("/api/v2/auth/two-factor/challenges/")
        .unwrap_or_default();
    let id = if path_id.is_empty() {
        js_trim(&scalar(body.get("challenge_id"))).to_owned()
    } else {
        path_id.to_owned()
    };
    if id.is_empty() {
        return Err(ApiError::bad_request("challenge_id 不能为空"));
    }
    let code = js_trim(&scalar(body.get("code"))).to_owned();
    if code.is_empty() {
        return Err(ApiError::bad_request("code 不能为空"));
    }
    state.repository.two_factor_readiness().await.map_err(|_| {
        ApiError::new(
            http::StatusCode::SERVICE_UNAVAILABLE,
            50301,
            "服务暂不可用，请稍后重试。",
        )
    })?;
    let row = state
        .repository
        .challenge_lookup(&id)
        .await
        .map_err(|_| server_error())?
        .ok_or_else(|| ApiError::unauthorized("双因素验证已过期，请重新登录"))?;
    let secret = state
        .repository
        .two_factor_secret(row.user_id)
        .await
        .map_err(|_| server_error())?
        .filter(|s| s.enabled)
        .ok_or_else(|| ApiError::unprocessable("双因素认证尚未启用"))?;
    let normalized: String = code
        .chars()
        .filter(|c| !((c.is_whitespace() && *c != '\u{0085}') || *c == '\u{feff}') && *c != '-')
        .flat_map(char::to_uppercase)
        .collect();
    let decoded =
        decrypted_secret(state.codec.two_factor_key(), &secret).ok_or_else(server_error)?;
    let mut valid = totp_valid(&decoded, &normalized, (state.clock)())?;
    if !valid && !(normalized.len() == 6 && normalized.bytes().all(|b| b.is_ascii_digit())) {
        for candidate in state
            .repository
            .recovery_codes(row.user_id)
            .await
            .map_err(|_| server_error())?
        {
            let code = normalized.clone();
            let id = candidate.id;
            let matched = tokio::task::spawn_blocking(move || {
                bcrypt::verify(code, &candidate.hash).unwrap_or(false)
            })
            .await
            .map_err(|_| server_error())?;
            if matched {
                valid = state
                    .repository
                    .consume_recovery(id)
                    .await
                    .map_err(|_| server_error())?
                    == 1;
                break;
            }
        }
    }
    if !valid {
        return Err(ApiError::unauthorized("双因素验证码错误"));
    }
    if state
        .repository
        .consume_challenge(&id)
        .await
        .map_err(|_| server_error())?
        != 1
    {
        return Err(ApiError::unauthorized("双因素验证已过期，请重新登录"));
    }
    if row.remember {
        let expiry = timestamp(
            (state.clock)()
                .checked_add(30 * 24 * 60 * 60)
                .ok_or_else(server_error)?,
        )
        .ok_or_else(server_error)?;
        state
            .repository
            .trust_challenge_device(&row, &expiry)
            .await
            .map_err(|_| server_error())?;
    }
    let ip = client_ip(&parts.headers, &parts.extensions);
    let headers = parts.headers;
    let device = LoginDevice {
        fingerprint: device_header(&headers, "x-device-fingerprint"),
        info: device_header(&headers, "x-device-info"),
        ip,
        user_agent: header(&headers, "user-agent"),
    };
    issue_session(&state, row.user_id, row.username, device).await
}

async fn issue_session(
    state: &NativeState,
    user_id: u64,
    username: String,
    device: LoginDevice,
) -> Result<Response, ApiError> {
    let now = (state.clock)();
    let access_exp = now
        .checked_add(state.refresh_policy.access_seconds)
        .ok_or_else(server_error)?;
    let refresh_exp = now
        .checked_add(state.refresh_policy.refresh_seconds)
        .ok_or_else(server_error)?;
    let access_date = timestamp(access_exp).ok_or_else(server_error)?;
    let refresh_date = timestamp(refresh_exp).ok_or_else(server_error)?;
    let session_id = format!("sess_{}", uuid::Uuid::new_v4());
    let access_jti = uuid::Uuid::new_v4().to_string();
    let token = |kind, exp, jti| {
        state
            .codec
            .sign(&IssuedToken {
                user_id,
                user_name: username.clone(),
                session_id: session_id.clone(),
                kind,
                issued_at: now,
                expires_at: exp,
                jti,
            })
            .map_err(|_| server_error())
    };
    let access = token(TokenKind::Access, access_exp, access_jti.clone())?;
    let refresh = token(
        TokenKind::Refresh,
        refresh_exp,
        uuid::Uuid::new_v4().to_string(),
    )?;
    let session = LoginSession {
        id: session_id.clone(),
        user_id,
        access_jti,
        refresh_hash: hex::encode(Sha256::digest(refresh.as_bytes())),
        device,
        access_expires_at: access_date.clone(),
        refresh_expires_at: refresh_date.clone(),
    };
    let known = state
        .repository
        .known_login_device(user_id, &session.device.fingerprint)
        .await
        .map_err(|_| server_error())?;
    state
        .repository
        .login_insert_session(&session)
        .await
        .map_err(|_| server_error())?;
    if !known {
        // Nuxt treats alert delivery as best effort after the session commits.
        let _ = state.repository.record_login_alert(&session).await;
    }
    let profile = state
        .repository
        .login_profile(user_id)
        .await
        .map_err(|_| server_error())?
        .ok_or_else(|| ApiError::not_found("用户不存在"))?;
    let mut response = Json(V2Response::ok_with_message(json!({"two_factor_required":false,"user":profile,"tokens":{
        "session_id":session_id,"access_token":access,"refresh_token":refresh,"access_token_expires_at":access_date,"refresh_token_expires_at":refresh_date
    }}), "login success")).into_response();
    for (name, value, age) in [
        ("access_token", &access, state.refresh_policy.access_seconds),
        (
            "refresh_token",
            &refresh,
            state.refresh_policy.refresh_seconds,
        ),
    ] {
        let secure = if state.refresh_policy.cookie_secure {
            "; Secure"
        } else {
            ""
        };
        let value =
            format!("{name}={value}; Max-Age={age}; Path=/; HttpOnly; SameSite=Lax{secure}");
        response.headers_mut().append(
            "set-cookie",
            HeaderValue::from_str(&value).map_err(|_| server_error())?,
        );
    }
    Ok(response)
}

#[cfg(test)]
mod crypto_tests {
    use super::*;
    #[test]
    fn decrypts_shared_node_aes_gcm_vectors_and_rejects_tampering() {
        let vectors: Value = serde_json::from_str(include_str!(
            "../../contracts/scenarios/auth-twofactor-crypto.json"
        ))
        .unwrap();
        for case in vectors["cases"].as_array().unwrap() {
            let key: [u8; 32] =
                Sha256::digest(case["refreshSecret"].as_str().unwrap().as_bytes()).into();
            let secret = EncryptedSecret {
                encrypted: case["encrypted"].as_str().unwrap().into(),
                iv: case["iv"].as_str().unwrap().into(),
                tag: case["tag"].as_str().unwrap().into(),
                enabled: true,
            };
            assert_eq!(
                decrypted_secret(&key, &secret).as_deref(),
                case["expected"].as_str(),
                "{}",
                case["id"]
            );
        }
    }
    #[test]
    fn malformed_base32_reports_bad_request_for_totp_but_not_non_numeric_recovery() {
        let err = totp_valid("INVALID!", "123456", 1700000000).unwrap_err();
        assert_eq!(err.status(), http::StatusCode::BAD_REQUEST);
        assert_eq!(err.body().message, "双因素密钥格式错误");
        assert!(!totp_valid("INVALID!", "RECOVERY", 1700000000).unwrap());
    }
}
