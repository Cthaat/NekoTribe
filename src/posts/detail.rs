use crate::{
    auth::{
        sessions::{access_token, NativeState},
        TokenKind,
    },
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    extract::{OriginalUri, Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use serde_json::Value;
fn failure() -> ApiError {
    ApiError::server_error("服务器内部错误")
}
fn normalize_user(state: &NativeState, user: &mut Value) -> Result<(), ApiError> {
    let avatar = user
        .get("avatar_url")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let avatar = state
        .storage_urls
        .normalize_avatar(avatar)
        .map_err(|_| failure())?;
    user.as_object_mut()
        .ok_or_else(failure)?
        .insert("avatar_url".into(), Value::String(avatar));
    Ok(())
}
pub(crate) async fn get_post(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    Path(raw): Path<String>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let token = access_token(&headers);
    let viewer = if token.is_empty() {
        let segment = uri.path().strip_prefix("/api/v2/posts/").unwrap_or("");
        if segment.is_empty()
            || segment.starts_with('0')
            || !segment.bytes().all(|b| b.is_ascii_digit())
        {
            return Err(ApiError::unauthorized("请先登录"));
        }
        None
    } else {
        let claims = state
            .codec
            .verify(&token, TokenKind::Access, (state.clock)())
            .map_err(|_| ApiError::unauthorized("Token无效或已过期"))?;
        if state.repository.touch(&claims).await.unwrap_or(0) != 1 {
            return Err(ApiError::unauthorized("Token无效或已过期"));
        };
        Some(claims.user_id)
    };
    if raw.is_empty() || raw.starts_with('0') || !raw.bytes().all(|b| b.is_ascii_digit()) {
        return Err(ApiError::bad_request("id 参数错误"));
    };
    let id = raw
        .parse::<u64>()
        .ok()
        .filter(|x| *x > 0 && *x <= 9_007_199_254_740_991)
        .ok_or_else(|| ApiError::bad_request("id 参数错误"))?;
    let mut post = state
        .repository
        .read_visible_post(viewer, id)
        .await
        .map_err(|_| failure())?
        .ok_or_else(|| ApiError::not_found("帖子不存在"))?;
    let author_id = post
        .get("author")
        .and_then(|v| v.get("user_id"))
        .and_then(Value::as_u64)
        .ok_or_else(failure)?;
    let mut author = state
        .repository
        .read_post_author(viewer, author_id)
        .await
        .map_err(|_| failure())?
        .ok_or_else(|| ApiError::not_found("用户不存在"))?;
    normalize_user(&state, &mut author)?;
    state.repository.media_readiness().await.map_err(|_| {
        ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            50301,
            "服务暂不可用，请稍后重试。",
        )
    })?;
    let mut media = state
        .repository
        .read_post_media(id)
        .await
        .map_err(|_| failure())?;
    for item in &mut media {
        let public = item
            .get("public_url")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let public = state
            .storage_urls
            .normalize_avatar(public)
            .map_err(|_| failure())?;
        let thumbnail = match item.get("thumbnail_url").and_then(Value::as_str) {
            Some(v) if !v.is_empty() => Value::String(
                state
                    .storage_urls
                    .normalize_avatar(v)
                    .map_err(|_| failure())?,
            ),
            _ => Value::Null,
        };
        let obj = item.as_object_mut().ok_or_else(failure)?;
        obj.insert("public_url".into(), public.into());
        obj.insert("thumbnail_url".into(), thumbnail);
    }
    let tags = state
        .repository
        .read_post_tags(id)
        .await
        .map_err(|_| failure())?;
    let mut mentions = state
        .repository
        .read_post_mentions(viewer, id)
        .await
        .map_err(|_| failure())?;
    for user in &mut mentions {
        normalize_user(&state, user)?;
    }
    let object = post.as_object_mut().ok_or_else(failure)?;
    object.insert("author".into(), author);
    object.insert("media".into(), media.into());
    object.insert(
        "tags".into(),
        serde_json::to_value(tags).map_err(|_| failure())?,
    );
    object.insert("mentions".into(), mentions.into());
    state
        .repository
        .increment_post_views(id)
        .await
        .map_err(|_| failure())?;
    let mut response = Json(V2Response::ok(post)).into_response();
    response.headers_mut().insert(
        axum::http::header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static("private, no-store"),
    );
    Ok(response)
}
