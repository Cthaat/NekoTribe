use crate::{
    auth::{
        session_list::{session_pagination, SessionPage},
        sessions::{access_token, NativeState},
        TokenKind,
    },
    httpx::errors::ApiError,
    posts::detail::{attached_content, hydrate_post_details},
};
use axum::{
    extract::{OriginalUri, Path, State},
    http::HeaderMap,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::json;

#[derive(Clone, Debug, PartialEq)]
pub struct PostListQuery {
    pub page: SessionPage,
    pub mode: String,
    pub timeline: String,
    pub sort: String,
    pub search: String,
    pub tag_search: String,
    pub target_id: Option<u64>,
    pub tag_name: Option<String>,
}
pub fn parse_post_list_query(raw: &str) -> PostListQuery {
    let url = reqwest::Url::parse(&format!("http://localhost/?{raw}")).expect("fixed URL");
    let pairs: Vec<_> = url.query_pairs().collect();
    let single = |key: &str, default: &str| {
        let values: Vec<_> = pairs.iter().filter(|(name, _)| name == key).collect();
        if values.len() == 1 {
            values[0].1.to_string()
        } else {
            default.to_owned()
        }
    };
    let trim = |s: &str| {
        s.trim_matches(|c: char| (c.is_whitespace() && c != '\u{0085}') || c == '\u{feff}')
            .to_owned()
    };
    let search = trim(&single("q", "")).to_lowercase();
    let tag = trim(search.trim_start_matches('#'));
    let tag_search = if tag.is_empty() { search.clone() } else { tag };
    PostListQuery {
        page: session_pagination(raw),
        mode: "all".into(),
        timeline: single("timeline", "home"),
        sort: single("sort", "newest"),
        search,
        tag_search,
        target_id: None,
        tag_name: None,
    }
}
pub(crate) async fn list_posts(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    list_with_target(state, uri, headers, None).await
}

pub(crate) async fn scoped_posts(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    Path(target): Path<String>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    list_with_target(state, uri, headers, Some(target)).await
}

async fn list_with_target(
    state: NativeState,
    uri: axum::http::Uri,
    headers: HeaderMap,
    target: Option<String>,
) -> Result<Response, ApiError> {
    let token = access_token(&headers);
    let mode = match uri.path() {
        "/api/v2/posts/trending" => "trending",
        "/api/v2/users/me/posts" => "me",
        "/api/v2/users/me/bookmarks" => "bookmarks",
        "/api/v2/users/me/likes" => "likes",
        path if path.starts_with("/api/v2/users/") && path.ends_with("/posts") => "user",
        path if path.starts_with("/api/v2/tags/") && path.ends_with("/posts") => "tag",
        path if path.starts_with("/api/v2/posts/") && path.ends_with("/replies") => "replies",
        path if path.starts_with("/api/v2/posts/") && path.ends_with("/retweets") => "retweets",
        _ => "all",
    };
    if token.is_empty() && !matches!(mode, "all" | "trending") {
        return Err(ApiError::unauthorized("请先登录"));
    }
    let viewer = if token.is_empty() {
        None
    } else {
        let claims = state
            .codec
            .verify(&token, TokenKind::Access, (state.clock)())
            .map_err(|_| ApiError::unauthorized("Token无效或已过期"))?;
        if state.repository.touch(&claims).await.unwrap_or(0) != 1 {
            return Err(ApiError::unauthorized("Token无效或已过期"));
        }
        Some(claims.user_id)
    };
    let mut query = parse_post_list_query(uri.query().unwrap_or_default());
    query.mode = mode.to_owned();
    if let Some(raw) = target {
        if mode == "tag" {
            if raw.is_empty() {
                return Err(ApiError::bad_request("name 参数错误"));
            }
            query.tag_name = Some(raw);
        } else {
            if raw.is_empty() || raw.starts_with('0') || !raw.bytes().all(|b| b.is_ascii_digit()) {
                return Err(ApiError::bad_request("id 参数错误"));
            }
            let id = raw
                .parse::<u64>()
                .ok()
                .filter(|id| *id > 0 && *id <= 9_007_199_254_740_991)
                .ok_or_else(|| ApiError::bad_request("id 参数错误"))?;
            query.target_id = Some(id);
        }
    }
    if mode == "trending" {
        query.sort = "popular".to_owned();
    }
    if viewer.is_none() && (query.timeline == "following" || query.timeline == "mentions") {
        return Err(ApiError::unauthorized("未认证或 token 无效"));
    }
    let (rows, total) = state
        .repository
        .list_visible_posts(viewer, &query)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    let mut posts = Vec::with_capacity(rows.len());
    let attachments = attached_content(&state, viewer, &rows).await?;
    for (row, attached) in rows.into_iter().zip(attachments) {
        posts.push(hydrate_post_details(&state, viewer, row, attached).await?);
    }
    let mut response = Json(json!({"code":200,"message":"success","data":posts,"meta":{"page":query.page.page,"page_size":query.page.page_size,"total":total,"has_next":query.page.end < total as f64}})).into_response();
    response.headers_mut().insert(
        axum::http::header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static("private, no-store"),
    );
    Ok(response)
}
