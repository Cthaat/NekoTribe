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
        content_queue,
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
use std::{
    collections::{BTreeSet, HashMap},
    sync::OnceLock,
};

#[derive(Deserialize)]
struct Action {
    status: String,
    report: String,
    deleted: Option<i64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Contract {
    max_posts: usize,
    max_note_bytes: usize,
    max_reason_bytes: usize,
    actions: HashMap<String, Action>,
    sql: HashMap<String, String>,
}

fn contract() -> &'static Contract {
    static SPEC: OnceLock<Contract> = OnceLock::new();
    SPEC.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../../contracts/requirements/moderation-post-actions.json"
        ))
        .expect("valid moderation post actions contract")
    })
}

pub struct Input {
    pub posts: BTreeSet<i64>,
    pub bulk: bool,
    pub action: String,
    pub note: String,
    pub reason: String,
}

pub enum Outcome {
    Applied(Value),
    Missing,
    NoteRequired,
    ClaimDisabled,
    Claimed,
}

pub(super) fn id(value: &Value) -> Option<i64> {
    let id = match value {
        Value::String(raw) if raw.bytes().all(|b| b.is_ascii_digit()) && !raw.starts_with('0') => {
            raw.parse().ok()?
        }
        Value::Number(number) => {
            let n = number.as_f64()?;
            if n.fract() != 0.0 {
                return None;
            }
            n as i64
        }
        _ => return None,
    };
    (1..=9_007_199_254_740_991).contains(&id).then_some(id)
}

fn parse(body: &Value, raw: Option<String>) -> Result<Input, ApiError> {
    let spec = contract();
    let bulk = raw.is_none();
    let action = match body.get("action") {
        None => "flag",
        Some(value) => js_trim(value.as_str().unwrap_or_default()),
    };
    if !spec.actions.contains_key(action) || bulk && matches!(action, "claim" | "release") {
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
    let note = text("note", spec.max_note_bytes)?;
    let reason = text("reason", spec.max_reason_bytes)?;
    let values = match raw {
        Some(raw) => vec![Value::String(raw)],
        None => body["post_ids"]
            .as_array()
            .filter(|ids| !ids.is_empty() && ids.len() <= spec.max_posts)
            .cloned()
            .ok_or_else(|| ApiError::bad_request("post_ids 参数错误"))?,
    };
    let posts = values
        .iter()
        .map(|value| id(value).ok_or_else(|| ApiError::bad_request("post_id 参数错误")))
        .collect::<Result<_, _>>()?;
    Ok(Input {
        posts,
        bulk,
        action: action.to_owned(),
        note,
        reason,
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
        let settings = query(conn, &spec.sql["settings"], BindMap::new())?;
        let enabled = |key| {
            settings
                .iter()
                .find(|r| row_text(r, "SETTING_KEY") == key)
                .map(|row| {
                    let val = row_text(row, "SETTING_VALUE");
                    !matches!(js_trim(&val).to_lowercase().as_str(), "0" | "false")
                })
                .unwrap_or(true)
        };
        let claiming = matches!(input.action.as_str(), "claim" | "release");
        if claiming && !enabled("allow_moderator_claim") {
            return Ok(Outcome::ClaimDisabled);
        }
        if matches!(input.action.as_str(), "reject" | "remove")
            && input.note.is_empty()
            && enabled("require_note_on_reject")
        {
            return Ok(Outcome::NoteRequired);
        }
        let post = |post_id| BindMap::from([("post_id".into(), DbValue::I64(post_id))]);
        for post_id in &input.posts {
            if query(conn, &spec.sql["post"], post(*post_id))?.is_empty() {
                return Ok(Outcome::Missing);
            }
        }
        let actor = DbValue::I64(viewer as i64);
        let action = &spec.actions[&input.action];
        let execute_one = |name: &str, binds: BindMap| {
            if tx.execute(&spec.sql[name], binds)?.rows_affected != 1 {
                return Err(DbError::SchemaNotReady);
            }
            Ok(())
        };
        for post_id in &input.posts {
            let mut rows = query(conn, &spec.sql["case"], post(*post_id))?;
            if rows.is_empty() {
                execute_one("create", post(*post_id))?;
                rows = query(conn, &spec.sql["case"], post(*post_id))?;
            }
            let row = rows.first().ok_or(DbError::SchemaNotReady)?;
            let case_id = row_number(row, "CASE_ID");
            if case_id <= 0 {
                return Err(DbError::SchemaNotReady);
            }
            let assigned = row_number(row, "ASSIGNED_TO");
            if claiming && assigned > 0 && assigned != viewer as i64 {
                return Ok(Outcome::Claimed);
            }
            if let Some(deleted) = action.deleted {
                let mut binds = post(*post_id);
                binds.insert("deleted".into(), DbValue::I64(deleted));
                execute_one("updatePost", binds)?;
            }
            let key = DbValue::I64(case_id);
            let verb = DbValue::String(input.action.clone());
            execute_one(
                "updateCase",
                BindMap::from([
                    ("case_id".into(), key.clone()),
                    ("action".into(), verb.clone()),
                    ("viewer_id".into(), actor.clone()),
                    ("status".into(), DbValue::String(action.status.clone())),
                ]),
            )?;
            tx.execute(
                &spec.sql["updateReports"],
                BindMap::from([
                    ("post_id".into(), DbValue::I64(*post_id)),
                    ("viewer_id".into(), actor.clone()),
                    ("status".into(), DbValue::String(action.report.clone())),
                ]),
            )?;
            execute_one(
                "audit",
                BindMap::from([
                    ("case_id".into(), key),
                    ("action".into(), verb),
                    ("viewer_id".into(), actor.clone()),
                    ("post_id".into(), DbValue::I64(*post_id)),
                    (
                        "reason".into(),
                        DbValue::from_option_string(
                            (!input.reason.is_empty()).then(|| input.reason.clone()),
                        ),
                    ),
                    (
                        "note".into(),
                        DbValue::from_option_string(
                            (!input.note.is_empty()).then(|| input.note.clone()),
                        ),
                    ),
                ]),
            )?;
        }
        if input.bulk {
            return Ok(Outcome::Applied(
                json!({"processed_count":input.posts.len()}),
            ));
        }
        let post_id = *input.posts.first().ok_or(DbError::SchemaNotReady)?;
        let (items, _) = content_queue::read(
            conn,
            viewer,
            Some(post_id),
            content_queue::Filters {
                status: None,
                priority: None,
                reason: None,
                search: None,
                date: "all".into(),
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

async fn handle(
    state: NativeState,
    policy: Option<Extension<ModerationSettings>>,
    raw: Option<String>,
    request: Request<Body>,
) -> Response {
    private(
        async {
            let (parts, body) = request.into_parts();
            let viewer = authorized(&state, &parts.headers, policy).await?;
            let bytes = to_bytes(body, 1 << 20)
                .await
                .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
            let input = parse(&request_body(&parts.headers, &bytes)?, raw)?;
            let message = if input.bulk {
                "bulk moderation action applied"
            } else {
                "moderation action applied"
            };
            match state
                .repository
                .moderate_posts(viewer, input, state.storage_urls.clone())
                .await
                .map_err(|_| server_error())?
            {
                Outcome::Applied(data) => Ok(Json(
                    json!({"code":200,"message":message,"data":data,"meta":null}),
                )),
                Outcome::Missing => Err(ApiError::not_found("帖子不存在")),
                Outcome::NoteRequired => Err(ApiError::bad_request("请填写审核备注")),
                Outcome::ClaimDisabled => Err(ApiError::forbidden("审核领取已关闭")),
                Outcome::Claimed => Err(ApiError::conflict("案件由其他审核员领取")),
            }
        }
        .await,
    )
}

pub(crate) async fn single(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    policy: Option<Extension<ModerationSettings>>,
    request: Request<Body>,
) -> Response {
    handle(state, policy, Some(raw), request).await
}

pub(crate) async fn bulk(
    State(state): State<NativeState>,
    policy: Option<Extension<ModerationSettings>>,
    request: Request<Body>,
) -> Response {
    handle(state, policy, None, request).await
}
