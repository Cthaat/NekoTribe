use crate::{
    ai::model_quota::{self, AiModelQuota},
    auth::{
        session_repository::{nullable_text, row_number, row_text},
        sessions::NativeState,
    },
    httpx::{errors::ApiError, response::V2Response},
    posts::bookmark::interaction_actor,
};
use axum::{
    extract::{OriginalUri, State},
    http::{header, HeaderMap, HeaderValue},
    response::{IntoResponse, Response},
    Extension, Json,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{fmt::Write, sync::OnceLock};

#[derive(Deserialize)]
struct Contract {
    sql: Queries,
}

#[derive(Deserialize)]
struct Queries {
    usage: String,
    posts: String,
    bookmarks: String,
}

pub enum ResourceQuery {
    Usage,
    Posts,
    Bookmarks,
}

impl ResourceQuery {
    pub(crate) fn sql(&self) -> &'static str {
        static CONTRACT: OnceLock<Contract> = OnceLock::new();
        let sql = &CONTRACT
            .get_or_init(|| {
                serde_json::from_str(include_str!(
                    "../../contracts/requirements/account-resources.json"
                ))
                .expect("valid account resources contract")
            })
            .sql;
        match self {
            Self::Usage => &sql.usage,
            Self::Posts => &sql.posts,
            Self::Bookmarks => &sql.bookmarks,
        }
    }
}

fn private(mut response: Response) -> Response {
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("private, no-store"),
    );
    response
}

pub(crate) async fn usage(
    State(state): State<NativeState>,
    quota: Option<Extension<AiModelQuota>>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let actor = interaction_actor(&state, &headers).await?;
    let rows = state
        .repository
        .account_resources(actor, ResourceQuery::Usage)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    let row = rows
        .first()
        .ok_or_else(|| ApiError::server_error("服务器内部错误"))?;
    let ai_quota = model_quota::account_usage(quota.as_ref().map(|quota| &quota.0), actor).await;
    Ok(private(
        Json(V2Response::ok(json!({
            "ai_quota": ai_quota,
            "media": { "bytes": row_number(row, "BYTES"), "files": row_number(row, "FILES") },
            "ai_history": { "conversations": row_number(row, "CONVERSATIONS") }
        })))
        .into_response(),
    ))
}

#[derive(Serialize)]
struct Bookmark {
    post_id: i64,
    created_at: String,
}

#[derive(Serialize)]
struct Post {
    #[serde(flatten)]
    bookmark: Bookmark,
    content: Option<String>,
}

#[derive(Serialize)]
struct AccountExport {
    posts: Vec<Post>,
    bookmarks: Vec<Bookmark>,
}

impl AccountExport {
    fn markdown(&self) -> String {
        let mut out = "# NekoTribe account export\n\n## Posts\n\n".to_owned();
        for post in &self.posts {
            let _ = write!(
                out,
                "### Post {}\n\n{}\n\n",
                post.bookmark.post_id, post.bookmark.created_at
            );
            if let Some(content) = post
                .content
                .as_deref()
                .filter(|content| !content.is_empty())
            {
                for line in content
                    .replace("\r\n", "\n")
                    .replace('\r', "\n")
                    .split('\n')
                {
                    let _ = writeln!(out, "    {line}");
                }
                out.push('\n');
            }
        }
        out.push_str("## Bookmarks\n\n");
        for bookmark in &self.bookmarks {
            let _ = writeln!(out, "- Post {} · {}", bookmark.post_id, bookmark.created_at);
        }
        out
    }
}

#[derive(Deserialize, Default)]
struct ExportQuery {
    format: Option<String>,
}

pub(crate) async fn export(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let actor = interaction_actor(&state, &headers).await?;
    let query = axum::extract::Query::<ExportQuery>::try_from_uri(&uri)
        .map_err(|_| ApiError::bad_request("format 参数错误"))?
        .0;
    let format = query.format.as_deref().unwrap_or("json");
    if !matches!(format, "json" | "markdown") {
        return Err(ApiError::bad_request("format 参数错误"));
    }
    let posts = state
        .repository
        .account_resources(actor, ResourceQuery::Posts)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    let bookmarks = state
        .repository
        .account_resources(actor, ResourceQuery::Bookmarks)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    let bookmark = |row: &crate::db::row::DbRow| Bookmark {
        post_id: row_number(row, "POST_ID"),
        created_at: row_text(row, "CREATED_AT"),
    };
    let data = AccountExport {
        posts: posts
            .iter()
            .map(|row| Post {
                bookmark: bookmark(row),
                content: nullable_text(row, "CONTENT"),
            })
            .collect(),
        bookmarks: bookmarks.iter().map(bookmark).collect(),
    };
    let (response, filename) = if format == "markdown" {
        let response = (
            [(header::CONTENT_TYPE, "text/markdown; charset=utf-8")],
            data.markdown(),
        )
            .into_response();
        (response, "attachment; filename=\"nekotribe-account.md\"")
    } else {
        (
            Json(data).into_response(),
            "attachment; filename=\"nekotribe-account.json\"",
        )
    };
    let mut response = private(response);
    response.headers_mut().insert(
        header::CONTENT_DISPOSITION,
        HeaderValue::from_static(filename),
    );
    Ok(response)
}
