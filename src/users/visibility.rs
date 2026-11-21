use crate::{
    auth::{
        login::request_body,
        session_list::session_pagination,
        sessions::{access_token, NativeState},
        TokenKind,
    },
    db::{
        oracle::{BindMap, DbError},
        tx::OracleTx,
        value::DbValue,
    },
    httpx::errors::ApiError,
};
use axum::{
    body::{to_bytes, Body},
    extract::{OriginalUri, Path, State},
    http::{header::CACHE_CONTROL, HeaderMap, HeaderValue, Method, Request},
    response::{IntoResponse, Response},
    Json,
};
use chrono::Datelike;
use serde_json::{json, Value};
use std::{collections::HashMap, sync::LazyLock};

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Blocks,
    Mutes,
}

impl Kind {
    fn from_path(path: &str) -> Self {
        if path.starts_with("/api/v2/users/me/mutes") {
            Self::Mutes
        } else {
            Self::Blocks
        }
    }
    pub(crate) fn list_statement(self) -> &'static str {
        statement(match self {
            Self::Blocks => "blocks",
            Self::Mutes => "mutes",
        })
    }
}

pub(crate) fn statement(name: &str) -> &'static str {
    static SQL: LazyLock<HashMap<String, String>> = LazyLock::new(|| {
        serde_json::from_str(include_str!(
            "../../contracts/requirements/user-visibility-sql.json"
        ))
        .expect("valid user visibility SQL contract")
    });
    &SQL[name]
}

pub(crate) fn write_transaction(
    connection: &oracle::Connection,
    actor: u64,
    target: u64,
    kind: Kind,
    remove: bool,
    expiry: Option<String>,
) -> Result<bool, DbError> {
    let tx = OracleTx::new(connection);
    let actor = actor as i64;
    let target = target as i64;
    let mut binds = BindMap::from([
        ("actor_id".into(), DbValue::I64(actor)),
        ("target_id".into(), DbValue::I64(target)),
    ]);
    let result = (|| {
        if remove {
            let name = if kind == Kind::Blocks {
                "unblock"
            } else {
                "unmute"
            };
            tx.execute(statement(name), binds)?;
        } else {
            if !lock_user_pair(connection, actor, target)? {
                return Ok(false);
            }
            if connection
                .query_named(statement("activeTarget"), &[("target_id", &target)])?
                .next()
                .transpose()?
                .is_none()
            {
                return Ok(false);
            }
            if kind == Kind::Blocks {
                tx.execute(statement("block"), binds.clone())?;
                tx.execute(statement("cancelFollows"), binds)?;
            } else {
                binds.insert(
                    "expires_at".into(),
                    expiry.map_or(DbValue::Null, |s| {
                        DbValue::String(s.trim_end_matches('Z').to_owned() + "+00:00")
                    }),
                );
                tx.execute(statement("mute"), binds)?;
            }
        }
        tx.commit()?;
        Ok(true)
    })();
    if !matches!(result, Ok(true)) {
        tx.rollback()?;
    }
    result
}

pub(crate) fn lock_user_pair(
    connection: &oracle::Connection,
    actor: i64,
    target: i64,
) -> Result<bool, DbError> {
    let ids = [actor.min(target), actor.max(target)];
    for id in ids.iter().take(if actor == target { 1 } else { 2 }) {
        if connection
            .query_named(statement("lockUser"), &[("user_id", id)])?
            .next()
            .transpose()?
            .is_none()
        {
            return Ok(false);
        }
    }
    Ok(true)
}

fn server_error() -> ApiError {
    ApiError::server_error("服务器内部错误")
}

fn parse_mute_expiry(value: Option<&Value>) -> Result<Option<String>, ApiError> {
    let invalid = || ApiError::bad_request("expires_at 参数错误");
    if value.is_none() || value == Some(&Value::Null) || value.and_then(Value::as_str) == Some("") {
        return Ok(None);
    }
    let raw = value.and_then(Value::as_str).ok_or_else(invalid)?;
    static PATTERN: LazyLock<regex::Regex> = LazyLock::new(|| {
        regex::Regex::new(
        r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\.[0-9]{1,9})?(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])$"
    ).expect("valid timestamp pattern")
    });
    if raw.starts_with("0000") || !PATTERN.is_match(raw) {
        return Err(invalid());
    }
    let instant = chrono::DateTime::parse_from_rfc3339(raw)
        .map_err(|_| invalid())?
        .to_utc();
    if !(1..=9999).contains(&instant.year()) {
        return Err(invalid());
    }
    Ok(Some(
        instant.to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
    ))
}

pub(crate) async fn viewer(state: &NativeState, headers: &HeaderMap) -> Result<u64, ApiError> {
    let token = access_token(headers);
    if token.is_empty() {
        return Err(ApiError::unauthorized("请先登录"));
    }
    let invalid = || ApiError::unauthorized("Token无效或已过期");
    let claims = state
        .codec
        .verify(&token, TokenKind::Access, (state.clock)())
        .map_err(|_| invalid())?;
    if state.repository.touch(&claims).await.unwrap_or(0) != 1 {
        return Err(invalid());
    }
    Ok(claims.user_id)
}

pub(crate) fn success(body: Value) -> Response {
    let mut response = Json(body).into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}

pub(crate) async fn list(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let viewer = viewer(&state, &headers).await?;
    let kind = Kind::from_path(uri.path());
    let page = session_pagination(uri.query().unwrap_or_default());
    let (mut items, total) = state
        .repository
        .list_user_visibility(viewer, kind, page)
        .await
        .map_err(|_| server_error())?;
    for user in &mut items {
        user["avatar_url"] = state
            .storage_urls
            .normalize_avatar(user["avatar_url"].as_str().unwrap_or_default())
            .map_err(|_| server_error())?
            .into();
    }
    Ok(success(
        json!({"code":200,"message":"success","data":items,"meta":{
            "page":page.page,"page_size":page.page_size,"total":total,"has_next":page.end < total as f64
        }}),
    ))
}

pub(crate) async fn write(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    request: Request<Body>,
) -> Result<Response, ApiError> {
    let (parts, body) = request.into_parts();
    let actor = viewer(&state, &parts.headers).await?;
    let target = raw
        .parse::<u64>()
        .ok()
        .filter(|target| {
            !raw.starts_with('0')
                && raw.bytes().all(|b| b.is_ascii_digit())
                && *target <= 9_007_199_254_740_991
        })
        .ok_or_else(|| ApiError::bad_request("target_id 参数错误"))?;
    let kind = Kind::from_path(parts.uri.path());
    let remove = parts.method == Method::DELETE;
    if actor == target && !remove {
        return Err(ApiError::unprocessable(if kind == Kind::Blocks {
            "不能屏蔽自己"
        } else {
            "不能静音自己"
        }));
    }
    let mut expiry = None;
    if !remove && kind == Kind::Mutes {
        let bytes = to_bytes(body, 1024 * 1024)
            .await
            .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
        if !bytes.is_empty() {
            expiry = parse_mute_expiry(request_body(&parts.headers, &bytes)?.get("expires_at"))?;
        }
    }
    let found = state
        .repository
        .write_user_visibility(actor, target, kind, remove, expiry.clone())
        .await
        .map_err(|_| server_error())?;
    if !found {
        return Err(ApiError::not_found("用户不存在"));
    }
    let data = match (remove, kind) {
        (true, _) => json!({"target_user_id":target,"relationship":"none"}),
        (false, Kind::Blocks) => json!({"target_user_id":target,"relationship":"blocking"}),
        (false, Kind::Mutes) => {
            json!({"target_user_id":target,"relationship":"muted","expires_at":expiry})
        }
    };
    Ok(success(
        json!({"code":200,"message":"success","data":data,"meta":null}),
    ))
}
