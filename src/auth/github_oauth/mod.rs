//! Native GitHub OAuth login and account linking.
mod provider;
mod store;
#[cfg(test)]
mod tests;

pub use provider::GithubOAuth;
pub(crate) use store::execute;
pub(super) use store::has_link;

use crate::{
    auth::{
        login::{finish_primary_login, LoginResponse},
        login_methods::access_claims,
        sessions::NativeState,
        TokenClaims,
    },
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    body::{to_bytes, Body},
    extract::{Path, Query, State},
    http::{
        header::{CACHE_CONTROL, CONTENT_SECURITY_POLICY, REFERRER_POLICY, X_CONTENT_TYPE_OPTIONS},
        HeaderMap, HeaderValue, Request, StatusCode, Uri,
    },
    response::{Html, IntoResponse, Response},
    routing::{get, post},
    Extension, Json, Router,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::sync::OnceLock;

const CALLBACK: &str = "/api/v2/auth/oauth/github/callback";
const BAD_FLOW: &str = "GitHub 授权流程无效";
const HTML: &str = "<!doctype html><html lang=\"zh-CN\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>返回 NekoTribe</title><main><h1>返回 NekoTribe</h1><p>请关闭此页面并返回应用查看结果。</p></main></html>";

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Contract {
    ttl_seconds: i64,
    nonce_bytes: usize,
    provider_timeout_ms: u64,
    provider_body_max_bytes: usize,
    endpoints: Endpoints,
    sql: Sql,
}

#[derive(Deserialize)]
struct Endpoints {
    authorize: String,
    exchange: String,
    profile: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Sql {
    prune: String,
    begin: String,
    callback_lock: String,
    callback_claim: String,
    callback_finish: String,
    complete_lock: String,
    complete_consume: String,
    #[serde(rename = "linkForGitHub")]
    link_for_github: String,
    link_for_user: String,
    link_create: String,
    link_remove: String,
    passkey_count: String,
}

fn spec() -> &'static Contract {
    static SPEC: OnceLock<Contract> = OnceLock::new();
    SPEC.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../../../contracts/requirements/github-oauth.json"
        ))
        .expect("synchronized GitHub OAuth contract")
    })
}

pub struct Flow {
    pub id: String,
    pub state_hash: String,
    pub flow_key_hash: String,
    pub pkce_verifier: String,
}

pub struct Identity {
    pub id: String,
    pub login: String,
}

#[derive(Serialize)]
pub struct Link {
    pub github_user_id: String,
    pub github_login: String,
    pub linked_at: String,
}

pub enum Operation {
    Ready,
    Begin {
        flow: Flow,
        session: Option<TokenClaims>,
    },
    Claim {
        state_hash: String,
    },
    Record {
        flow_id: String,
        identity: Option<Identity>,
    },
    Complete {
        flow_id: String,
        flow_key_hash: String,
        session: Option<TokenClaims>,
    },
    Read(u64),
    Remove(TokenClaims),
}

pub enum Outcome {
    Ready,
    Unavailable,
    Begun,
    Claimed {
        flow_id: String,
        pkce_verifier: String,
    },
    Recorded,
    Pending,
    Login(u64),
    Link(Option<Link>),
    Linked(Link),
    Removed,
    Invalid,
    Missing,
    Conflict,
}

pub(crate) fn router() -> Router<NativeState> {
    Router::new()
        .route("/api/v2/auth/oauth/github/login/flows", post(begin_login))
        .route(
            "/api/v2/auth/oauth/github/login/flows/{flow_id}/complete",
            post(complete_login),
        )
        .route(
            CALLBACK,
            get(callback).head(|| async { StatusCode::METHOD_NOT_ALLOWED }),
        )
        .route("/api/v2/users/me/oauth/github/flows", post(begin_link))
        .route(
            "/api/v2/users/me/oauth/github/flows/{flow_id}/complete",
            post(complete_link),
        )
        .route(
            "/api/v2/users/me/oauth/github",
            get(read_link).delete(remove_link),
        )
}

fn success(data: Value) -> Response {
    Json(V2Response::ok(data)).into_response()
}

fn invalid_input() -> ApiError {
    ApiError::bad_request("GitHub 授权参数无效")
}
fn invalid_flow() -> ApiError {
    ApiError::unauthorized(BAD_FLOW)
}
fn internal() -> ApiError {
    ApiError::server_error("服务器内部错误")
}
fn unavailable() -> ApiError {
    ApiError::new(
        StatusCode::SERVICE_UNAVAILABLE,
        50301,
        "GitHub 授权暂不可用",
    )
}

async fn ready(
    state: &NativeState,
    extension: Option<Extension<GithubOAuth>>,
) -> Result<GithubOAuth, ApiError> {
    let Extension(engine) = extension.ok_or_else(unavailable)?;
    match state.repository.github_oauth(Operation::Ready).await {
        Ok(Outcome::Ready) => Ok(engine),
        _ => Err(unavailable()),
    }
}

async fn run(state: &NativeState, operation: Operation) -> Result<Outcome, ApiError> {
    state
        .repository
        .github_oauth(operation)
        .await
        .map_err(|_| internal())
}

fn digest(text: &str) -> String {
    hex::encode(Sha256::digest(text.as_bytes()))
}

fn nonce() -> Result<String, ApiError> {
    let mut bytes = vec![0; spec().nonce_bytes];
    getrandom::fill(&mut bytes).map_err(|_| internal())?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}

fn valid_nonce(text: &str) -> bool {
    text.len() == (spec().nonce_bytes * 4).div_ceil(3)
        && URL_SAFE_NO_PAD.decode(text).is_ok_and(|bytes| {
            bytes.len() == spec().nonce_bytes && URL_SAFE_NO_PAD.encode(bytes) == text
        })
}

async fn begin_login(
    State(state): State<NativeState>,
    extension: Option<Extension<GithubOAuth>>,
) -> Result<Response, ApiError> {
    begin(&state, ready(&state, extension).await?, None).await
}

async fn begin_link(
    State(state): State<NativeState>,
    extension: Option<Extension<GithubOAuth>>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let session = access_claims(&state, &headers).await?;
    begin(&state, ready(&state, extension).await?, Some(session)).await
}

async fn begin(
    state: &NativeState,
    engine: GithubOAuth,
    session: Option<TokenClaims>,
) -> Result<Response, ApiError> {
    let flow_id = nonce()?;
    let flow_key = nonce()?;
    let state_token = nonce()?;
    let pkce_verifier = nonce()?;
    let authorization_url = engine.authorization_url(&state_token, &pkce_verifier);
    let flow = Flow {
        id: flow_id.clone(),
        state_hash: digest(&state_token),
        flow_key_hash: digest(&flow_key),
        pkce_verifier,
    };
    match run(state, Operation::Begin { flow, session }).await? {
        Outcome::Begun => Ok(success(json!({
            "flow_id":flow_id,"flow_key":flow_key,
            "authorization_url":authorization_url.as_str(),"expires_in":spec().ttl_seconds,
        }))),
        Outcome::Invalid => Err(invalid_flow()),
        _ => Err(internal()),
    }
}

#[derive(Deserialize)]
struct CallbackQuery {
    state: String,
    code: Option<String>,
    error: Option<String>,
}

async fn callback(
    State(state): State<NativeState>,
    extension: Option<Extension<GithubOAuth>>,
    uri: Uri,
) -> Response {
    let status = callback_status(&state, extension, uri).await;
    let mut response = (status, Html(HTML)).into_response();
    response.headers_mut().extend([
        (CACHE_CONTROL, HeaderValue::from_static("private, no-store")),
        (REFERRER_POLICY, HeaderValue::from_static("no-referrer")),
        (X_CONTENT_TYPE_OPTIONS, HeaderValue::from_static("nosniff")),
        (
            CONTENT_SECURITY_POLICY,
            HeaderValue::from_static("default-src 'none'; base-uri 'none'; frame-ancestors 'none'"),
        ),
    ]);
    response
}

async fn callback_status(
    state: &NativeState,
    extension: Option<Extension<GithubOAuth>>,
    uri: Uri,
) -> StatusCode {
    if uri.query().is_some_and(|query| query.len() > 8_192) {
        return StatusCode::BAD_REQUEST;
    }
    let Ok(Query(query)) = Query::<CallbackQuery>::try_from_uri(&uri) else {
        return StatusCode::BAD_REQUEST;
    };
    let valid_result = match &query.error {
        Some(error) => !error.is_empty(),
        None => query.code.as_ref().is_some_and(|code| {
            (1..=512).contains(&code.len())
                && code
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
        }),
    };
    if !valid_nonce(&query.state) || !valid_result {
        return StatusCode::BAD_REQUEST;
    }
    let Ok(engine) = ready(state, extension).await else {
        return StatusCode::SERVICE_UNAVAILABLE;
    };
    let (flow_id, pkce_verifier) = match run(
        state,
        Operation::Claim {
            state_hash: digest(&query.state),
        },
    )
    .await
    {
        Ok(Outcome::Claimed {
            flow_id,
            pkce_verifier,
        }) => (flow_id, pkce_verifier),
        Ok(Outcome::Invalid) => return StatusCode::UNAUTHORIZED,
        _ => return StatusCode::SERVICE_UNAVAILABLE,
    };
    let identity = match (query.code, query.error) {
        (Some(code), None) => engine.verify(&code, &pkce_verifier).await,
        _ => None,
    };
    let verified = identity.is_some();
    match run(state, Operation::Record { flow_id, identity }).await {
        Ok(Outcome::Recorded) if verified => StatusCode::OK,
        Ok(Outcome::Recorded | Outcome::Invalid) => StatusCode::UNAUTHORIZED,
        _ => StatusCode::SERVICE_UNAVAILABLE,
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct LoginFinish {
    flow_key: String,
    #[serde(default)]
    remember_me: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct LinkFinish {
    flow_key: String,
}

async fn body<T: DeserializeOwned>(body: Body) -> Result<T, ApiError> {
    let bytes = to_bytes(body, 4_096).await.map_err(|_| invalid_input())?;
    serde_json::from_slice(&bytes).map_err(|_| invalid_input())
}

async fn complete(
    state: &NativeState,
    extension: Option<Extension<GithubOAuth>>,
    flow_id: String,
    flow_key: String,
    session: Option<TokenClaims>,
) -> Result<Outcome, ApiError> {
    if !valid_nonce(&flow_id) || !valid_nonce(&flow_key) {
        return Err(invalid_input());
    }
    ready(state, extension).await?;
    run(
        state,
        Operation::Complete {
            flow_id,
            flow_key_hash: digest(&flow_key),
            session,
        },
    )
    .await
}

async fn complete_login(
    State(state): State<NativeState>,
    extension: Option<Extension<GithubOAuth>>,
    Path(flow_id): Path<String>,
    request: Request<Body>,
) -> Result<Response, ApiError> {
    let (parts, payload) = request.into_parts();
    let LoginFinish {
        flow_key,
        remember_me,
    } = body(payload).await?;
    let user = match complete(&state, extension, flow_id, flow_key, None).await? {
        Outcome::Login(user) => user,
        Outcome::Pending => return Ok(success(json!({"status":"pending"}))),
        Outcome::Invalid => return Err(invalid_flow()),
        _ => return Err(internal()),
    };
    let account = state
        .repository
        .login_account_by_id(user)
        .await
        .map_err(|_| internal())?
        .ok_or_else(invalid_flow)?;
    let name = account.username.clone();
    finish_primary_login(
        &state,
        parts,
        account,
        &name,
        remember_me,
        BAD_FLOW,
        LoginResponse::GitHub,
    )
    .await
}

async fn complete_link(
    State(state): State<NativeState>,
    extension: Option<Extension<GithubOAuth>>,
    Path(flow_id): Path<String>,
    request: Request<Body>,
) -> Result<Response, ApiError> {
    let (parts, payload) = request.into_parts();
    let session = access_claims(&state, &parts.headers).await?;
    let LinkFinish { flow_key } = body(payload).await?;
    match complete(&state, extension, flow_id, flow_key, Some(session)).await? {
        Outcome::Linked(link) => Ok(success(json!({"status":"completed","link":link}))),
        Outcome::Pending => Ok(success(json!({"status":"pending"}))),
        Outcome::Invalid => Err(invalid_flow()),
        Outcome::Conflict => Err(ApiError::conflict("GitHub 账号绑定冲突")),
        _ => Err(internal()),
    }
}

async fn read_link(
    State(state): State<NativeState>,
    extension: Option<Extension<GithubOAuth>>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let session = access_claims(&state, &headers).await?;
    ready(&state, extension).await?;
    match run(&state, Operation::Read(session.user_id)).await? {
        Outcome::Link(link) => Ok(success(json!({"link":link}))),
        _ => Err(internal()),
    }
}

async fn remove_link(
    State(state): State<NativeState>,
    extension: Option<Extension<GithubOAuth>>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let session = access_claims(&state, &headers).await?;
    ready(&state, extension).await?;
    match run(&state, Operation::Remove(session)).await? {
        Outcome::Removed => Ok(success(Value::Null)),
        Outcome::Invalid => Err(invalid_flow()),
        Outcome::Missing => Err(ApiError::not_found("GitHub 绑定不存在")),
        Outcome::Conflict => Err(ApiError::conflict("至少保留一种登录方式")),
        _ => Err(internal()),
    }
}
