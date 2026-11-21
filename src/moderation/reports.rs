use crate::{
    ai::conversation_http::ModerationSettings,
    auth::{
        login::{js_trim, request_body},
        session_list::{session_pagination, SessionPage},
        session_repository::{nullable_text, row_number, row_text},
        sessions::NativeState,
        storage_urls::StorageUrlPolicy,
    },
    db::{
        oracle::{BindMap, DbError},
        row::DbRow,
        tx::OracleTx,
        value::DbValue,
    },
    direct_history::query,
    group_content::user,
    httpx::errors::ApiError,
    moderation::appeals::{authorized, private, server_error},
};
use axum::{
    body::{to_bytes, Body},
    extract::{OriginalUri, Path, State},
    http::{HeaderMap, Request},
    response::Response,
    Extension, Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{collections::HashMap, sync::OnceLock};

mod create;
pub(crate) use create::submit;
pub use create::ReportInput;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreateContract {
    max_text_bytes: usize,
    priorities: Vec<String>,
    evidence_pattern: String,
    targets: HashMap<String, String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Contract {
    statuses: Vec<String>,
    reasons: Vec<String>,
    target_types: Vec<String>,
    create: CreateContract,
    sql: HashMap<String, String>,
}

fn contract() -> &'static Contract {
    static VALUE: OnceLock<Contract> = OnceLock::new();
    VALUE.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../../contracts/requirements/moderation-reports.json"
        ))
        .expect("valid moderation reports contract")
    })
}

pub struct Filters {
    status: Option<String>,
    reason: Option<String>,
    target_type: Option<String>,
}

pub enum Operation {
    Create {
        input: ReportInput,
        storage: StorageUrlPolicy,
    },
    List {
        filters: Filters,
        page: SessionPage,
        storage: StorageUrlPolicy,
    },
    Update {
        id: i64,
        status: String,
        storage: StorageUrlPolicy,
    },
}

pub enum Outcome {
    Created(Value),
    Conflict,
    Listed(Vec<Value>, i64),
    Updated(Value),
    Missing,
}

pub(super) fn recognized_reason(reason: &str) -> bool {
    contract().reasons.iter().any(|value| value == reason)
}

pub(super) fn map(
    conn: &oracle::Connection,
    viewer: i64,
    row: &DbRow,
    storage: &StorageUrlPolicy,
) -> Result<Value, DbError> {
    let person = |column| {
        let id = row_number(row, column);
        if id > 0 {
            user(conn, viewer, id, storage)
        } else {
            Ok(None)
        }
    };
    Ok(json!({
        "report_id": row_number(row, "REPORT_ID"),
        "target_type": row_text(row, "TARGET_TYPE"),
        "target_id": row_number(row, "TARGET_ID"),
        "reporter": person("REPORTER_USER_ID")?,
        "reason": row_text(row, "REASON"),
        "description": row_text(row, "DESCRIPTION"),
        "evidence_url": nullable_text(row, "EVIDENCE_URL"),
        "status": row_text(row, "STATUS"),
        "priority": row_text(row, "PRIORITY"),
        "handled_by": person("HANDLED_BY")?,
        "created_at": row_text(row, "CREATED_AT"),
        "updated_at": row_text(row, "UPDATED_AT"),
        "resolved_at": nullable_text(row, "RESOLVED_AT"),
    }))
}

pub(crate) fn execute(
    conn: &oracle::Connection,
    viewer: u64,
    operation: Operation,
) -> Result<Outcome, DbError> {
    let viewer = viewer as i64;
    let sql = &contract().sql;
    match operation {
        Operation::Create { input, storage } => create::execute(conn, viewer, input, storage),
        Operation::List {
            filters,
            page,
            storage,
        } => {
            let rows = query(
                conn,
                &sql["list"],
                BindMap::from([
                    ("status".into(), DbValue::from_option_string(filters.status)),
                    ("reason".into(), DbValue::from_option_string(filters.reason)),
                    (
                        "target_type".into(),
                        DbValue::from_option_string(filters.target_type),
                    ),
                    ("start_row".into(), DbValue::F64(page.start)),
                    ("end_row".into(), DbValue::F64(page.end)),
                ]),
            )?;
            let total = rows
                .first()
                .map(|row| row_number(row, "TOTAL"))
                .unwrap_or_default();
            let items = rows
                .iter()
                .filter(|row| row_number(row, "REPORT_ID") > 0)
                .map(|row| map(conn, viewer, row, &storage))
                .collect::<Result<_, _>>()?;
            Ok(Outcome::Listed(items, total))
        }
        Operation::Update {
            id,
            status,
            storage,
        } => {
            let tx = OracleTx::new(conn);
            let key = BindMap::from([("report_id".into(), DbValue::I64(id))]);
            let write = (|| {
                let rows = query(conn, &sql["lock"], key.clone())?;
                let Some(current) = rows.first() else {
                    return Ok(Outcome::Missing);
                };
                let terminal = matches!(status.as_str(), "resolved" | "dismissed");
                if row_text(current, "STATUS") != status
                    || row_number(current, "HANDLED_BY") != viewer
                    || (row_number(current, "IS_RESOLVED") == 1) != terminal
                {
                    let mut binds = key.clone();
                    binds.insert("status".into(), DbValue::String(status));
                    binds.insert("handled_by".into(), DbValue::I64(viewer));
                    if tx.execute(&sql["update"], binds)?.rows_affected != 1 {
                        return Err(DbError::SchemaNotReady);
                    }
                }
                let rows = query(conn, &sql["read"], key)?;
                let row = rows.first().ok_or(DbError::SchemaNotReady)?;
                Ok(Outcome::Updated(map(conn, viewer, row, &storage)?))
            })();
            if matches!(write, Ok(Outcome::Updated(_))) {
                tx.commit()?;
            } else {
                tx.rollback()?;
            }
            write
        }
    }
}

pub(crate) async fn list(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    settings: Option<Extension<ModerationSettings>>,
    headers: HeaderMap,
) -> Response {
    private(async {
        let viewer = authorized(&state, &headers, settings).await?;
        let raw = uri.query().unwrap_or_default();
        let url = reqwest::Url::parse(&format!("http://localhost/?{raw}")).expect("fixed URL");
        let filter = |key: &str, allowed: &[String], fallback: &str| {
            let mut values = url.query_pairs().filter(|(k, _)| k == key).map(|(_, v)| v);
            let value = values.next().filter(|v| values.next().is_none() && v != "all")?;
            Some(if allowed.iter().any(|s| s == value.as_ref()) { value.into_owned() } else { fallback.to_owned() })
        };
        let spec = contract();
        let page = session_pagination(raw);
        let filters = Filters {
            status: filter("status", &spec.statuses, "pending"),
            reason: filter("reason", &spec.reasons, "other"),
            target_type: filter("target_type", &spec.target_types, "post"),
        };
        let outcome = state.repository.moderation_report(viewer, Operation::List {
            filters, page, storage: state.storage_urls.clone(),
        }).await.map_err(|_| server_error())?;
        let Outcome::Listed(data, total) = outcome else { return Err(server_error()); };
        Ok(Json(json!({
            "code":200, "message":"moderation reports listed","data":data,
            "meta":{"page":page.page,"page_size":page.page_size,"total":total,"has_next":page.end < total as f64}
        })))
    }.await)
}

pub(crate) async fn update(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    settings: Option<Extension<ModerationSettings>>,
    request: Request<Body>,
) -> Response {
    private(
        async {
            let (parts, body) = request.into_parts();
            let viewer = authorized(&state, &parts.headers, settings).await?;
            let id = raw
                .parse::<i64>()
                .ok()
                .filter(|id| {
                    (1..=9_007_199_254_740_991).contains(id)
                        && !raw.starts_with('0')
                        && raw.bytes().all(|b| b.is_ascii_digit())
                })
                .ok_or_else(|| ApiError::bad_request("report_id 参数错误"))?;
            let bytes = to_bytes(body, 1 << 20)
                .await
                .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
            let input = request_body(&parts.headers, &bytes)?;
            let status = js_trim(input["status"].as_str().unwrap_or_default()).to_owned();
            if !contract().statuses.contains(&status) {
                return Err(ApiError::bad_request("status 参数错误"));
            }
            let outcome = state
                .repository
                .moderation_report(
                    viewer,
                    Operation::Update {
                        id,
                        status,
                        storage: state.storage_urls.clone(),
                    },
                )
                .await
                .map_err(|_| server_error())?;
            match outcome {
                Outcome::Updated(data) => Ok(Json(
                    json!({"code":200,"message":"report updated","data":data,"meta":null}),
                )),
                Outcome::Missing => Err(ApiError::not_found("举报不存在")),
                _ => Err(server_error()),
            }
        }
        .await,
    )
}
