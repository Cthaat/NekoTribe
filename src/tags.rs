use crate::{
    auth::{
        session_list::SessionPage,
        sessions::{access_token, NativeState},
        TokenKind,
    },
    httpx::errors::ApiError,
    posts::list::parse_post_list_query,
};
use axum::{
    extract::{OriginalUri, Path, State},
    http::HeaderMap,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::json;

#[derive(Debug, Clone, PartialEq)]
pub struct TagListQuery {
    pub page: SessionPage,
    pub q: Option<String>,
    pub trending: bool,
}
pub(crate) async fn tag_analytics(
    State(state): State<NativeState>,
    Path(name): Path<String>,
    headers: HeaderMap,
) -> Response {
    let mut response = tag_analytics_inner(state, name, headers)
        .await
        .into_response();
    response.headers_mut().insert(
        axum::http::header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static("private, no-store"),
    );
    response
}
async fn tag_analytics_inner(
    state: NativeState,
    name: String,
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
    if name.is_empty() {
        return Err(ApiError::bad_request("name 参数错误"));
    }
    let result = state
        .repository
        .read_tag_analytics(claims.user_id, &name)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?
        .ok_or_else(|| ApiError::not_found("话题不存在"))?;
    Ok(Json(json!({"code":200,"message":"success","data":result,"meta":null})).into_response())
}
pub(crate) async fn list_tags(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
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
    let values = parse_post_list_query(uri.query().unwrap_or_default());
    let trending = uri.path() == "/api/v2/tags/trending";
    let q = if !trending && !values.search.is_empty() {
        Some(format!("%{}%", values.search))
    } else {
        None
    };
    let query = TagListQuery {
        page: values.page,
        q,
        trending,
    };
    let (items, total) = state
        .repository
        .list_tags(&query)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    let mut response=Json(json!({"code":200,"message":"success","data":items,"meta":{"page":query.page.page,"page_size":query.page.page_size,"total":total,"has_next":query.page.end<total as f64}})).into_response();
    response.headers_mut().insert(
        axum::http::header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static("private, no-store"),
    );
    Ok(response)
}
