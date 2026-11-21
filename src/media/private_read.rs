use crate::{
    auth::sessions::{percent_decode, NativeState, SessionStoreError},
    db::{
        oracle::{BindMap, DbError},
        pool::OraclePool,
        value::DbValue,
    },
    httpx::errors::ApiError,
    posts::bookmark::interaction_actor,
    storage::{
        local_http::{read_private, LocalStorageConfig},
        local_policy::normalize_local_key,
    },
};
use axum::{
    extract::{OriginalUri, State},
    http::{header, HeaderMap, HeaderValue, Method, StatusCode},
    response::{IntoResponse, Response},
    Extension,
};
use serde::Deserialize;
use std::sync::OnceLock;

const MAX_SAFE_ID: i64 = 9_007_199_254_740_991;
pub(crate) const CONTENT_ROUTE: &str = "/api/v2/media/{id}/content";

pub enum Lookup {
    Missing,
    SchemaUnavailable,
    Permitted {
        storage_key: String,
        access_scope: String,
    },
}

pub(crate) struct PrivateKey(String);

impl PrivateKey {
    fn new(raw: &str, scope: &str) -> Option<Self> {
        let prefix = match scope {
            "chat" => "private/chat/",
            "post" => "private/post/",
            _ => return None,
        };
        let key = normalize_local_key(raw).ok()?;
        key.starts_with(prefix).then_some(Self(key))
    }

    pub(crate) fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Deserialize)]
struct ReadContract {
    query: String,
}

fn query() -> &'static str {
    static CONTRACT: OnceLock<ReadContract> = OnceLock::new();
    &CONTRACT
        .get_or_init(|| {
            serde_json::from_str(include_str!(
                "../../contracts/requirements/media-private-read.json"
            ))
            .expect("valid private media read contract")
        })
        .query
}

pub(crate) async fn lookup(
    pool: &OraclePool,
    viewer_id: i64,
    media_id: i64,
) -> Result<Lookup, SessionStoreError> {
    if !(1..=MAX_SAFE_ID).contains(&viewer_id) || !(1..=MAX_SAFE_ID).contains(&media_id) {
        return Ok(Lookup::Missing);
    }
    let result = pool
        .query_one(
            query(),
            BindMap::from([
                ("viewer_id".into(), DbValue::I64(viewer_id)),
                ("media_id".into(), DbValue::I64(media_id)),
            ]),
        )
        .await;
    match result {
        Ok(Some(row)) => {
            let key = row.get("STORAGE_KEY").and_then(DbValue::as_str);
            let scope = row.get("ACCESS_SCOPE").and_then(DbValue::as_str);
            match (key, scope) {
                (Some(storage_key), Some(access_scope)) => Ok(Lookup::Permitted {
                    storage_key: storage_key.to_owned(),
                    access_scope: access_scope.to_owned(),
                }),
                _ => Ok(Lookup::Missing),
            }
        }
        Ok(None) => Ok(Lookup::Missing),
        Err(error) if missing_schema(&error) => Ok(Lookup::SchemaUnavailable),
        Err(_) => Err(SessionStoreError),
    }
}

pub(super) fn missing_schema(error: &DbError) -> bool {
    matches!(error, DbError::Oracle(error) if error.db_error().is_some_and(|error| matches!(error.code(), 904 | 942)))
}

fn media_id(path: &str) -> Option<i64> {
    let raw = path
        .strip_prefix("/api/v2/media/")?
        .strip_suffix("/content")?;
    let id = percent_decode(raw)?;
    if id.starts_with('0') || !id.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    id.parse::<i64>()
        .ok()
        .filter(|id| (1..=MAX_SAFE_ID).contains(id))
}

fn missing() -> ApiError {
    ApiError::not_found("媒体不存在")
}

pub(super) fn unavailable() -> ApiError {
    ApiError::new(StatusCode::SERVICE_UNAVAILABLE, 50301, "媒体存储暂不可用")
}

pub(crate) fn content_url(media_id: i64) -> Option<String> {
    (1..=MAX_SAFE_ID)
        .contains(&media_id)
        .then(|| format!("/api/v2/media/{media_id}/content"))
}

pub(crate) async fn read(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
    method: Method,
    config: Option<Extension<LocalStorageConfig>>,
) -> Response {
    let result = async {
        let viewer = interaction_actor(&state, &headers).await?;
        let viewer_id = i64::try_from(viewer)
            .ok()
            .filter(|id| (1..=MAX_SAFE_ID).contains(id))
            .ok_or_else(|| ApiError::unauthorized("Token无效或已过期"))?;
        let media_id = media_id(uri.path()).ok_or_else(|| ApiError::bad_request("id 参数错误"))?;
        let key = match state
            .repository
            .lookup_private_media(viewer_id, media_id)
            .await
        {
            Ok(Lookup::Permitted {
                storage_key,
                access_scope,
            }) => PrivateKey::new(&storage_key, &access_scope).ok_or_else(missing)?,
            Ok(Lookup::Missing) => return Err(missing()),
            Ok(Lookup::SchemaUnavailable) => return Err(unavailable()),
            Err(_) => return Err(ApiError::server_error("服务器内部错误")),
        };
        let config = config
            .map(|extension| extension.0)
            .unwrap_or_else(|| LocalStorageConfig::from_lookup(|_| None));
        if config.unsupported {
            return Err(unavailable());
        }
        let mut response = read_private(config, &key, &headers, method == Method::HEAD).await;
        match response.status() {
            StatusCode::NOT_FOUND => return Err(missing()),
            StatusCode::SERVICE_UNAVAILABLE => return Err(unavailable()),
            StatusCode::INTERNAL_SERVER_ERROR => {
                return Err(ApiError::server_error("服务器内部错误"))
            }
            StatusCode::RANGE_NOT_SATISFIABLE => {
                let mut error =
                    ApiError::new(StatusCode::RANGE_NOT_SATISFIABLE, 41601, "请求范围无效")
                        .into_response();
                if let Some(range) = response.headers().get(header::CONTENT_RANGE) {
                    error
                        .headers_mut()
                        .insert(header::CONTENT_RANGE, range.clone());
                }
                return Ok(error);
            }
            StatusCode::OK | StatusCode::PARTIAL_CONTENT => {
                let headers = response.headers_mut();
                headers.insert(
                    header::CONTENT_TYPE,
                    HeaderValue::from_static("application/octet-stream"),
                );
                headers.insert(
                    header::CONTENT_DISPOSITION,
                    HeaderValue::from_static("attachment"),
                );
                headers.remove(header::ETAG);
                headers.remove(header::LAST_MODIFIED);
            }
            _ => {}
        }
        Ok(response)
    }
    .await;
    let mut response = result.into_response();
    let headers = response.headers_mut();
    headers.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("private, no-store"),
    );
    headers.insert(
        "x-content-type-options",
        HeaderValue::from_static("nosniff"),
    );
    response
}
