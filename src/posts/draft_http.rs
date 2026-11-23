use super::{
    bookmark::interaction_actor,
    create_notification::NotificationContext,
    draft_input::{parse_id, parse_payload, parse_query, parse_schedule},
    draft_store::{contract, Operation, Outcome},
};
use crate::{
    auth::sessions::NativeState,
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    body::{to_bytes, Body},
    extract::{OriginalUri, Path, State},
    http::{header::CACHE_CONTROL, HeaderValue, Method, Request},
    response::{IntoResponse, Response},
    routing::{get, post, put},
    Json, Router,
};

pub(crate) fn router() -> Router<NativeState> {
    Router::new()
        .route("/api/v2/users/me/drafts", get(collection).post(collection))
        .route("/api/v2/users/me/drafts/{id}", put(item).delete(item))
        .route(
            "/api/v2/users/me/drafts/{id}/schedule",
            put(item).delete(item),
        )
        .route("/api/v2/users/me/drafts/{id}/publish", post(item))
}

async fn collection(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    request: Request<Body>,
) -> Response {
    respond(state, uri, None, request).await
}

async fn item(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    Path(id): Path<String>,
    request: Request<Body>,
) -> Response {
    respond(state, uri, Some(&id), request).await
}

async fn respond(
    state: NativeState,
    uri: axum::http::Uri,
    id: Option<&str>,
    request: Request<Body>,
) -> Response {
    let result = async {
        let (parts, body) = request.into_parts();
        let owner = interaction_actor(&state, &parts.headers).await?;
        let id = id.map(|value| parse_id(value, "id")).transpose()?;
        let read_body = async move {
            to_bytes(body, contract().max_payload_bytes)
                .await
                .map_err(|_| ApiError::bad_request("请求体参数错误"))
        };
        let (operation, message) = match (parts.method, id) {
            (Method::GET, None) => (
                Operation::List(parse_query(uri.query().unwrap_or_default())?),
                "success",
            ),
            (Method::POST, None) => (
                Operation::Create(parse_payload(&read_body.await?)?),
                "draft saved",
            ),
            (Method::PUT, Some(id)) if uri.path().ends_with("/schedule") => (
                Operation::Schedule(id, parse_schedule(&read_body.await?)?),
                "draft scheduled",
            ),
            (Method::PUT, Some(id)) => (
                Operation::Edit(id, parse_payload(&read_body.await?)?),
                "draft saved",
            ),
            (Method::DELETE, Some(id)) if uri.path().ends_with("/schedule") => {
                (Operation::Unschedule(id), "draft unscheduled")
            }
            (Method::DELETE, Some(id)) => (Operation::Remove(id), "draft deleted"),
            (Method::POST, Some(id)) => (Operation::Publish(id), "draft published"),
            _ => return Err(ApiError::route_not_found()),
        };
        let outcome = state
            .repository
            .post_draft(owner, operation, &state.storage_urls)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?;
        match outcome {
            Outcome::Saved(value, notice) => {
                if let Some(notice) = notice {
                    super::draft_worker::notify(&NotificationContext::from(&state), notice).await;
                }
                Ok(Json(V2Response::ok_with_message(value, message)))
            }
            Outcome::Rejected(error) => Err(error),
        }
    }
    .await;
    let mut response = result.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}
