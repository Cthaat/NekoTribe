use crate::{
    auth::{session_list::session_pagination, sessions::NativeState},
    httpx::errors::ApiError,
    posts::bookmark::interaction_identity,
};
use axum::{
    extract::{OriginalUri, Path, State},
    http::{header::CACHE_CONTROL, HeaderMap, HeaderValue},
    response::{IntoResponse, Response},
    Json,
};
use serde_json::{json, Value};
use std::sync::OnceLock;

pub(crate) fn statement() -> &'static str {
    #[derive(serde::Deserialize)]
    struct Statements {
        list: String,
    }
    static SQL: OnceLock<Statements> = OnceLock::new();
    &SQL.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../../contracts/requirements/post-likers.json"
        ))
        .expect("valid post likers SQL contract")
    })
    .list
}

pub(crate) async fn list(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
) -> Response {
    let result: Result<Json<Value>, ApiError> = async {
        let (viewer, id) = interaction_identity(&state, &raw, &headers).await?;
        let page = session_pagination(uri.query().unwrap_or_default());
        let internal_error = || ApiError::server_error("服务器内部错误");
        let (mut users, total) = state
            .repository
            .list_post_likers(viewer, id, page)
            .await
            .map_err(|_| internal_error())?
            .ok_or_else(|| ApiError::not_found("帖子不存在"))?;
        for user in &mut users {
            let avatar = user["avatar_url"].as_str().unwrap_or_default();
            user["avatar_url"] = state
                .storage_urls
                .normalize_avatar(avatar)
                .map_err(|_| internal_error())?
                .into();
        }
        Ok(Json(json!({"code": 200, "message": "success", "data": users, "meta": {
            "page": page.page, "page_size": page.page_size, "total": total, "has_next": page.end < total as f64
        }})))
    }
    .await;
    let mut response = result.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}
