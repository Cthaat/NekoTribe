use crate::{
    auth::{
        login::{self, EncryptedSecret},
        otp::required,
        sessions::{access_token, NativeState},
        TokenKind,
    },
    httpx::{errors::ApiError, response::V2Response},
};
use aes_gcm::{aead::Aead, Aes256Gcm, KeyInit};
use axum::{
    body::{to_bytes, Body},
    extract::State,
    http::{HeaderValue, Request},
    response::{IntoResponse, Response},
    Json,
};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::json;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum FactorAction {
    Setup,
    Confirm,
    Disable,
}
#[derive(Clone)]
pub struct FactorMutation {
    pub action: FactorAction,
    pub expected: EncryptedSecret,
    pub new_secret: Option<EncryptedSecret>,
    pub recovery_hashes: Vec<String>,
    pub recovery_id: Option<u64>,
}
pub enum FactorOutcome {
    Applied,
    Changed,
    RecoveryUsed,
}
fn server_error() -> ApiError {
    ApiError::server_error("服务器内部错误")
}
fn normalized(value: &str) -> String {
    value
        .chars()
        .filter(|c| *c != '-' && !((c.is_whitespace() && *c != '\u{0085}') || *c == '\u{feff}'))
        .flat_map(char::to_uppercase)
        .collect()
}
fn random_base32(size: usize) -> Result<String, ApiError> {
    let mut raw = vec![0u8; size];
    getrandom::fill(&mut raw).map_err(|_| server_error())?;
    let (mut value, mut bits, mut text) = (0u32, 0u8, String::new());
    let alphabet = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    for b in raw {
        value = (value << 8) | u32::from(b);
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            text.push(char::from(alphabet[((value >> bits) & 31) as usize]));
        }
    }
    if bits > 0 {
        text.push(char::from(alphabet[((value << (5 - bits)) & 31) as usize]));
    }
    Ok(text)
}
fn sealed(key: &[u8; 32], plain: &str) -> Result<EncryptedSecret, ApiError> {
    let mut iv = [0u8; 12];
    getrandom::fill(&mut iv).map_err(|_| server_error())?;
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| server_error())?;
    let bytes = cipher
        .encrypt(aes_gcm::Nonce::from_slice(&iv), plain.as_bytes())
        .map_err(|_| server_error())?;
    let n = bytes.len() - 16;
    Ok(EncryptedSecret {
        encrypted: STANDARD.encode(&bytes[..n]),
        iv: STANDARD.encode(iv),
        tag: STANDARD.encode(&bytes[n..]),
        enabled: false,
    })
}
fn label(value: &str) -> String {
    let mut s = String::new();
    for b in value.bytes() {
        if b.is_ascii_alphanumeric() || b"-_.!~*'()".contains(&b) {
            s.push(char::from(b))
        } else {
            s.push_str(&format!("%{b:02X}"));
        }
    }
    s
}
pub(crate) async fn setup(
    state: State<NativeState>,
    request: Request<Body>,
) -> Result<Response, ApiError> {
    manage(state.0, request, FactorAction::Setup).await
}
pub(crate) async fn confirm(
    state: State<NativeState>,
    request: Request<Body>,
) -> Result<Response, ApiError> {
    manage(state.0, request, FactorAction::Confirm).await
}
pub(crate) async fn disable(
    state: State<NativeState>,
    request: Request<Body>,
) -> Result<Response, ApiError> {
    manage(state.0, request, FactorAction::Disable).await
}
async fn manage(
    state: NativeState,
    request: Request<Body>,
    action: FactorAction,
) -> Result<Response, ApiError> {
    let (parts, body) = request.into_parts();
    let token = access_token(&parts.headers);
    if token.is_empty() {
        return Err(ApiError::unauthorized("请先登录"));
    };
    let claims = state
        .codec
        .verify(&token, TokenKind::Access, (state.clock)())
        .map_err(|_| ApiError::unauthorized("Token无效或已过期"))?;
    let user = claims.user_id;
    if state.repository.touch(&claims).await.unwrap_or(0) != 1 {
        return Err(ApiError::unauthorized("Token无效或已过期"));
    }
    let bytes = to_bytes(body, 1024 * 1024)
        .await
        .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
    let body = login::request_body(&parts.headers, &bytes)?;
    if action != FactorAction::Confirm {
        let password = required(&body, "password")?;
        let account = state
            .repository
            .account_credential(user)
            .await
            .map_err(|_| server_error())?
            .ok_or_else(|| ApiError::not_found("用户不存在"))?;
        if !account.active || account.status != "active" {
            return Err(ApiError::forbidden("账号不可用"));
        };
        if !tokio::task::spawn_blocking(move || {
            bcrypt::verify(password, &account.password_hash).unwrap_or(false)
        })
        .await
        .map_err(|_| server_error())?
        {
            return Err(ApiError::unauthorized("密码错误"));
        }
    }
    let code = if action == FactorAction::Disable {
        normalized(&required(&body, "code")?)
    } else {
        normalized(&login::scalar(body.get("code")))
    };
    state.repository.two_factor_readiness().await.map_err(|_| {
        ApiError::new(
            axum::http::StatusCode::SERVICE_UNAVAILABLE,
            50301,
            "服务暂不可用，请稍后重试。",
        )
    })?;
    let found = state
        .repository
        .two_factor_secret(user)
        .await
        .map_err(|_| server_error())?;
    let mut mutation = FactorMutation {
        action,
        expected: found.clone().unwrap_or(EncryptedSecret {
            encrypted: String::new(),
            iv: String::new(),
            tag: String::new(),
            enabled: false,
        }),
        new_secret: None,
        recovery_hashes: vec![],
        recovery_id: None,
    };
    let data;
    if action == FactorAction::Setup {
        if found.is_some_and(|s| s.enabled) {
            return Err(ApiError::unprocessable(
                "双因素认证已启用，请先关闭后再重新设置",
            ));
        }
        let profile = state
            .repository
            .login_profile(user)
            .await
            .map_err(|_| server_error())?
            .ok_or_else(|| ApiError::not_found("用户不存在"))?;
        let secret = random_base32(20)?;
        mutation.new_secret = Some(sealed(state.codec.two_factor_key(), &secret)?);
        let account = profile["email"]
            .as_str()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| profile["username"].as_str().unwrap_or_default());
        let uri = format!(
            "otpauth://totp/{}?secret={secret}&issuer=NekoTribe&algorithm=SHA1&digits=6&period=30",
            label(&format!("NekoTribe:{account}"))
        );
        data = json!({"secret":secret,"otpauth_url":uri});
    } else {
        let secret = found.ok_or_else(|| {
            ApiError::unprocessable(if action == FactorAction::Confirm {
                "请先生成双因素认证密钥"
            } else {
                "双因素认证尚未启用"
            })
        })?;
        if action == FactorAction::Confirm && secret.enabled {
            return Err(ApiError::unprocessable(
                "双因素认证已启用，请先关闭后再重新设置",
            ));
        };
        if action == FactorAction::Disable && !secret.enabled {
            return Err(ApiError::unprocessable("双因素认证尚未启用"));
        }
        let plain = login::decrypted_secret(state.codec.two_factor_key(), &secret)
            .ok_or_else(server_error)?;
        let mut matched = login::totp_valid(&plain, &code, (state.clock)())?;
        if action == FactorAction::Disable
            && !matched
            && !(code.len() == 6 && code.bytes().all(|b| b.is_ascii_digit()))
        {
            let candidates = state
                .repository
                .recovery_codes(user)
                .await
                .map_err(|_| server_error())?;
            let candidate_code = code.clone();
            let id = tokio::task::spawn_blocking(move || {
                candidates
                    .into_iter()
                    .find(|r| bcrypt::verify(&candidate_code, &r.hash).unwrap_or(false))
                    .map(|r| r.id)
            })
            .await
            .map_err(|_| server_error())?;
            mutation.recovery_id = id;
            matched = id.is_some();
        }
        if !matched {
            return Err(ApiError::unauthorized("双因素验证码错误"));
        }
        if action == FactorAction::Confirm {
            let (codes, hashes) =
                tokio::task::spawn_blocking(|| -> Result<(Vec<String>, Vec<String>), ApiError> {
                    let (mut codes, mut hashes) = (Vec::new(), Vec::new());
                    for _ in 0..10 {
                        let raw = random_base32(10)?;
                        let code = format!("{}-{}-{}", &raw[..5], &raw[5..10], &raw[10..15]);
                        hashes
                            .push(bcrypt::hash(normalized(&code), 10).map_err(|_| server_error())?);
                        codes.push(code);
                    }
                    Ok((codes, hashes))
                })
                .await
                .map_err(|_| server_error())??;
            mutation.recovery_hashes = hashes;
            data = json!({"enabled":true,"recovery_codes":codes});
        } else {
            data = json!({"enabled":false});
        }
    }
    match state
        .repository
        .apply_factor_mutation(user, &mutation)
        .await
        .map_err(|_| server_error())?
    {
        FactorOutcome::Applied => {}
        FactorOutcome::Changed => return Err(ApiError::conflict("双因素设置已变更，请重试")),
        FactorOutcome::RecoveryUsed => return Err(ApiError::unauthorized("双因素验证码错误")),
    };
    let mut response = Json(V2Response::ok(data)).into_response();
    response.headers_mut().insert(
        "cache-control",
        HeaderValue::from_static("private, no-store"),
    );
    Ok(response)
}
