//! Internal knowledge conversation generation; caller authenticates the user.
use super::{
    conversation_store::{AiOperation, AssistantInput, ModerationPolicy},
    knowledge_service::{self, KnowledgeStore, KnowledgeTransport},
    knowledge_turn::TurnError,
    model_config::{ModelRouter, SelectionSnapshot},
    transport::{CredentialResolver, Transport, TransportError},
};
use crate::auth::sessions::SessionRepository;
use serde_json::Value;
use std::sync::Arc;
use tokio::sync::watch;

#[derive(Debug)]
pub enum Error {
    Context,
    Configuration,
    Cancelled,
    Knowledge(TurnError),
    Repository,
    Store(super::conversation_store::Error),
}
fn cancelled(signal: &Option<watch::Receiver<bool>>) -> Result<(), Error> {
    if signal.as_ref().is_some_and(|s| *s.borrow()) {
        Err(Error::Cancelled)
    } else {
        Ok(())
    }
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

/// Repository calls complete before model inference and the sequence is checked when writing.
pub async fn generate_with_transport<S: KnowledgeStore + ?Sized, T: KnowledgeTransport>(
    repository: &dyn SessionRepository,
    knowledge: &S,
    user: u64,
    id: &str,
    policy: ModerationPolicy,
    selection: SelectionSnapshot,
    transport: &T,
    signal: Option<watch::Receiver<bool>>,
) -> Result<Option<Value>, Error> {
    generate_with_transport_and_search(
        repository, knowledge, user, id, policy, selection, transport, signal, None,
    )
    .await
}
pub async fn generate_with_transport_and_search<
    S: KnowledgeStore + ?Sized,
    T: KnowledgeTransport,
>(
    repository: &dyn SessionRepository,
    knowledge: &S,
    user: u64,
    id: &str,
    policy: ModerationPolicy,
    selection: SelectionSnapshot,
    transport: &T,
    signal: Option<watch::Receiver<bool>>,
    search_phrase: Option<&str>,
) -> Result<Option<Value>, Error> {
    cancelled(&signal)?;
    if user == 0
        || user > 9_007_199_254_740_991
        || selection.role != "knowledge"
        || selection.configuration_revision == 0
        || selection.configuration_revision > 999_999_999_999_999
    {
        return Err(Error::Context);
    }
    let conversation = store(
        repository,
        user,
        AiOperation::Read(id.into()),
        policy.clone(),
    )
    .await?;
    let history = store(
        repository,
        user,
        AiOperation::Recent(id.into()),
        policy.clone(),
    )
    .await?;
    if conversation["purpose"] != "knowledge" {
        return Err(Error::Context);
    }
    let messages = history
        .as_array()
        .filter(|m| !m.is_empty() && m.len() <= 50)
        .ok_or(Error::Context)?;
    let mut previous = 0_i64;
    for message in messages {
        let sequence = message["sequence_no"]
            .as_i64()
            .filter(|n| *n > previous && *n <= 9_999_999_999)
            .ok_or(Error::Context)?;
        if !matches!(message["role"].as_str(), Some("user" | "assistant"))
            || message["content"].as_str().is_none_or(str::is_empty)
        {
            return Err(Error::Context);
        }
        previous = sequence;
    }
    let last = messages.last().ok_or(Error::Context)?;
    if last["role"] != "user" {
        return Err(Error::Context);
    }
    let query = last["content"].as_str().ok_or(Error::Context)?;
    cancelled(&signal)?;
    let result = knowledge_service::generate_with_transport_and_search(
        knowledge,
        user as i64,
        query,
        search_phrase,
        selection.clone(),
        transport,
        signal.clone(),
    )
    .await
    .map_err(Error::Knowledge)?;
    cancelled(&signal)?;
    let Some(answer) = result.answer else {
        return Ok(None);
    };
    let value = store(
        repository,
        user,
        AiOperation::KnowledgeAssistant {
            id: id.into(),
            input: AssistantInput {
                content: answer,
                expected_sequence: previous,
                model_id: selection.profile_id,
                config_revision: selection.configuration_revision as i64,
            },
            sources: result.sources,
        },
        policy,
    )
    .await?;
    Ok(Some(value))
}
/// The configuration and credentials are server-owned.
pub async fn generate<S: KnowledgeStore + ?Sized>(
    repository: &dyn SessionRepository,
    knowledge: &S,
    user: u64,
    id: &str,
    policy: ModerationPolicy,
    configuration: &str,
    signal: Option<watch::Receiver<bool>>,
) -> Result<Option<Value>, Error> {
    generate_and_search(
        repository,
        knowledge,
        user,
        id,
        policy,
        configuration,
        signal,
        None,
    )
    .await
}
pub async fn generate_and_search<S: KnowledgeStore + ?Sized>(
    repository: &dyn SessionRepository,
    knowledge: &S,
    user: u64,
    id: &str,
    policy: ModerationPolicy,
    configuration: &str,
    signal: Option<watch::Receiver<bool>>,
    search_phrase: Option<&str>,
) -> Result<Option<Value>, Error> {
    if configuration.is_empty() || configuration.len() > 65536 {
        return Err(Error::Configuration);
    }
    let value: Value = serde_json::from_str(configuration).map_err(|_| Error::Configuration)?;
    let selection = ModelRouter::new(&value)
        .and_then(|router| router.select("knowledge", &[]))
        .map_err(|_| Error::Configuration)?;
    let resolver: CredentialResolver = Arc::new(|reference| {
        std::env::var(reference).map_err(|_| TransportError("MISSING_CREDENTIAL"))
    });
    let transport = Transport::new(Some(resolver), None).map_err(|_| Error::Configuration)?;
    generate_with_transport_and_search(
        repository,
        knowledge,
        user,
        id,
        policy,
        selection,
        &transport,
        signal,
        search_phrase,
    )
    .await
}
