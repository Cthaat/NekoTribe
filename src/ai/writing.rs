//! Limited writing generation. Model configuration and credentials are server-owned.
use super::{
    conversation_store::{AiOperation, AssistantInput, ModerationPolicy},
    model_config::ModelRouter,
    model_source::ModelFile,
    transport::{CredentialResolver, Transport, TransportError},
    user_provider,
};
use crate::auth::sessions::SessionRepository;
use serde_json::{Value, json};
use std::sync::Arc;
use tokio::sync::watch;

const SYSTEM: &str =
    "你是写作助手。根据用户提供的内容提供可审阅的草稿和修改建议；不要假装已发布或执行任何操作。";

#[derive(Clone, Default, PartialEq, Eq)]
pub struct Settings {
    inline: Arc<str>,
    file: Option<Arc<ModelFile>>,
}
impl std::fmt::Debug for Settings {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("AiWritingSettings [redacted]")
    }
}
impl Settings {
    pub(crate) async fn configuration(&self) -> Option<Arc<str>> {
        if let Some(file) = &self.file {
            return file.clone().load().await;
        }
        Some(self.inline.clone())
    }
    pub fn from_lookup(get: &impl Fn(&str) -> Option<String>) -> Self {
        Self {
            inline: get("AI_MODEL_CONFIG_JSON").unwrap_or_default().into(),
            file: get("AI_MODEL_CONFIG_FILE")
                .filter(|path| !path.is_empty())
                .map(|path| Arc::new(ModelFile::new(path))),
        }
    }
}

#[derive(Debug)]
pub enum Error {
    Context,
    Unavailable,
    Repository,
    Store(super::conversation_store::Error),
    Quota(super::model_quota::QuotaError),
}

async fn store(
    repository: &dyn SessionRepository,
    user: u64,
    operation: AiOperation,
    policy: ModerationPolicy,
) -> Result<Value, Error> {
    repository
        .ai_conversation(user, operation, policy)
        .await
        .map_err(|_| Error::Repository)?
        .map_err(Error::Store)
}

#[derive(Default)]
pub struct WritingRequest {
    skill_id: Option<&'static str>,
    expected_sequence: Option<i64>,
}

pub(super) fn parse_request(raw: &[u8]) -> Option<WritingRequest> {
    if raw.is_empty() {
        return Some(WritingRequest::default());
    }
    let value: Value = serde_json::from_slice(raw).ok()?;
    let body = value.as_object()?;
    if body
        .keys()
        .any(|key| !matches!(key.as_str(), "skill_id" | "expected_sequence"))
        || super::knowledge_search_body::has_too_many_members(raw, body.len())
    {
        return None;
    }
    let skill_id = match body.get("skill_id") {
        None => None,
        Some(value) if value.as_str() == Some("writing-draft") => Some("writing-draft"),
        _ => return None,
    };
    let expected_sequence = match body.get("expected_sequence") {
        None => None,
        Some(value) => Some(super::knowledge_search_body::expected_sequence(value)?),
    };
    Some(WritingRequest {
        skill_id,
        expected_sequence,
    })
}

pub async fn generate(
    repository: &dyn SessionRepository,
    user: u64,
    id: &str,
    policy: ModerationPolicy,
    settings: &Settings,
    cancel: Option<watch::Receiver<bool>>,
    quota: Option<&super::model_quota::AiModelQuota>,
    input: WritingRequest,
    personal: &user_provider::Settings,
) -> Result<Value, Error> {
    let (selection, resolver) = match user_provider::writing_connection(repository, personal, user)
        .await
        .map_err(|_| Error::Unavailable)?
    {
        Some(connection) => connection,
        None => {
            let raw = settings.configuration().await.ok_or(Error::Unavailable)?;
            let selection = ModelRouter::from_json(&raw)
                .and_then(|router| router.select("writing", &[]))
                .map_err(|_| Error::Unavailable)?;
            let resolver: CredentialResolver = Arc::new(|reference| {
                std::env::var(reference).map_err(|_| TransportError("MISSING_CREDENTIAL"))
            });
            (selection, resolver)
        }
    };
    if selection.configuration_revision > 999_999_999_999_999 {
        return Err(Error::Context);
    }
    let conversation = store(
        repository,
        user,
        AiOperation::Read(id.into()),
        policy.clone(),
    )
    .await?;
    if conversation["purpose"] != "writing" {
        return Err(Error::Context);
    }
    let history = store(
        repository,
        user,
        AiOperation::Recent(id.into()),
        policy.clone(),
    )
    .await?;
    let messages = history
        .as_array()
        .filter(|v| v.len() <= 50)
        .ok_or(Error::Context)?;
    let mut previous = 0_i64;
    for message in messages {
        let sequence = message["sequence_no"]
            .as_i64()
            .filter(|n| *n > previous)
            .ok_or(Error::Context)?;
        if !matches!(message["role"].as_str(), Some("user" | "assistant"))
            || message["content"].as_str().is_none_or(str::is_empty)
        {
            return Err(Error::Context);
        }
        previous = sequence;
    }
    let last = messages.last();
    if input.expected_sequence.is_some_and(|sequence| {
        last.is_none_or(|message| {
            message["sequence_no"].as_i64() != Some(sequence) || message["role"] != "user"
        })
    }) {
        return Err(Error::Store(super::conversation_store::Error::Conflict));
    }
    if last.and_then(|m| m["role"].as_str()) != Some("user") {
        return Err(Error::Context);
    }
    let skill_generation = store(
        repository,
        user,
        AiOperation::WritingSkill(id.into(), input.skill_id),
        policy.clone(),
    )
    .await?
    .as_i64()
    .filter(|generation| (1..=999_999_999_999_999).contains(generation))
    .ok_or(Error::Unavailable)?;
    let mut audit = super::run_audit::AiRunAudit::new("writing_draft", skill_generation);
    audit.config_revision = selection.configuration_revision;
    if input.skill_id.is_some() {
        audit.skill_selection = "explicit";
    }
    let result = async {
        let mut budget = (i64::from(selection.context_window_tokens)
            - i64::from(selection.max_output_tokens)
            - 512)
            .min(16384)
            - SYSTEM.len() as i64;
        let mut selected = Vec::new();
        for message in messages.iter().rev() {
            let content = message["content"].as_str().ok_or(Error::Context)?;
            let cost = content.len() as i64 + 16;
            if cost > budget {
                break;
            }
            budget -= cost;
            selected.push(json!({"role":message["role"],"content":content}));
        }
        if selected.is_empty() {
            return Err(Error::Context);
        }
        selected.reverse();
        selected.insert(0, json!({"role":"system","content":SYSTEM}));
        let transport = Transport::new(Some(resolver), None).map_err(|_| Error::Unavailable)?;
        audit.stage = "quota";
        super::model_quota::require(quota, user, 1)
            .await
            .map_err(Error::Quota)?;
        audit.stage = "inference";
        let answer = transport
            .infer(&selection, &json!({"messages":selected}), cancel.clone())
            .await
            .map_err(|_| Error::Unavailable)?;
        if cancel.as_ref().is_some_and(|signal| *signal.borrow())
            || answer.finish_reason != "stop"
            || !answer.tool_calls.is_empty()
            || answer.text.is_empty()
            || answer.text.len() > 65536
        {
            return Err(Error::Unavailable);
        }
        audit.stage = "persist";
        store(
            repository,
            user,
            AiOperation::Assistant {
                id: id.into(),
                skill_generation,
                cancel: cancel.clone(),
                input: AssistantInput {
                    content: answer.text,
                    expected_sequence: previous,
                    model_id: selection.profile_id,
                    model_version: selection.model_version,
                    config_revision: selection.configuration_revision as i64,
                },
            },
            policy,
        )
        .await
    }
    .await;
    audit.finish(
        &result.as_ref().map(Some),
        cancel.as_ref().is_some_and(|signal| *signal.borrow()),
        |error| match error {
            Error::Quota(quota) => Some(*quota),
            _ => None,
        },
    );
    result
}
