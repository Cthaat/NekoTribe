use crate::{
    auth::{
        login::{js_trim, request_body},
        sessions::NativeState,
    },
    db::{
        oracle::{BindMap, DbError},
        tx::OracleTx,
        value::DbValue,
    },
    direct_history::query,
    httpx::errors::ApiError,
    posts::bookmark::interaction_actor,
};
use axum::{
    body::{to_bytes, Body},
    extract::State,
    http::{header::CACHE_CONTROL, HeaderValue, Request, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{collections::HashMap, sync::OnceLock};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct FeedbackSql {
    actions: Vec<String>,
    targets: HashMap<String, String>,
    pub schema: String,
    lock_actor: String,
    save: String,
    pub feed_filter: String,
    pub feed_order: String,
}

pub(crate) fn feedback_sql() -> &'static FeedbackSql {
    static SQL: OnceLock<FeedbackSql> = OnceLock::new();
    SQL.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../contracts/requirements/recommendation-feedback.json"
        ))
        .expect("valid recommendation feedback SQL")
    })
}

#[derive(Debug)]
pub struct FeedbackInput {
    pub resource_type: String,
    pub resource_id: i64,
    pub action: String,
    pub reason: String,
}

#[derive(PartialEq, Eq)]
pub enum FeedbackOutcome {
    Saved,
    Missing,
    SchemaUnavailable,
    ActorUnavailable,
}

fn parse(value: &Value) -> Option<FeedbackInput> {
    let body = value.as_object()?;
    let legacy = body.contains_key("post_id") || body.contains_key("feedback");
    let (keys, kind, id, action): (&[&str], &str, &Value, &Value) = if legacy {
        (
            &["post_id", "feedback", "reason"],
            "post",
            body.get("post_id")?,
            body.get("feedback")?,
        )
    } else {
        (
            &["resource_type", "resource_id", "action", "reason"],
            body.get("resource_type")?.as_str()?,
            body.get("resource_id")?,
            body.get("action")?,
        )
    };
    let id = id
        .as_f64()
        .filter(|id| id.fract() == 0.0 && (1.0..=9_007_199_254_740_991.0).contains(id))?;
    let action = action.as_str()?;
    if body.keys().any(|key| !keys.contains(&key.as_str()))
        || !feedback_sql().targets.contains_key(kind)
        || !feedback_sql().actions.iter().any(|a| a == action)
    {
        return None;
    }
    let reason = match body.get("reason") {
        Some(value) => js_trim(value.as_str()?),
        None => "",
    };
    if reason.len() > 500 || reason.contains('\0') {
        return None;
    }
    Some(FeedbackInput {
        resource_type: kind.into(),
        resource_id: id as i64,
        action: action.into(),
        reason: reason.into(),
    })
}

pub(crate) fn persist(
    connection: &oracle::Connection,
    actor: u64,
    input: FeedbackInput,
) -> Result<FeedbackOutcome, DbError> {
    let sql = feedback_sql();
    if query(connection, &sql.schema, BindMap::new())?.is_empty() {
        return Ok(FeedbackOutcome::SchemaUnavailable);
    }
    let tx = OracleTx::new(connection);
    let result = (|| {
        let actor_id = DbValue::I64(actor as i64);
        let resource_id = DbValue::I64(input.resource_id);
        let actor_binds = BindMap::from([("actor_id".into(), actor_id.clone())]);
        if query(connection, &sql.lock_actor, actor_binds.clone())?.is_empty() {
            return Ok(FeedbackOutcome::ActorUnavailable);
        }
        let mut target = BindMap::from([("resource_id".into(), resource_id.clone())]);
        if input.resource_type != "tag" {
            target.extend(actor_binds.clone());
        }
        let statement = sql
            .targets
            .get(&input.resource_type)
            .ok_or(DbError::SchemaNotReady)?;
        if query(connection, statement, target)?.is_empty() {
            return Ok(FeedbackOutcome::Missing);
        }
        let mut binds = actor_binds;
        binds.extend([
            ("resource_id".into(), resource_id),
            ("resource_type".into(), DbValue::String(input.resource_type)),
            ("action".into(), DbValue::String(input.action)),
            (
                "reason".into(),
                DbValue::from_option_string((!input.reason.is_empty()).then_some(input.reason)),
            ),
        ]);
        if tx.execute(&sql.save, binds)?.rows_affected != 1 {
            return Err(DbError::SchemaNotReady);
        }
        Ok(FeedbackOutcome::Saved)
    })();
    if matches!(result, Ok(FeedbackOutcome::Saved)) {
        tx.commit()?;
    } else {
        tx.rollback()?;
    }
    result
}

pub(crate) async fn write(State(state): State<NativeState>, request: Request<Body>) -> Response {
    let result: Result<Json<Value>, ApiError> = async {
        let (parts, body) = request.into_parts();
        let actor = interaction_actor(&state, &parts.headers).await?;
        let body = to_bytes(body, 1 << 20)
            .await
            .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
        let input = parse(&request_body(&parts.headers, &body)?)
            .ok_or_else(|| ApiError::bad_request("推荐反馈参数错误"))?;
        match state
            .repository
            .write_recommendation_feedback(actor, input)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?
        {
            FeedbackOutcome::Saved => Ok(Json(
                json!({"code":200,"message":"success","data":{"accepted":true},"meta":null}),
            )),
            FeedbackOutcome::Missing => Err(ApiError::not_found("反馈目标不存在")),
            FeedbackOutcome::ActorUnavailable => Err(ApiError::forbidden("账号不可用")),
            FeedbackOutcome::SchemaUnavailable => Err(ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                50301,
                "服务暂不可用，请稍后重试。",
            )),
        }
    }
    .await;
    let mut response = result.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}
