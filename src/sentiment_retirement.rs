use axum::{
    extract::OriginalUri,
    http::{header::CACHE_CONTROL, HeaderValue, Method, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::OnceLock;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Retirement {
    prefix: String,
    config: Value,
    config_message: String,
    retired_message: String,
    operations: Vec<Operation>,
}

#[derive(Deserialize)]
struct Operation {
    method: String,
    path: String,
}

fn policy() -> &'static Retirement {
    static POLICY: OnceLock<Retirement> = OnceLock::new();
    POLICY.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../contracts/requirements/sentiment-retirement.json"
        ))
        .expect("valid sentiment retirement contract")
    })
}

fn matches_path(pattern: &str, path: &str) -> bool {
    let mut segments = path.split('/');
    for part in pattern.split('/') {
        let Some(actual) = segments.next() else {
            return false;
        };
        let parameter = part.starts_with('{') && part.ends_with('}');
        if part != actual && !(parameter && !actual.is_empty()) {
            return false;
        }
    }
    segments.next().is_none()
}

pub(crate) fn response(method: &Method, path: &str) -> Option<Response> {
    let policy = policy();
    let suffix = path.trim_end_matches('/').strip_prefix(&policy.prefix)?;
    let path = match suffix {
        "" => "",
        other => other.strip_prefix('/')?,
    };
    let (status, code, message, data) = if method == Method::GET && path == "config" {
        (
            StatusCode::OK,
            200,
            policy.config_message.as_str(),
            &policy.config,
        )
    } else if policy
        .operations
        .iter()
        .any(|op| op.method == method.as_str() && matches_path(&op.path, path))
    {
        (
            StatusCode::GONE,
            41001,
            policy.retired_message.as_str(),
            &Value::Null,
        )
    } else {
        (
            StatusCode::NOT_FOUND,
            40404,
            "API route not found",
            &Value::Null,
        )
    };
    let mut response = (
        status,
        Json(json!({"code":code,"message":message,"data":data,"meta":null})),
    )
        .into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    Some(response)
}

pub(crate) async fn handle(method: Method, OriginalUri(uri): OriginalUri) -> Response {
    response(&method, uri.path())
        .unwrap_or_else(|| crate::httpx::errors::ApiError::route_not_found().into_response())
}
