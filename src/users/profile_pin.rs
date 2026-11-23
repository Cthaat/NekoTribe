use crate::{
    auth::{readiness, sessions::NativeState},
    db::{
        oracle::{BindMap, DbError},
        tx::{OracleTx, Transaction},
        value::DbValue,
    },
    httpx::{errors::ApiError, response::V2Response},
    posts::{
        bookmark::{interaction_actor, interaction_identity},
        detail::hydrate_post,
    },
};
use axum::{
    body::{to_bytes, Body},
    extract::{Path, State},
    http::{header::CACHE_CONTROL, HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, put},
    Json, Router,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::OnceLock;

const MAX_ID: u64 = 9_007_199_254_740_991;

#[derive(Deserialize)]
struct Contract {
    sql: Sql,
}

#[derive(Deserialize)]
struct Sql {
    owner: String,
    eligible: String,
    read: String,
    write: String,
    remove: String,
}

fn sql() -> &'static Sql {
    static CONTRACT: OnceLock<Contract> = OnceLock::new();
    &CONTRACT
        .get_or_init(|| {
            serde_json::from_str(include_str!(
                "../../contracts/requirements/profile-pinned-post.json"
            ))
            .expect("valid profile pinned post contract")
        })
        .sql
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Operation {
    Read(u64),
    Set(u64),
    Clear,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    Read(Option<u64>),
    Set(u64),
    Cleared,
    MissingOwner,
    Ineligible,
    Unavailable,
}

fn number(key: &str, value: u64) -> (String, DbValue) {
    (key.to_owned(), DbValue::I64(value as i64))
}

pub(crate) fn execute(
    connection: &oracle::Connection,
    actor: u64,
    operation: Operation,
) -> Result<Outcome, DbError> {
    let ready = readiness::collect_profile_pin_snapshot(connection).and_then(|snapshot| {
        readiness::validate_feature_snapshot(&snapshot, "profile-pinned-post")
            .map_err(|_| DbError::SchemaNotReady)
    });
    if ready.is_err() {
        return Ok(Outcome::Unavailable);
    }
    run(&OracleTx::new(connection), actor, operation)
}

fn run(tx: &impl Transaction, actor: u64, operation: Operation) -> Result<Outcome, DbError> {
    if let Operation::Read(profile) = operation {
        let binds = BindMap::from([number("profile_id", profile), number("viewer_id", actor)]);
        let rows = tx.query(&sql().read, binds)?;
        let post = rows
            .first()
            .map(|row| {
                row.get("POST_ID")
                    .and_then(DbValue::as_i64)
                    .and_then(|id| u64::try_from(id).ok())
                    .filter(|id| (1..=MAX_ID).contains(id))
                    .ok_or_else(|| DbError::ExpectedNumber("POST_ID".into()))
            })
            .transpose()?;
        return Ok(Outcome::Read(post));
    }
    let result = write(tx, actor, operation);
    match result {
        Ok(outcome @ (Outcome::Set(_) | Outcome::Cleared)) => {
            if let Err(error) = tx.commit() {
                let _ = tx.rollback();
                return Err(error);
            }
            Ok(outcome)
        }
        result => {
            tx.rollback()?;
            result
        }
    }
}

fn write(tx: &impl Transaction, actor: u64, operation: Operation) -> Result<Outcome, DbError> {
    let sql = sql();
    let mut binds = BindMap::from([number("user_id", actor)]);
    if tx.query(&sql.owner, binds.clone())?.is_empty() {
        return Ok(Outcome::MissingOwner);
    }
    match operation {
        Operation::Set(id) => {
            binds.extend([number("post_id", id)]);
            if tx.query(&sql.eligible, binds.clone())?.is_empty() {
                return Ok(Outcome::Ineligible);
            }
            crate::chat_message_send::write_one(tx, &sql.write, binds)?;
            Ok(Outcome::Set(id))
        }
        Operation::Clear => match tx.execute(&sql.remove, binds)? {
            0 | 1 => Ok(Outcome::Cleared),
            _ => Err(DbError::SchemaNotReady),
        },
        Operation::Read(_) => Err(DbError::SchemaNotReady),
    }
}

pub(crate) fn router() -> Router<NativeState> {
    Router::new()
        .route("/api/v2/users/{id}/pinned-post", get(get_pin))
        .route(
            "/api/v2/users/me/pinned-post",
            put(set_pin).delete(clear_pin),
        )
}

fn parse_post(raw: &[u8]) -> Result<u64, ApiError> {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Payload {
        post_id: f64,
    }

    let invalid = || ApiError::bad_request("post_id 参数错误");
    let Payload { post_id } = serde_json::from_slice(raw).map_err(|_| invalid())?;
    if !(1.0..=MAX_ID as f64).contains(&post_id) || post_id.fract() != 0.0 {
        return Err(invalid());
    }
    Ok(post_id as u64)
}

async fn get_pin(
    State(state): State<NativeState>,
    Path(profile): Path<String>,
    headers: HeaderMap,
) -> Response {
    private(
        async {
            let (viewer, profile) = interaction_identity(&state, &profile, &headers).await?;
            respond(&state, viewer, Operation::Read(profile)).await
        }
        .await,
    )
}

async fn set_pin(State(state): State<NativeState>, headers: HeaderMap, body: Body) -> Response {
    private(
        async {
            let actor = interaction_actor(&state, &headers).await?;
            let raw = to_bytes(body, 1 << 20)
                .await
                .map_err(|_| ApiError::bad_request("post_id 参数错误"))?;
            respond(&state, actor, Operation::Set(parse_post(&raw)?)).await
        }
        .await,
    )
}

async fn clear_pin(State(state): State<NativeState>, headers: HeaderMap) -> Response {
    private(
        async {
            let actor = interaction_actor(&state, &headers).await?;
            respond(&state, actor, Operation::Clear).await
        }
        .await,
    )
}

fn private(result: Result<Json<V2Response<Value>>, ApiError>) -> Response {
    let mut response = result.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}

async fn respond(
    state: &NativeState,
    actor: u64,
    operation: Operation,
) -> Result<Json<V2Response<Value>>, ApiError> {
    let outcome = state
        .repository
        .profile_pin(actor, operation)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    let response = match outcome {
        Outcome::Read(post) => {
            let post = match post {
                Some(id) => read_hydrated(state, actor, id).await?,
                None => None,
            };
            V2Response::ok(json!({ "post": post }))
        }
        Outcome::Set(id) => V2Response::ok_with_message(json!({ "post_id": id }), "post pinned"),
        Outcome::Cleared => V2Response::ok_with_message(Value::Null, "post unpinned"),
        Outcome::MissingOwner => return Err(ApiError::not_found("账号不存在")),
        Outcome::Ineligible => return Err(ApiError::not_found("帖子不存在")),
        Outcome::Unavailable => {
            return Err(ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                50301,
                "服务暂不可用，请稍后重试。",
            ))
        }
    };
    Ok(Json(response))
}

async fn read_hydrated(
    state: &NativeState,
    actor: u64,
    id: u64,
) -> Result<Option<Value>, ApiError> {
    let post = state
        .repository
        .read_visible_post(Some(actor), id)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    let Some(post) = post else {
        return Ok(None);
    };
    match hydrate_post(state, Some(actor), post).await {
        Ok(post) => Ok(Some(post)),
        Err(error) if error.status() == StatusCode::NOT_FOUND => Ok(None),
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod tests;
