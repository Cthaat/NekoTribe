use crate::{
    auth::sessions::NativeState,
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    body::{to_bytes, Body},
    extract::{Path, State},
    http::Request,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::Value;
use serde_json::{json, Map};

#[derive(Debug, PartialEq)]
pub enum CommentCreation {
    PublishForbidden,
    Created(Value),
    PostUnavailable,
    ParentUnavailable,
    CommentUnavailable,
}

#[derive(Clone, Debug)]
pub struct CommentNoticeContext {
    pub actor_name: String,
    pub post_author: Option<u64>,
    pub comment_excerpt: String,
    pub post_excerpt: String,
}
#[derive(Clone, Debug)]
pub struct CommentParentNotice {
    pub author: Option<u64>,
    pub excerpt: String,
}
#[derive(Clone, Debug)]
pub struct CommentNoticeInput {
    pub recipient: u64,
    pub actor: u64,
    pub comment_id: u64,
    pub title: String,
    pub message: String,
    pub metadata_json: String,
}
#[derive(Clone, Debug)]
pub struct StoredCommentNotification {
    pub recipient: u64,
    pub id: u64,
    pub push_enabled: bool,
}

fn parent_id(value: Option<&Value>) -> Result<Option<u64>, ApiError> {
    let error = || ApiError::bad_request("parent_comment_id 参数错误");
    let number = match value {
        None | Some(Value::Null) => return Ok(None),
        Some(Value::String(s)) if s.is_empty() => return Ok(None),
        Some(Value::String(s)) => {
            if s.starts_with('0') || !s.bytes().all(|b| b.is_ascii_digit()) {
                return Err(error());
            }
            s.parse::<u64>().map_err(|_| error())?
        }
        Some(Value::Number(n)) => {
            let n = n
                .as_f64()
                .filter(|v| *v >= 1.0 && *v <= 9_007_199_254_740_991.0 && v.fract() == 0.0)
                .ok_or_else(error)?;
            n as u64
        }
        _ => return Err(error()),
    };
    if number == 0 || number > 9_007_199_254_740_991 {
        return Err(error());
    }
    Ok(Some(number))
}

pub(crate) async fn create(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    request: Request<Body>,
) -> Response {
    let mut response = create_inner(state, raw, request).await.into_response();
    response.headers_mut().insert(
        axum::http::header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static("private, no-store"),
    );
    response
}
async fn create_inner(
    state: NativeState,
    raw: String,
    request: Request<Body>,
) -> Result<Response, ApiError> {
    let (parts, body) = request.into_parts();
    let (user, post) =
        crate::posts::bookmark::interaction_identity(&state, &raw, &parts.headers).await?;
    let bytes = to_bytes(body, 1024 * 1024)
        .await
        .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
    let body = crate::auth::login::request_body(&parts.headers, &bytes)?;
    let parent = parent_id(body.get("parent_comment_id"))?;
    let raw_content = crate::auth::login::scalar(body.get("content"));
    let content = crate::auth::login::js_trim(&raw_content);
    if content.is_empty() {
        return Err(ApiError::bad_request("content 不能为空"));
    }
    let mut comment = match state
        .repository
        .create_post_comment(user, post, content, parent)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?
    {
        CommentCreation::Created(value) => value,
        CommentCreation::PublishForbidden => return Err(ApiError::forbidden(crate::moderation::publish_policy::message())),
        CommentCreation::PostUnavailable => return Err(ApiError::not_found("帖子不存在")),
        CommentCreation::ParentUnavailable => return Err(ApiError::not_found("父评论不存在")),
        CommentCreation::CommentUnavailable => return Err(ApiError::not_found("评论不存在")),
    };
    let comment_id = comment
        .get("comment_id")
        .and_then(Value::as_u64)
        .ok_or_else(|| ApiError::server_error("服务器内部错误"))?;
    let notice = state
        .repository
        .comment_notice_context(user, post, comment_id)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    if let Some(recipient) = notice.post_author {
        let meta=format!("{{\"post_id\":{post},\"target_post_id\":{post},\"comment_id\":{comment_id},\"comment_excerpt\":{},\"post_excerpt\":{},\"event\":\"comment_created\"}}",notice.comment_excerpt,notice.post_excerpt);
        let input = CommentNoticeInput {
            recipient,
            actor: user,
            comment_id,
            title: format!("{} 评论了你的推文", notice.actor_name),
            message: "你的推文收到了一条新评论。".into(),
            metadata_json: meta,
        };
        deliver(&state, &input).await?;
    }
    if let Some(parent) = parent {
        let parent_notice = state
            .repository
            .comment_parent_notice(parent, notice.post_author)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?;
        if let Some(recipient) = parent_notice
            .author
            .filter(|id| Some(*id) != notice.post_author)
        {
            let meta=format!("{{\"post_id\":{post},\"target_post_id\":{post},\"comment_id\":{comment_id},\"parent_comment_id\":{parent},\"comment_excerpt\":{},\"parent_comment_excerpt\":{},\"post_excerpt\":{},\"event\":\"comment_reply\"}}",notice.comment_excerpt,parent_notice.excerpt,notice.post_excerpt);
            let input = CommentNoticeInput {
                recipient,
                actor: user,
                comment_id,
                title: format!("{} 回复了你的评论", notice.actor_name),
                message: "你的评论收到了一条新回复。".into(),
                metadata_json: meta,
            };
            deliver(&state, &input).await?;
        }
    }
    let object = comment
        .as_object_mut()
        .ok_or_else(|| ApiError::server_error("服务器内部错误"))?;
    if object.remove("author_id").and_then(|v| v.as_u64()) != Some(user) {
        return Err(ApiError::server_error("服务器内部错误"));
    }
    object.remove("is_liked");
    let mut author = state
        .repository
        .read_post_author(Some(user), user)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?
        .ok_or_else(|| ApiError::not_found("用户不存在"))?;
    let avatar = author
        .get("avatar_url")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let avatar = state
        .storage_urls
        .normalize_avatar(avatar)
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    author
        .as_object_mut()
        .ok_or_else(|| ApiError::server_error("服务器内部错误"))?
        .insert("avatar_url".into(), avatar.into());
    object.insert("author".into(), author);
    object.insert(
        "viewer_state".into(),
        json!({"is_liked":false,"can_delete":true}),
    );
    Ok(Json(V2Response::ok_with_message(comment, "comment created")).into_response())
}
async fn deliver(state: &NativeState, input: &CommentNoticeInput) -> Result<(), ApiError> {
    let stored = state
        .repository
        .store_comment_notification(input)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    if let Some(stored) = stored {
        if let Some(mut item) = state
            .repository
            .read_notification(stored.recipient, stored.id)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?
        {
            crate::notifications::hydrate_notification(state, stored.recipient, &mut item).await?;
            if stored.push_enabled {
                let mut data = Map::new();
                data.insert("notification".into(), item);
                data.insert("notification_type".into(), "comment".into());
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
    Ok(())
}
