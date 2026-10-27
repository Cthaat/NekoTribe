use crate::{
    auth::{
        sessions::{access_token, NativeState},
        TokenKind,
    },
    httpx::errors::ApiError,
};
use axum::{
    extract::{OriginalUri, State},
    http::HeaderMap,
    response::{IntoResponse, Response},
    Json,
};
use regex::Regex;
use serde::Serialize;
use serde_json::json;
use std::sync::OnceLock;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SessionPage {
    pub page: f64,
    pub page_size: f64,
    pub start: f64,
    pub end: f64,
}
#[derive(Clone, Debug, Serialize)]
pub struct SessionItem {
    pub session_id: String,
    pub device_info: String,
    pub ip_address: String,
    pub last_accessed_at: String,
    pub created_at: String,
    pub is_current: bool,
}

fn number(value: &str) -> Option<f64> {
    static DECIMAL: OnceLock<Regex> = OnceLock::new();
    let value =
        value.trim_matches(|c: char| (c.is_whitespace() && c != '\u{0085}') || c == '\u{feff}');
    let decimal = DECIMAL.get_or_init(|| {
        Regex::new(r"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$").unwrap()
    });
    let n = if decimal.is_match(value) {
        value.parse::<f64>().ok()?
    } else {
        let (radix, digits) = if let Some(s) = value
            .strip_prefix("0x")
            .or_else(|| value.strip_prefix("0X"))
        {
            (16, s)
        } else if let Some(s) = value
            .strip_prefix("0b")
            .or_else(|| value.strip_prefix("0B"))
        {
            (2, s)
        } else if let Some(s) = value
            .strip_prefix("0o")
            .or_else(|| value.strip_prefix("0O"))
        {
            (8, s)
        } else {
            return None;
        };
        if digits.is_empty() {
            return None;
        }
        let mut n = 0.0;
        for c in digits.chars() {
            let digit = c.to_digit(radix)?;
            n = n * f64::from(radix) + f64::from(digit);
        }
        n
    };
    (n.is_finite() && n > 0.0).then_some(n)
}
pub fn session_pagination(query: &str) -> SessionPage {
    let parsed = reqwest::Url::parse(&format!("http://localhost/?{query}")).expect("fixed URL");
    let pairs: Vec<_> = parsed.query_pairs().collect();
    let get = |key: &str, default: f64, max: f64| {
        let values: Vec<_> = pairs.iter().filter(|(k, _)| k == key).collect();
        let n = if values.len() == 1 {
            number(&values[0].1).unwrap_or(default)
        } else {
            default
        };
        n.clamp(1.0, max)
    };
    let page = get("page", 1.0, 10000.0);
    let page_size = get("page_size", 20.0, 100.0);
    SessionPage {
        page,
        page_size,
        start: (page - 1.0) * page_size + 1.0,
        end: page * page_size,
    }
}
pub(crate) async fn list_sessions(
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
    let page = session_pagination(uri.query().unwrap_or_default());
    let (mut items, total) = state
        .repository
        .list_sessions(claims.user_id, page)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    for item in &mut items {
        item.is_current = item.session_id == claims.session_id;
    }
    Ok(Json(json!({"code":200,"message":"success","data":items,"meta":{"page":page.page,"page_size":page.page_size,"total":total,"has_next":page.end < total as f64}})).into_response())
}
