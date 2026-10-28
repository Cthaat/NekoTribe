use crate::{
    auth::sessions::NativeState,
    httpx::{errors::ApiError, response::V2Response},
    posts::{
        bookmark::interaction_actor,
        create_notification::notify_created,
        create_request::{parse_create_body, parse_repost_id},
        create_transaction::PostCreation,
        detail::hydrate_post,
    },
};
use axum::{
    body::{to_bytes, Body},
    extract::{OriginalUri, State},
    http::{header, HeaderValue, Request},
    response::{IntoResponse, Response},
    Json,
};

pub(crate) async fn create(State(state): State<NativeState>, request: Request<Body>) -> Response {
    private_response(create_inner(&state, None, request).await)
}

pub(crate) async fn retweet(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    request: Request<Body>,
) -> Response {
    let raw = uri
        .path()
        .strip_prefix("/api/v2/posts/")
        .and_then(|s| s.strip_suffix("/retweets"))
        .unwrap_or("");
    private_response(create_inner(&state, Some(raw), request).await)
}

fn private_response(result: Result<Response, ApiError>) -> Response {
    let mut response = result.into_response();
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("private, no-store"),
    );
    response
}

async fn create_inner(
    state: &NativeState,
    raw: Option<&str>,
    request: Request<Body>,
) -> Result<Response, ApiError> {
    let (parts, body) = request.into_parts();
    let actor = interaction_actor(state, &parts.headers).await?;
    let repost = raw.map(parse_repost_id).transpose()?;
    let bytes = to_bytes(body, 1024 * 1024)
        .await
        .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
    let content_type = parts
        .headers
        .get(header::CONTENT_TYPE)
        .and_then(|h| h.to_str().ok())
        .unwrap_or_default();
    let input = parse_create_body(&bytes, content_type, repost)?;
    let post_id = match state
        .repository
        .create_post_atomic(actor, &input)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?
    {
        PostCreation::Created(id) => id,
        PostCreation::ReferenceUnavailable => return Err(ApiError::not_found("帖子不存在")),
        PostCreation::MediaUnavailable => return Err(ApiError::bad_request("媒体不存在或不可用")),
        PostCreation::ContentEmpty => return Err(ApiError::bad_request("content 不能为空")),
        PostCreation::Invalid => return Err(ApiError::server_error("服务器内部错误")),
    };
    notify_created(state, actor, post_id, &input).await?;
    let post = state
        .repository
        .read_visible_post(Some(actor), post_id)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?
        .ok_or_else(|| ApiError::not_found("帖子不存在"))?;
    let post = hydrate_post(state, Some(actor), post).await?;
    let message = if input.repost_of_post_id.is_some() {
        "retweet created"
    } else {
        "post created"
    };
    Ok(Json(V2Response::ok_with_message(post, message)).into_response())
}
