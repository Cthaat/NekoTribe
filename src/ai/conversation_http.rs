use crate::{
    ai::conversation_store::{self, AiOperation, Error, Input, ModerationPolicy},
    auth::sessions::NativeState,
    httpx::{errors::ApiError, response::V2Response},
    posts::bookmark::interaction_actor,
};
use axum::{
    body::{to_bytes, Body},
    extract::{OriginalUri, Path, State},
    http::{header, HeaderValue, Request, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
    Extension, Json,
};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ModerationSettings {
    pub allow_all: String,
    pub accounts: String,
}
impl ModerationSettings {
    pub fn from_lookup(get: &impl Fn(&str) -> Option<String>) -> Self {
        Self {
            allow_all: get("MODERATION_ALLOW_ALL").unwrap_or_default(),
            accounts: get("MODERATION_ADMIN_ACCOUNTS").unwrap_or_default(),
        }
    }
    fn policy(&self) -> ModerationPolicy {
        ModerationPolicy::new(&self.allow_all, &self.accounts)
    }
}
pub(crate) async fn private_headers(request: Request<Body>, next: Next) -> Response {
    let is_ai =
        request.uri().path() == "/api/v2/ai" || request.uri().path().starts_with("/api/v2/ai/");
    let mut response = next.run(request).await;
    if is_ai {
        response.headers_mut().insert(
            header::CACHE_CONTROL,
            HeaderValue::from_static("private, no-store"),
        );
    }
    response
}
fn error(error: Error) -> ApiError {
    match error {
        Error::Invalid => ApiError::bad_request("会话参数错误"),
        Error::NotFound => ApiError::not_found("会话不存在"),
        Error::Forbidden => ApiError::forbidden("权限不足"),
        Error::Conflict => ApiError::conflict("会话已变更，请重试"),
        Error::SchemaUnavailable => ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            50301,
            "服务暂不可用，请稍后重试。",
        ),
        Error::Store => ApiError::server_error("服务器内部错误"),
    }
}
fn page(query: &str) -> Result<(i64, i64), ApiError> {
    let url = reqwest::Url::parse(&format!("http://localhost/?{query}"))
        .map_err(|_| ApiError::bad_request("分页参数错误"))?;
    let (mut after, mut limit) = (None, None);
    for (key, value) in url.query_pairs() {
        let (target, max) = match key.as_ref() {
            "after_sequence" => (&mut after, 9_999_999_999),
            "limit" => (&mut limit, 50),
            _ => continue,
        };
        let s = value.as_ref();
        if target.is_some()
            || s.is_empty()
            || (s.len() > 1 && s.starts_with('0'))
            || !s.bytes().all(|b| b.is_ascii_digit())
        {
            return Err(ApiError::bad_request("分页参数错误"));
        }
        let n = s
            .parse::<i64>()
            .map_err(|_| ApiError::bad_request("分页参数错误"))?;
        if n > max {
            return Err(ApiError::bad_request("分页参数错误"));
        }
        *target = Some(n);
    }
    let limit = limit.unwrap_or(20);
    if limit < 1 {
        return Err(ApiError::bad_request("分页参数错误"));
    }
    Ok((after.unwrap_or(0), limit))
}
async fn json_body(body: Body) -> Result<serde_json::Map<String, serde_json::Value>, ApiError> {
    let bytes = to_bytes(body, 1024 * 1024)
        .await
        .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
    serde_json::from_slice::<serde_json::Value>(&bytes)
        .ok()
        .and_then(|v| v.as_object().cloned())
        .ok_or_else(|| ApiError::bad_request("请求体必须是 JSON 对象"))
}
fn parse_create(body: serde_json::Map<String, serde_json::Value>) -> Result<Input, ApiError> {
    if body
        .keys()
        .any(|key| !matches!(key.as_str(), "purpose" | "group_id" | "title"))
    {
        return Err(ApiError::bad_request("会话参数错误"));
    }
    let purpose = body
        .get("purpose")
        .and_then(|v| v.as_str())
        .ok_or_else(|| ApiError::bad_request("会话用途错误"))?
        .to_owned();
    let group_id = match body.get("group_id") {
        None | Some(serde_json::Value::Null) => None,
        Some(v) => {
            let n = v
                .as_f64()
                .filter(|n| {
                    n.is_finite() && n.fract() == 0.0 && *n > 0.0 && *n <= 9_007_199_254_740_991.0
                })
                .ok_or_else(|| ApiError::bad_request("群组参数错误"))?;
            Some(n as i64)
        }
    };
    let title = match body.get("title") {
        None | Some(serde_json::Value::Null) => String::new(),
        Some(v) => v
            .as_str()
            .ok_or_else(|| ApiError::bad_request("会话标题错误"))?
            .to_owned(),
    };
    conversation_store::validate(Input {
        purpose,
        group_id,
        title,
    })
    .map_err(|_| ApiError::bad_request("会话参数错误"))
}
async fn execute(
    state: NativeState,
    request: Request<Body>,
    settings: Option<Extension<ModerationSettings>>,
    kind: &str,
    id: Option<String>,
) -> Result<Response, ApiError> {
    let (parts, body) = request.into_parts();
    let actor = interaction_actor(&state, &parts.headers).await?;
    if let Some(id) = &id {
        if !conversation_store::valid_uuid(id) {
            return Err(ApiError::not_found("会话不存在"));
        }
    }
    let operation = match kind {
        "create" => AiOperation::Create(parse_create(json_body(body).await?)?),
        "read" => AiOperation::Read(id.expect("route id")),
        "append" => {
            let body = json_body(body).await?;
            if body.len() != 1 || !body.contains_key("content") {
                return Err(ApiError::bad_request("消息参数错误"));
            }
            let content = body["content"]
                .as_str()
                .filter(|s| !s.is_empty() && s.len() <= 65536)
                .ok_or_else(|| ApiError::bad_request("消息内容错误"))?
                .to_owned();
            AiOperation::Append {
                id: id.expect("route id"),
                content,
            }
        }
        "list" => {
            let (after, limit) = page(parts.uri.query().unwrap_or_default())?;
            AiOperation::List {
                id: id.expect("route id"),
                after,
                limit,
            }
        }
        _ => return Err(ApiError::route_not_found()),
    };
    let policy = settings
        .map(|Extension(value)| value)
        .unwrap_or_default()
        .policy();
    let result = state
        .repository
        .ai_conversation(actor, operation, policy)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?
        .map_err(error)?;
    Ok(Json(V2Response::ok(result)).into_response())
}
pub(crate) async fn create(
    State(state): State<NativeState>,
    settings: Option<Extension<ModerationSettings>>,
    request: Request<Body>,
) -> Response {
    execute(state, request, settings, "create", None)
        .await
        .into_response()
}
pub(crate) async fn read(
    State(state): State<NativeState>,
    Path(id): Path<String>,
    settings: Option<Extension<ModerationSettings>>,
    request: Request<Body>,
) -> Response {
    execute(state, request, settings, "read", Some(id))
        .await
        .into_response()
}
pub(crate) async fn append(
    State(state): State<NativeState>,
    Path(id): Path<String>,
    settings: Option<Extension<ModerationSettings>>,
    request: Request<Body>,
) -> Response {
    execute(state, request, settings, "append", Some(id))
        .await
        .into_response()
}
pub(crate) async fn list(
    State(state): State<NativeState>,
    Path(id): Path<String>,
    settings: Option<Extension<ModerationSettings>>,
    OriginalUri(_): OriginalUri,
    request: Request<Body>,
) -> Response {
    execute(state, request, settings, "list", Some(id))
        .await
        .into_response()
}
