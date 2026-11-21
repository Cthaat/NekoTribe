use super::{contract, map, Operation, Outcome};
use crate::{
    auth::{
        login::{js_trim, request_body},
        session_repository::{row_number, row_text},
        sessions::NativeState,
        storage_urls::StorageUrlPolicy,
    },
    db::{
        oracle::{BindMap, DbError},
        tx::OracleTx,
        value::DbValue,
    },
    direct_history::query,
    httpx::errors::ApiError,
    moderation::appeals::{private, server_error},
    posts::bookmark::interaction_actor,
};
use axum::{
    body::{to_bytes, Body},
    extract::State,
    http::Request,
    response::Response,
    Json,
};
use regex::Regex;
use serde_json::{json, Value};
use std::sync::OnceLock;

pub struct ReportInput {
    pub target_type: String,
    pub target_id: i64,
    pub reason: String,
    pub priority: String,
    pub description: String,
    pub evidence_url: String,
}

fn parse(body: &Value) -> Result<ReportInput, ApiError> {
    let spec = contract();
    let bad = |field: &str| ApiError::bad_request(format!("{field} 参数错误"));
    let choice = |field: &str, allowed: &[String]| {
        let value = js_trim(body[field].as_str().unwrap_or_default());
        if allowed.iter().any(|choice| choice == value) {
            Ok(value.to_owned())
        } else {
            Err(bad(field))
        }
    };
    let text = |field: &str| {
        if body[field].is_null() {
            return Ok(String::new());
        }
        let value = js_trim(body[field].as_str().ok_or_else(|| bad(field))?);
        if value.len() > spec.create.max_text_bytes || value.contains('\0') {
            return Err(bad(field));
        }
        Ok(value.to_owned())
    };
    let target_type = choice("target_type", &spec.target_types)?;
    let id = &body["target_id"];
    let target_id = if let Some(raw) = id.as_str() {
        if raw.starts_with('0') || !raw.bytes().all(|b| b.is_ascii_digit()) {
            return Err(bad("target_id"));
        }
        raw.parse::<i64>().ok()
    } else {
        id.as_f64().filter(|n| n.fract() == 0.0).map(|n| n as i64)
    }
    .filter(|n| (1..=9_007_199_254_740_991).contains(n))
    .ok_or_else(|| bad("target_id"))?;
    let reason = choice("reason", &spec.reasons)?;
    let priority = if body.get("priority").is_none() {
        "normal".to_owned()
    } else {
        choice("priority", &spec.create.priorities)?
    };
    let description = text("description")?;
    let evidence_url = text("evidence_url")?;
    static EVIDENCE: OnceLock<Regex> = OnceLock::new();
    let link = EVIDENCE.get_or_init(|| {
        Regex::new(&spec.create.evidence_pattern).expect("valid report evidence regex")
    });
    if !evidence_url.is_empty() && !link.is_match(&evidence_url) {
        return Err(bad("evidence_url"));
    }
    Ok(ReportInput {
        target_type,
        target_id,
        reason,
        priority,
        description,
        evidence_url,
    })
}

pub(super) fn execute(
    conn: &oracle::Connection,
    viewer: i64,
    input: ReportInput,
    storage: StorageUrlPolicy,
) -> Result<Outcome, DbError> {
    let contract = contract();
    let sql = &contract.sql;
    let tx = OracleTx::new(conn);
    let write = (|| {
        let mut actor = BindMap::from([
            ("target_id".into(), DbValue::I64(input.target_id)),
            ("viewer_id".into(), DbValue::I64(viewer)),
        ]);
        if query(
            conn,
            &contract.create.targets[&input.target_type],
            actor.clone(),
        )?
        .is_empty()
        {
            return Ok(Outcome::Missing);
        }
        actor.insert(
            "target_type".into(),
            DbValue::String(input.target_type.clone()),
        );
        let reports = query(conn, &sql["findOpen"], actor.clone())?;
        let id = if let Some(existing) = reports.first() {
            if row_text(existing, "REASON") != input.reason
                || row_text(existing, "DESCRIPTION") != input.description
                || row_text(existing, "EVIDENCE_URL") != input.evidence_url
                || row_text(existing, "PRIORITY") != input.priority
            {
                return Ok(Outcome::Conflict);
            }
            row_number(existing, "REPORT_ID")
        } else {
            let ids = query(conn, &sql["next"], BindMap::new())?;
            let id = row_number(ids.first().ok_or(DbError::SchemaNotReady)?, "REPORT_ID");
            if id <= 0 {
                return Err(DbError::SchemaNotReady);
            }
            actor.extend([
                ("report_id".into(), DbValue::I64(id)),
                ("reason".into(), DbValue::String(input.reason)),
                (
                    "description".into(),
                    DbValue::from_option_string(
                        (!input.description.is_empty()).then_some(input.description),
                    ),
                ),
                (
                    "evidence_url".into(),
                    DbValue::from_option_string(
                        (!input.evidence_url.is_empty()).then_some(input.evidence_url),
                    ),
                ),
                ("priority".into(), DbValue::String(input.priority)),
            ]);
            if tx.execute(&sql["insert"], actor)?.rows_affected != 1 {
                return Err(DbError::SchemaNotReady);
            }
            let scope = BindMap::from([
                ("target_type".into(), DbValue::String(input.target_type)),
                ("target_id".into(), DbValue::I64(input.target_id)),
            ]);
            if tx.execute(&sql["mergeCase"], scope)?.rows_affected != 1 {
                return Err(DbError::SchemaNotReady);
            }
            id
        };
        let rows = query(
            conn,
            &sql["read"],
            BindMap::from([("report_id".into(), DbValue::I64(id))]),
        )?;
        let row = rows.first().ok_or(DbError::SchemaNotReady)?;
        Ok(Outcome::Created(map(conn, viewer, row, &storage)?))
    })();
    if matches!(write, Ok(Outcome::Created(_))) {
        tx.commit()?;
    } else {
        tx.rollback()?;
    }
    write
}

pub(crate) async fn submit(State(state): State<NativeState>, request: Request<Body>) -> Response {
    private(
        async {
            let (parts, body) = request.into_parts();
            let viewer = interaction_actor(&state, &parts.headers).await?;
            let bytes = to_bytes(body, 1 << 20)
                .await
                .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
            let input = parse(&request_body(&parts.headers, &bytes)?)?;
            if input.target_type == "user" && input.target_id == viewer as i64 {
                return Err(ApiError::forbidden("不能举报自己"));
            }
            let outcome = state
                .repository
                .moderation_report(
                    viewer,
                    Operation::Create {
                        input,
                        storage: state.storage_urls.clone(),
                    },
                )
                .await
                .map_err(|_| server_error())?;
            match outcome {
                Outcome::Created(data) => Ok(Json(
                    json!({"code":200,"message":"report created","data":data,"meta":null}),
                )),
                Outcome::Missing => Err(ApiError::not_found("举报目标不存在")),
                Outcome::Conflict => Err(ApiError::conflict("已有待处理举报")),
                _ => Err(server_error()),
            }
        }
        .await,
    )
}
