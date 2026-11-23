use crate::{
    auth::sessions::{access_token, NativeState},
    group_content::{parse_content_id, parse_post_id},
    httpx::{errors::ApiError, response::V2Response},
    posts::{
        bookmark::interaction_actor,
        polls::{parse_ballot, Operation, Outcome, Target},
    },
};
use axum::{
    body::{to_bytes, Body},
    extract::{Path, State},
    http::{header::CACHE_CONTROL, HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use std::collections::HashMap;

pub(crate) fn router() -> Router<NativeState> {
    Router::new()
        .route("/api/v2/posts/{id}/poll", get(read))
        .route("/api/v2/posts/{id}/poll/vote", post(vote))
        .route("/api/v2/groups/{id}/posts/{post_id}/poll", get(read))
        .route("/api/v2/groups/{id}/posts/{post_id}/poll/vote", post(vote))
}

pub(crate) fn unavailable() -> ApiError {
    ApiError::new(
        StatusCode::SERVICE_UNAVAILABLE,
        50301,
        "服务暂不可用，请稍后重试。",
    )
}

async fn read(
    State(state): State<NativeState>,
    Path(params): Path<HashMap<String, String>>,
    headers: HeaderMap,
) -> Response {
    respond(state, params, headers, None).await
}

async fn vote(
    State(state): State<NativeState>,
    Path(params): Path<HashMap<String, String>>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    respond(state, params, headers, Some(body)).await
}

async fn respond(
    state: NativeState,
    params: HashMap<String, String>,
    headers: HeaderMap,
    body: Option<Body>,
) -> Response {
    let result = async {
        let grouped = params.get("post_id");
        let voting = body.is_some();
        let viewer = if grouped.is_some() || voting || !access_token(&headers).is_empty() {
            Some(interaction_actor(&state, &headers).await?)
        } else {
            None
        };
        let id = parse_content_id(params.get("id").map_or("", String::as_str), "id")? as i64;
        let target = match grouped {
            Some(raw) => Target::Group {
                group_id: id,
                post_id: parse_post_id(raw)? as i64,
            },
            None => Target::Regular(id),
        };
        let operation = if let Some(body) = body {
            let bytes = to_bytes(body, 1 << 20)
                .await
                .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
            Operation::Vote(parse_ballot(&bytes)?)
        } else {
            Operation::Read
        };
        let outcome = state
            .repository
            .post_poll(viewer, target, operation)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?;
        let poll = match outcome {
            Outcome::Found(poll) => poll,
            Outcome::MissingPost if grouped.is_some() => {
                return Err(ApiError::not_found("群组帖子不存在"))
            }
            Outcome::MissingPost => return Err(ApiError::not_found("帖子不存在")),
            Outcome::MissingGroup => return Err(ApiError::not_found("群组不存在")),
            Outcome::MissingPoll => return Err(ApiError::not_found("投票不存在")),
            Outcome::Forbidden => return Err(ApiError::forbidden("无权参与群组投票")),
            Outcome::Closed => return Err(ApiError::conflict("投票已截止")),
            Outcome::Duplicate => return Err(ApiError::conflict("已提交选票")),
            Outcome::InvalidChoice => return Err(ApiError::bad_request("投票选项与原帖不匹配")),
            Outcome::Unavailable => return Err(unavailable()),
        };
        let message = if voting { "vote recorded" } else { "success" };
        Ok::<_, ApiError>(Json(V2Response::ok_with_message(poll, message)))
    }
    .await;
    let mut response = result.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}
