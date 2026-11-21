use crate::{
    ai::{conversation_http::ModerationSettings, conversation_store::ModerationPolicy},
    auth::{
        login::{js_trim, request_body},
        session_list::{session_pagination, SessionPage},
        session_repository::{public_profile_json, row_number, row_text},
        sessions::NativeState,
        storage_urls::StorageUrlPolicy,
    },
    db::{
        oracle::{bind_refs, bind_values, BindMap, DbError},
        row::{oracle_row_to_db_row, DbRow},
        tx::OracleTx,
        value::DbValue,
    },
    httpx::errors::ApiError,
    posts::bookmark::interaction_actor,
};
use axum::{
    body::{to_bytes, Body},
    extract::{OriginalUri, Path, State},
    http::{header, HeaderMap, HeaderValue, Request},
    response::{IntoResponse, Response},
    Extension, Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{collections::HashMap, sync::OnceLock};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Contract {
    max_response_bytes: usize,
    statuses: Vec<String>,
    decisions: Vec<String>,
    sql: HashMap<String, String>,
}

fn contract() -> &'static Contract {
    static VALUE: OnceLock<Contract> = OnceLock::new();
    VALUE.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../../contracts/requirements/moderation-appeals.json"
        ))
        .expect("valid moderation appeals contract")
    })
}

pub enum Operation {
    Authorize(ModerationPolicy),
    List {
        status: Option<String>,
        page: SessionPage,
        storage: StorageUrlPolicy,
    },
    Decide {
        id: u64,
        status: String,
        reply: String,
        storage: StorageUrlPolicy,
    },
}

pub enum Outcome {
    Access(bool),
    Listed(Vec<Value>, i64),
    Decided(Value),
    Missing,
    Conflict,
}

fn map(row: &DbRow, storage: &StorageUrlPolicy) -> Result<Value, DbError> {
    if row_number(row, "USER_ID") <= 0 || row_number(row, "STATEMENT_ID") <= 0 {
        return Err(DbError::SchemaNotReady);
    }
    let mut user = public_profile_json(row);
    user["avatar_url"] = json!(storage
        .normalize_avatar(&row_text(row, "AVATAR_URL"))
        .map_err(|_| DbError::SchemaNotReady)?);
    let status = row_text(row, "APPEAL_STATUS");
    Ok(json!({
        "appeal_id":row_number(row,"APPEAL_ID"),"statement_id":row_number(row,"STATEMENT_ID"),
        "user": user,"appeal_message":row_text(row,"APPEAL_MESSAGE"),
        "appeal_status": match status.as_str() { "approved" | "rejected" => status.as_str(), _ => "pending" },
        "admin_response":row_text(row,"ADMIN_RESPONSE"),
        "created_at":row_text(row,"CREATED_AT"),"updated_at":row_text(row,"UPDATED_AT")
    }))
}

pub(crate) fn execute(
    connection: &oracle::Connection,
    viewer: u64,
    operation: Operation,
) -> Result<Outcome, DbError> {
    let viewer = viewer as i64;
    let sql = &contract().sql;
    match operation {
        Operation::Authorize(policy) => Ok(Outcome::Access(policy.allows(connection, viewer)?)),
        Operation::List {
            status,
            page,
            storage,
        } => {
            let binds = bind_values(BindMap::from([
                ("viewer_id".into(), DbValue::I64(viewer)),
                ("status".into(), DbValue::from_option_string(status)),
                ("start_row".into(), DbValue::F64(page.start)),
                ("end_row".into(), DbValue::F64(page.end)),
            ]));
            let mut total = 0;
            let mut items = Vec::new();
            for row in connection.query_named(&sql["list"], &bind_refs(&binds))? {
                let row = oracle_row_to_db_row(&row?)?;
                total = row_number(&row, "TOTAL");
                if row_number(&row, "APPEAL_ID") > 0 {
                    items.push(map(&row, &storage)?);
                }
            }
            Ok(Outcome::Listed(items, total))
        }
        Operation::Decide {
            id,
            status,
            reply,
            storage,
        } => {
            let id = id as i64;
            let tx = OracleTx::new(connection);
            let write = (|| {
                let mut rows = connection.query_named(&sql["lock"], &[("appeal_id", &id)])?;
                let Some(row) = rows.next().transpose()? else {
                    return Ok(Outcome::Missing);
                };
                let target: i64 = row.get(0)?;
                let existing: String = row.get(1)?;
                let previous: Option<String> = row.get(2)?;
                drop(rows);
                if existing == "pending" {
                    let response =
                        DbValue::from_option_string((!reply.is_empty()).then_some(reply));
                    let update = tx.execute(
                        &sql["update"],
                        BindMap::from([
                            ("appeal_id".into(), DbValue::I64(id)),
                            ("status".into(), DbValue::String(status.clone())),
                            ("response".into(), response.clone()),
                        ]),
                    )?;
                    if update.rows_affected != 1 {
                        return Err(DbError::SchemaNotReady);
                    }
                    let audit = tx.execute(
                        &sql["audit"],
                        BindMap::from([
                            ("target_id".into(), DbValue::I64(target)),
                            ("viewer_id".into(), DbValue::I64(viewer)),
                            ("action".into(), DbValue::String(format!("appeal_{status}"))),
                            ("reason".into(), DbValue::String(format!("appeal:{id}"))),
                            ("response".into(), response),
                        ]),
                    )?;
                    if audit.rows_affected != 1 {
                        return Err(DbError::SchemaNotReady);
                    }
                } else if existing != status || previous.as_deref().unwrap_or_default() != reply {
                    return Ok(Outcome::Conflict);
                }
                let mut rows = connection
                    .query_named(&sql["read"], &[("viewer_id", &viewer), ("appeal_id", &id)])?;
                let row = rows.next().transpose()?.ok_or(DbError::SchemaNotReady)?;
                let row = oracle_row_to_db_row(&row)?;
                if row_number(&row, "APPEAL_ID") != id {
                    return Err(DbError::SchemaNotReady);
                }
                Ok(Outcome::Decided(map(&row, &storage)?))
            })();
            if matches!(write, Ok(Outcome::Decided(_))) {
                tx.commit()?;
            } else {
                tx.rollback()?;
            }
            write
        }
    }
}

pub(crate) fn server_error() -> ApiError {
    ApiError::server_error("服务器内部错误")
}

pub(crate) async fn authorized(
    state: &NativeState,
    headers: &HeaderMap,
    settings: Option<Extension<ModerationSettings>>,
) -> Result<u64, ApiError> {
    let viewer = interaction_actor(state, headers).await?;
    let policy = settings
        .map(|Extension(settings)| settings)
        .unwrap_or_default()
        .policy();
    match state
        .repository
        .moderation_appeal(viewer, Operation::Authorize(policy))
        .await
        .map_err(|_| server_error())?
    {
        Outcome::Access(true) => Ok(viewer),
        Outcome::Access(false) => Err(ApiError::forbidden("需要审核权限")),
        _ => Err(server_error()),
    }
}

pub(crate) fn private(result: Result<Json<Value>, ApiError>) -> Response {
    let mut response = result.into_response();
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("private, no-store"),
    );
    response
}

pub(crate) async fn list(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    settings: Option<Extension<ModerationSettings>>,
    headers: HeaderMap,
) -> Response {
    let result = async {
        let viewer = authorized(&state,&headers,settings).await?;
        let raw = uri.query().unwrap_or_default();
        let url = reqwest::Url::parse(&format!("http://localhost/?{raw}")).expect("fixed URL");
        let mut filters = url.query_pairs().filter(|(key, _)| key == "status").map(|(_,v)| v.into_owned());
        let filter = filters.next().filter(|s| filters.next().is_none() && s != "all");
        let status = filter.map(|s| if contract().statuses.contains(&s) { s } else { "pending".to_owned() });
        let page = session_pagination(raw);
        let outcome = state.repository.moderation_appeal(viewer,Operation::List {
            page,status,storage:state.storage_urls.clone(),
        }).await.map_err(|_| server_error())?;
        let Outcome::Listed(items,total) = outcome else { return Err(server_error()); };
        Ok(Json(json!({"code":200,"message":"moderation appeals listed","data":items,"meta":{
            "page":page.page,"page_size":page.page_size,"total":total,"has_next":page.end < total as f64
        }})))
    }.await;
    private(result)
}

pub(crate) async fn decide(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    settings: Option<Extension<ModerationSettings>>,
    request: Request<Body>,
) -> Response {
    let result = async {
        let (parts, body) = request.into_parts();
        let viewer = authorized(&state, &parts.headers, settings).await?;
        let id = raw
            .parse::<u64>()
            .ok()
            .filter(|id| {
                (1..=9_007_199_254_740_991).contains(id)
                    && !raw.starts_with('0')
                    && raw.bytes().all(|b| b.is_ascii_digit())
            })
            .ok_or_else(|| ApiError::bad_request("appeal_id 参数错误"))?;
        let bytes = to_bytes(body, 1 << 20)
            .await
            .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
        let input = request_body(&parts.headers, &bytes)?;
        let status = js_trim(input["appeal_status"].as_str().unwrap_or_default()).to_owned();
        if !contract().decisions.contains(&status) {
            return Err(ApiError::bad_request("appeal_status 参数错误"));
        }
        let reply = match input.get("admin_response") {
            None => "",
            Some(value) => value
                .as_str()
                .map(js_trim)
                .filter(|s| s.len() <= contract().max_response_bytes && !s.contains('\0'))
                .ok_or_else(|| ApiError::bad_request("admin_response 参数错误"))?,
        };
        let outcome = state
            .repository
            .moderation_appeal(
                viewer,
                Operation::Decide {
                    id,
                    status,
                    reply: reply.to_owned(),
                    storage: state.storage_urls.clone(),
                },
            )
            .await
            .map_err(|_| server_error())?;
        match outcome {
            Outcome::Decided(data) => Ok(Json(
                json!({"code":200,"message":"appeal updated","data":data,"meta":null}),
            )),
            Outcome::Missing => Err(ApiError::not_found("申诉不存在")),
            Outcome::Conflict => Err(ApiError::conflict("申诉已处理")),
            _ => Err(server_error()),
        }
    }
    .await;
    private(result)
}
