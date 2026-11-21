use crate::{
    ai::conversation_http::ModerationSettings,
    auth::{
        login::{js_trim, request_body},
        session_repository::{row_number, row_text},
        sessions::NativeState,
    },
    db::{
        oracle::{BindMap, DbError},
        tx::OracleTx,
        value::DbValue,
    },
    direct_history::query,
    httpx::errors::ApiError,
    moderation::appeals::{authorized, private, server_error},
};
use axum::{
    body::{to_bytes, Body},
    extract::State,
    http::{HeaderMap, Request},
    response::Response,
    Extension, Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, HashMap},
    sync::OnceLock,
};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Contract {
    settings: HashMap<String, String>,
    max_number: i64,
    sql: HashMap<String, String>,
}

fn contract() -> &'static Contract {
    static VALUE: OnceLock<Contract> = OnceLock::new();
    VALUE.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../../contracts/requirements/moderation-dashboard.json"
        ))
        .expect("valid moderation dashboard contract")
    })
}

pub struct SettingChange {
    pub value: String,
    pub kind: String,
}

pub enum Operation {
    Stats,
    Settings,
    Update(BTreeMap<String, SettingChange>),
}

fn normalize(value: &Value, kind: &str) -> Option<String> {
    let text = value.as_str().map(js_trim);
    if kind == "boolean" {
        return match (value.as_bool(), text) {
            (Some(true), _) | (_, Some("true" | "1")) => Some("true".into()),
            (Some(false), _) | (_, Some("false" | "0")) => Some("false".into()),
            _ => None,
        };
    }
    let number = match text {
        Some(text) if !text.is_empty() && text.bytes().all(|b| b.is_ascii_digit()) => {
            let digits = text.trim_start_matches('0');
            if digits.is_empty() {
                0
            } else {
                digits.parse().ok()?
            }
        }
        Some(_) => return None,
        None => {
            let numeric = value.as_f64()?;
            if numeric.fract() != 0.0 {
                return None;
            }
            numeric as i64
        }
    };
    (0..=contract().max_number)
        .contains(&number)
        .then(|| number.to_string())
}

fn changes(body: &Value) -> Option<BTreeMap<String, SettingChange>> {
    let items = body["settings"].as_array()?;
    let registry = &contract().settings;
    if items.len() > registry.len() {
        return None;
    }
    let mut batch = BTreeMap::new();
    for item in items {
        let key = item["key"].as_str()?;
        let kind = registry.get(key)?;
        let value = normalize(&item["value"], kind)?;
        if batch
            .insert(
                key.to_owned(),
                SettingChange {
                    value,
                    kind: kind.clone(),
                },
            )
            .is_some()
        {
            return None;
        }
    }
    Some(batch)
}

fn list(conn: &oracle::Connection) -> Result<Value, DbError> {
    let rows = query(conn, &contract().sql["list"], BindMap::new())?;
    Ok(Value::Array(rows.iter().map(|row| {
        let kind = row_text(row,"VALUE_TYPE");
        json!({
            "key":row_text(row,"SETTING_KEY"), "value":row_text(row,"SETTING_VALUE"),
            "value_type":match kind.as_str() { "number" | "boolean" => kind.as_str(), _ => "string" },
            "label":row_text(row,"LABEL"),"description":row_text(row,"DESCRIPTION"),"updated_at":row_text(row,"UPDATED_AT"),
        })
    }).collect()))
}

pub(crate) fn execute(
    conn: &oracle::Connection,
    actor: u64,
    operation: Operation,
) -> Result<Value, DbError> {
    match operation {
        Operation::Stats => {
            let names = [
                "pending",
                "approved",
                "rejected",
                "flagged",
                "today_processed",
                "avg_process_minutes",
                "open_reports",
                "appeal_success_rate",
            ];
            let rows = query(conn, &contract().sql["stats"], BindMap::new())?;
            let row = rows.first().ok_or(DbError::SchemaNotReady)?;
            Ok(Value::Object(
                names
                    .into_iter()
                    .map(|name| {
                        (
                            name.into(),
                            json!(row_number(row, &name.to_ascii_uppercase())),
                        )
                    })
                    .collect(),
            ))
        }
        Operation::Settings => list(conn),
        Operation::Update(batch) => {
            if batch.is_empty() {
                return list(conn);
            }
            let tx = OracleTx::new(conn);
            let write = (|| {
                for (key, entry) in batch {
                    let rows = tx.execute(
                        &contract().sql["update"],
                        BindMap::from([
                            ("setting_key".into(), DbValue::String(key)),
                            ("setting_value".into(), DbValue::String(entry.value)),
                            ("value_type".into(), DbValue::String(entry.kind)),
                            ("updated_by".into(), DbValue::I64(actor as i64)),
                        ]),
                    )?;
                    if rows.rows_affected != 1 {
                        return Err(DbError::SchemaNotReady);
                    }
                }
                list(conn)
            })();
            if write.is_ok() {
                tx.commit()?;
            } else {
                tx.rollback()?;
            }
            write
        }
    }
}

async fn response(
    state: &NativeState,
    actor: u64,
    operation: Operation,
) -> Result<Json<Value>, ApiError> {
    let data = state
        .repository
        .moderation_dashboard(actor, operation)
        .await
        .map_err(|_| server_error())?;
    Ok(Json(
        json!({"code":200,"message":"success","data":data,"meta":null}),
    ))
}

pub(crate) async fn stats(
    State(state): State<NativeState>,
    settings: Option<Extension<ModerationSettings>>,
    headers: HeaderMap,
) -> Response {
    private(
        async {
            let actor = authorized(&state, &headers, settings).await?;
            response(&state, actor, Operation::Stats).await
        }
        .await,
    )
}

pub(crate) async fn settings(
    State(state): State<NativeState>,
    policy: Option<Extension<ModerationSettings>>,
    headers: HeaderMap,
) -> Response {
    private(
        async {
            let actor = authorized(&state, &headers, policy).await?;
            response(&state, actor, Operation::Settings).await
        }
        .await,
    )
}

pub(crate) async fn update(
    State(state): State<NativeState>,
    policy: Option<Extension<ModerationSettings>>,
    request: Request<Body>,
) -> Response {
    private(
        async {
            let (parts, body) = request.into_parts();
            let actor = authorized(&state, &parts.headers, policy).await?;
            let bytes = to_bytes(body, 1 << 20)
                .await
                .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
            let input = request_body(&parts.headers, &bytes)?;
            let batch =
                changes(&input).ok_or_else(|| ApiError::bad_request("settings 参数错误"))?;
            response(&state, actor, Operation::Update(batch)).await
        }
        .await,
    )
}
