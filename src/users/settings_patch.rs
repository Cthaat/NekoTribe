use crate::{
    auth::login::{js_trim, scalar},
    db::{oracle::BindMap, value::DbValue},
    httpx::errors::ApiError,
};
use serde_json::Value;
use std::collections::BTreeMap;

const FLAGS: [&str; 8] = [
    "login_alerts",
    "show_online_status",
    "allow_dm_from_strangers",
    "push_notification_enabled",
    "email_notification_enabled",
    "ai_sentiment_enabled",
    "ai_sentiment_return_probabilities",
    "ai_sentiment_include_metadata",
];
const FIELDS: [&str; 11] = [
    "login_alerts",
    "show_online_status",
    "allow_dm_from_strangers",
    "push_notification_enabled",
    "email_notification_enabled",
    "ai_sentiment_enabled",
    "ai_sentiment_return_probabilities",
    "ai_sentiment_include_metadata",
    "profile_visibility",
    "ai_sentiment_model_id",
    "ai_sentiment_top_k",
];

#[derive(Clone, Debug, Default)]
pub struct SettingsPatch {
    pub fields: BTreeMap<String, DbValue>,
    pub publish_presence: bool,
}

pub(crate) async fn patch(
    axum::extract::State(state): axum::extract::State<crate::auth::sessions::NativeState>,
    request: axum::http::Request<axum::body::Body>,
) -> Result<axum::response::Response, ApiError> {
    use crate::{httpx::response::V2Response, users::settings_read::SettingsRead};
    use axum::response::IntoResponse;
    let (parts, body) = request.into_parts();
    let user = crate::posts::bookmark::interaction_actor(&state, &parts.headers).await?;
    let bytes = axum::body::to_bytes(body, 1024 * 1024)
        .await
        .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
    let input = crate::auth::login::request_body(&parts.headers, &bytes)?;
    let patch = parse(&input)?;
    let result = state
        .repository
        .patch_user_settings(user, &patch)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    let value = match result {
        SettingsRead::Ready(value) => value,
        SettingsRead::UserMissing => return Err(ApiError::not_found("用户不存在")),
        SettingsRead::SettingsMissing => return Err(ApiError::not_found("用户设置不存在")),
        SettingsRead::SchemaUnavailable => {
            return Err(ApiError::new(
                axum::http::StatusCode::SERVICE_UNAVAILABLE,
                50301,
                "服务暂不可用，请稍后重试。",
            ))
        }
    };
    if patch.publish_presence {
        let presence = state
            .repository
            .user_presence(user)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?;
        let data = presence
            .as_object()
            .ok_or_else(|| ApiError::server_error("服务器内部错误"))?;
        if let Some(publisher) = &state.notification_publisher {
            if publisher.publish_presence(data).await.is_err() {
                eprintln!("presence delivery unavailable");
            }
        } else {
            eprintln!("presence delivery unavailable");
        }
    }
    let mut response = axum::Json(V2Response::ok(value)).into_response();
    response.headers_mut().insert(
        axum::http::header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static("private, no-store"),
    );
    Ok(response)
}

pub fn parse(body: &Value) -> Result<SettingsPatch, ApiError> {
    let body = body
        .as_object()
        .ok_or_else(|| ApiError::bad_request("请求体必须是 JSON 对象"))?;
    if body.contains_key("two_factor_enabled") {
        return Err(ApiError::bad_request(
            "请通过双因素认证设置流程修改 two_factor_enabled",
        ));
    }
    let mut result = SettingsPatch::default();
    for key in FLAGS {
        if let Some(value) = body.get(key) {
            result.fields.insert(
                key.into(),
                DbValue::BoolNumber(crate::notifications::read_flag(Some(value))),
            );
            result.publish_presence |= key == "show_online_status";
        }
    }
    if let Some(value) = body.get("profile_visibility") {
        let value = scalar(Some(value));
        if value != "public" && value != "private" {
            return Err(ApiError::bad_request("profile_visibility 参数错误"));
        }
        result
            .fields
            .insert("profile_visibility".into(), DbValue::String(value));
    }
    if let Some(value) = body.get("ai_sentiment_model_id") {
        let raw = scalar(Some(value));
        let model = js_trim(&raw);
        if model.encode_utf16().count() > 128 {
            return Err(ApiError::bad_request(
                "ai_sentiment_model_id 长度不能超过 128",
            ));
        }
        result.fields.insert(
            "ai_sentiment_model_id".into(),
            if model.is_empty() {
                DbValue::Null
            } else {
                DbValue::String(model.into())
            },
        );
    }
    if let Some(value) = body.get("ai_sentiment_top_k") {
        let n = match value {
            Value::Number(n) => n.as_f64(),
            Value::String(s) => crate::posts::create_request::string_number(js_trim(s)),
            _ => None,
        }
        .filter(|n| n.is_finite())
        .unwrap_or(3.0)
        .trunc();
        if !(1.0..=10.0).contains(&n) {
            return Err(ApiError::bad_request(
                "ai_sentiment_top_k 必须在 1 到 10 之间",
            ));
        }
        result
            .fields
            .insert("ai_sentiment_top_k".into(), DbValue::I64(n as i64));
    }
    Ok(result)
}

pub(crate) fn update_statement(user: i64, patch: &SettingsPatch) -> Option<(String, BindMap)> {
    let mut binds = BindMap::from([("user_id".into(), DbValue::I64(user))]);
    let mut clauses = Vec::new();
    for field in FIELDS {
        if let Some(value) = patch.fields.get(field) {
            clauses.push(format!("{field} = :{field}"));
            binds.insert(field.into(), value.clone());
        }
    }
    if clauses.is_empty() {
        return None;
    }
    Some((format!("UPDATE n_user_settings SET {}, updated_at = CURRENT_TIMESTAMP WHERE user_id = :user_id", clauses.join(", ")), binds))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn query_uses_only_allowed_columns_and_user_bind() {
        let mut patch = SettingsPatch::default();
        patch
            .fields
            .insert("login_alerts".into(), DbValue::BoolNumber(true));
        patch
            .fields
            .insert("injected = 0 --".into(), DbValue::I64(1));
        let (query, binds) = update_statement(42, &patch).unwrap();
        assert_eq!(query, "UPDATE n_user_settings SET login_alerts = :login_alerts, updated_at = CURRENT_TIMESTAMP WHERE user_id = :user_id");
        assert_eq!(binds["user_id"], DbValue::I64(42));
        assert_eq!(binds.len(), 2);
    }
}
