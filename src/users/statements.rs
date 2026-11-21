use crate::{
    auth::{
        login::{js_trim, request_body},
        session_list::{session_pagination, SessionPage},
        session_repository::{row_number, row_text},
        sessions::NativeState,
    },
    db::{
        oracle::{BindMap, DbError},
        row::DbRow,
        tx::OracleTx,
        value::DbValue,
    },
    httpx::errors::ApiError,
    posts::bookmark::interaction_actor,
};
use axum::{
    body::{to_bytes, Body},
    extract::{OriginalUri, Path, State},
    http::{header, HeaderMap, HeaderValue, Method, Request},
    response::{IntoResponse, Response},
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{collections::HashMap, sync::OnceLock};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Contract {
    max_appeal_bytes: usize,
    actions: HashMap<String, String>,
    sql: HashMap<String, String>,
}

fn contract() -> &'static Contract {
    static VALUE: OnceLock<Contract> = OnceLock::new();
    VALUE.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../../contracts/requirements/account-statements.json"
        ))
        .expect("valid account statements contract")
    })
}

pub struct StatementQuery {
    pub page: SessionPage,
    pub status: Option<String>,
    pub kind: Option<String>,
}

impl StatementQuery {
    fn from_query(raw: &str) -> Self {
        let url = reqwest::Url::parse(&format!("http://localhost/?{raw}")).expect("fixed URL");
        let filter = |name: &str| {
            let mut pairs = url.query_pairs().filter(|(key, _)| key == name);
            let first = pairs.next()?.1;
            (pairs.next().is_none() && !first.is_empty() && first != "all")
                .then(|| first.into_owned())
        };
        Self {
            page: session_pagination(raw),
            status: filter("status"),
            kind: filter("type"),
        }
    }

    pub(crate) fn bind(self, actor: u64) -> (&'static str, BindMap) {
        (
            &contract().sql["list"],
            BindMap::from([
                ("user_id".into(), DbValue::I64(actor as i64)),
                ("status".into(), DbValue::from_option_string(self.status)),
                (
                    "statement_type".into(),
                    DbValue::from_option_string(self.kind),
                ),
                ("start_row".into(), DbValue::F64(self.page.start)),
                ("end_row".into(), DbValue::F64(self.page.end)),
            ]),
        )
    }
}

pub(crate) fn map_rows(rows: &[DbRow]) -> (Vec<Value>, i64) {
    let total = rows.first().map_or(0, |row| row_number(row, "TOTAL"));
    let items =
        rows.iter()
            .filter_map(|row| {
                let id = row_number(row, "STATEMENT_ID");
                (id > 0).then(|| json!({
            "statement_id":id,"type":row_text(row,"STATEMENT_TYPE"),
            "title":row_text(row,"TITLE"),"message":row_text(row,"MESSAGE"),
            "policy_code":row_text(row,"POLICY_CODE"),"status":row_text(row,"STATUS"),
            "created_at":row_text(row,"CREATED_AT"),"updated_at":row_text(row,"UPDATED_AT")
        }))
            })
            .collect();
    (items, total)
}

pub enum StatementWrite {
    Status(String),
    Appeal(String),
}

pub enum WriteOutcome {
    Missing,
    Pending,
    Applied(Value),
}

pub(crate) fn execute(
    connection: &oracle::Connection,
    actor: u64,
    target: u64,
    write: StatementWrite,
) -> Result<WriteOutcome, DbError> {
    let sql = &contract().sql;
    let (actor, target) = (actor as i64, target as i64);
    let tx = OracleTx::new(connection);
    let names: [(&str, &dyn oracle::sql_type::ToSql); 2] =
        [("user_id", &actor), ("statement_id", &target)];
    let scope = BindMap::from([
        ("user_id".into(), DbValue::I64(actor)),
        ("statement_id".into(), DbValue::I64(target)),
    ]);
    let update = |status: String| {
        let mut binds = scope.clone();
        binds.insert("status".into(), DbValue::String(status));
        match tx.execute(&sql["update"], binds)?.rows_affected {
            0 => Ok(false),
            1 => Ok(true),
            _ => Err(DbError::SchemaNotReady),
        }
    };
    let result = (|| match write {
        StatementWrite::Status(status) => {
            if !update(status)? {
                return Ok(WriteOutcome::Missing);
            }
            let mut rows = connection.query_named(&sql["readStatus"], &names)?;
            let row = rows.next().transpose()?.ok_or(DbError::SchemaNotReady)?;
            let id: i64 = row.get(0)?;
            let status: String = row.get(1)?;
            let updated: String = row.get(2)?;
            if id != target {
                return Err(DbError::SchemaNotReady);
            }
            Ok(WriteOutcome::Applied(
                json!({"statement_id":id, "status":status, "updated_at":updated}),
            ))
        }
        StatementWrite::Appeal(message) => {
            let mut rows = connection.query_named(&sql["lock"], &names)?;
            let Some(row) = rows.next().transpose()? else {
                return Ok(WriteOutcome::Missing);
            };
            let status: String = row.get(0)?;
            drop(rows);
            let mut rows = connection.query_named(&sql["pending"], &names)?;
            if let Some(row) = rows.next().transpose()? {
                let id: i64 = row.get(0)?;
                if !(1..=9_007_199_254_740_991).contains(&id) {
                    return Err(DbError::SchemaNotReady);
                }
                let existing: String = row.get(1)?;
                return Ok(if existing == message {
                    WriteOutcome::Applied(appeal_json(target, id, &status))
                } else {
                    WriteOutcome::Pending
                });
            }
            drop(rows);
            let id = connection.query_row_as::<i64>(&sql["next"], &[])?;
            if !(1..=9_007_199_254_740_991).contains(&id) {
                return Err(DbError::SchemaNotReady);
            }
            let mut binds = scope.clone();
            binds.insert("appeal_id".into(), DbValue::I64(id));
            binds.insert("appeal_message".into(), DbValue::String(message));
            if tx.execute(&sql["insert"], binds)?.rows_affected != 1 || !update("appealed".into())?
            {
                return Err(DbError::SchemaNotReady);
            }
            Ok(WriteOutcome::Applied(appeal_json(target, id, "appealed")))
        }
    })();
    if matches!(result, Ok(WriteOutcome::Applied(_))) {
        tx.commit()?;
    } else {
        tx.rollback()?;
    }
    result
}

fn appeal_json(target: i64, id: i64, status: &str) -> Value {
    json!({"statement_id":target, "status":status, "appeal_id":id, "appeal_status":"pending"})
}

fn private(result: Result<Json<Value>, ApiError>) -> Response {
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
    headers: HeaderMap,
) -> Response {
    let result = async {
        let owner = interaction_actor(&state, &headers).await?;
        let query = StatementQuery::from_query(uri.query().unwrap_or_default());
        let page = query.page;
        let (items,total) = state.repository.account_statements(owner,query).await.map_err(|_| ApiError::server_error("服务器内部错误"))?;
        Ok(Json(json!({"code":200,"message":"success","data":items,"meta":{
            "page":page.page,"page_size":page.page_size,"total":total,"has_next":page.end < total as f64
        }})))
    }.await;
    private(result)
}

pub(crate) async fn write(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    request: Request<Body>,
) -> Response {
    let result = async {
        let (parts, body) = request.into_parts();
        let actor = interaction_actor(&state, &parts.headers).await?;
        let target = raw
            .parse::<u64>()
            .ok()
            .filter(|id| {
                (1..=9_007_199_254_740_991).contains(id)
                    && !raw.starts_with('0')
                    && raw.bytes().all(|b| b.is_ascii_digit())
            })
            .ok_or_else(|| ApiError::bad_request("id 参数错误"))?;
        let data = to_bytes(body, 1 << 20)
            .await
            .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
        let payload = request_body(&parts.headers, &data)?;
        let command = if parts.method == Method::PATCH {
            let action = js_trim(payload["action"].as_str().unwrap_or_default());
            let status = contract()
                .actions
                .get(action)
                .ok_or_else(|| ApiError::bad_request("action 参数错误"))?;
            StatementWrite::Status(status.clone())
        } else {
            let message = js_trim(payload["appeal_message"].as_str().unwrap_or_default());
            if message.is_empty() {
                return Err(ApiError::bad_request("appeal_message 不能为空"));
            }
            if message.len() > contract().max_appeal_bytes || message.contains('\0') {
                return Err(ApiError::bad_request("appeal_message 参数错误"));
            }
            StatementWrite::Appeal(message.to_owned())
        };
        match state
            .repository
            .write_account_statement(actor, target, command)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?
        {
            WriteOutcome::Missing => Err(ApiError::not_found("处置记录不存在")),
            WriteOutcome::Pending => Err(ApiError::conflict("已有待处理申诉")),
            WriteOutcome::Applied(data) => Ok(Json(
                json!({"code":200,"message":"success","data":data,"meta":null}),
            )),
        }
    }
    .await;
    private(result)
}
