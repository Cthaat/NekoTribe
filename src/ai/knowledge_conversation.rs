//! Internal knowledge conversation generation; caller authenticates the user.
use super::{
    conversation_store::{AiOperation, AssistantInput, ModerationPolicy},
    knowledge_service::{self, KnowledgeStore, KnowledgeTransport},
    knowledge_turn::{TurnError, TurnFuture},
    model_config::{ModelRouter, SelectionSnapshot},
    model_quota::{self, AiModelQuota},
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

struct QuotaTransport<'a> {
    transport: Transport,
    quota: Option<&'a AiModelQuota>,
    actor: u64,
}

impl KnowledgeTransport for QuotaTransport<'_> {
    fn infer<'a>(
        &'a self,
        selection: &'a SelectionSnapshot,
        input: &'a Value,
    ) -> TurnFuture<'a, String> {
        Box::pin(async move {
            model_quota::require(self.quota, self.actor, 1)
                .await
                .map_err(TurnError::Quota)?;
            KnowledgeTransport::infer(&self.transport, selection, input).await
        })
    }
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
        repository,
        knowledge,
        user,
        id,
        policy,
        selection,
        transport,
        signal,
        &super::knowledge_search_body::KnowledgeSearchBody::default(),
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
    input: &super::knowledge_search_body::KnowledgeSearchBody,
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
        .filter(|m| m.len() <= 50)
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
    let last = messages.last();
    if input.expected_sequence.is_some_and(|sequence| {
        last.is_none_or(|message| {
            message["sequence_no"].as_i64() != Some(sequence) || message["role"] != "user"
        })
    }) {
        return Err(Error::Store(super::conversation_store::Error::Conflict));
    }
    let last = last.ok_or(Error::Context)?;
    if last["role"] != "user" {
        return Err(Error::Context);
    }
    let query = last["content"].as_str().ok_or(Error::Context)?;
    let skill_generation = store(
        repository,
        user,
        AiOperation::KnowledgeSkill(id.into(), input.skill_id),
        policy.clone(),
    )
    .await?
    .as_i64()
    .filter(|generation| (1..=999_999_999_999_999).contains(generation))
    .ok_or(Error::Configuration)?;
    let mut audit = super::run_audit::AiRunAudit::new("knowledge_answer", skill_generation);
    audit.config_revision = selection.configuration_revision;
    if input.skill_id.is_some() {
        audit.skill_selection = "explicit";
    }
    let result = async {
        cancelled(&signal)?;
        audit.stage = "evidence";
        let (result, context) = knowledge_service::generate_with_history(
            knowledge,
            user as i64,
            query,
            input.phrase.as_deref(),
            selection.clone(),
            transport,
            signal.clone(),
            messages,
        )
        .await
        .map_err(Error::Knowledge)?;
        cancelled(&signal)?;
        let Some(answer) = result.answer else {
            return Ok(None);
        };
        let context = context.ok_or(Error::Context)?;
        audit.stage = "persist";
        let value = store(
            repository,
            user,
            AiOperation::KnowledgeAssistant {
                id: id.into(),
                input: AssistantInput {
                    content: answer,
                    expected_sequence: previous,
                    model_id: selection.profile_id,
                    model_version: selection.model_version,
                    config_revision: selection.configuration_revision as i64,
                },
                sources: result.sources,
                context_snapshot: context.snapshot,
                skill_generation,
                cancel: signal.clone(),
            },
            policy,
        )
        .await?;
        Ok(Some(value))
    }
    .await;
    audit.finish(&result, cancelled(&signal).is_err(), |error| match error {
        Error::Knowledge(TurnError::Quota(quota)) => Some(*quota),
        _ => None,
    });
    result
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
    quota: Option<&AiModelQuota>,
) -> Result<Option<Value>, Error> {
    generate_and_search(
        repository,
        knowledge,
        user,
        id,
        policy,
        configuration,
        signal,
        &super::knowledge_search_body::KnowledgeSearchBody::default(),
        quota,
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
    input: &super::knowledge_search_body::KnowledgeSearchBody,
    quota: Option<&AiModelQuota>,
) -> Result<Option<Value>, Error> {
    if configuration.is_empty() || configuration.len() > 65536 {
        return Err(Error::Configuration);
    }
    let selection = ModelRouter::from_json(configuration)
        .and_then(|router| router.select("knowledge", &[]))
        .map_err(|_| Error::Configuration)?;
    let resolver: CredentialResolver = Arc::new(|reference| {
        std::env::var(reference).map_err(|_| TransportError("MISSING_CREDENTIAL"))
    });
    let transport = QuotaTransport {
        transport: Transport::new(Some(resolver), None).map_err(|_| Error::Configuration)?,
        quota,
        actor: user,
    };
    generate_with_transport_and_search(
        repository, knowledge, user, id, policy, selection, &transport, signal, input,
    )
    .await
}
