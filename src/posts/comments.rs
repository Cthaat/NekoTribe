use crate::{
    auth::{
        session_list::{session_pagination, SessionPage},
        sessions::NativeState,
    },
    httpx::errors::ApiError,
};
use axum::{
    extract::{OriginalUri, Path, State},
    http::HeaderMap,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::{json, Value};

#[derive(Clone, Debug)]
pub struct CommentListQuery {
    pub page: SessionPage,
    pub sort: String,
}

pub(crate) async fn list_comments(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    Path(raw): Path<String>,
    headers: HeaderMap,
) -> Response {
    let mut response = list_comments_inner(state, uri, raw, headers)
        .await
        .into_response();
    response.headers_mut().insert(
        axum::http::header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static("private, no-store"),
    );
    response
}
async fn list_comments_inner(
    state: NativeState,
    uri: axum::http::Uri,
    raw: String,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let (user, id) = crate::posts::bookmark::interaction_identity(&state, &raw, &headers).await?;
    let query_text = uri.query().unwrap_or_default();
    let url = reqwest::Url::parse(&format!("http://localhost/?{query_text}")).expect("fixed URL");
    let sorts: Vec<_> = url
        .query_pairs()
        .filter(|(key, _)| key == "sort")
        .map(|(_, value)| value.into_owned())
        .collect();
    let query = CommentListQuery {
        page: session_pagination(query_text),
        sort: if sorts.len() == 1 {
            sorts[0].clone()
        } else {
            "newest".into()
        },
    };
    let (mut comments, total) = state
        .repository
        .list_post_comments(user, id, &query)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?
        .ok_or_else(|| ApiError::not_found("帖子不存在"))?;
    for comment in &mut comments {
        let object = comment
            .as_object_mut()
            .ok_or_else(|| ApiError::server_error("服务器内部错误"))?;
        let author_id = object
            .remove("author_id")
            .and_then(|v| v.as_u64())
            .ok_or_else(|| ApiError::server_error("服务器内部错误"))?;
        let mut author = state
            .repository
            .read_post_author(Some(user), author_id)
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
        let liked = object
            .remove("is_liked")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        object.insert(
            "viewer_state".into(),
            json!({"is_liked":liked,"can_delete":author_id==user}),
        );
    }
    Ok(Json(json!({"code":200,"message":"success","data":comments,"meta":{"page":query.page.page,"page_size":query.page.page_size,"total":total,"has_next":query.page.end < total as f64}})).into_response())
}
