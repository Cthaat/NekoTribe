use crate::{
    auth::{
        session_list::{session_pagination, SessionPage},
        sessions::{access_token, NativeState},
        TokenKind,
    },
    httpx::errors::ApiError,
};
use axum::{
    body::{to_bytes, Body},
    extract::{OriginalUri, Path, State},
    http::{HeaderMap, Request},
    response::{IntoResponse, Response},
    Json,
};
use serde_json::{json, Value};

#[derive(Clone, Debug, PartialEq)]
pub struct NotificationQuery {
    pub page: SessionPage,
    pub kind: String,
    pub unread_only: bool,
    pub show_deleted: bool,
}

#[derive(Clone, Debug, PartialEq, serde::Serialize)]
pub struct NotificationReadResult {
    pub notification_id: u64,
    pub is_read: u8,
    pub read_at: Option<String>,
}

pub(crate) fn read_flag(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Bool(v)) => *v,
        Some(Value::Number(v)) => v.as_f64() == Some(1.0),
        Some(Value::String(v)) => matches!(v.to_lowercase().as_str(), "1" | "true" | "yes"),
        _ => false,
    }
}

pub(crate) async fn delete_notification(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
) -> Response {
    set_deleted(state, raw, headers, false).await
}
pub(crate) async fn restore_notification(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
) -> Response {
    set_deleted(state, raw, headers, true).await
}
async fn set_deleted(
    state: NativeState,
    raw: String,
    headers: HeaderMap,
    restore: bool,
) -> Response {
    let mut response = set_deleted_inner(state, raw, headers, restore)
        .await
        .into_response();
    response.headers_mut().insert(
        axum::http::header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static("private, no-store"),
    );
    response
}
async fn set_deleted_inner(
    state: NativeState,
    raw: String,
    headers: HeaderMap,
    restore: bool,
) -> Result<Response, ApiError> {
    let (user, id) = crate::posts::bookmark::interaction_identity(&state, &raw, &headers).await?;
    let date = state
        .repository
        .set_notification_deleted(user, id, restore)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?
        .ok_or_else(|| ApiError::not_found("通知不存在"))?;
    let data = json!({"notification_id":id,"deleted_at":date});
    let kind = if restore {
        "notification_restored"
    } else {
        "notification_deleted"
    };
    let delivered = match &state.notification_publisher {
        Some(p) => p
            .publish(user, kind, data.as_object().expect("object"))
            .await
            .is_ok(),
        None => false,
    };
    if !delivered {
        eprintln!("notification delivery unavailable");
    }
    if restore {
        Ok(Json(crate::httpx::response::V2Response::ok(data)).into_response())
    } else {
        Ok(Json(crate::httpx::response::V2NullResponse::null(
            "notification deleted",
        ))
        .into_response())
    }
}

pub(crate) async fn set_batch_read(
    State(state): State<NativeState>,
    request: Request<Body>,
) -> Response {
    let mut response = set_batch_read_inner(state, request).await.into_response();
    response.headers_mut().insert(
        axum::http::header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static("private, no-store"),
    );
    response
}

async fn set_batch_read_inner(
    state: NativeState,
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
    let body = crate::auth::login::request_body(&parts.headers, &bytes)?;
    let mut ids = Vec::new();
    if let Some(value) = body.get("notification_ids") {
        let values = value
            .as_array()
            .filter(|v| v.len() <= 1000)
            .ok_or_else(|| ApiError::bad_request("notification_ids 参数错误"))?;
        for value in values {
            let n = value
                .as_f64()
                .filter(|n| *n >= 1.0 && *n <= 9007199254740991.0 && n.fract() == 0.0)
                .ok_or_else(|| ApiError::bad_request("notification_ids 参数错误"))?;
            ids.push(n as u64);
        }
    }
    let read = read_flag(body.get("is_read"));
    let updated = state
        .repository
        .batch_set_notification_read(claims.user_id, &ids, read)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    let data = if ids.is_empty() {
        json!({"all":true,"is_read":u8::from(read),"updated_count":updated})
    } else {
        json!({"notification_ids":ids,"is_read":u8::from(read),"updated_count":updated})
    };
    let published = match &state.notification_publisher {
        Some(p) => p
            .publish(
                claims.user_id,
                "notifications_read_status_updated",
                data.as_object().expect("object"),
            )
            .await
            .is_ok(),
        None => false,
    };
    if !published {
        eprintln!("notification delivery unavailable");
    }
    Ok(Json(crate::httpx::response::V2Response::ok(
        json!({"updated_count":updated}),
    ))
    .into_response())
}

#[cfg(test)]
mod single_read_vectors {
    use super::*;
    #[test]
    fn shared_boolean_cases() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../contracts/scenarios/notification-single-read.json"
        ))
        .unwrap();
        let cases = fixture["cases"].as_array().unwrap();
        assert_eq!(cases.len(), 11);
        for case in cases {
            assert_eq!(
                read_flag(case.get("value")),
                case["expected"].as_bool().unwrap(),
                "{}",
                case["id"]
            );
        }
    }
}

pub(crate) async fn set_read(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    request: Request<Body>,
) -> Response {
    let mut response = set_read_inner(state, raw, request).await.into_response();
    response.headers_mut().insert(
        axum::http::header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static("private, no-store"),
    );
    response
}
async fn set_read_inner(
    state: NativeState,
    raw: String,
    request: Request<Body>,
) -> Result<Response, ApiError> {
    let (parts, body) = request.into_parts();
    let (user, id) =
        crate::posts::bookmark::interaction_identity(&state, &raw, &parts.headers).await?;
    let bytes = to_bytes(body, 1024 * 1024)
        .await
        .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
    let body = crate::auth::login::request_body(&parts.headers, &bytes)?;
    let read = read_flag(body.get("is_read"));
    let result = state
        .repository
        .set_notification_read(user, id, read)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?
        .ok_or_else(|| ApiError::not_found("通知不存在"))?;
    let data = serde_json::to_value(&result)
        .map_err(|_| ApiError::server_error("服务器内部错误"))?
        .as_object()
        .cloned()
        .ok_or_else(|| ApiError::server_error("服务器内部错误"))?;
    let published = match &state.notification_publisher {
        Some(p) => p
            .publish(user, "notification_read_status_updated", &data)
            .await
            .is_ok(),
        None => false,
    };
    if !published {
        eprintln!("notification delivery unavailable");
    }
    Ok(Json(crate::httpx::response::V2Response::ok(result)).into_response())
}
pub fn parse_notification_query(raw: &str) -> NotificationQuery {
    let url = reqwest::Url::parse(&format!("http://localhost/?{raw}")).expect("fixed URL");
    let pairs: Vec<_> = url.query_pairs().collect();
    let one = |key: &str, default: &str| {
        let values: Vec<_> = pairs.iter().filter(|(k, _)| k == key).collect();
        if values.len() == 1 {
            values[0].1.to_string()
        } else {
            default.to_owned()
        }
    };
    NotificationQuery {
        page: session_pagination(raw),
        kind: one("type", "all"),
        unread_only: one("unread_only", "false") == "true",
        show_deleted: one("show_deleted", "false") == "true",
    }
}

pub(crate) async fn hydrate_notification(
    state: &NativeState,
    viewer: u64,
    item: &mut Value,
) -> Result<(), ApiError> {
    let object = item
        .as_object_mut()
        .ok_or_else(|| ApiError::server_error("服务器内部错误"))?;
    let actor_id = object
        .remove("actor_id")
        .and_then(|v| v.as_u64())
        .filter(|v| *v > 0);
    let actor = if let Some(id) = actor_id {
        match state
            .repository
            .public_profile(viewer, id)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?
        {
            Some(mut profile) => {
                let avatar = profile
                    .get("avatar_url")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let normalized = state
                    .storage_urls
                    .normalize_avatar(avatar)
                    .map_err(|_| ApiError::server_error("服务器内部错误"))?;
                profile
                    .as_object_mut()
                    .ok_or_else(|| ApiError::server_error("服务器内部错误"))?
                    .insert("avatar_url".into(), normalized.into());
                profile
            }
            None => Value::Null,
        }
    } else {
        Value::Null
    };
    object.insert("actor".into(), actor);
    Ok(())
}
pub(crate) async fn list(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
) -> Response {
    let mut response = list_inner(state, uri.query().unwrap_or_default(), headers)
        .await
        .into_response();
    response.headers_mut().insert(
        axum::http::header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static("private, no-store"),
    );
    response
}
async fn list_inner(
    state: NativeState,
    raw: &str,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let token = access_token(&headers);
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
    let query = parse_notification_query(raw);
    let (mut items, total) = state
        .repository
        .list_notifications(claims.user_id, &query)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    for item in &mut items {
        hydrate_notification(&state, claims.user_id, item).await?;
    }
    #[derive(serde::Serialize)]
    struct Envelope {
        code: u16,
        message: &'static str,
        data: Vec<Box<serde_json::value::RawValue>>,
        meta: Value,
    }
    let data = items
        .iter()
        .map(crate::notification_events::notification_json_raw)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    Ok(Json(Envelope{code:200,message:"success",data,meta:json!({"page":query.page.page,"page_size":query.page.page_size,"total":total,"has_next":query.page.end<total as f64})}).into_response())
}
