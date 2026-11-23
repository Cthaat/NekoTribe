use crate::{
    auth::sessions::NativeState,
    httpx::{errors::ApiError, response::V2Response},
    posts::{
        bookmark::interaction_actor, create_request::parse_repost_id, detail::hydrate_post,
        update_request::parse_update_body, update_transaction::PostUpdate,
    },
};
use axum::{
    body::{to_bytes, Body},
    extract::{OriginalUri, State},
    http::{header, HeaderValue, Request},
    response::{IntoResponse, Response},
    Json,
};

pub(crate) async fn edit(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    request: Request<Body>,
) -> Response {
    let result = async {
        let (parts, body) = request.into_parts();
        let actor = interaction_actor(&state, &parts.headers).await?;
        let id = parse_repost_id(
            uri.path()
                .strip_prefix("/api/v2/posts/")
                .unwrap_or_default(),
        )?;
        let bytes = to_bytes(body, 1024 * 1024)
            .await
            .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
        let content_type = parts
            .headers
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or_default();
        let input = parse_update_body(&bytes, content_type)?;
        match state
            .repository
            .update_post_atomic(actor, id, &input)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?
        {
            PostUpdate::Updated => {}
            PostUpdate::Missing => return Err(ApiError::not_found("帖子不存在")),
            PostUpdate::NotOwner => return Err(ApiError::unprocessable("只能修改自己的帖子")),
            PostUpdate::MediaUnavailable => {
                return Err(ApiError::bad_request("附件不存在或无权使用"))
            }
            PostUpdate::ContentEmpty => return Err(ApiError::bad_request("content 不能为空")),
            PostUpdate::Invalid => return Err(ApiError::server_error("服务器内部错误")),
            PostUpdate::PublishForbidden => return Err(ApiError::forbidden(crate::moderation::publish_policy::message())),
            PostUpdate::MarkdownUnavailable => return Err(crate::posts::markdown::unavailable()),
            PostUpdate::MarkdownNotAllowed => return Err(crate::posts::markdown::not_allowed()),
        }
        let post = state
            .repository
            .read_visible_post(Some(actor), id)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?
            .ok_or_else(|| ApiError::not_found("帖子不存在"))?;
        let post = hydrate_post(&state, Some(actor), post).await?;
        Ok(Json(V2Response::ok_with_message(post, "post updated")).into_response())
    }
    .await;
    let mut response = result.into_response();
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("private, no-store"),
    );
    response
}
