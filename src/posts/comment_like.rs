use crate::{
    auth::sessions::NativeState,
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    extract::{Path, State},
    http::HeaderMap,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::{json, Map, Value};

pub(crate) async fn add(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
) -> Response {
    respond(state, raw, headers, true).await
}
pub(crate) async fn remove(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
) -> Response {
    respond(state, raw, headers, false).await
}
async fn respond(state: NativeState, raw: String, headers: HeaderMap, liked: bool) -> Response {
    let mut response = run(state, raw, headers, liked).await.into_response();
    response.headers_mut().insert(
        axum::http::header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static("private, no-store"),
    );
    response
}
async fn run(
    state: NativeState,
    raw: String,
    headers: HeaderMap,
    liked: bool,
) -> Result<Response, ApiError> {
    let (viewer, id) = super::bookmark::interaction_identity(&state, &raw, &headers).await?;
    let outcome = state
        .repository
        .set_comment_like(viewer, id, liked)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?
        .ok_or_else(|| ApiError::not_found("评论不存在"))?;
    if outcome.inserted {
        if let Some(stored) = state
            .repository
            .prepare_comment_like_notification(viewer, id)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?
        {
            if let Some(mut notification) = state
                .repository
                .read_notification(stored.recipient, stored.id)
                .await
                .map_err(|_| ApiError::server_error("服务器内部错误"))?
            {
                crate::notifications::hydrate_notification(
                    &state,
                    stored.recipient,
                    &mut notification,
                )
                .await?;
                if stored.push_enabled {
                    let mut data = Map::new();
                    data.insert("notification".into(), notification);
                    data.insert("notification_type".into(), Value::String("like".into()));
                    let sent = match &state.notification_publisher {
                        Some(p) => p
                            .publish(stored.recipient, "notification_created", &data)
                            .await
                            .is_ok(),
                        None => false,
                    };
                    if !sent {
                        eprintln!("notification delivery unavailable");
                    }
                }
            }
        }
    }
    Ok(Json(V2Response::ok(
        json!({"comment_id":id,"is_liked":liked,"likes_count":outcome.count}),
    ))
    .into_response())
}
