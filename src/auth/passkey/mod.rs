//! Native WebAuthn endpoints. Challenge state is only serialized to Oracle.
mod crypto;
mod store;
#[cfg(test)]
mod tests;

pub use crypto::PasskeyEngine;
pub(crate) use store::execute;

use crate::{
    auth::{
        login::{finish_primary_login, LoginResponse},
        login_methods::access_claims as active_claims,
        sessions::NativeState,
        TokenClaims,
    },
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    body::{to_bytes, Body},
    extract::{Path, State},
    http::{HeaderMap, Request, StatusCode},
    response::{IntoResponse, Response},
    routing::{delete, get, post},
    Extension, Json, Router,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::{json, Value};
use std::sync::OnceLock;
use webauthn_rs::prelude::{
    Credential, DiscoverableAuthentication, PublicKeyCredential, RegisterPublicKeyCredential,
    Webauthn,
};

const PROOF_INVALID: &str = "Passkey 验证失败";

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Contract {
    ttl_seconds: i64,
    timeout_ms: u64,
    max_payload_bytes: usize,
    max_label_chars: usize,
    algorithm: i64,
    challenge_id_bytes: usize,
    max_credential_id_bytes: usize,
    password_hash_pattern: String,
    sql: Sql,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Sql {
    owner: String,
    lock_owner: String,
    credential_list: String,
    credential_read: String,
    credential_insert: String,
    credential_use: String,
    credential_delete: String,
    challenge_prune: String,
    challenge_insert: String,
    challenge_lock: String,
    challenge_delete: String,
}

fn spec() -> &'static Contract {
    static SPEC: OnceLock<Contract> = OnceLock::new();
    SPEC.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../../../contracts/requirements/passkey-auth.json"
        ))
        .expect("synchronized Passkey contract")
    })
}

pub(super) fn password_hash_pattern() -> &'static str {
    &spec().password_hash_pattern
}

pub(super) fn active_owner_sql() -> &'static str {
    &spec().sql.lock_owner
}

#[derive(Serialize)]
pub struct CredentialView {
    pub credential_id: String,
    pub label: String,
    pub created_at: String,
    pub last_used_at: Option<String>,
}

pub struct StoredProof {
    pub challenge: String,
    pub engine_state: String,
}

pub enum Operation {
    Ready,
    Owner(u64),
    List(u64),
    Begin {
        id: String,
        session: Option<TokenClaims>,
        proof: StoredProof,
    },
    Take {
        id: String,
        owner: Option<(u64, String)>,
    },
    Add {
        session: TokenClaims,
        credential: Credential,
        label: String,
    },
    Use {
        id: String,
        user: u64,
        engine: Webauthn,
        state: DiscoverableAuthentication,
        proof: PublicKeyCredential,
    },
    Delete {
        id: String,
        session: TokenClaims,
    },
}

pub enum Outcome {
    Ready,
    Unavailable,
    Owner {
        username: String,
        display_name: String,
        excluded: Vec<Vec<u8>>,
    },
    List(Vec<CredentialView>),
    Begun,
    Taken(StoredProof),
    Added(CredentialView),
    Used,
    Removed,
    Invalid,
    Missing,
    Conflict,
}

pub(crate) fn router() -> Router<NativeState> {
    Router::new()
        .route(
            "/api/v2/auth/passkeys/registration/options",
            post(register_options),
        )
        .route(
            "/api/v2/auth/passkeys/registration/verification",
            post(register_verify),
        )
        .route(
            "/api/v2/auth/passkeys/authentication/options",
            post(login_options),
        )
        .route(
            "/api/v2/auth/passkeys/authentication/verification",
            post(login_verify),
        )
        .route("/api/v2/users/me/passkeys", get(list))
        .route("/api/v2/users/me/passkeys/{credential_id}", delete(remove))
}

fn response(data: Value) -> Response {
    Json(V2Response::ok(data)).into_response()
}

fn invalid_proof() -> ApiError {
    ApiError::unauthorized(PROOF_INVALID)
}

fn invalid_input() -> ApiError {
    ApiError::bad_request("Passkey 参数无效")
}

fn unavailable() -> ApiError {
    ApiError::new(
        StatusCode::SERVICE_UNAVAILABLE,
        50301,
        "Passkey 服务暂不可用",
    )
}

fn internal() -> ApiError {
    ApiError::server_error("服务器内部错误")
}

async fn engine(
    state: &NativeState,
    extension: Option<Extension<PasskeyEngine>>,
) -> Result<PasskeyEngine, ApiError> {
    let Extension(engine) = extension.ok_or_else(unavailable)?;
    match state.repository.passkey(Operation::Ready).await {
        Ok(Outcome::Ready) => Ok(engine),
        _ => Err(unavailable()),
    }
}

async fn run(state: &NativeState, operation: Operation) -> Result<Outcome, ApiError> {
    state
        .repository
        .passkey(operation)
        .await
        .map_err(|_| internal())
}

async fn register_options(
    State(state): State<NativeState>,
    extension: Option<Extension<PasskeyEngine>>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let claims = active_claims(&state, &headers).await?;
    let engine = engine(&state, extension).await?;
    let (username, display_name, excluded) =
        match run(&state, Operation::Owner(claims.user_id)).await? {
            Outcome::Owner {
                username,
                display_name,
                excluded,
            } => (username, display_name, excluded),
            Outcome::Invalid => return Err(ApiError::forbidden("账号不可用")),
            _ => return Err(internal()),
        };
    let (options, proof) = engine
        .register_options(claims.user_id, &username, &display_name, excluded)
        .map_err(|_| internal())?;
    begin(
        &state,
        Some(claims),
        &options.public_key.challenge,
        &proof,
        &options.public_key,
    )
    .await
}

async fn login_options(
    State(state): State<NativeState>,
    extension: Option<Extension<PasskeyEngine>>,
) -> Result<Response, ApiError> {
    let engine = engine(&state, extension).await?;
    let (options, proof) = engine
        .webauthn
        .start_discoverable_authentication()
        .map_err(|_| internal())?;
    begin(
        &state,
        None,
        &options.public_key.challenge,
        &proof,
        &options.public_key,
    )
    .await
}

async fn begin(
    state: &NativeState,
    session: Option<TokenClaims>,
    challenge: &[u8],
    proof: &impl Serialize,
    options: &impl Serialize,
) -> Result<Response, ApiError> {
    let mut random = vec![0; spec().challenge_id_bytes];
    getrandom::fill(&mut random).map_err(|_| internal())?;
    let id = encode(&random);
    let engine_state = serde_json::to_string(proof).map_err(|_| internal())?;
    if engine_state.len() > 4_000 {
        return Err(internal());
    }
    let proof = StoredProof {
        challenge: encode(challenge),
        engine_state,
    };
    match run(
        state,
        Operation::Begin {
            id: id.clone(),
            session,
            proof,
        },
    )
    .await?
    {
        Outcome::Begun => Ok(response(json!({"challenge_id": id, "options": options}))),
        Outcome::Invalid => Err(invalid_proof()),
        _ => Err(internal()),
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Registration {
    challenge_id: String,
    credential: Value,
    #[serde(default)]
    label: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Authentication {
    challenge_id: String,
    credential: Value,
    #[serde(default)]
    remember_me: bool,
}

async fn parse<T: DeserializeOwned>(body: Body) -> Result<T, ApiError> {
    let bytes = to_bytes(body, spec().max_payload_bytes)
        .await
        .map_err(|_| invalid_input())?;
    serde_json::from_slice(&bytes).map_err(|_| invalid_input())
}

fn validate_credential_input(credential: &Value) -> Result<(), ApiError> {
    let id = credential
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(invalid_input)?;
    if decode_credential_id(id).is_none()
        || credential["rawId"].as_str() != Some(id)
        || credential["type"].as_str() != Some("public-key")
        || !credential["response"].is_object()
    {
        return Err(invalid_input());
    }
    Ok(())
}

async fn take(
    state: &NativeState,
    id: String,
    session: Option<&TokenClaims>,
) -> Result<StoredProof, ApiError> {
    decode_exact(&id, spec().challenge_id_bytes).ok_or_else(invalid_input)?;
    let owner = session.map(|claims| (claims.user_id, claims.session_id.clone()));
    match run(state, Operation::Take { id, owner }).await? {
        Outcome::Taken(proof) => Ok(proof),
        Outcome::Invalid => Err(invalid_proof()),
        _ => Err(internal()),
    }
}

async fn register_verify(
    State(state): State<NativeState>,
    extension: Option<Extension<PasskeyEngine>>,
    request: Request<Body>,
) -> Result<Response, ApiError> {
    let (parts, body) = request.into_parts();
    let claims = active_claims(&state, &parts.headers).await?;
    let engine = engine(&state, extension).await?;
    let Registration {
        challenge_id,
        credential,
        label,
    } = parse(body).await?;
    validate_credential_input(&credential)?;
    let label = label.trim();
    let label = if label.is_empty() { "Passkey" } else { label };
    if label.chars().count() > spec().max_label_chars {
        return Err(invalid_input());
    }
    let proof = take(&state, challenge_id, Some(&claims)).await?;
    let supplied: RegisterPublicKeyCredential =
        serde_json::from_value(credential).map_err(|_| invalid_proof())?;
    let credential = engine.registration_proof(supplied, proof)?;
    match run(
        &state,
        Operation::Add {
            session: claims,
            credential,
            label: label.into(),
        },
    )
    .await?
    {
        Outcome::Added(credential) => Ok(response(json!({ "credential": credential }))),
        Outcome::Conflict => Err(ApiError::conflict("Passkey 已登记")),
        Outcome::Invalid => Err(invalid_proof()),
        _ => Err(internal()),
    }
}

async fn login_verify(
    State(state): State<NativeState>,
    extension: Option<Extension<PasskeyEngine>>,
    request: Request<Body>,
) -> Result<Response, ApiError> {
    let (parts, body) = request.into_parts();
    let engine = engine(&state, extension).await?;
    let Authentication {
        challenge_id,
        credential,
        remember_me,
    } = parse(body).await?;
    validate_credential_input(&credential)?;
    let challenge = take(&state, challenge_id, None).await?;
    let proof: PublicKeyCredential =
        serde_json::from_value(credential).map_err(|_| invalid_proof())?;
    let (id, user, proof_state) = engine.authentication_proof(&proof, challenge)?;
    let outcome = run(
        &state,
        Operation::Use {
            id,
            user,
            engine: engine.webauthn,
            state: proof_state,
            proof,
        },
    )
    .await?;
    match outcome {
        Outcome::Used => {}
        Outcome::Invalid => return Err(invalid_proof()),
        _ => return Err(internal()),
    }
    let account = state
        .repository
        .login_account_by_id(user)
        .await
        .map_err(|_| internal())?
        .ok_or_else(invalid_proof)?;
    let account_name = account.username.clone();
    finish_primary_login(
        &state,
        parts,
        account,
        &account_name,
        remember_me,
        PROOF_INVALID,
        LoginResponse::Direct,
    )
    .await
}

async fn list(
    State(state): State<NativeState>,
    extension: Option<Extension<PasskeyEngine>>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let claims = active_claims(&state, &headers).await?;
    engine(&state, extension).await?;
    match run(&state, Operation::List(claims.user_id)).await? {
        Outcome::List(credentials) => Ok(response(json!({ "credentials": credentials }))),
        _ => Err(internal()),
    }
}

async fn remove(
    State(state): State<NativeState>,
    extension: Option<Extension<PasskeyEngine>>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Response, ApiError> {
    let session = active_claims(&state, &headers).await?;
    engine(&state, extension).await?;
    decode_credential_id(&id).ok_or_else(invalid_input)?;
    match run(&state, Operation::Delete { id, session }).await? {
        Outcome::Removed => Ok(response(Value::Null)),
        Outcome::Invalid => Err(invalid_proof()),
        Outcome::Missing => Err(ApiError::not_found("Passkey 不存在")),
        Outcome::Conflict => Err(ApiError::conflict("至少保留一种登录方式")),
        _ => Err(internal()),
    }
}

fn encode(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

fn decode_exact(text: &str, expected: usize) -> Option<Vec<u8>> {
    URL_SAFE_NO_PAD
        .decode(text)
        .ok()
        .filter(|bytes| bytes.len() == expected && encode(bytes) == text)
}

fn decode_credential_id(text: &str) -> Option<Vec<u8>> {
    if text.len() > (spec().max_credential_id_bytes * 4).div_ceil(3) {
        return None;
    }
    URL_SAFE_NO_PAD.decode(text).ok().filter(|bytes| {
        (1..=spec().max_credential_id_bytes).contains(&bytes.len()) && encode(bytes) == text
    })
}
