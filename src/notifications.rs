use crate::{
    auth::{
        session_list::{session_pagination, SessionPage},
        sessions::{access_token, NativeState},
        TokenKind,
    },
    httpx::errors::ApiError,
};
use axum::{
    extract::{OriginalUri, State},
    http::HeaderMap,
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
    Ok(Json(json!({"code":200,"message":"success","data":items,"meta":{"page":query.page.page,"page_size":query.page.page_size,"total":total,"has_next":query.page.end<total as f64}})).into_response())
}
