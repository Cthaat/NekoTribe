//! Limited writing generation. Model configuration and credentials are server-owned.
use super::{
    conversation_store::{AiOperation, AssistantInput, ModerationPolicy},
    model_config::ModelRouter,
    transport::{CredentialResolver, Transport, TransportError},
};
use crate::auth::sessions::SessionRepository;
use serde_json::{json, Value};
use std::sync::Arc;

const SYSTEM: &str =
    "你是写作助手。根据用户提供的内容提供可审阅的草稿和修改建议；不要假装已发布或执行任何操作。";

#[derive(Clone, Default, PartialEq, Eq)]
pub struct Settings(String);
impl std::fmt::Debug for Settings {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("AiWritingSettings [redacted]")
    }
}
impl Settings {
    pub(crate) fn configuration(&self) -> &str {
        &self.0
    }
    pub fn from_lookup(get: &impl Fn(&str) -> Option<String>) -> Self {
        Self(get("AI_MODEL_CONFIG_JSON").unwrap_or_default())
    }
}

#[derive(Debug)]
pub enum Error {
    Context,
    Unavailable,
    Repository,
    Store(super::conversation_store::Error),
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

pub async fn generate(
    repository: &dyn SessionRepository,
    user: u64,
    id: &str,
    policy: ModerationPolicy,
    settings: &Settings,
) -> Result<Value, Error> {
    if settings.0.is_empty() || settings.0.len() > 65536 {
        return Err(Error::Unavailable);
    }
    let configuration: Value = serde_json::from_str(&settings.0).map_err(|_| Error::Unavailable)?;
    let selection = ModelRouter::new(&configuration)
        .and_then(|r| r.select("writing", &[]))
        .map_err(|_| Error::Unavailable)?;
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
        .filter(|v| !v.is_empty() && v.len() <= 50)
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
    if messages.last().and_then(|m| m["role"].as_str()) != Some("user") {
        return Err(Error::Context);
    }
    let mut budget =
        (i64::from(selection.context_window_tokens) - i64::from(selection.max_output_tokens) - 512)
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
    let resolver: CredentialResolver = Arc::new(|reference| {
        std::env::var(reference).map_err(|_| TransportError("MISSING_CREDENTIAL"))
    });
    let transport = Transport::new(Some(resolver), None).map_err(|_| Error::Unavailable)?;
    let answer = transport
        .infer(&selection, &json!({"messages":selected}), None)
        .await
        .map_err(|_| Error::Unavailable)?;
    if answer.finish_reason != "stop"
        || !answer.tool_calls.is_empty()
        || answer.text.is_empty()
        || answer.text.len() > 65536
    {
        return Err(Error::Unavailable);
    }
    store(
        repository,
        user,
        AiOperation::Assistant {
            id: id.into(),
            input: AssistantInput {
                content: answer.text,
                expected_sequence: previous,
                model_id: selection.profile_id,
                config_revision: selection.configuration_revision as i64,
            },
        },
        policy,
    )
    .await
}
