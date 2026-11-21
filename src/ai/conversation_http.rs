use crate::{
    ai::conversation_store::{self, AiOperation, Error, Input, ModerationPolicy},
    auth::sessions::NativeState,
    httpx::{errors::ApiError, response::V2Response},
    posts::bookmark::interaction_actor,
};
use axum::{
    body::{to_bytes, Body},
    extract::{OriginalUri, Path, State},
    http::{Request, StatusCode},
    response::{IntoResponse, Response},
    Extension, Json,
};
use std::sync::Arc;

#[derive(Clone)]
pub struct KnowledgeRuntime(pub Arc<dyn crate::ai::knowledge_service::KnowledgeStore>);

pub(crate) async fn availability(
    State(state): State<NativeState>,
    models: Option<Extension<crate::ai::writing::Settings>>,
    request: Request<Body>,
) -> Response {
    async {
        let (parts, _) = request.into_parts();
        let actor = interaction_actor(&state, &parts.headers).await?;
        let mut value = state
            .repository
            .ai_conversation(
                actor,
                AiOperation::Availability,
                ModerationPolicy::new("", ""),
            )
            .await
            .map_err(|_| {
                ApiError::new(
                    StatusCode::SERVICE_UNAVAILABLE,
                    50301,
                    "服务暂不可用，请稍后重试。",
                )
            })?
            .map_err(|_| {
                ApiError::new(
                    StatusCode::SERVICE_UNAVAILABLE,
                    50301,
                    "服务暂不可用，请稍后重试。",
                )
            })?;
        let enabled = |feature: &str| value[feature].as_bool().unwrap_or(false);
        let flags = super::skill_selection::UserAvailability {
            knowledge: enabled("knowledge"),
            writing: enabled("writing"),
            group: enabled("group"),
            moderation: enabled("moderation"),
        };
        if let Some(data) = value.as_object_mut() {
            data.insert("skills".into(), serde_json::json!(flags.skills()));
            let settings = models
                .map(|Extension(settings)| settings)
                .unwrap_or_default();
            let (inference, revision) = inference_availability(&settings, flags).await;
            data.insert("inference".into(), inference);
            data.insert("model_config_revision".into(), serde_json::json!(revision));
        }
        Ok::<_, ApiError>(Json(V2Response::ok(value)))
    }
    .await
    .into_response()
}

async fn inference_availability(
    settings: &crate::ai::writing::Settings,
    flags: super::skill_selection::UserAvailability,
) -> (serde_json::Value, Option<u64>) {
    use super::model_config::ModelRouter;
    let router = settings
        .configuration()
        .await
        .filter(|raw| raw.len() <= 65536)
        .and_then(|raw| ModelRouter::from_json(&raw).ok());
    let revision = router
        .as_ref()
        .and_then(|router| router.select("knowledge", &[]).ok())
        .map(|model| model.configuration_revision)
        .filter(|revision| *revision <= 999_999_999_999_999);
    let configured = |role: &str| {
        router
            .as_ref()
            .and_then(|router| router.select(role, &[]).ok())
            .is_some_and(|model| {
                revision.is_some()
                    && model.api_key_env.is_none_or(|reference| {
                        std::env::var(reference).is_ok_and(|key| {
                            !key.is_empty() && key.bytes().all(|byte| (0x21..=0x7e).contains(&byte))
                        })
                    })
            })
    };
    let inference = serde_json::json!({
        "knowledge": flags.knowledge && configured("knowledge"),
        "writing": flags.writing && configured("writing"),
        "group": flags.group && configured("agent"),
        "moderation": flags.moderation && configured("moderation")
    });
    (inference, revision)
}

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
    pub(crate) fn policy(&self) -> ModerationPolicy {
        ModerationPolicy::new(&self.allow_all, &self.accounts)
    }
}
pub(crate) async fn generate_knowledge(
    State(state): State<NativeState>,
    Path(id): Path<String>,
    settings: Option<Extension<ModerationSettings>>,
    writing: Option<Extension<crate::ai::writing::Settings>>,
    knowledge: Option<Extension<KnowledgeRuntime>>,
    quota: Option<Extension<super::model_quota::AiModelQuota>>,
    request: Request<Body>,
) -> Response {
    let (sender, signal) = tokio::sync::watch::channel(false);
    let _cancel = CancelOnDrop(sender);
    async {
        use crate::ai::{
            knowledge_conversation::Error as KnowledgeError, knowledge_turn::TurnError,
        };
        let (parts, body) = request.into_parts();
        let actor = interaction_actor(&state, &parts.headers).await?;
        if !conversation_store::valid_uuid(&id) {
            return Err(ApiError::not_found("会话不存在"));
        }
        let bytes = to_bytes(body, 4096)
            .await
            .map_err(|_| ApiError::bad_request("知识检索参数错误"))?;
        let input = crate::ai::knowledge_search_body::parse(&bytes)
            .map_err(|_| ApiError::bad_request("知识检索参数错误"))?;
        let unavailable = || {
            ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                50301,
                "服务暂不可用，请稍后重试。",
            )
        };
        let runtime = knowledge.ok_or_else(unavailable)?.0;
        let config = writing.map(|Extension(s)| s).unwrap_or_default();
        let configuration = config.configuration().await.ok_or_else(unavailable)?;
        let policy = settings.map(|Extension(s)| s).unwrap_or_default().policy();
        let result = crate::ai::knowledge_conversation::generate_and_search(
            state.repository.as_ref(),
            runtime.0.as_ref(),
            actor,
            &id,
            policy,
            &configuration,
            Some(signal),
            &input,
            quota.as_ref().map(|Extension(value)| value),
        )
        .await;
        let result = match result {
            Ok(message) => message,
            Err(KnowledgeError::Knowledge(TurnError::Quota(quota_error))) => {
                return Ok(quota_error.into_response());
            }
            Err(KnowledgeError::Store(e)) => return Err(error(e)),
            Err(KnowledgeError::Repository) => {
                return Err(ApiError::server_error("服务器内部错误"));
            }
            Err(
                KnowledgeError::Context
                | KnowledgeError::Knowledge(TurnError::InvalidSource | TurnError::ContextTooLarge),
            ) => {
                return Err(ApiError::bad_request("知识会话上下文不可用"));
            }
            Err(_) => return Err(unavailable()),
        };
        let status = if result.is_some() {
            "generated"
        } else {
            "insufficient_evidence"
        };
        Ok::<_, ApiError>(
            Json(V2Response::ok(
                serde_json::json!({"status":status,"message":result}),
            ))
            .into_response(),
        )
    }
    .await
    .into_response()
}
struct CancelOnDrop(tokio::sync::watch::Sender<bool>);
impl Drop for CancelOnDrop {
    fn drop(&mut self) {
        self.0.send_replace(true);
    }
}
pub(crate) async fn generate_group(
    State(state): State<NativeState>,
    Path(id): Path<String>,
    settings: Option<Extension<ModerationSettings>>,
    writing: Option<Extension<crate::ai::writing::Settings>>,
    quota: Option<Extension<super::model_quota::AiModelQuota>>,
    request: Request<Body>,
) -> Response {
    let (sender, signal) = tokio::sync::watch::channel(false);
    let _cancel = CancelOnDrop(sender);
    async {
        let (parts, body) = request.into_parts();
        let actor = interaction_actor(&state, &parts.headers).await?;
        if !conversation_store::valid_uuid(&id) {
            return Err(ApiError::not_found("会话不存在"));
        }
        let bytes = to_bytes(body, 4096)
            .await
            .map_err(|_| ApiError::bad_request("群运营草稿参数错误"))?;
        let request = crate::ai::group_draft::Request::parse(&bytes)
            .ok_or_else(|| ApiError::bad_request("群运营草稿参数错误"))?;
        let policy = settings
            .map(|Extension(value)| value)
            .unwrap_or_default()
            .policy();
        let config = writing.map(|Extension(value)| value).unwrap_or_default();
        let result = crate::ai::group_draft::generate(
            state.repository.as_ref(),
            actor,
            &id,
            policy,
            &config,
            request,
            Some(signal),
            quota.as_ref().map(|Extension(value)| value),
        )
        .await;
        let result = match result {
            Ok(message) => message,
            Err(crate::ai::group_draft::Error::Quota(quota_error)) => {
                return Ok(quota_error.into_response());
            }
            Err(crate::ai::group_draft::Error::Store(Error::Invalid)) => {
                return Err(ApiError::bad_request("群运营草稿参数错误"));
            }
            Err(crate::ai::group_draft::Error::Store(e)) => return Err(error(e)),
            Err(crate::ai::group_draft::Error::Unavailable) => {
                return Err(error(Error::SchemaUnavailable));
            }
        };
        let status = if result.is_some() {
            "generated"
        } else {
            "insufficient_evidence"
        };
        Ok::<_, ApiError>(
            Json(V2Response::ok(
                serde_json::json!({"status": status, "message": result}),
            ))
            .into_response(),
        )
    }
    .await
    .into_response()
}
pub(crate) async fn generate_moderation(
    State(state): State<NativeState>,
    Path(id): Path<String>,
    settings: Option<Extension<ModerationSettings>>,
    model: Option<Extension<crate::ai::writing::Settings>>,
    quota: Option<Extension<super::model_quota::AiModelQuota>>,
    request: Request<Body>,
) -> Response {
    use crate::ai::moderation_advice as review;
    let (sender, signal) = tokio::sync::watch::channel(false);
    let _cancel = CancelOnDrop(sender);
    async {
        let (parts, body) = request.into_parts();
        let actor = interaction_actor(&state, &parts.headers).await?;
        if !conversation_store::valid_uuid(&id) {
            return Err(ApiError::not_found("会话不存在"));
        }
        let bytes = to_bytes(body, 4096)
            .await
            .map_err(|_| ApiError::bad_request("审核建议参数错误"))?;
        let input = review::Request::parse(&bytes)
            .ok_or_else(|| ApiError::bad_request("审核建议参数错误"))?;
        let policy = settings
            .map(|Extension(value)| value)
            .unwrap_or_default()
            .policy();
        let config = model.map(|Extension(value)| value).unwrap_or_default();
        let result = review::generate(
            state.repository.as_ref(),
            actor,
            &id,
            policy,
            &config,
            input,
            Some(signal),
            quota.as_ref().map(|Extension(value)| value),
        )
        .await;
        let result = match result {
            Ok(message) => message,
            Err(review::Error::Quota(quota_error)) => return Ok(quota_error.into_response()),
            Err(review::Error::Store(Error::Invalid)) => {
                return Err(ApiError::bad_request("审核建议参数错误"));
            }
            Err(review::Error::Store(e)) => return Err(error(e)),
            Err(review::Error::Unavailable) => return Err(error(Error::SchemaUnavailable)),
        };
        let status = if result.is_some() {
            "generated"
        } else {
            "insufficient_evidence"
        };
        Ok::<_, ApiError>(
            Json(V2Response::ok(
                serde_json::json!({"status":status,"message":result}),
            ))
            .into_response(),
        )
    }
    .await
    .into_response()
}
pub(crate) async fn save_moderation_feedback(
    State(state): State<NativeState>,
    Path((id, message_id)): Path<(String, String)>,
    settings: Option<Extension<ModerationSettings>>,
    request: Request<Body>,
) -> Response {
    async {
        let (parts, body) = request.into_parts();
        let actor = interaction_actor(&state, &parts.headers).await?;
        if !conversation_store::valid_uuid(&id) || !conversation_store::valid_uuid(&message_id) {
            return Err(error(Error::NotFound));
        }
        let invalid = || ApiError::bad_request("审核反馈参数错误");
        let bytes = to_bytes(body, 4096).await.map_err(|_| invalid())?;
        let rating = super::moderation_feedback::parse_rating(&bytes).ok_or_else(invalid)?;
        let policy = settings
            .map(|Extension(value)| value)
            .unwrap_or_default()
            .policy();
        let result = state
            .repository
            .ai_conversation(
                actor,
                AiOperation::ModerationFeedbackSave {
                    id,
                    message_id,
                    rating,
                },
                policy,
            )
            .await
            .map_err(|_| error(Error::SchemaUnavailable))?
            .map_err(|failure| match failure {
                Error::Invalid => invalid(),
                Error::Store => error(Error::SchemaUnavailable),
                other => error(other),
            })?;
        Ok::<_, ApiError>(Json(V2Response::ok(result)))
    }
    .await
    .into_response()
}

pub(crate) async fn generate(
    State(state): State<NativeState>,
    Path(id): Path<String>,
    settings: Option<Extension<ModerationSettings>>,
    writing: Option<Extension<crate::ai::writing::Settings>>,
    quota: Option<Extension<super::model_quota::AiModelQuota>>,
    request: Request<Body>,
) -> Response {
    let (sender, signal) = tokio::sync::watch::channel(false);
    let _cancel = CancelOnDrop(sender);
    async {
        let (parts, body) = request.into_parts();
        let actor = interaction_actor(&state, &parts.headers).await?;
        if !conversation_store::valid_uuid(&id) {
            return Err(ApiError::not_found("会话不存在"));
        }
        let policy = settings.map(|Extension(s)| s).unwrap_or_default().policy();
        let config = writing.map(|Extension(s)| s).unwrap_or_default();
        use crate::ai::writing::{self, Error as WritingError};
        let bytes = to_bytes(body, 4096)
            .await
            .map_err(|_| ApiError::bad_request("写作生成参数错误"))?;
        let input = writing::parse_request(&bytes)
            .ok_or_else(|| ApiError::bad_request("写作生成参数错误"))?;
        let result = writing::generate(
            state.repository.as_ref(),
            actor,
            &id,
            policy,
            &config,
            Some(signal),
            quota.as_ref().map(|Extension(value)| value),
            input,
        )
        .await;
        let value = match result {
            Ok(value) => value,
            Err(WritingError::Quota(quota_error)) => return Ok(quota_error.into_response()),
            Err(WritingError::Store(e)) => return Err(error(e)),
            Err(WritingError::Repository) => return Err(ApiError::server_error("服务器内部错误")),
            Err(WritingError::Context) => {
                return Err(ApiError::bad_request("会话内容无法用于生成"));
            }
            Err(WritingError::Unavailable) => return Err(error(Error::SchemaUnavailable)),
        };
        Ok::<_, ApiError>(Json(V2Response::ok(value)).into_response())
    }
    .await
    .into_response()
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
fn page(query: &str) -> Result<(i64, i64, i64), ApiError> {
    let url = reqwest::Url::parse(&format!("http://localhost/?{query}"))
        .map_err(|_| ApiError::bad_request("分页参数错误"))?;
    let (mut after, mut before, mut limit) = (None, None, None);
    for (key, value) in url.query_pairs() {
        let (target, max) = match key.as_ref() {
            "after_sequence" => (&mut after, 9_999_999_999),
            "before_sequence" => (&mut before, 10_000_000_000),
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
    if limit < 1 || before.is_some_and(|n| n == 0 || after.is_some()) {
        return Err(ApiError::bad_request("分页参数错误"));
    }
    Ok((after.unwrap_or(0), before.unwrap_or(0), limit))
}
fn owned_page(query: &str) -> Result<(String, i64, String, Option<i64>, String), ApiError> {
    let url = reqwest::Url::parse(&format!("http://localhost/?{query}"))
        .map_err(|_| ApiError::bad_request("分页参数错误"))?;
    let (mut after, mut limit, mut purpose) = (None, None, None);
    let mut group_id = None;
    let (mut target_kind, mut target_id) = (None, None);
    for (key, value) in url.query_pairs() {
        match key.as_ref() {
            "after_id" => {
                if after.is_some() || (!value.is_empty() && !conversation_store::valid_uuid(&value))
                {
                    return Err(ApiError::bad_request("分页参数错误"));
                }
                after = Some(value.into_owned());
            }
            "limit" => {
                if limit.is_some()
                    || value.is_empty()
                    || (value.len() > 1 && value.starts_with('0'))
                    || !value.bytes().all(|b| b.is_ascii_digit())
                {
                    return Err(ApiError::bad_request("分页参数错误"));
                }
                let n = value
                    .parse::<i64>()
                    .map_err(|_| ApiError::bad_request("分页参数错误"))?;
                if !(1..=50).contains(&n) {
                    return Err(ApiError::bad_request("分页参数错误"));
                }
                limit = Some(n);
            }
            "purpose" => {
                if purpose.is_some()
                    || value.is_empty()
                    || !conversation_store::valid_list_purpose(&value)
                {
                    return Err(ApiError::bad_request("会话用途错误"));
                }
                purpose = Some(value.into_owned());
            }
            "group_id" => {
                if group_id.is_some()
                    || value.is_empty()
                    || value.starts_with('0')
                    || !value.bytes().all(|b| b.is_ascii_digit())
                {
                    return Err(ApiError::bad_request("群组参数错误"));
                }
                group_id = Some(
                    value
                        .parse::<i64>()
                        .ok()
                        .filter(|id| (1..=9007199254740991).contains(id))
                        .ok_or_else(|| ApiError::bad_request("群组参数错误"))?,
                );
            }
            "target_type" => {
                if target_kind.is_some()
                    || !matches!(
                        value.as_ref(),
                        "post" | "comment" | "group_post" | "group_post_comment"
                    )
                {
                    return Err(ApiError::bad_request("审核对象错误"));
                }
                target_kind = Some(value.into_owned());
            }
            "target_id" => {
                if target_id.is_some()
                    || value.is_empty()
                    || value.len() > 15
                    || value.starts_with('0')
                    || !value.bytes().all(|b| b.is_ascii_digit())
                {
                    return Err(ApiError::bad_request("审核对象错误"));
                }
                target_id = Some(value.into_owned());
            }
            _ => (),
        }
    }
    if group_id.is_some() && purpose.as_deref() != Some("group") {
        return Err(ApiError::bad_request("群组参数错误"));
    }
    let target_title = match (target_kind, target_id) {
        (None, None) => String::new(),
        (Some(kind), Some(id)) if purpose.as_deref() == Some("moderation") => {
            format!("moderation:{kind}:{id}")
        }
        _ => return Err(ApiError::bad_request("审核对象错误")),
    };
    Ok((
        after.unwrap_or_default(),
        limit.unwrap_or(20),
        purpose.unwrap_or_default(),
        group_id,
        target_title,
    ))
}
async fn json_body(body: Body) -> Result<serde_json::Map<String, serde_json::Value>, ApiError> {
    let bytes = to_bytes(body, 1024 * 1024)
        .await
        .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
    serde_json::from_slice::<serde_json::Value>(&bytes)
        .ok()
        .and_then(|value| match value {
            serde_json::Value::Object(fields)
                if !super::knowledge_search_body::has_too_many_members(&bytes, fields.len()) =>
            {
                Some(fields)
            }
            _ => None,
        })
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
        "list-owned" => {
            let (after, limit, purpose, group_id, target_title) =
                owned_page(parts.uri.query().unwrap_or_default())?;
            AiOperation::ListOwned {
                after,
                limit,
                purpose,
                group_id,
                target_title,
            }
        }
        "read" => AiOperation::Read(id.expect("route id")),
        "delete" => AiOperation::Delete(id.expect("route id")),
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
            let (after, before, limit) = page(parts.uri.query().unwrap_or_default())?;
            AiOperation::List {
                id: id.expect("route id"),
                after,
                before,
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
pub(crate) async fn list_owned(
    State(state): State<NativeState>,
    settings: Option<Extension<ModerationSettings>>,
    request: Request<Body>,
) -> Response {
    execute(state, request, settings, "list-owned", None)
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
pub(crate) async fn remove(
    State(state): State<NativeState>,
    Path(id): Path<String>,
    settings: Option<Extension<ModerationSettings>>,
    request: Request<Body>,
) -> Response {
    execute(state, request, settings, "delete", Some(id))
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
