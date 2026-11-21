use crate::{
    auth::{
        login::js_trim,
        session_list::{number, session_pagination, SessionPage},
        sessions::{percent_decode, NativeState},
    },
    db::{oracle::BindMap, value::DbValue},
    httpx::errors::ApiError,
    users::visibility::{success, viewer},
};
use axum::{
    extract::{OriginalUri, State},
    http::HeaderMap,
    response::Response,
};
use serde_json::{json, Value};
use std::{collections::HashMap, sync::OnceLock};

#[derive(Clone, Debug, PartialEq)]
pub enum DiscoveryQuery {
    Search {
        page: SessionPage,
        pattern: String,
        sort: &'static str,
        verified_only: i64,
    },
    Recommendations {
        limit: f64,
    },
}

impl DiscoveryQuery {
    pub(crate) fn parse(raw: &str, recommendations: bool) -> Self {
        let decode = |value: &str| {
            let value = value.replace('+', " ");
            percent_decode(&value).unwrap_or(value)
        };
        let pairs: Vec<_> = raw
            .split('&')
            .filter(|part| !part.is_empty())
            .map(|part| {
                let (key, value) = part.split_once('=').unwrap_or((part, ""));
                (decode(key), decode(value))
            })
            .collect();
        let single = |key: &str| {
            let mut values = pairs.iter().filter(|(name, _)| name == key);
            let first = values.next()?.1.as_ref();
            values.next().is_none().then_some(first)
        };
        if recommendations {
            return Self::Recommendations {
                limit: single("limit").and_then(number).unwrap_or(10.0).min(50.0),
            };
        }
        let query = js_trim(single("q").unwrap_or_default()).to_lowercase();
        Self::Search {
            page: session_pagination(raw),
            pattern: format!("%{query}%"),
            sort: match single("sort") {
                Some("newest") => "newest",
                Some("oldest") => "oldest",
                _ => "popular",
            },
            verified_only: i64::from(single("verified") == Some("true")),
        }
    }

    pub(crate) fn oracle_query(self, viewer: u64) -> (&'static str, BindMap) {
        static QUERIES: OnceLock<HashMap<String, String>> = OnceLock::new();
        let queries = QUERIES.get_or_init(|| {
            serde_json::from_str(include_str!(
                "../../contracts/requirements/user-discovery-sql.json"
            ))
            .expect("valid user discovery SQL")
        });
        let mut binds = BindMap::from([("viewer_id".into(), DbValue::I64(viewer as i64))]);
        let statement = match self {
            Self::Search {
                page,
                pattern,
                sort,
                verified_only,
            } => {
                binds.extend([
                    ("pattern".into(), DbValue::String(pattern)),
                    ("sort_mode".into(), DbValue::String(sort.into())),
                    ("verified_only".into(), DbValue::I64(verified_only)),
                    ("start_row".into(), DbValue::F64(page.start)),
                    ("end_row".into(), DbValue::F64(page.end)),
                ]);
                "search"
            }
            Self::Recommendations { limit } => {
                binds.insert("row_limit".into(), DbValue::F64(limit));
                "recommendations"
            }
        };
        (&queries[statement], binds)
    }
}

pub(crate) async fn list(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let actor = viewer(&state, &headers).await?;
    let query = DiscoveryQuery::parse(
        uri.query().unwrap_or_default(),
        uri.path() == "/api/v2/users/recommendations",
    );
    let server_error = || ApiError::server_error("服务器内部错误");
    let (mut users, total) = state
        .repository
        .discover_users(actor, query.clone())
        .await
        .map_err(|_| server_error())?;
    for user in &mut users {
        let avatar = user
            .get("avatar_url")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let url = state
            .storage_urls
            .normalize_avatar(avatar)
            .map_err(|_| server_error())?;
        user.as_object_mut()
            .ok_or_else(server_error)?
            .insert("avatar_url".into(), Value::String(url));
    }
    let meta = match query {
        DiscoveryQuery::Search { page, .. } => {
            json!({"page":page.page,"page_size":page.page_size,"total":total,"has_next":page.end < total as f64})
        }
        DiscoveryQuery::Recommendations { limit } => json!({"limit":limit}),
    };
    Ok(success(
        json!({"code":200,"message":"success","data":users,"meta":meta}),
    ))
}
