use crate::{
    auth::{
        session_list::number,
        session_repository::{row_float, row_number, row_text},
        sessions::NativeState,
    },
    db::{oracle::BindMap, row::DbRow, value::DbValue},
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

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum AnalyticsKind {
    Post,
    Summary,
    Daily { days: i64 },
}

pub enum AnalyticsOutcome {
    Missing,
    NotOwner,
    Data(Value),
}

impl AnalyticsKind {
    pub(crate) fn oracle_query(self, viewer: u64, id: u64) -> (&'static str, BindMap) {
        #[derive(serde::Deserialize)]
        struct Statements {
            post: String,
            summary: String,
            daily: String,
        }
        static SQL: OnceLock<Statements> = OnceLock::new();
        let sql = SQL.get_or_init(|| {
            serde_json::from_str(include_str!(
                "../contracts/requirements/content-analytics.json"
            ))
            .expect("valid content analytics SQL")
        });
        let mut binds = BindMap::from([
            ("viewer_id".into(), DbValue::I64(viewer as i64)),
            ("target_id".into(), DbValue::I64(id as i64)),
        ]);
        let statement = match self {
            Self::Post => &sql.post,
            Self::Summary => &sql.summary,
            Self::Daily { days } => {
                binds.insert("days".into(), DbValue::I64(days));
                &sql.daily
            }
        };
        (statement, binds)
    }

    pub(crate) fn map_rows(self, rows: &[DbRow]) -> AnalyticsOutcome {
        let Some(row) = rows.first() else {
            return AnalyticsOutcome::Missing;
        };
        let value = match self {
            Self::Post => {
                if row_number(row, "IS_OWNER") != 1 {
                    return AnalyticsOutcome::NotOwner;
                }
                if row_number(row, "STATS_POST_ID") <= 0 {
                    return AnalyticsOutcome::Missing;
                }
                json!({
                    "post_id": row_number(row, "POST_ID"),
                    "views_count": row_number(row, "VIEWS_COUNT"),
                    "likes_count": row_number(row, "LIKES_COUNT"),
                    "comments_count": row_number(row, "COMMENTS_COUNT"),
                    "replies_count": row_number(row, "REPLIES_COUNT"),
                    "retweets_count": row_number(row, "RETWEETS_COUNT"),
                    "engagement_score": row_float(row, "ENGAGEMENT_SCORE"),
                    "like_rate": row_float(row, "LIKE_RATE")
                })
            }
            Self::Summary => json!({
                "user_id": row_number(row, "USER_ID"),
                "total_posts": row_number(row, "TOTAL_POSTS"),
                "posts_this_week": row_number(row, "POSTS_THIS_WEEK"),
                "posts_this_month": row_number(row, "POSTS_THIS_MONTH"),
                "total_likes_received": row_number(row, "TOTAL_LIKES_RECEIVED"),
                "avg_likes_per_post": row_float(row, "AVG_LIKES_PER_POST"),
                "total_likes_given": row_number(row, "TOTAL_LIKES_GIVEN"),
                "total_comments_made": row_number(row, "TOTAL_COMMENTS_MADE"),
                "engagement_score": row_float(row, "ENGAGEMENT_SCORE")
            }),
            Self::Daily { .. } => Value::Array(
                rows.iter()
                    .map(|row| {
                        json!({
                            "day": row_text(row, "DAY"),
                            "posts_count": row_number(row, "POSTS_COUNT"),
                            "likes_received": row_number(row, "LIKES_RECEIVED"),
                            "comments_received": row_number(row, "COMMENTS_RECEIVED"),
                            "retweets_received": row_number(row, "RETWEETS_RECEIVED"),
                            "likes_given": row_number(row, "LIKES_GIVEN"),
                            "comments_made": row_number(row, "COMMENTS_MADE"),
                            "engagement_score": row_number(row, "ENGAGEMENT_SCORE")
                        })
                    })
                    .collect(),
            ),
        };
        AnalyticsOutcome::Data(value)
    }
}

fn daily_days(query: &str) -> i64 {
    let url = reqwest::Url::parse(&format!("http://localhost/?{query}")).expect("fixed URL");
    let mut values = url.query_pairs().filter(|(key, _)| key == "days");
    let first = values.next().and_then(|(_, value)| number(&value));
    let days = if values.next().is_some() { None } else { first };
    days.unwrap_or(14.0).clamp(7.0, 90.0) as i64
}

pub(crate) async fn read(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
) -> Response {
    let result: Result<Json<Value>, ApiError> = async {
        let (viewer, id) = interaction_identity(&state, &raw, &headers).await?;
        let kind = if uri.path().ends_with("/daily") {
            if viewer != id {
                return Err(ApiError::not_found("用户不存在"));
            }
            AnalyticsKind::Daily {
                days: daily_days(uri.query().unwrap_or_default()),
            }
        } else if uri.path().starts_with("/api/v2/posts/") {
            AnalyticsKind::Post
        } else {
            AnalyticsKind::Summary
        };
        let outcome = state
            .repository
            .read_content_analytics(viewer, id, kind)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?;
        match outcome {
            AnalyticsOutcome::Missing => Err(ApiError::not_found(if kind == AnalyticsKind::Post {
                "帖子不存在"
            } else {
                "用户不存在"
            })),
            AnalyticsOutcome::NotOwner => Err(ApiError::unprocessable("只能查看自己帖子的统计")),
            AnalyticsOutcome::Data(data) => {
                let message = if matches!(kind, AnalyticsKind::Daily { .. }) {
                    "user daily analytics"
                } else {
                    "success"
                };
                Ok(Json(
                    json!({"code": 200, "message": message, "data": data, "meta": null}),
                ))
            }
        }
    }
    .await;
    let mut response = result.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}
