use crate::{
    ai::conversation_http::ModerationSettings,
    auth::{
        login::{js_trim, request_body},
        session_list::SessionPage,
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
    moderation::{
        appeals::{authorized, private, server_error},
        post_actions, user_queue,
    },
};
use axum::{
    body::{to_bytes, Body},
    extract::{Path, State},
    http::Request,
    response::Response,
    Extension, Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{collections::HashMap, sync::OnceLock};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Contract {
    actions: Vec<String>,
    max_duration_hours: i64,
    default_duration_hours: i64,
    max_note_bytes: usize,
    max_reason_bytes: usize,
    sql: HashMap<String, String>,
}
fn contract() -> &'static Contract {
    static SPEC: OnceLock<Contract> = OnceLock::new();
    SPEC.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../../contracts/requirements/moderation-user-actions.json"
        ))
        .expect("valid moderation user actions contract")
    })
}

pub struct Input {
    pub id: i64,
    pub action: String,
    pub note: String,
    pub reason: String,
    pub hours: Option<i64>,
}
pub enum Outcome {
    Applied(Value),
    Missing,
    InvalidState,
}

fn hours(value: &Value) -> Option<i64> {
    let n = match value {
        Value::String(raw) => {
            let raw = js_trim(raw);
            if raw.is_empty() || !raw.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            let digits = raw.trim_start_matches('0');
            if digits.is_empty() {
                0
            } else {
                digits.parse().ok()?
            }
        }
        Value::Number(v) => {
            let v = v.as_f64()?;
            if v.fract() != 0.0 {
                return None;
            }
            v as i64
        }
        _ => return None,
    };
    (0..=contract().max_duration_hours)
        .contains(&n)
        .then_some(n)
}

fn parse(id: i64, body: &Value) -> Result<Input, ApiError> {
    let spec = contract();
    let action = js_trim(body["action"].as_str().unwrap_or_default()).to_owned();
    if !spec.actions.contains(&action) {
        return Err(ApiError::bad_request("action 参数错误"));
    }
    let text = |key: &str, max| {
        let value = &body[key];
        if value.is_null() {
            return Ok(String::new());
        }
        value
            .as_str()
            .map(js_trim)
            .filter(|v| v.len() <= max && !v.contains('\0'))
            .map(str::to_owned)
            .ok_or_else(|| ApiError::bad_request(format!("{key} 参数错误")))
    };
    let reason = text("reason", spec.max_reason_bytes)?;
    let note = text("note", spec.max_note_bytes)?;
    let mut duration = None;
    if matches!(action.as_str(), "ban" | "mute") {
        if let Some(value) = body.get("duration_hours") {
            duration = Some(
                hours(value)
                    .filter(|n| action != "mute" || *n > 0)
                    .ok_or_else(|| ApiError::bad_request("duration_hours 参数错误"))?,
            );
        }
    }
    Ok(Input {
        id,
        action,
        note,
        reason,
        hours: duration,
    })
}

pub(crate) fn execute(
    conn: &oracle::Connection,
    viewer: u64,
    input: Input,
    storage: StorageUrlPolicy,
) -> Result<Outcome, DbError> {
    let spec = contract();
    let tx = OracleTx::new(conn);
    let apply = (|| {
        let key = BindMap::from([("user_id".into(), DbValue::I64(input.id))]);
        let rows = query(conn, &spec.sql["lock"], key.clone())?;
        let Some(target) = rows.first() else {
            return Ok(Outcome::Missing);
        };
        let status = row_text(target, "STATUS");
        let active = row_number(target, "IS_ACTIVE");
        let ban_state = status == "suspended" && active == 0;
        let action = input.action.as_str();
        if matches!(action, "ban" | "unban")
            && !(status == "active" && active == 1)
            && (!ban_state || query(conn, &spec.sql["banHistory"], key.clone())?.is_empty())
        {
            return Ok(Outcome::InvalidState);
        }
        let adding = matches!(action, "ban" | "mute");
        let duration = if input.hours.is_none() && adding {
            let value = if action == "mute" {
                query(conn, &spec.sql["defaultMute"], BindMap::new())?
                    .first()
                    .and_then(|row| hours(&Value::String(row_text(row, "SETTING_VALUE"))))
                    .map(|n| n.max(1))
            } else {
                None
            };
            Some(value.unwrap_or(spec.default_duration_hours))
        } else {
            input.hours
        };
        let one = |name: &str, values: BindMap| {
            if tx.execute(&spec.sql[name], values)?.rows_affected != 1 {
                return Err(DbError::SchemaNotReady);
            }
            Ok(())
        };
        let mut cases = query(conn, &spec.sql["case"], key.clone())?;
        if cases.is_empty() {
            one("create", key.clone())?;
            cases = query(conn, &spec.sql["case"], key.clone())?;
        }
        let case_id = row_number(cases.first().ok_or(DbError::SchemaNotReady)?, "CASE_ID");
        if case_id <= 0 {
            return Err(DbError::SchemaNotReady);
        }
        if action == "ban" || action == "unban" && ban_state {
            let (status, active) = if action == "ban" {
                ("suspended", 0)
            } else {
                ("active", 1)
            };
            let mut params = key.clone();
            params.insert("status".into(), DbValue::String(status.into()));
            params.insert("active".into(), DbValue::I64(active));
            one("updateUser", params)?;
        }
        if action == "ban" {
            tx.execute(&spec.sql["revokeSessions"], key.clone())?;
        }
        let mut actor = key;
        actor.insert("viewer_id".into(), DbValue::I64(viewer as i64));
        let reason =
            DbValue::from_option_string((!input.reason.is_empty()).then_some(input.reason));
        let note = DbValue::from_option_string((!input.note.is_empty()).then_some(input.note));
        let hours = duration.map(DbValue::I64).unwrap_or(DbValue::Null);
        if action != "note" {
            let kind = if matches!(action, "ban" | "unban") {
                "ban"
            } else {
                "mute"
            };
            let mut params = actor.clone();
            params.insert("kind".into(), DbValue::String(kind.into()));
            tx.execute(&spec.sql["revokeRestriction"], params.clone())?;
            if adding {
                params.insert("reason".into(), reason.clone());
                params.insert("hours".into(), hours.clone());
                one("addRestriction", params)?;
            }
        }
        actor.extend([
            ("case_id".into(), DbValue::I64(case_id)),
            ("action".into(), DbValue::String(action.into())),
            ("reason".into(), reason),
            ("note".into(), note),
            ("hours".into(), hours),
        ]);
        one("audit", actor)?;
        let (items, _) = user_queue::read(
            conn,
            Some(input.id),
            user_queue::Filters {
                status: None,
                search: None,
                sort: "newest".into(),
                page: SessionPage {
                    page: 1.,
                    page_size: 1.,
                    start: 1.,
                    end: 1.,
                },
                storage,
            },
        )?;
        Ok(Outcome::Applied(
            items.into_iter().next().ok_or(DbError::SchemaNotReady)?,
        ))
    })();
    if matches!(apply, Ok(Outcome::Applied(_))) {
        tx.commit()?;
    } else {
        tx.rollback()?;
    }
    apply
}

pub(crate) async fn handle(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    policy: Option<Extension<ModerationSettings>>,
    request: Request<Body>,
) -> Response {
    private(async{
        let (parts,body)=request.into_parts();
        let viewer=authorized(&state,&parts.headers,policy).await?;
        let id=post_actions::id(&Value::String(raw)).ok_or_else(||ApiError::bad_request("user_id 参数错误"))?;
        if id==viewer as i64{return Err(ApiError::forbidden("不能处罚自己"));}
        let bytes=to_bytes(body,1<<20).await.map_err(|_|ApiError::bad_request("请求体必须是 JSON 对象"))?;
        let input=parse(id,&request_body(&parts.headers,&bytes)?)?;
        match state.repository.moderate_user(viewer,input,state.storage_urls.clone()).await.map_err(|_|server_error())?{
            Outcome::Applied(data)=>Ok(Json(json!({"code":200,"message":"user moderation action applied","data":data,"meta":null}))),
            Outcome::Missing=>Err(ApiError::not_found("用户不存在")),
            Outcome::InvalidState=>Err(ApiError::conflict("账号状态不允许此处置")),
        }
    }.await)
}
