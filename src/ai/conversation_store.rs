//! Internal conversation persistence. Callers must authenticate the actor first.
use crate::{
    auth::{
        login::js_trim,
        readiness,
        session_repository::{nullable_text, profile_date, row_number, row_text},
    },
    db::{
        oracle::{bind_refs, bind_values, BindMap},
        row::oracle_row_to_db_row,
        tx::OracleTx,
        value::DbValue,
    },
};
use std::collections::HashSet;

use super::moderation_feedback as feedback;

const MAX_SAFE_ID: i64 = 9_007_199_254_740_991;
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    Invalid,
    NotFound,
    Forbidden,
    Conflict,
    SchemaUnavailable,
    Store,
}
#[derive(Debug, Clone)]
pub struct Input {
    pub purpose: String,
    pub group_id: Option<i64>,
    pub title: String,
}
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct Record {
    #[serde(rename = "conversation_id")]
    pub id: String,
    pub purpose: String,
    pub group_id: Option<i64>,
    pub title: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct ConversationPage {
    pub items: Vec<Record>,
    pub next_cursor: Option<String>,
}
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct UserMessage {
    pub message_id: String,
    pub conversation_id: String,
    pub sequence_no: i64,
    pub role: &'static str,
}
#[derive(Clone)]
pub struct AssistantInput {
    pub content: String,
    pub expected_sequence: i64,
    pub model_id: String,
    pub model_version: Option<String>,
    pub config_revision: i64,
}
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct HistoryMessage {
    pub message_id: String,
    pub conversation_id: String,
    pub sequence_no: i64,
    pub role: String,
    pub content: String,
    pub model_id: Option<String>,
    pub model_version: Option<String>,
    pub config_revision: Option<i64>,
    pub created_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub citations: Option<Vec<super::knowledge_history::Citation>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub group_sources: Option<Vec<super::group_draft::GroupSource>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub group_tools: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub moderation_advice: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub moderation_feedback: Option<String>,
}
#[derive(Clone)]
pub struct ModerationPolicy {
    allow_all: bool,
    accounts: HashSet<String>,
}
#[derive(Clone)]
pub enum AiOperation {
    Availability,
    Create(Input),
    Read(String),
    Delete(String),
    ListOwned {
        after: String,
        limit: i64,
        purpose: String,
        group_id: Option<i64>,
        target_title: String,
    },
    Append {
        id: String,
        content: String,
    },
    List {
        id: String,
        after: i64,
        before: i64,
        limit: i64,
    },
    Recent(String),
    KnowledgeSkill(String, Option<&'static str>),
    WritingSkill(String, Option<&'static str>),
    GroupDraftLoad {
        id: String,
        request: super::group_draft::Request,
    },
    GroupDraftSave {
        id: String,
        input: AssistantInput,
        draft: super::group_draft::DraftRecord,
        cancel: Option<tokio::sync::watch::Receiver<bool>>,
    },
    ModerationAdviceLoad {
        id: String,
        request: super::moderation_advice::Request,
    },
    ModerationAdviceSave {
        id: String,
        input: AssistantInput,
        record: super::moderation_advice::AdviceRecord,
        cancel: Option<tokio::sync::watch::Receiver<bool>>,
    },
    ModerationFeedbackSave {
        id: String,
        message_id: String,
        rating: String,
    },
    Assistant {
        id: String,
        input: AssistantInput,
        skill_generation: i64,
        cancel: Option<tokio::sync::watch::Receiver<bool>>,
    },
    KnowledgeAssistant {
        id: String,
        input: AssistantInput,
        sources: Vec<super::knowledge_source::Candidate>,
        context_snapshot: Vec<serde_json::Value>,
        skill_generation: i64,
        cancel: Option<tokio::sync::watch::Receiver<bool>>,
    },
}
pub fn execute_operation(
    connection: &oracle::Connection,
    user: u64,
    operation: AiOperation,
    policy: &ModerationPolicy,
) -> Result<serde_json::Value, Error> {
    let user = i64::try_from(user).map_err(|_| Error::Invalid)?;
    match operation {
        AiOperation::Availability => {
            let config = super::skill_config_store::load_from_oracle(connection, user)
                .map_err(|_| Error::SchemaUnavailable)?;
            serde_json::to_value(config.registry.user_availability())
        }
        AiOperation::Create(input) => {
            serde_json::to_value(create(connection, user, input, policy)?)
        }
        AiOperation::Read(id) => serde_json::to_value(read(connection, user, &id, policy)?),
        AiOperation::ListOwned {
            after,
            limit,
            purpose,
            group_id,
            target_title,
        } => serde_json::to_value(list_conversations(
            connection,
            user,
            &after,
            limit,
            &purpose,
            group_id,
            &target_title,
            policy,
        )?),
        AiOperation::Delete(id) => {
            delete(connection, user, &id, policy)?;
            Ok(serde_json::Value::Null)
        }
        AiOperation::Append { id, content } => serde_json::to_value(append_user_message(
            connection, user, &id, &content, policy,
        )?),
        AiOperation::List {
            id,
            after,
            before,
            limit,
        } => serde_json::to_value(list_messages(
            connection, user, &id, after, before, limit, policy,
        )?),
        AiOperation::Recent(id) => {
            serde_json::to_value(recent_messages(connection, user, &id, policy)?)
        }
        AiOperation::KnowledgeSkill(id, skill_id) => {
            let selection =
                select_configured_conversation_skill(connection, user, &id, skill_id, policy)
                    .map_err(|_| Error::SchemaUnavailable)?;
            serde_json::to_value(selection.generation)
        }
        AiOperation::WritingSkill(id, skill_id) => {
            let selection =
                select_configured_conversation_skill(connection, user, &id, skill_id, policy)
                    .map_err(|_| Error::SchemaUnavailable)?;
            serde_json::to_value(selection.generation)
        }
        AiOperation::GroupDraftLoad { id, request } => {
            let tx = OracleConversation(connection);
            let loaded = (|| {
                let record = read(connection, user, &id, policy)?;
                let group = record
                    .group_id
                    .filter(|_| record.purpose == "group")
                    .ok_or(Error::Invalid)?;
                let evidence = super::group_draft::read_evidence(
                    connection,
                    user,
                    group,
                    super::group_evidence::EvidenceQuery {
                        lookback_days: request.lookback()?,
                        window_end: None,
                        search_term: request.search_term.as_deref(),
                        match_excerpt: request.search_term.is_some(),
                    },
                )?;
                if tx.next_sequence(&id)? != request.expected_sequence + 1 {
                    return Err(Error::Conflict);
                }
                let selected = select_configured_conversation_skill(
                    connection,
                    user,
                    &id,
                    request.explicit_skill.then_some("group-brief"),
                    policy,
                )
                .map_err(|_| Error::SchemaUnavailable)?;
                if !super::group_draft::tool_grants_match(&selected.skill.tools) {
                    return Err(Error::SchemaUnavailable);
                }
                Ok(super::group_draft::Loaded {
                    evidence,
                    generation: selected.generation,
                })
            })();
            tx.rollback()?;
            serde_json::to_value(loaded?)
        }
        AiOperation::GroupDraftSave {
            id,
            input,
            draft,
            cancel,
        } => {
            validate_assistant_from(&input, 0)?;
            let content = serde_json::to_string(&draft).map_err(|_| Error::Invalid)?;
            if super::group_draft::decode_record(&content).is_none() {
                return Err(Error::Invalid);
            }
            serde_json::to_value(run_append_inner(
                &OracleConversation(connection),
                user,
                &id,
                &content,
                Some(&input),
                false,
                None,
                Some(draft.skill_generation),
                Some(EvidenceGuard::Group(&draft, cancel.as_ref())),
                policy,
            )?)
        }
        AiOperation::ModerationAdviceLoad { id, request } => {
            let tx = OracleConversation(connection);
            let loaded = (|| {
                let record = read(connection, user, &id, policy)?;
                if record.purpose != "moderation" {
                    return Err(Error::Invalid);
                }
                if tx.next_sequence(&id)? != request.sequence + 1 {
                    return Err(Error::Conflict);
                }
                let selected = select_configured_conversation_skill(
                    connection,
                    user,
                    &id,
                    request.skill_id,
                    policy,
                )
                .map_err(|_| Error::SchemaUnavailable)?;
                let material =
                    super::moderation_advice::read_material(connection, user, &request, false)?;
                Ok(super::moderation_advice::Loaded {
                    material,
                    generation: selected.generation,
                })
            })();
            tx.rollback()?;
            serde_json::to_value(loaded?)
        }
        AiOperation::ModerationAdviceSave {
            id,
            input,
            record,
            cancel,
        } => {
            validate_assistant_from(&input, 0)?;
            let content = serde_json::to_string(&record).map_err(|_| Error::Invalid)?;
            if super::moderation_advice::decode_record(&content).is_none() {
                return Err(Error::Invalid);
            }
            serde_json::to_value(run_append_inner(
                &OracleConversation(connection),
                user,
                &id,
                &content,
                Some(&input),
                false,
                None,
                Some(record.skill_generation),
                Some(EvidenceGuard::Moderation(&record, cancel.as_ref())),
                policy,
            )?)
        }
        AiOperation::ModerationFeedbackSave {
            id,
            message_id,
            rating,
        } => {
            save_moderation_feedback(connection, user, &id, &message_id, &rating, policy)?;
            Ok(serde_json::json!({"message_id": message_id, "rating": rating}))
        }
        AiOperation::Assistant {
            id,
            input,
            skill_generation,
            cancel,
        } => serde_json::to_value(append_assistant_message(
            connection,
            user,
            &id,
            &input,
            skill_generation,
            cancel.as_ref(),
            policy,
        )?),
        AiOperation::KnowledgeAssistant {
            id,
            input,
            sources,
            context_snapshot,
            skill_generation,
            cancel,
        } => serde_json::to_value(append_knowledge_assistant_message(
            connection,
            user,
            &id,
            &input,
            &sources,
            &context_snapshot,
            skill_generation,
            cancel.as_ref(),
            policy,
        )?),
    }
    .map_err(|_| Error::Store)
}
impl ModerationPolicy {
    pub fn new(allow_all: &str, accounts: &str) -> Self {
        let allow_all = matches!(
            js_trim(allow_all).to_lowercase().as_str(),
            "1" | "true" | "yes" | "on"
        );
        let accounts: HashSet<_> = accounts
            .split(',')
            .map(|s| js_trim(s).to_lowercase())
            .filter(|s| !s.is_empty())
            .collect();
        Self {
            allow_all,
            accounts,
        }
    }

    pub(crate) fn allows(
        &self,
        connection: &oracle::Connection,
        actor: i64,
    ) -> Result<bool, oracle::Error> {
        if self.allow_all {
            return Ok(true);
        }
        if self.accounts.is_empty() {
            return Ok(false);
        }
        let mut rows = connection.query_named(
            "SELECT username,email FROM n_users WHERE user_id=:user_id AND is_active=1 AND status='active'",
            &[("user_id", &actor)],
        )?;
        let Some(row) = rows.next().transpose()? else {
            return Ok(false);
        };
        let username: Option<String> = row.get(0)?;
        let email: Option<String> = row.get(1)?;
        Ok(username
            .into_iter()
            .chain(email)
            .any(|value| self.accounts.contains(&value.to_lowercase())))
    }
}
pub(crate) fn validate(mut input: Input) -> Result<Input, Error> {
    match (input.purpose.as_str(), input.group_id) {
        ("group", Some(id)) if (1..=MAX_SAFE_ID).contains(&id) => {}
        ("knowledge" | "writing" | "moderation", None) => {}
        _ => return Err(Error::Invalid),
    }
    input.title = js_trim(&input.title).to_owned();
    if input.title.encode_utf16().count() > 200 {
        return Err(Error::Invalid);
    }
    Ok(input)
}
pub(crate) fn valid_uuid(id: &str) -> bool {
    id.len() == 36
        && uuid::Uuid::parse_str(id).is_ok_and(|u| {
            u.get_version_num() == 4
                && u.get_variant() == uuid::Variant::RFC4122
                && u.hyphenated().to_string().eq_ignore_ascii_case(id)
        })
}
trait Transaction {
    fn check_schema(&self) -> Result<(), Error>;
    fn authorize(&self, user: i64, input: &Input, policy: &ModerationPolicy) -> Result<(), Error>;
    fn insert(&self, user: i64, id: &str, input: &Input) -> Result<(), Error>;
    fn read(&self, user: i64, id: &str) -> Result<Option<Record>, Error>;
    fn commit(&self) -> Result<(), Error>;
    fn rollback(&self) -> Result<(), Error>;
    fn restore_knowledge(
        &self,
        _user: i64,
        _content: &str,
    ) -> Result<Option<super::knowledge_history::Restored>, Error> {
        Err(Error::Store)
    }
    fn restore_knowledge_for_write(
        &self,
        user: i64,
        content: &str,
    ) -> Result<super::knowledge_history::Restored, Error> {
        self.restore_knowledge(user, content)?.ok_or(Error::Store)
    }
}
fn run_select_conversation_skill(
    tx: &impl Transaction,
    registry: &super::skill_selection::Registry,
    user: i64,
    id: &str,
    skill_id: Option<&str>,
    policy: &ModerationPolicy,
) -> Result<super::skill_selection::Selection, super::skill_selection::Error> {
    use super::skill_selection::{Error as SkillError, Scope};
    if !(1..=MAX_SAFE_ID).contains(&user) || !valid_uuid(id) {
        return Err(SkillError::Unavailable);
    }
    tx.check_schema().map_err(|_| SkillError::Unavailable)?;
    let record = tx
        .read(user, id)
        .map_err(|_| SkillError::Unavailable)?
        .ok_or(SkillError::Unavailable)?;
    let input = validate(Input {
        purpose: record.purpose,
        group_id: record.group_id,
        title: String::new(),
    })
    .map_err(|_| SkillError::Unavailable)?;
    let scope = Scope {
        actor_id: user,
        purpose: input.purpose.clone(),
        group_id: input.group_id,
    };
    registry.select(&scope, skill_id, |_| {
        tx.authorize(user, &input, policy)
            .map_err(|_| SkillError::Unavailable)
    })
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfiguredSkillSelection {
    pub generation: i64,
    pub skill: super::skill_selection::Selection,
}
fn run_select_configured_skill(
    tx: &impl Transaction,
    reader: &impl super::skill_config_store::Reader,
    user: i64,
    id: &str,
    skill_id: Option<&str>,
    policy: &ModerationPolicy,
) -> Result<ConfiguredSkillSelection, super::skill_selection::Error> {
    let config = super::skill_config_store::load(reader, user)
        .map_err(|_| super::skill_selection::Error::Unavailable)?;
    let skill = run_select_conversation_skill(tx, &config.registry, user, id, skill_id, policy)?;
    Ok(ConfiguredSkillSelection {
        generation: config.generation,
        skill,
    })
}
trait ListingTransaction: Transaction {
    fn candidates(
        &self,
        user: i64,
        after: &str,
        limit: i64,
        moderation_allowed: bool,
        purpose: &str,
        group_id: Option<i64>,
        target_title: &str,
    ) -> Result<Vec<Record>, Error>;
}
pub(crate) fn valid_list_purpose(purpose: &str) -> bool {
    matches!(
        purpose,
        "" | "knowledge" | "writing" | "group" | "moderation"
    )
}
fn run_conversation_listing(
    tx: &impl ListingTransaction,
    user: i64,
    after: &str,
    limit: i64,
    purpose: &str,
    group_id: Option<i64>,
    target_title: &str,
    policy: &ModerationPolicy,
) -> Result<ConversationPage, Error> {
    if !(1..=MAX_SAFE_ID).contains(&user)
        || (!after.is_empty() && !valid_uuid(after))
        || !(1..=50).contains(&limit)
        || !valid_list_purpose(purpose)
        || group_id.is_some_and(|id| purpose != "group" || !(1..=MAX_SAFE_ID).contains(&id))
        || (!target_title.is_empty() && purpose != "moderation")
    {
        return Err(Error::Invalid);
    }
    tx.check_schema()?;
    let result = (|| {
        let moderation = Input {
            purpose: "moderation".into(),
            group_id: None,
            title: String::new(),
        };
        let moderation_allowed = match tx.authorize(user, &moderation, policy) {
            Ok(()) => true,
            Err(Error::Forbidden) => false,
            Err(error) => return Err(error),
        };
        let mut page = ConversationPage {
            items: Vec::new(),
            next_cursor: None,
        };
        let mut scan_after = after.to_ascii_lowercase();
        for _ in 0..10 {
            let rows = tx.candidates(
                user,
                &scan_after,
                limit + 1,
                moderation_allowed,
                purpose,
                group_id,
                target_title,
            )?;
            let count = rows.len();
            for record in rows {
                if !valid_uuid(&record.id)
                    || record.id <= scan_after
                    || (!purpose.is_empty() && record.purpose != purpose)
                    || (group_id.is_some() && record.group_id != group_id)
                    || (!target_title.is_empty()
                        && (record.title.as_deref() != Some(target_title)
                            || record.group_id.is_some()))
                {
                    return Err(Error::Store);
                }
                scan_after = record.id.clone();
                let scope = validate(Input {
                    purpose: record.purpose.clone(),
                    group_id: record.group_id,
                    title: String::new(),
                })
                .map_err(|_| Error::Store)?;
                match tx.authorize(user, &scope, policy) {
                    Ok(()) => (),
                    Err(Error::Forbidden) => continue,
                    Err(error) => return Err(error),
                }
                if page.items.len() == limit as usize {
                    page.next_cursor = page.items.last().map(|item| item.id.clone());
                    return Ok(page);
                }
                page.items.push(record);
            }
            if count < (limit + 1) as usize {
                return Ok(page);
            }
            if !page.items.is_empty() {
                page.next_cursor = page.items.last().map(|item| item.id.clone());
                return Ok(page);
            }
        }
        Err(Error::Store)
    })();
    match result {
        Ok(page) => {
            tx.commit()?;
            Ok(page)
        }
        Err(error) => {
            tx.rollback()?;
            Err(error)
        }
    }
}
fn verify_locked_knowledge_skill(
    tx: &impl Transaction,
    user: i64,
    scope: &Input,
    generation: i64,
    policy: &ModerationPolicy,
    config: super::skill_config_store::Config,
) -> Result<(), Error> {
    if config.generation != generation {
        return Err(Error::Conflict);
    }
    let selected = super::skill_selection::Scope {
        actor_id: user,
        purpose: scope.purpose.clone(),
        group_id: scope.group_id,
    };
    let skill = match scope.purpose.as_str() {
        "knowledge" => "knowledge-answer",
        "writing" => "writing-draft",
        "group" => "group-brief",
        "moderation" => "moderation-advice",
        _ => return Err(Error::SchemaUnavailable),
    };
    config
        .registry
        .select(&selected, Some(skill), |_| {
            tx.authorize(user, scope, policy)
                .map_err(|_| super::skill_selection::Error::Unavailable)
        })
        .map_err(|_| Error::SchemaUnavailable)?;
    Ok(())
}
trait MessageTransaction: HistoryTransaction {
    fn guard_moderation_advice(
        &self,
        _actor: i64,
        _record: &super::moderation_advice::AdviceRecord,
        _lock: bool,
    ) -> Result<(), Error> {
        Err(Error::SchemaUnavailable)
    }
    fn guard_group_draft(
        &self,
        _actor: i64,
        _group: i64,
        _draft: &super::group_draft::DraftRecord,
        _lock: bool,
    ) -> Result<(), Error> {
        Err(Error::SchemaUnavailable)
    }
    fn guard_knowledge_skill(
        &self,
        _user: i64,
        _scope: &Input,
        _generation: i64,
        _policy: &ModerationPolicy,
    ) -> Result<(), Error> {
        Err(Error::SchemaUnavailable)
    }
    fn read_locked(&self, user: i64, id: &str) -> Result<Option<Record>, Error>;
    fn delete(&self, user: i64, id: &str) -> Result<(), Error>;
    fn next_sequence(&self, id: &str) -> Result<i64, Error>;
    fn insert_message(
        &self,
        id: &str,
        message_id: &str,
        sequence: i64,
        content: &str,
        assistant: Option<&AssistantInput>,
    ) -> Result<(), Error>;
    fn touch(&self, user: i64, id: &str) -> Result<(), Error>;
}
fn run_delete(
    tx: &impl MessageTransaction,
    user: i64,
    id: &str,
    policy: &ModerationPolicy,
) -> Result<(), Error> {
    if !(1..=MAX_SAFE_ID).contains(&user) {
        return Err(Error::Invalid);
    }
    if !valid_uuid(id) {
        return Err(Error::NotFound);
    }
    tx.check_schema()?;
    let result = (|| {
        let record = tx.read_locked(user, id)?.ok_or(Error::NotFound)?;
        let scope = validate(Input {
            purpose: record.purpose,
            group_id: record.group_id,
            title: String::new(),
        })
        .map_err(|_| Error::Store)?;
        tx.authorize(user, &scope, policy)?;
        tx.delete(user, id)?;
        tx.authorize(user, &scope, policy)
    })();
    match result {
        Ok(()) => tx.commit(),
        Err(error) => {
            tx.rollback()?;
            Err(error)
        }
    }
}
trait HistoryTransaction: Transaction {
    fn feedback_table_present(&self) -> Result<bool, Error> {
        Ok(false)
    }
    fn read_moderation_rating(&self, _id: &str) -> Result<Option<String>, Error> {
        Ok(None)
    }
    fn restore_moderation_advice(
        &self,
        _actor: i64,
        _record: &super::moderation_advice::AdviceRecord,
    ) -> Result<serde_json::Value, Error> {
        Ok(serde_json::Value::Null)
    }
    fn restore_group_draft(
        &self,
        _actor: i64,
        _group: i64,
        _draft: &super::group_draft::DraftRecord,
    ) -> Result<Option<Vec<super::group_draft::GroupSource>>, Error> {
        Ok(None)
    }
    fn messages(
        &self,
        user: i64,
        id: &str,
        after: i64,
        before: i64,
        limit: i64,
        newest: bool,
    ) -> Result<Vec<HistoryMessage>, Error>;
}
#[cfg(test)]
fn run_history(
    tx: &impl HistoryTransaction,
    user: i64,
    id: &str,
    after: i64,
    limit: i64,
    policy: &ModerationPolicy,
) -> Result<Vec<HistoryMessage>, Error> {
    run_history_ordered(tx, user, id, after, 0, limit, false, policy)
}
fn run_recent_history(
    tx: &impl HistoryTransaction,
    user: i64,
    id: &str,
    policy: &ModerationPolicy,
) -> Result<Vec<HistoryMessage>, Error> {
    run_history_ordered(tx, user, id, 0, 0, 50, true, policy)
}
fn run_history_ordered(
    tx: &impl HistoryTransaction,
    user: i64,
    id: &str,
    after: i64,
    before: i64,
    limit: i64,
    newest: bool,
    policy: &ModerationPolicy,
) -> Result<Vec<HistoryMessage>, Error> {
    if !(1..=MAX_SAFE_ID).contains(&user)
        || !(0..=9_999_999_999).contains(&after)
        || !(0..=10_000_000_000).contains(&before)
        || (before > 0 && (after > 0 || newest))
        || !(1..=50).contains(&limit)
    {
        return Err(Error::Invalid);
    }
    if !valid_uuid(id) {
        return Err(Error::NotFound);
    }
    tx.check_schema()?;
    let check_access = || {
        let record = tx.read(user, id)?.ok_or(Error::NotFound)?;
        let scope = validate(Input {
            purpose: record.purpose,
            group_id: record.group_id,
            title: String::new(),
        })
        .map_err(|_| Error::Store)?;
        tx.authorize(user, &scope, policy)?;
        Ok((scope.purpose, scope.group_id))
    };
    let result = (|| {
        let (purpose, group) = check_access()?;
        let mut messages = tx.messages(user, id, after, before, limit, newest)?;
        if purpose == "knowledge" {
            let mut usable = messages.len();
            for (index, message) in messages.iter_mut().enumerate() {
                if message.role == "tool" {
                    return Err(Error::Store);
                }
                if message.role == "assistant" {
                    match tx.restore_knowledge(user, &message.content)? {
                        Some(restored) => {
                            message.content = restored.answer.ok_or(Error::Store)?;
                            message.citations = Some(restored.citations);
                        }
                        None if newest => {
                            // Rows are newest first. Keep only the contiguous newer suffix.
                            usable = index;
                            break;
                        }
                        None => message.content = "公开资料已变更，历史回答不可用。".into(),
                    }
                }
            }
            messages.truncate(usable);
        }
        if let Some(group) = group.filter(|_| purpose == "group") {
            for message in &mut messages {
                if message.role != "assistant" {
                    continue;
                }
                let draft = super::group_draft::decode_record(&message.content);
                let sources = if let Some(ref draft) = draft {
                    tx.restore_group_draft(user, group, draft)?
                } else {
                    None
                };
                message.content = match (&sources, draft) {
                    (Some(_), Some(draft)) => {
                        message.group_tools = draft.tools_used;
                        draft.draft
                    }
                    _ => "资料已变更，历史草稿不可用。".into(),
                };
                message.group_sources = Some(sources.unwrap_or_default());
            }
        }
        if purpose == "moderation" {
            let mut has_feedback = None;
            for message in &mut messages {
                if message.role != "assistant" {
                    continue;
                }
                let advice = match super::moderation_advice::decode_record(&message.content) {
                    Some(record) => tx.restore_moderation_advice(user, &record)?,
                    None => serde_json::Value::Null,
                };
                message.content = advice["reason"]
                    .as_str()
                    .unwrap_or("公开资料已变更，历史审核建议不可用。")
                    .into();
                if !advice.is_null() {
                    let present = match has_feedback {
                        Some(value) => value,
                        None => {
                            let value = tx.feedback_table_present()?;
                            has_feedback = Some(value);
                            value
                        }
                    };
                    if present {
                        message.moderation_feedback =
                            tx.read_moderation_rating(&message.message_id)?;
                    }
                }
                message.moderation_advice = Some(advice);
            }
        }
        if newest {
            messages.reverse();
        }
        if check_access()? != (purpose, group) {
            return Err(Error::Store);
        }
        Ok(messages)
    })();
    match result {
        Ok(messages) => {
            tx.commit()?;
            Ok(messages)
        }
        Err(error) => {
            tx.rollback()?;
            Err(error)
        }
    }
}
fn run_append(
    tx: &impl MessageTransaction,
    user: i64,
    id: &str,
    content: &str,
    policy: &ModerationPolicy,
) -> Result<UserMessage, Error> {
    run_append_inner(tx, user, id, content, None, false, None, None, None, policy)
}
fn run_append_assistant(
    tx: &impl MessageTransaction,
    user: i64,
    id: &str,
    input: &AssistantInput,
    skill_generation: i64,
    cancel: Cancellation<'_>,
    policy: &ModerationPolicy,
) -> Result<UserMessage, Error> {
    validate_assistant(input)?;
    if !(1..=999_999_999_999_999).contains(&skill_generation) {
        return Err(Error::Invalid);
    }
    run_append_inner(
        tx,
        user,
        id,
        &input.content,
        Some(input),
        false,
        None,
        Some(skill_generation),
        Some(EvidenceGuard::Generation(cancel)),
        policy,
    )
}
fn validate_assistant(input: &AssistantInput) -> Result<(), Error> {
    validate_assistant_from(input, 1)
}
fn validate_assistant_from(input: &AssistantInput, first_sequence: i64) -> Result<(), Error> {
    let id_ok = !input.model_id.is_empty()
        && input.model_id.len() <= 64
        && input.model_id.as_bytes()[0].is_ascii_alphanumeric()
        && input
            .model_id
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_' | b'-'));
    if !(first_sequence..9_999_999_999).contains(&input.expected_sequence)
        || !(1..=999_999_999_999_999).contains(&input.config_revision)
        || !id_ok
        || input
            .model_version
            .as_deref()
            .is_some_and(|version| !super::model_config::valid_model_version(version))
    {
        return Err(Error::Invalid);
    }
    Ok(())
}
#[cfg(test)]
fn run_append_knowledge(
    tx: &impl MessageTransaction,
    user: i64,
    id: &str,
    input: &AssistantInput,
    sources: &[super::knowledge_source::Candidate],
    policy: &ModerationPolicy,
) -> Result<UserMessage, Error> {
    run_append_knowledge_guarded(tx, user, id, input, sources, None, 1, None, policy)
}
fn run_append_knowledge_guarded(
    tx: &impl MessageTransaction,
    user: i64,
    id: &str,
    input: &AssistantInput,
    sources: &[super::knowledge_source::Candidate],
    snapshot: Option<&[serde_json::Value]>,
    skill_generation: i64,
    cancel: Cancellation<'_>,
    policy: &ModerationPolicy,
) -> Result<UserMessage, Error> {
    validate_assistant(input)?;
    if !(1..=999_999_999_999_999).contains(&skill_generation) {
        return Err(Error::Invalid);
    }
    if let Some(snapshot) = snapshot {
        let selected = super::knowledge_context::select(snapshot, 4_000_000, 20)
            .map_err(|_| Error::Invalid)?;
        if selected.snapshot.len() != snapshot.len()
            || selected
                .snapshot
                .last()
                .and_then(|m| m["sequence_no"].as_i64())
                != Some(input.expected_sequence)
            || selected.sources.iter().any(|s| !sources.contains(s))
        {
            return Err(Error::Invalid);
        }
    }
    let encoded =
        super::knowledge_history::encode(&input.content, sources).map_err(|_| Error::Invalid)?;
    run_append_inner(
        tx,
        user,
        id,
        &encoded,
        Some(input),
        true,
        snapshot,
        Some(skill_generation),
        Some(EvidenceGuard::Generation(cancel)),
        policy,
    )
}
fn check_context_snapshot(
    tx: &impl MessageTransaction,
    user: i64,
    id: &str,
    snapshot: &[serde_json::Value],
) -> Result<(), Error> {
    let first = snapshot
        .first()
        .and_then(|m| m["sequence_no"].as_i64())
        .ok_or(Error::Invalid)?;
    let mut messages = tx.messages(user, id, first - 1, 0, snapshot.len() as i64, false)?;
    if messages.len() != snapshot.len() {
        return Err(Error::Conflict);
    }
    for msg in &mut messages {
        if msg.role == "assistant" {
            let restored = tx
                .restore_knowledge(user, &msg.content)?
                .ok_or(Error::Conflict)?;
            msg.content = restored.answer.ok_or(Error::Store)?;
            msg.citations = Some(restored.citations);
        }
    }
    let values: Vec<_> = messages
        .iter()
        .map(serde_json::to_value)
        .collect::<Result<_, _>>()
        .map_err(|_| Error::Store)?;
    let current =
        super::knowledge_context::select(&values, 4_000_000, 20).map_err(|_| Error::Conflict)?;
    if current.snapshot != snapshot {
        return Err(Error::Conflict);
    }
    Ok(())
}
type Cancellation<'a> = Option<&'a tokio::sync::watch::Receiver<bool>>;
#[derive(Clone, Copy)]
enum EvidenceGuard<'a> {
    Generation(Cancellation<'a>),
    Group(&'a super::group_draft::DraftRecord, Cancellation<'a>),
    Moderation(&'a super::moderation_advice::AdviceRecord, Cancellation<'a>),
}
fn run_append_inner(
    tx: &impl MessageTransaction,
    user: i64,
    id: &str,
    content: &str,
    assistant: Option<&AssistantInput>,
    knowledge: bool,
    snapshot: Option<&[serde_json::Value]>,
    skill_generation: Option<i64>,
    evidence: Option<EvidenceGuard<'_>>,
    policy: &ModerationPolicy,
) -> Result<UserMessage, Error> {
    if !(1..=MAX_SAFE_ID).contains(&user) {
        return Err(Error::Invalid);
    }
    if !valid_uuid(id) {
        return Err(Error::NotFound);
    }
    if content.is_empty() || content.len() > 65536 {
        return Err(Error::Invalid);
    }
    tx.check_schema()?;
    let result = (|| {
        let record = tx.read_locked(user, id)?.ok_or(Error::NotFound)?;
        let scope = validate(Input {
            purpose: record.purpose,
            group_id: record.group_id,
            title: String::new(),
        })
        .map_err(|_| Error::Store)?;
        tx.authorize(user, &scope, policy)?;
        if assistant.is_some() && ((scope.purpose == "knowledge") != knowledge) {
            return Err(Error::Conflict);
        }
        if assistant.is_some() {
            if (scope.purpose == "group") != matches!(evidence, Some(EvidenceGuard::Group(..)))
                || (scope.purpose == "moderation")
                    != matches!(evidence, Some(EvidenceGuard::Moderation(..)))
            {
                return Err(Error::Conflict);
            }
        }
        if let Some(EvidenceGuard::Group(draft, _)) = evidence {
            tx.guard_group_draft(user, scope.group_id.ok_or(Error::Conflict)?, draft, true)?;
        }
        if knowledge || (assistant.is_some() && scope.purpose == "writing") || evidence.is_some() {
            tx.guard_knowledge_skill(
                user,
                &scope,
                skill_generation.ok_or(Error::Invalid)?,
                policy,
            )?;
        }
        if let Some(EvidenceGuard::Moderation(record, _)) = evidence {
            tx.guard_moderation_advice(user, record, true)?;
        }
        if knowledge {
            tx.restore_knowledge_for_write(user, content)?;
        }
        let sequence = tx.next_sequence(id)?;
        if !(1..=9_999_999_999).contains(&sequence) {
            return Err(Error::Store);
        }
        if assistant.is_some_and(|input| sequence != input.expected_sequence + 1) {
            return Err(Error::Conflict);
        }
        if let Some(snapshot) = snapshot {
            check_context_snapshot(tx, user, id, snapshot)?;
        }
        let message_id = uuid::Uuid::new_v4().to_string();
        tx.insert_message(id, &message_id, sequence, content, assistant)?;
        tx.touch(user, id)?;
        tx.authorize(user, &scope, policy)?;
        if knowledge {
            tx.restore_knowledge_for_write(user, content)?;
        }
        if let Some(snapshot) = snapshot {
            check_context_snapshot(tx, user, id, snapshot)?;
        }
        if let Some(evidence) = evidence {
            let cancel = match evidence {
                EvidenceGuard::Generation(cancel) => cancel,
                EvidenceGuard::Group(draft, cancel) => {
                    tx.guard_group_draft(
                        user,
                        scope.group_id.ok_or(Error::Conflict)?,
                        draft,
                        false,
                    )?;
                    cancel
                }
                EvidenceGuard::Moderation(record, cancel) => {
                    tx.guard_moderation_advice(user, record, false)?;
                    cancel
                }
            };
            if cancel.is_some_and(|signal| *signal.borrow()) {
                return Err(Error::SchemaUnavailable);
            }
        }
        Ok(UserMessage {
            message_id,
            conversation_id: id.to_owned(),
            sequence_no: sequence,
            role: if assistant.is_some() {
                "assistant"
            } else {
                "user"
            },
        })
    })();
    match result {
        Ok(message) => {
            tx.commit()?;
            Ok(message)
        }
        Err(error) => {
            tx.rollback()?;
            Err(error)
        }
    }
}
fn run(
    tx: &impl Transaction,
    user: i64,
    id: &str,
    input: Option<Input>,
    policy: &ModerationPolicy,
) -> Result<Record, Error> {
    if !(1..=MAX_SAFE_ID).contains(&user) {
        return Err(Error::Invalid);
    }
    if !valid_uuid(id) {
        return Err(Error::NotFound);
    }
    let input = input.map(validate).transpose()?;
    tx.check_schema()?;
    let result = (|| {
        if let Some(ref input) = input {
            tx.authorize(user, input, policy)?;
            tx.insert(user, id, input)?;
        }
        let record = tx.read(user, id)?.ok_or(Error::NotFound)?;
        let scope = validate(Input {
            purpose: record.purpose.clone(),
            group_id: record.group_id,
            title: String::new(),
        })
        .map_err(|_| Error::Store)?;
        tx.authorize(user, &scope, policy)?;
        Ok(record)
    })();
    match result {
        Ok(record) => {
            tx.commit()?;
            Ok(record)
        }
        Err(error) => {
            tx.rollback()?;
            Err(error)
        }
    }
}

struct OracleConversation<'a>(&'a oracle::Connection);

fn save_moderation_feedback(
    connection: &oracle::Connection,
    actor: i64,
    id: &str,
    message_id: &str,
    rating: &str,
    policy: &ModerationPolicy,
) -> Result<(), Error> {
    if !valid_uuid(id) || !valid_uuid(message_id) {
        return Err(Error::NotFound);
    }
    if !feedback::valid_rating(rating) {
        return Err(Error::Invalid);
    }
    let tx = OracleConversation(connection);
    tx.check_schema()?;
    let sql = feedback::queries();
    let result = (|| {
        let locked = feedback::optional_text(
            connection,
            &sql.lock,
            &[("conversation_id", &id), ("owner_user_id", &actor)],
        )?;
        if locked.as_deref() != Some(id) {
            return Err(Error::NotFound);
        }
        let scope = Input {
            purpose: "moderation".into(),
            group_id: None,
            title: String::new(),
        };
        tx.authorize(actor, &scope, policy)?;
        let content = feedback::optional_text(
            connection,
            &sql.message,
            &[("conversation_id", &id), ("message_id", &message_id)],
        )?
        .ok_or(Error::NotFound)?;
        let record = super::moderation_advice::decode_record(&content).ok_or(Error::Conflict)?;
        super::moderation_advice::current_advice(connection, actor, &record, true)?;
        if !feedback::table_present(connection)? {
            return Err(Error::SchemaUnavailable);
        }
        let affected = OracleTx::new(connection)
            .execute(
                &sql.save,
                BindMap::from([
                    ("message_id".into(), DbValue::String(message_id.into())),
                    ("rating".into(), DbValue::String(rating.into())),
                ]),
            )
            .map_err(|_| Error::SchemaUnavailable)?
            .rows_affected;
        if affected > 1 {
            return Err(Error::SchemaUnavailable);
        }
        tx.authorize(actor, &scope, policy)?;
        super::moderation_advice::current_advice(connection, actor, &record, false)?;
        Ok(())
    })();
    match result {
        Ok(()) => tx.commit().map_err(|_| Error::SchemaUnavailable),
        Err(error) => {
            tx.rollback().map_err(|_| Error::SchemaUnavailable)?;
            if error == Error::Store {
                Err(Error::SchemaUnavailable)
            } else {
                Err(error)
            }
        }
    }
}

impl ListingTransaction for OracleConversation<'_> {
    fn candidates(
        &self,
        user: i64,
        after: &str,
        limit: i64,
        moderation_allowed: bool,
        purpose: &str,
        group_id: Option<i64>,
        target_title: &str,
    ) -> Result<Vec<Record>, Error> {
        let values = bind_values(BindMap::from([
            ("owner_user_id".into(), DbValue::I64(user)),
            (
                "after_id".into(),
                if after.is_empty() {
                    DbValue::Null
                } else {
                    DbValue::String(after.into())
                },
            ),
            (
                "moderation_allowed".into(),
                DbValue::I64(i64::from(moderation_allowed)),
            ),
            ("row_limit".into(), DbValue::I64(limit)),
            (
                "target_title".into(),
                if target_title.is_empty() {
                    DbValue::Null
                } else {
                    DbValue::String(target_title.into())
                },
            ),
            (
                "group_id".into(),
                group_id.map_or(DbValue::Null, DbValue::I64),
            ),
            (
                "purpose".into(),
                if purpose.is_empty() {
                    DbValue::Null
                } else {
                    DbValue::String(purpose.into())
                },
            ),
        ]));
        let rows = self.0.query_named("SELECT c.conversation_id,c.owner_user_id,c.purpose,c.group_id,c.title,c.created_at,c.updated_at FROM n_ai_conversations c WHERE c.owner_user_id=:owner_user_id AND (:after_id IS NULL OR c.conversation_id>:after_id) AND (:purpose IS NULL OR c.purpose=:purpose) AND (:group_id IS NULL OR c.group_id=:group_id) AND (:target_title IS NULL OR (c.title=:target_title AND c.group_id IS NULL)) AND (c.purpose IN ('knowledge','writing') OR (c.purpose='group' AND fn_has_group_permission(:owner_user_id,c.group_id,'admin')=1) OR (c.purpose='moderation' AND :moderation_allowed=1)) ORDER BY c.conversation_id ASC FETCH FIRST :row_limit ROWS ONLY", &bind_refs(&values)).map_err(|_| Error::Store)?;
        rows.map(|row| {
            let row =
                oracle_row_to_db_row(&row.map_err(|_| Error::Store)?).map_err(|_| Error::Store)?;
            if row_number(&row, "OWNER_USER_ID") != user {
                return Err(Error::Store);
            }
            Ok(Record {
                id: row_text(&row, "CONVERSATION_ID"),
                purpose: row_text(&row, "PURPOSE"),
                group_id: nullable_text(&row, "GROUP_ID").map(|_| row_number(&row, "GROUP_ID")),
                title: nullable_text(&row, "TITLE"),
                created_at: nullable_text(&row, "CREATED_AT")
                    .map(|s| profile_date(&s))
                    .unwrap_or_default(),
                updated_at: nullable_text(&row, "UPDATED_AT")
                    .map(|s| profile_date(&s))
                    .unwrap_or_default(),
            })
        })
        .collect()
    }
}
impl Transaction for OracleConversation<'_> {
    fn check_schema(&self) -> Result<(), Error> {
        let snapshot = readiness::collect_ai_conversation_snapshot(self.0)
            .map_err(|_| Error::SchemaUnavailable)?;
        readiness::validate_feature_snapshot(&snapshot, "ai-conversations")
            .map_err(|_| Error::SchemaUnavailable)
    }
    fn authorize(&self, user: i64, input: &Input, policy: &ModerationPolicy) -> Result<(), Error> {
        match input.purpose.as_str() {
            "group" => {
                let values = bind_values(BindMap::from([
                    ("user_id".into(), DbValue::I64(user)),
                    (
                        "group_id".into(),
                        DbValue::I64(input.group_id.ok_or(Error::Store)?),
                    ),
                    ("role".into(), DbValue::String("admin".into())),
                ]));
                let allowed = self.0.query_row_as_named::<Option<i64>>("SELECT fn_has_group_permission(:user_id,:group_id,:role) AS allowed FROM dual", &bind_refs(&values)).map_err(|_| Error::Store)?;
                if allowed != Some(1) {
                    return Err(Error::Forbidden);
                }
            }
            "moderation" => {
                if !policy.allows(self.0, user).map_err(|_| Error::Store)? {
                    return Err(Error::Forbidden);
                }
            }
            _ => {}
        }
        Ok(())
    }
    fn insert(&self, user: i64, id: &str, input: &Input) -> Result<(), Error> {
        let binds = BindMap::from([
            ("conversation_id".into(), DbValue::String(id.into())),
            ("owner_user_id".into(), DbValue::I64(user)),
            ("purpose".into(), DbValue::String(input.purpose.clone())),
            (
                "group_id".into(),
                input.group_id.map(DbValue::I64).unwrap_or(DbValue::Null),
            ),
            (
                "title".into(),
                if input.title.is_empty() {
                    DbValue::Null
                } else {
                    DbValue::String(input.title.clone())
                },
            ),
        ]);
        let result = OracleTx::new(self.0).execute("INSERT INTO n_ai_conversations (conversation_id,owner_user_id,purpose,group_id,title) VALUES (:conversation_id,:owner_user_id,:purpose,:group_id,:title)", binds).map_err(|_| Error::Store)?;
        if result.rows_affected != 1 {
            return Err(Error::Store);
        }
        Ok(())
    }
    fn read(&self, user: i64, id: &str) -> Result<Option<Record>, Error> {
        self.read_owned(user, id, false)
    }
    fn commit(&self) -> Result<(), Error> {
        OracleTx::new(self.0).commit().map_err(|_| Error::Store)
    }
    fn rollback(&self) -> Result<(), Error> {
        OracleTx::new(self.0).rollback().map_err(|_| Error::Store)
    }
    fn restore_knowledge(
        &self,
        user: i64,
        content: &str,
    ) -> Result<Option<super::knowledge_history::Restored>, Error> {
        use super::knowledge_history::{restore, HistoryError};
        match restore(content, |refs| {
            super::knowledge_source::hydrate_sources(self.0, user, refs)
                .map_err(|_| HistoryError::Store)
        }) {
            Ok(restored) => Ok(Some(restored)),
            Err(HistoryError::Invalid | HistoryError::SourceChanged) => Ok(None),
            Err(HistoryError::Store) => Err(Error::Store),
        }
    }
    fn restore_knowledge_for_write(
        &self,
        user: i64,
        content: &str,
    ) -> Result<super::knowledge_history::Restored, Error> {
        super::knowledge_history::restore(content, |refs| {
            if refs.iter().any(|r| r.kind == "terms") {
                let raw: serde_json::Value = serde_json::from_str(include_str!(
                    "../../contracts/requirements/ai-public-terms-catalog.json"
                ))
                .map_err(|_| super::knowledge_history::HistoryError::Store)?;
                super::public_terms_authority::read_from_oracle_locked(self.0, user, &raw)
                    .map_err(|_| super::knowledge_history::HistoryError::Store)?;
            }
            super::knowledge_source::hydrate_sources(self.0, user, refs)
                .map_err(|_| super::knowledge_history::HistoryError::Store)
        })
        .map_err(|_| Error::Store)
    }
}
impl OracleConversation<'_> {
    fn read_owned(&self, user: i64, id: &str, lock: bool) -> Result<Option<Record>, Error> {
        let values = bind_values(BindMap::from([
            ("conversation_id".into(), DbValue::String(id.into())),
            ("owner_user_id".into(), DbValue::I64(user)),
        ]));
        let query = if lock {
            "SELECT conversation_id,purpose,group_id,title,created_at,updated_at FROM n_ai_conversations WHERE conversation_id=:conversation_id AND owner_user_id=:owner_user_id FOR UPDATE"
        } else {
            "SELECT conversation_id,purpose,group_id,title,created_at,updated_at FROM n_ai_conversations WHERE conversation_id=:conversation_id AND owner_user_id=:owner_user_id"
        };
        let mut rows = self
            .0
            .query_named(query, &bind_refs(&values))
            .map_err(|_| Error::Store)?;
        let Some(row) = rows.next().transpose().map_err(|_| Error::Store)? else {
            return Ok(None);
        };
        let row = oracle_row_to_db_row(&row).map_err(|_| Error::Store)?;
        if rows.next().is_some() {
            return Err(Error::Store);
        }
        let group_id = nullable_text(&row, "GROUP_ID").map(|_| row_number(&row, "GROUP_ID"));
        Ok(Some(Record {
            id: row_text(&row, "CONVERSATION_ID"),
            purpose: row_text(&row, "PURPOSE"),
            group_id,
            title: nullable_text(&row, "TITLE"),
            created_at: nullable_text(&row, "CREATED_AT")
                .map(|s| profile_date(&s))
                .unwrap_or_default(),
            updated_at: nullable_text(&row, "UPDATED_AT")
                .map(|s| profile_date(&s))
                .unwrap_or_default(),
        }))
    }
}
impl MessageTransaction for OracleConversation<'_> {
    fn guard_moderation_advice(
        &self,
        actor: i64,
        record: &super::moderation_advice::AdviceRecord,
        lock: bool,
    ) -> Result<(), Error> {
        super::moderation_advice::current_advice(self.0, actor, record, lock).map(|_| ())
    }
    fn guard_group_draft(
        &self,
        actor: i64,
        group: i64,
        draft: &super::group_draft::DraftRecord,
        lock: bool,
    ) -> Result<(), Error> {
        if lock {
            self.0
                .query_row_as_named::<i64>(
                    "SELECT group_id FROM n_groups WHERE group_id=:group_id FOR UPDATE",
                    &[("group_id", &group)],
                )
                .map_err(|_| Error::Store)?;
        }
        super::group_draft::recheck(self.0, actor, group, draft).map(|_| ())
    }
    fn guard_knowledge_skill(
        &self,
        user: i64,
        scope: &Input,
        generation: i64,
        policy: &ModerationPolicy,
    ) -> Result<(), Error> {
        let config = super::skill_config_store::lock_from_oracle(self.0, user)
            .map_err(|_| Error::SchemaUnavailable)?;
        verify_locked_knowledge_skill(self, user, scope, generation, policy, config)
    }
    fn read_locked(&self, user: i64, id: &str) -> Result<Option<Record>, Error> {
        self.read_owned(user, id, true)
    }
    fn delete(&self, user: i64, id: &str) -> Result<(), Error> {
        let binds = BindMap::from([
            ("conversation_id".into(), DbValue::String(id.into())),
            ("owner_user_id".into(), DbValue::I64(user)),
        ]);
        let result = OracleTx::new(self.0).execute("DELETE FROM n_ai_conversations WHERE conversation_id=:conversation_id AND owner_user_id=:owner_user_id", binds).map_err(|_| Error::Store)?;
        if result.rows_affected != 1 {
            return Err(Error::Store);
        }
        Ok(())
    }
    fn next_sequence(&self, id: &str) -> Result<i64, Error> {
        let values = bind_values(BindMap::from([(
            "conversation_id".into(),
            DbValue::String(id.into()),
        )]));
        self.0.query_row_as_named::<i64>("SELECT NVL(MAX(sequence_no),0)+1 AS next_sequence FROM n_ai_messages WHERE conversation_id=:conversation_id", &bind_refs(&values)).map_err(|_| Error::Store)
    }
    fn insert_message(
        &self,
        id: &str,
        message_id: &str,
        sequence: i64,
        content: &str,
        assistant: Option<&AssistantInput>,
    ) -> Result<(), Error> {
        use oracle::sql_type::{Clob, ToSql};
        use std::io::Write;
        let mut clob = Clob::new(self.0).map_err(|_| Error::Store)?;
        clob.write_all(content.as_bytes())
            .map_err(|_| Error::Store)?;
        let role = if assistant.is_some() {
            "assistant"
        } else {
            "user"
        };
        let model_id = assistant.map(|input| input.model_id.clone());
        let model_version = assistant.and_then(|input| input.model_version.clone());
        let revision = assistant.map(|input| input.config_revision);
        let binds: &[(&str, &dyn ToSql)] = &[
            ("message_id", &message_id),
            ("conversation_id", &id),
            ("sequence_no", &sequence),
            ("role", &role),
            ("content", &clob),
            ("model_id", &model_id),
            ("model_version", &model_version),
            ("config_revision", &revision),
        ];
        let result = self.0.execute_named("INSERT INTO n_ai_messages (message_id,conversation_id,sequence_no,role,content,model_id,model_version,config_revision) VALUES (:message_id,:conversation_id,:sequence_no,:role,:content,:model_id,:model_version,:config_revision)", binds).map_err(|_| Error::Store)?;
        if result.row_count().map_err(|_| Error::Store)? != 1 {
            return Err(Error::Store);
        }
        Ok(())
    }
    fn touch(&self, user: i64, id: &str) -> Result<(), Error> {
        let binds = BindMap::from([
            ("conversation_id".into(), DbValue::String(id.into())),
            ("owner_user_id".into(), DbValue::I64(user)),
        ]);
        let result = OracleTx::new(self.0).execute("UPDATE n_ai_conversations SET updated_at=CURRENT_TIMESTAMP WHERE conversation_id=:conversation_id AND owner_user_id=:owner_user_id", binds).map_err(|_| Error::Store)?;
        if result.rows_affected != 1 {
            return Err(Error::Store);
        }
        Ok(())
    }
}
impl HistoryTransaction for OracleConversation<'_> {
    fn feedback_table_present(&self) -> Result<bool, Error> {
        feedback::table_present(self.0)
    }
    fn read_moderation_rating(&self, id: &str) -> Result<Option<String>, Error> {
        feedback::read_rating(self.0, id)
    }
    fn restore_moderation_advice(
        &self,
        actor: i64,
        record: &super::moderation_advice::AdviceRecord,
    ) -> Result<serde_json::Value, Error> {
        match super::moderation_advice::current_advice(self.0, actor, record, false) {
            Err(Error::SchemaUnavailable | Error::Conflict) => Ok(serde_json::Value::Null),
            other => other,
        }
    }
    fn restore_group_draft(
        &self,
        actor: i64,
        group: i64,
        draft: &super::group_draft::DraftRecord,
    ) -> Result<Option<Vec<super::group_draft::GroupSource>>, Error> {
        match super::group_draft::recheck(self.0, actor, group, draft) {
            Ok(data) => Ok(Some(
                data.examples
                    .into_iter()
                    .map(|example| super::group_draft::GroupSource {
                        kind: example.kind,
                        source_id: example.source_id,
                        post_id: example.post_id,
                    })
                    .collect(),
            )),
            Err(Error::Forbidden | Error::Conflict) => Ok(None),
            Err(error) => Err(error),
        }
    }
    fn messages(
        &self,
        user: i64,
        id: &str,
        after: i64,
        before: i64,
        limit: i64,
        newest: bool,
    ) -> Result<Vec<HistoryMessage>, Error> {
        let (cursor_name, cursor, predicate) = if before > 0 {
            ("before_sequence", before, "<:before_sequence")
        } else {
            ("after_sequence", after, ">:after_sequence")
        };
        let values = bind_values(BindMap::from([
            ("conversation_id".into(), DbValue::String(id.into())),
            ("owner_user_id".into(), DbValue::I64(user)),
            (cursor_name.into(), DbValue::I64(cursor)),
            ("row_limit".into(), DbValue::I64(limit)),
        ]));
        let order = if newest || before > 0 { "DESC" } else { "ASC" };
        let query = format!("SELECT m.message_id,m.conversation_id,m.sequence_no,m.role,m.content,m.model_id,m.model_version,m.config_revision,m.created_at FROM n_ai_messages m JOIN n_ai_conversations c ON c.conversation_id=m.conversation_id WHERE m.conversation_id=:conversation_id AND c.owner_user_id=:owner_user_id AND m.sequence_no{predicate} ORDER BY m.sequence_no {order} FETCH FIRST :row_limit ROWS ONLY");
        let query = if before > 0 {
            format!("SELECT * FROM ({query}) ORDER BY sequence_no ASC")
        } else {
            query
        };
        let rows = self
            .0
            .query_named(&query, &bind_refs(&values))
            .map_err(|_| Error::Store)?;
        rows.map(|row| {
            let row =
                oracle_row_to_db_row(&row.map_err(|_| Error::Store)?).map_err(|_| Error::Store)?;
            let content = row
                .get("CONTENT")
                .and_then(DbValue::as_str)
                .ok_or(Error::Store)?
                .to_owned();
            let revision =
                nullable_text(&row, "CONFIG_REVISION").map(|_| row_number(&row, "CONFIG_REVISION"));
            Ok(HistoryMessage {
                message_id: row_text(&row, "MESSAGE_ID"),
                conversation_id: row_text(&row, "CONVERSATION_ID"),
                sequence_no: row_number(&row, "SEQUENCE_NO"),
                role: row_text(&row, "ROLE"),
                content,
                model_id: nullable_text(&row, "MODEL_ID"),
                model_version: nullable_text(&row, "MODEL_VERSION"),
                config_revision: revision,
                created_at: nullable_text(&row, "CREATED_AT")
                    .map(|s| profile_date(&s))
                    .unwrap_or_default(),
                citations: None,
                group_sources: None,
                group_tools: None,
                moderation_advice: None,
                moderation_feedback: None,
            })
        })
        .collect()
    }
}
pub fn create(
    connection: &oracle::Connection,
    user: i64,
    input: Input,
    policy: &ModerationPolicy,
) -> Result<Record, Error> {
    run(
        &OracleConversation(connection),
        user,
        &uuid::Uuid::new_v4().to_string(),
        Some(input),
        policy,
    )
}
pub fn read(
    connection: &oracle::Connection,
    user: i64,
    id: &str,
    policy: &ModerationPolicy,
) -> Result<Record, Error> {
    run(&OracleConversation(connection), user, id, None, policy)
}
/// Authenticated callers provide a dedicated connection and an owned conversation ID.
pub fn select_conversation_skill(
    connection: &oracle::Connection,
    registry: &super::skill_selection::Registry,
    user: i64,
    id: &str,
    skill_id: Option<&str>,
    policy: &ModerationPolicy,
) -> Result<super::skill_selection::Selection, super::skill_selection::Error> {
    run_select_conversation_skill(
        &OracleConversation(connection),
        registry,
        user,
        id,
        skill_id,
        policy,
    )
}
/// The caller supplies an authenticated identity and a dedicated connection.
pub fn select_configured_conversation_skill(
    connection: &oracle::Connection,
    user: i64,
    id: &str,
    skill_id: Option<&str>,
    policy: &ModerationPolicy,
) -> Result<ConfiguredSkillSelection, super::skill_selection::Error> {
    run_select_configured_skill(
        &OracleConversation(connection),
        &super::skill_config_store::OracleReader(connection),
        user,
        id,
        skill_id,
        policy,
    )
}
/// Lists owned conversations after filtering and rechecking their current permissions.
pub fn list_conversations(
    connection: &oracle::Connection,
    user: i64,
    after: &str,
    limit: i64,
    purpose: &str,
    group_id: Option<i64>,
    target_title: &str,
    policy: &ModerationPolicy,
) -> Result<ConversationPage, Error> {
    run_conversation_listing(
        &OracleConversation(connection),
        user,
        after,
        limit,
        purpose,
        group_id,
        target_title,
        policy,
    )
}
/// Deletes the owned conversation and its cascading messages after authorization.
pub fn delete(
    connection: &oracle::Connection,
    user: i64,
    id: &str,
    policy: &ModerationPolicy,
) -> Result<(), Error> {
    run_delete(&OracleConversation(connection), user, id, policy)
}
/// The caller must authenticate the actor and supply a trusted moderation policy.
pub fn append_user_message(
    connection: &oracle::Connection,
    user: i64,
    id: &str,
    content: &str,
    policy: &ModerationPolicy,
) -> Result<UserMessage, Error> {
    run_append(&OracleConversation(connection), user, id, content, policy)
}
/// Trusted internal generation only; clients cannot supply assistant metadata.
pub fn append_assistant_message(
    connection: &oracle::Connection,
    user: i64,
    id: &str,
    input: &AssistantInput,
    skill_generation: i64,
    cancel: Cancellation<'_>,
    policy: &ModerationPolicy,
) -> Result<UserMessage, Error> {
    run_append_assistant(
        &OracleConversation(connection),
        user,
        id,
        input,
        skill_generation,
        cancel,
        policy,
    )
}
pub fn append_knowledge_assistant_message(
    connection: &oracle::Connection,
    user: i64,
    id: &str,
    input: &AssistantInput,
    sources: &[super::knowledge_source::Candidate],
    context_snapshot: &[serde_json::Value],
    skill_generation: i64,
    cancel: Cancellation<'_>,
    policy: &ModerationPolicy,
) -> Result<UserMessage, Error> {
    run_append_knowledge_guarded(
        &OracleConversation(connection),
        user,
        id,
        input,
        sources,
        Some(context_snapshot),
        skill_generation,
        cancel,
        policy,
    )
}
/// The caller must authenticate the actor and supply a trusted moderation policy.
pub fn list_messages(
    connection: &oracle::Connection,
    user: i64,
    id: &str,
    after: i64,
    before: i64,
    limit: i64,
    policy: &ModerationPolicy,
) -> Result<Vec<HistoryMessage>, Error> {
    run_history_ordered(
        &OracleConversation(connection),
        user,
        id,
        after,
        before,
        limit,
        false,
        policy,
    )
}
/// Internal history window for model inference, returned in chronological order.
pub fn recent_messages(
    connection: &oracle::Connection,
    user: i64,
    id: &str,
    policy: &ModerationPolicy,
) -> Result<Vec<HistoryMessage>, Error> {
    run_recent_history(&OracleConversation(connection), user, id, policy)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::{Cell, RefCell};

    struct SkillFake {
        allowed: bool,
        calls: Cell<usize>,
    }
    struct SkillConfigFake {
        enabled: Cell<bool>,
        calls: Cell<usize>,
    }
    impl super::super::skill_config_store::Reader for SkillConfigFake {
        fn load(
            &self,
        ) -> Result<Vec<crate::db::row::DbRow>, super::super::skill_config_store::Error> {
            self.calls.set(self.calls.get() + 1);
            Ok(vec![crate::db::row::DbRow::from([
                (
                    "GENERATION".into(),
                    DbValue::String(self.calls.get().to_string()),
                ),
                (
                    "ENABLED_IDS".into(),
                    DbValue::String(
                        if self.enabled.get() {
                            r#"["group-brief"]"#
                        } else {
                            "[]"
                        }
                        .into(),
                    ),
                ),
            ])])
        }
    }
    impl Transaction for SkillFake {
        fn check_schema(&self) -> Result<(), Error> {
            Ok(())
        }
        fn authorize(&self, user: i64, input: &Input, _: &ModerationPolicy) -> Result<(), Error> {
            self.calls.set(self.calls.get() + 1);
            if user == 42 && input.purpose == "group" && input.group_id == Some(7) && self.allowed {
                Ok(())
            } else {
                Err(Error::Forbidden)
            }
        }
        fn read(&self, user: i64, id: &str) -> Result<Option<Record>, Error> {
            Ok(if user == 42 {
                Some(Record {
                    id: id.into(),
                    purpose: "group".into(),
                    group_id: Some(7),
                    title: None,
                    created_at: String::new(),
                    updated_at: String::new(),
                })
            } else {
                None
            })
        }
        fn insert(&self, _: i64, _: &str, _: &Input) -> Result<(), Error> {
            unreachable!()
        }
        fn commit(&self) -> Result<(), Error> {
            unreachable!()
        }
        fn rollback(&self) -> Result<(), Error> {
            unreachable!()
        }
    }
    #[test]
    fn skill_selection_uses_owned_record_and_current_permission() {
        let reg = super::super::skill_selection::Registry::new(&["group-brief".into()]).unwrap();
        let policy = ModerationPolicy::new("", "");
        let id = "f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb";
        let good = SkillFake {
            allowed: true,
            calls: Cell::new(0),
        };
        let result = run_select_conversation_skill(&good, &reg, 42, id, None, &policy).unwrap();
        assert_eq!(result.id, "group-brief");
        assert_eq!(good.calls.get(), 1);
        let denied = SkillFake {
            allowed: false,
            calls: Cell::new(0),
        };
        assert!(run_select_conversation_skill(&denied, &reg, 42, id, None, &policy).is_err());
        assert!(run_select_conversation_skill(&good, &reg, 43, id, None, &policy).is_err());
    }
    #[test]
    fn configured_skill_selection_reloads_configuration_and_scope() {
        let config = SkillConfigFake {
            enabled: Cell::new(true),
            calls: Cell::new(0),
        };
        let tx = SkillFake {
            allowed: true,
            calls: Cell::new(0),
        };
        let policy = ModerationPolicy::new("", "");
        let id = "f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb";
        let result = run_select_configured_skill(&tx, &config, 42, id, None, &policy).unwrap();
        assert_eq!(result.generation, 1);
        assert_eq!(result.skill.id, "group-brief");
        config.enabled.set(false);
        assert!(run_select_configured_skill(&tx, &config, 42, id, None, &policy).is_err());
        assert_eq!(config.calls.get(), 2);
    }

    struct ListingFake {
        records: Vec<Record>,
        fail_group: bool,
    }
    impl ListingFake {
        fn new(fail_group: bool) -> Self {
            let ids = [
                "0f9da41c-7296-4f51-91f4-141f5c6e3c01",
                "1f9da41c-7296-4f51-91f4-141f5c6e3c01",
                "2f9da41c-7296-4f51-91f4-141f5c6e3c01",
            ];
            let records = ids
                .iter()
                .enumerate()
                .map(|(i, id)| Record {
                    id: (*id).into(),
                    purpose: ["writing", "group", "knowledge"][i].into(),
                    group_id: if i == 1 { Some(7) } else { None },
                    title: Some(["first", "hidden", "third"][i].into()),
                    created_at: String::new(),
                    updated_at: String::new(),
                })
                .collect();
            Self {
                records,
                fail_group,
            }
        }
    }
    impl Transaction for ListingFake {
        fn check_schema(&self) -> Result<(), Error> {
            Ok(())
        }
        fn authorize(&self, _: i64, input: &Input, _: &ModerationPolicy) -> Result<(), Error> {
            match input.purpose.as_str() {
                "moderation" => Err(Error::Forbidden),
                "group" if self.fail_group => Err(Error::Store),
                "group" => Err(Error::Forbidden),
                _ => Ok(()),
            }
        }
        fn insert(&self, _: i64, _: &str, _: &Input) -> Result<(), Error> {
            unreachable!()
        }
        fn read(&self, _: i64, _: &str) -> Result<Option<Record>, Error> {
            unreachable!()
        }
        fn commit(&self) -> Result<(), Error> {
            Ok(())
        }
        fn rollback(&self) -> Result<(), Error> {
            Ok(())
        }
    }
    impl ListingTransaction for ListingFake {
        fn candidates(
            &self,
            user: i64,
            after: &str,
            limit: i64,
            moderation_allowed: bool,
            purpose: &str,
            group_id: Option<i64>,
            _target_title: &str,
        ) -> Result<Vec<Record>, Error> {
            assert_eq!(user, 42);
            assert!(!moderation_allowed);
            Ok(self
                .records
                .iter()
                .filter(|r| {
                    r.id.as_str() > after
                        && (purpose.is_empty() || r.purpose == purpose)
                        && (group_id.is_none() || r.group_id == group_id)
                })
                .take(limit as usize)
                .cloned()
                .collect())
        }
    }

    #[test]
    fn listing_filters_revoked_items_and_uses_only_visible_cursor() {
        let tx = ListingFake::new(false);
        let policy = ModerationPolicy::new("", "");
        let first = run_conversation_listing(&tx, 42, "", 1, "", None, "", &policy).unwrap();
        assert_eq!(first.items[0].title.as_deref(), Some("first"));
        assert_eq!(
            first.next_cursor.as_deref(),
            Some("0f9da41c-7296-4f51-91f4-141f5c6e3c01")
        );
        let second = run_conversation_listing(
            &tx,
            42,
            first.next_cursor.as_deref().unwrap(),
            1,
            "",
            None,
            "",
            &policy,
        )
        .unwrap();
        assert_eq!(second.items[0].title.as_deref(), Some("third"));
        assert_eq!(
            second.next_cursor.as_deref(),
            Some("2f9da41c-7296-4f51-91f4-141f5c6e3c01")
        );
        assert_eq!(
            run_conversation_listing(&tx, 42, "invalid", 1, "", None, "", &policy),
            Err(Error::Invalid)
        );
        let failed = ListingFake::new(true);
        assert_eq!(
            run_conversation_listing(
                &failed,
                42,
                "1f9da41c-7296-4f51-91f4-141f5c6e3c01",
                1,
                "",
                None,
                "",
                &policy
            ),
            Ok(ConversationPage {
                items: vec![failed.records[2].clone()],
                next_cursor: None
            })
        );
        assert_eq!(
            run_conversation_listing(
                &failed,
                42,
                "0f9da41c-7296-4f51-91f4-141f5c6e3c01",
                1,
                "",
                None,
                "",
                &policy
            ),
            Err(Error::Store)
        );
    }

    #[test]
    fn listing_applies_purpose_before_page_limit() {
        let tx = ListingFake::new(true);
        let policy = ModerationPolicy::new("", "");
        let page =
            run_conversation_listing(&tx, 42, "", 1, "knowledge", None, "", &policy).unwrap();
        assert_eq!(page.items, vec![tx.records[2].clone()]);
        assert!(page.next_cursor.is_none());
    }

    struct Fake {
        events: RefCell<Vec<&'static str>>,
        checks: Cell<u32>,
        revoked: bool,
    }
    struct KnowledgeFake {
        events: RefCell<Vec<&'static str>>,
        checks: Cell<u32>,
        write_checks: Cell<u32>,
        revoke: bool,
        encoded: String,
        history_mode: &'static str,
        history_checks: Cell<u32>,
    }
    impl Transaction for KnowledgeFake {
        fn check_schema(&self) -> Result<(), Error> {
            Ok(())
        }
        fn authorize(&self, _: i64, _: &Input, _: &ModerationPolicy) -> Result<(), Error> {
            Ok(())
        }
        fn insert(&self, _: i64, _: &str, _: &Input) -> Result<(), Error> {
            Ok(())
        }
        fn read(&self, _: i64, id: &str) -> Result<Option<Record>, Error> {
            Ok(Some(Record {
                id: id.into(),
                purpose: if self.history_mode.starts_with("writing-") {
                    "writing"
                } else {
                    "knowledge"
                }
                .into(),
                group_id: None,
                title: None,
                created_at: String::new(),
                updated_at: String::new(),
            }))
        }
        fn restore_knowledge(
            &self,
            _: i64,
            content: &str,
        ) -> Result<Option<super::super::knowledge_history::Restored>, Error> {
            self.checks.set(self.checks.get() + 1);
            if self.revoke && self.checks.get() > 1 {
                return Err(Error::Store);
            };
            use super::super::knowledge_history::{restore, HistoryError};
            match restore(content, |refs| {
                Ok(refs
                    .iter()
                    .map(|r| super::super::knowledge_source::Source {
                        kind: r.kind.clone(),
                        id: r.id,
                        post_id: r.id,
                        group_id: 0,
                        content: "public".into(),
                        version: r.version.clone(),
                    })
                    .collect())
            }) {
                Ok(restored) => Ok(Some(restored)),
                Err(HistoryError::Invalid | HistoryError::SourceChanged) => Ok(None),
                Err(HistoryError::Store) => Err(Error::Store),
            }
        }
        fn restore_knowledge_for_write(
            &self,
            user: i64,
            content: &str,
        ) -> Result<super::super::knowledge_history::Restored, Error> {
            self.write_checks.set(self.write_checks.get() + 1);
            self.restore_knowledge(user, content)?.ok_or(Error::Store)
        }
        fn commit(&self) -> Result<(), Error> {
            self.events.borrow_mut().push("commit");
            Ok(())
        }
        fn rollback(&self) -> Result<(), Error> {
            self.events.borrow_mut().push("rollback");
            Ok(())
        }
    }
    impl MessageTransaction for KnowledgeFake {
        fn guard_knowledge_skill(
            &self,
            user: i64,
            scope: &Input,
            generation: i64,
            policy: &ModerationPolicy,
        ) -> Result<(), Error> {
            self.events.borrow_mut().push("skill-lock");
            let enabled = if self.history_mode.ends_with("disabled") {
                vec![]
            } else if self.history_mode.starts_with("writing-") {
                vec!["writing-draft".to_string()]
            } else {
                vec!["knowledge-answer".to_string()]
            };
            let config = super::super::skill_config_store::Config {
                generation: if self.history_mode.ends_with("stale") {
                    2
                } else {
                    1
                },
                registry: super::super::skill_selection::Registry::new(&enabled).unwrap(),
            };
            verify_locked_knowledge_skill(self, user, scope, generation, policy, config)
        }
        fn read_locked(&self, user: i64, id: &str) -> Result<Option<Record>, Error> {
            self.read(user, id)
        }
        fn delete(&self, _: i64, _: &str) -> Result<(), Error> {
            Ok(())
        }
        fn next_sequence(&self, _: &str) -> Result<i64, Error> {
            Ok(2)
        }
        fn insert_message(
            &self,
            _: &str,
            _: &str,
            _: i64,
            _: &str,
            _: Option<&AssistantInput>,
        ) -> Result<(), Error> {
            Ok(())
        }
        fn touch(&self, _: i64, _: &str) -> Result<(), Error> {
            Ok(())
        }
    }
    impl HistoryTransaction for KnowledgeFake {
        fn messages(
            &self,
            _: i64,
            id: &str,
            _: i64,
            _: i64,
            _: i64,
            _: bool,
        ) -> Result<Vec<HistoryMessage>, Error> {
            if !self.history_mode.is_empty() {
                self.history_checks.set(self.history_checks.get() + 1);
                let changed = self.history_mode == "before"
                    || (self.history_mode == "during" && self.history_checks.get() > 1);
                return Ok(vec![HistoryMessage {
                    message_id: "msg".into(),
                    conversation_id: id.into(),
                    sequence_no: 1,
                    role: "user".into(),
                    content: if changed { "changed" } else { "question" }.into(),
                    model_id: None,
                    model_version: None,
                    config_revision: None,
                    created_at: String::new(),
                    citations: None,
                    group_sources: None,
                    group_tools: None,
                    moderation_advice: None,
                    moderation_feedback: None,
                }]);
            }
            Ok(vec![HistoryMessage {
                message_id: "msg".into(),
                conversation_id: id.into(),
                sequence_no: 2,
                role: "assistant".into(),
                content: self.encoded.clone(),
                model_id: None,
                model_version: None,
                config_revision: None,
                created_at: String::new(),
                citations: None,
                group_sources: None,
                group_tools: None,
                moderation_advice: None,
                moderation_feedback: None,
            }])
        }
    }
    #[test]
    fn unavailable_knowledge_answer_preserves_history_position_and_cuts_context() {
        let id = "bf9da41c-7296-4f51-91f4-141f5c6e3c01";
        let policy = ModerationPolicy::new("", "");
        let tx = KnowledgeFake {
            events: RefCell::new(vec![]),
            checks: Cell::new(0),
            write_checks: Cell::new(0),
            revoke: false,
            encoded: "old unreferenced answer".into(),
            history_mode: "",
            history_checks: Cell::new(0),
        };
        let rows = run_history(&tx, 1, id, 0, 10, &policy).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].sequence_no, 2);
        assert_eq!(rows[0].content, "公开资料已变更，历史回答不可用。");
        assert!(rows[0].citations.is_none());
        assert!(run_recent_history(&tx, 1, id, &policy).unwrap().is_empty());
    }
    #[test]
    fn knowledge_writes_and_history_recheck_sources() {
        let ref_ = super::super::knowledge_source::Candidate {
            kind: "post".into(),
            id: 1,
            version: "a".repeat(64),
        };
        let encoded =
            super::super::knowledge_history::encode("answer", std::slice::from_ref(&ref_)).unwrap();
        let id = "bf9da41c-7296-4f51-91f4-141f5c6e3c01";
        let policy = ModerationPolicy::new("", "");
        let tx = KnowledgeFake {
            events: RefCell::new(vec![]),
            checks: Cell::new(0),
            write_checks: Cell::new(0),
            revoke: false,
            encoded: encoded.clone(),
            history_mode: "",
            history_checks: Cell::new(0),
        };
        let input = AssistantInput {
            content: "answer".into(),
            expected_sequence: 1,
            model_id: "profile-a".into(),
            model_version: None,
            config_revision: 12,
        };
        run_append_knowledge(&tx, 1, id, &input, std::slice::from_ref(&ref_), &policy).unwrap();
        assert_eq!(tx.checks.get(), 2);
        assert_eq!(tx.write_checks.get(), 2);
        let rows = run_history(&tx, 1, id, 0, 10, &policy).unwrap();
        assert_eq!(tx.write_checks.get(), 2);
        assert_eq!(rows[0].content, "answer");
        assert_eq!(
            rows[0].citations.as_ref().unwrap(),
            &vec![super::super::knowledge_history::Citation {
                kind: ref_.kind.clone(),
                id: ref_.id,
                version: ref_.version.clone(),
                post_id: ref_.id,
                group_id: 0,
            }]
        );
        let bad = KnowledgeFake {
            events: RefCell::new(vec![]),
            checks: Cell::new(0),
            write_checks: Cell::new(0),
            revoke: true,
            encoded,
            history_mode: "",
            history_checks: Cell::new(0),
        };
        assert_eq!(
            run_append_knowledge(&bad, 1, id, &input, &[ref_], &policy),
            Err(Error::Store)
        );
        assert_eq!(*bad.events.borrow(), vec!["skill-lock", "rollback"]);
        assert_eq!(
            run_append_assistant(&tx, 1, id, &input, 1, None, &policy),
            Err(Error::Conflict)
        );
    }
    #[test]
    fn knowledge_write_guards_exact_history_before_insert_and_commit() {
        let reference = super::super::knowledge_source::Candidate {
            kind: "post".into(),
            id: 1,
            version: "a".repeat(64),
        };
        let input = AssistantInput {
            content: "answer".into(),
            expected_sequence: 1,
            model_id: "profile".into(),
            model_version: None,
            config_revision: 1,
        };
        let snapshot =
            vec![serde_json::json!({"sequence_no":1,"role":"user","content":"question"})];
        for mode in ["ok", "before", "during"] {
            let tx = KnowledgeFake {
                events: RefCell::new(vec![]),
                checks: Cell::new(0),
                write_checks: Cell::new(0),
                revoke: false,
                encoded: String::new(),
                history_mode: mode,
                history_checks: Cell::new(0),
            };
            let result = run_append_knowledge_guarded(
                &tx,
                1,
                "bf9da41c-7296-4f51-91f4-141f5c6e3c01",
                &input,
                std::slice::from_ref(&reference),
                Some(&snapshot),
                1,
                None,
                &ModerationPolicy::new("", ""),
            );
            if mode == "ok" {
                assert!(result.is_ok());
                assert_eq!(tx.history_checks.get(), 2)
            } else {
                assert_eq!(result, Err(Error::Conflict));
                assert_eq!(*tx.events.borrow(), vec!["skill-lock", "rollback"])
            }
        }
    }
    #[test]
    fn knowledge_write_rejects_changed_or_disabled_skill_before_insert() {
        let reference = super::super::knowledge_source::Candidate {
            kind: "post".into(),
            id: 1,
            version: "a".repeat(64),
        };
        let input = AssistantInput {
            content: "answer".into(),
            expected_sequence: 1,
            model_id: "profile".into(),
            model_version: None,
            config_revision: 1,
        };
        for (mode, expected) in [
            ("skill-stale", Error::Conflict),
            ("skill-disabled", Error::SchemaUnavailable),
        ] {
            let tx = KnowledgeFake {
                events: RefCell::new(vec![]),
                checks: Cell::new(0),
                write_checks: Cell::new(0),
                revoke: false,
                encoded: String::new(),
                history_mode: mode,
                history_checks: Cell::new(0),
            };
            assert_eq!(
                run_append_knowledge(
                    &tx,
                    1,
                    "bf9da41c-7296-4f51-91f4-141f5c6e3c01",
                    &input,
                    std::slice::from_ref(&reference),
                    &ModerationPolicy::new("", "")
                ),
                Err(expected)
            );
            assert_eq!(*tx.events.borrow(), vec!["skill-lock", "rollback"]);
            assert_eq!(tx.write_checks.get(), 0);
        }
    }
    #[test]
    fn writing_write_rechecks_locked_skill_before_insert() {
        let input = AssistantInput {
            content: "draft".into(),
            expected_sequence: 1,
            model_id: "profile".into(),
            model_version: None,
            config_revision: 1,
        };
        for (mode, expected) in [
            ("writing-ok", None),
            ("writing-stale", Some(Error::Conflict)),
            ("writing-disabled", Some(Error::SchemaUnavailable)),
            ("writing-cancelled", Some(Error::SchemaUnavailable)),
        ] {
            let (_sender, cancel) = tokio::sync::watch::channel(mode == "writing-cancelled");
            let tx = KnowledgeFake {
                events: RefCell::new(vec![]),
                checks: Cell::new(0),
                write_checks: Cell::new(0),
                revoke: false,
                encoded: String::new(),
                history_mode: mode,
                history_checks: Cell::new(0),
            };
            let result = run_append_assistant(
                &tx,
                1,
                "bf9da41c-7296-4f51-91f4-141f5c6e3c01",
                &input,
                1,
                Some(&cancel),
                &ModerationPolicy::new("", ""),
            );
            assert_eq!(result.as_ref().err(), expected.as_ref());
            assert_eq!(
                *tx.events.borrow(),
                if expected.is_none() {
                    vec!["skill-lock", "commit"]
                } else {
                    vec!["skill-lock", "rollback"]
                }
            );
        }
    }
    impl Transaction for Fake {
        fn check_schema(&self) -> Result<(), Error> {
            self.events.borrow_mut().push("schema");
            Ok(())
        }
        fn authorize(&self, _: i64, _: &Input, _: &ModerationPolicy) -> Result<(), Error> {
            self.events.borrow_mut().push("authorize");
            self.checks.set(self.checks.get() + 1);
            if self.revoked && self.checks.get() > 1 {
                Err(Error::Forbidden)
            } else {
                Ok(())
            }
        }
        fn insert(&self, _: i64, _: &str, _: &Input) -> Result<(), Error> {
            self.events.borrow_mut().push("insert");
            Ok(())
        }
        fn read(&self, _: i64, id: &str) -> Result<Option<Record>, Error> {
            self.events.borrow_mut().push("read");
            Ok(Some(Record {
                id: id.into(),
                purpose: "group".into(),
                group_id: Some(12),
                title: None,
                created_at: String::new(),
                updated_at: String::new(),
            }))
        }
        fn commit(&self) -> Result<(), Error> {
            self.events.borrow_mut().push("commit");
            Ok(())
        }
        fn rollback(&self) -> Result<(), Error> {
            self.events.borrow_mut().push("rollback");
            Ok(())
        }
    }
    impl MessageTransaction for Fake {
        fn guard_group_draft(
            &self,
            _: i64,
            _: i64,
            _: &super::super::group_draft::DraftRecord,
            lock: bool,
        ) -> Result<(), Error> {
            self.events
                .borrow_mut()
                .push(if lock { "group-lock" } else { "group-recheck" });
            Ok(())
        }
        fn guard_knowledge_skill(
            &self,
            _: i64,
            _: &Input,
            _: i64,
            _: &ModerationPolicy,
        ) -> Result<(), Error> {
            self.events.borrow_mut().push("skill-lock");
            Ok(())
        }
        fn read_locked(&self, user: i64, id: &str) -> Result<Option<Record>, Error> {
            self.events.borrow_mut().push("lock");
            self.read(user, id)
        }
        fn delete(&self, _: i64, _: &str) -> Result<(), Error> {
            self.events.borrow_mut().push("delete");
            Ok(())
        }
        fn next_sequence(&self, id: &str) -> Result<i64, Error> {
            self.events.borrow_mut().push("sequence");
            Ok(if id.starts_with("bf9") { 2 } else { 1 })
        }
        fn insert_message(
            &self,
            _: &str,
            _: &str,
            _: i64,
            _: &str,
            assistant: Option<&AssistantInput>,
        ) -> Result<(), Error> {
            self.events.borrow_mut().push("message");
            if let Some(input) = assistant {
                assert_eq!(input.model_id, "profile-a");
                assert_eq!(input.config_revision, 12);
            }
            Ok(())
        }
        fn touch(&self, _: i64, _: &str) -> Result<(), Error> {
            self.events.borrow_mut().push("touch");
            Ok(())
        }
    }
    impl HistoryTransaction for Fake {
        fn messages(
            &self,
            _: i64,
            id: &str,
            after: i64,
            _: i64,
            limit: i64,
            newest: bool,
        ) -> Result<Vec<HistoryMessage>, Error> {
            self.events.borrow_mut().push("messages");
            if newest {
                assert_eq!((after, limit), (0, 50));
                return Ok([52, 51]
                    .into_iter()
                    .map(|sequence_no| HistoryMessage {
                        message_id: "message".into(),
                        conversation_id: id.into(),
                        sequence_no,
                        role: "user".into(),
                        content: "text".into(),
                        model_id: None,
                        model_version: None,
                        config_revision: None,
                        created_at: String::new(),
                        citations: None,
                        group_sources: None,
                        group_tools: None,
                        moderation_advice: None,
                        moderation_feedback: None,
                    })
                    .collect());
            }
            assert_eq!((after, limit), (1, 10));
            Ok(vec![HistoryMessage {
                message_id: "message".into(),
                conversation_id: id.into(),
                sequence_no: 2,
                role: "user".into(),
                content: "第二条".into(),
                model_id: None,
                model_version: None,
                config_revision: None,
                created_at: String::new(),
                citations: None,
                group_sources: None,
                group_tools: None,
                moderation_advice: None,
                moderation_feedback: None,
            }])
        }
    }
    #[test]
    fn delete_rechecks_permission_and_rolls_back_when_revoked() {
        let tx = Fake {
            events: RefCell::new(vec![]),
            checks: Cell::new(0),
            revoked: true,
        };
        assert_eq!(
            run_delete(
                &tx,
                1,
                "af9da41c-7296-4f51-91f4-141f5c6e3c01",
                &ModerationPolicy::new("", "")
            ),
            Err(Error::Forbidden)
        );
        assert_eq!(
            *tx.events.borrow(),
            vec![
                "schema",
                "lock",
                "read",
                "authorize",
                "delete",
                "authorize",
                "rollback"
            ]
        );
    }
    #[test]
    fn delete_commits_after_rechecking_access() {
        let tx = Fake {
            events: RefCell::new(vec![]),
            checks: Cell::new(0),
            revoked: false,
        };
        assert_eq!(
            run_delete(
                &tx,
                1,
                "af9da41c-7296-4f51-91f4-141f5c6e3c01",
                &ModerationPolicy::new("", "")
            ),
            Ok(())
        );
        assert_eq!(
            *tx.events.borrow(),
            vec![
                "schema",
                "lock",
                "read",
                "authorize",
                "delete",
                "authorize",
                "commit"
            ]
        );
    }
    #[test]
    fn recent_history_selects_latest_messages_and_keeps_chronological_order() {
        let tx = Fake {
            events: RefCell::new(vec![]),
            checks: Cell::new(0),
            revoked: false,
        };
        let messages = run_recent_history(
            &tx,
            1,
            "af9da41c-7296-4f51-91f4-141f5c6e3c01",
            &ModerationPolicy::new("", ""),
        )
        .unwrap();
        assert_eq!(
            messages.iter().map(|m| m.sequence_no).collect::<Vec<_>>(),
            vec![51, 52]
        );
        assert_eq!(tx.events.borrow().last(), Some(&"commit"));
    }
    #[test]
    fn recent_history_does_not_return_messages_after_permission_revocation() {
        let tx = Fake {
            events: RefCell::new(vec![]),
            checks: Cell::new(0),
            revoked: true,
        };
        assert_eq!(
            run_recent_history(
                &tx,
                1,
                "af9da41c-7296-4f51-91f4-141f5c6e3c01",
                &ModerationPolicy::new("", ""),
            ),
            Err(Error::Forbidden)
        );
        assert_eq!(tx.events.borrow().last(), Some(&"rollback"));
    }
    #[test]
    fn history_rechecks_group_permission_before_returning_messages() {
        let tx = Fake {
            events: RefCell::new(vec![]),
            checks: Cell::new(0),
            revoked: true,
        };
        assert_eq!(
            run_history(
                &tx,
                1,
                "af9da41c-7296-4f51-91f4-141f5c6e3c01",
                1,
                10,
                &ModerationPolicy::new("", "")
            ),
            Err(Error::Forbidden)
        );
        assert_eq!(
            *tx.events.borrow(),
            vec![
                "schema",
                "read",
                "authorize",
                "messages",
                "read",
                "authorize",
                "rollback"
            ]
        );
    }
    #[test]
    fn history_returns_ordered_content_and_rejects_invalid_page() {
        let tx = Fake {
            events: RefCell::new(vec![]),
            checks: Cell::new(0),
            revoked: false,
        };
        let id = "af9da41c-7296-4f51-91f4-141f5c6e3c01";
        assert_eq!(
            run_history(&tx, 1, id, -1, 10, &ModerationPolicy::new("", "")),
            Err(Error::Invalid)
        );
        assert!(tx.events.borrow().is_empty());
        let result = run_history(&tx, 1, id, 1, 10, &ModerationPolicy::new("", "")).unwrap();
        assert_eq!(
            (result[0].sequence_no, result[0].content.as_str()),
            (2, "第二条")
        );
        assert_eq!(
            *tx.events.borrow(),
            vec![
                "schema",
                "read",
                "authorize",
                "messages",
                "read",
                "authorize",
                "commit"
            ]
        );
    }
    #[test]
    fn user_message_rechecks_group_permission_before_commit() {
        let tx = Fake {
            events: RefCell::new(vec![]),
            checks: Cell::new(0),
            revoked: true,
        };
        assert_eq!(
            run_append(
                &tx,
                1,
                "af9da41c-7296-4f51-91f4-141f5c6e3c01",
                "hello",
                &ModerationPolicy::new("", "")
            ),
            Err(Error::Forbidden)
        );
        assert_eq!(
            *tx.events.borrow(),
            vec![
                "schema",
                "lock",
                "read",
                "authorize",
                "sequence",
                "message",
                "touch",
                "authorize",
                "rollback"
            ]
        );
    }
    #[test]
    fn user_message_checks_utf8_length_before_touching_database() {
        let tx = Fake {
            events: RefCell::new(vec![]),
            checks: Cell::new(0),
            revoked: false,
        };
        let id = "af9da41c-7296-4f51-91f4-141f5c6e3c01";
        assert_eq!(
            run_append(
                &tx,
                1,
                id,
                &"猫".repeat(21846),
                &ModerationPolicy::new("", "")
            ),
            Err(Error::Invalid)
        );
        assert!(tx.events.borrow().is_empty());
    }
    #[test]
    fn user_message_commits_after_lock_and_permission_recheck() {
        let tx = Fake {
            events: RefCell::new(vec![]),
            checks: Cell::new(0),
            revoked: false,
        };
        let id = "af9da41c-7296-4f51-91f4-141f5c6e3c01";
        let result = run_append(
            &tx,
            1,
            id,
            &"x".repeat(65536),
            &ModerationPolicy::new("", ""),
        )
        .unwrap();
        assert_eq!(result.sequence_no, 1);
        assert_eq!(result.role, "user");
        assert_eq!(result.conversation_id, id);
        assert!(valid_uuid(&result.message_id));
        assert_eq!(
            *tx.events.borrow(),
            vec![
                "schema",
                "lock",
                "read",
                "authorize",
                "sequence",
                "message",
                "touch",
                "authorize",
                "commit"
            ]
        );
    }
    #[test]
    fn assistant_message_rejects_stale_sequence_and_invalid_revision() {
        let tx = Fake {
            events: RefCell::new(vec![]),
            checks: Cell::new(0),
            revoked: false,
        };
        let id = "af9da41c-7296-4f51-91f4-141f5c6e3c01";
        let mut input = AssistantInput {
            content: "answer".into(),
            expected_sequence: 1,
            model_id: "profile-a".into(),
            model_version: None,
            config_revision: 12,
        };
        let draft = fixture_group_draft();
        assert_eq!(
            run_append_inner(
                &tx,
                1,
                id,
                &input.content,
                Some(&input),
                false,
                None,
                Some(1),
                Some(EvidenceGuard::Group(&draft, None)),
                &ModerationPolicy::new("", "")
            ),
            Err(Error::Conflict)
        );
        assert_eq!(
            *tx.events.borrow(),
            vec![
                "schema",
                "lock",
                "read",
                "authorize",
                "group-lock",
                "skill-lock",
                "sequence",
                "rollback"
            ]
        );
        tx.events.borrow_mut().clear();
        input.config_revision = 1_000_000_000_000_000;
        assert_eq!(
            run_append_assistant(&tx, 1, id, &input, 1, None, &ModerationPolicy::new("", "")),
            Err(Error::Invalid)
        );
        assert!(tx.events.borrow().is_empty());
    }
    fn fixture_group_draft() -> super::super::group_draft::DraftRecord {
        super::super::group_draft::DraftRecord {
            version: 1,
            kind: "weekly_report".into(),
            window_end: "2026-11-17T12:00:00.000000".into(),
            source_digest: "a".repeat(64),
            example_count: 1,
            skill_generation: 1,
            draft: "result".into(),
            tools_used: None,
            search_term: None,
            match_excerpt: false,
        }
    }
    #[test]
    fn assistant_message_preserves_model_metadata_and_rechecks_access() {
        let tx = Fake {
            events: RefCell::new(vec![]),
            checks: Cell::new(0),
            revoked: false,
        };
        let id = "bf9da41c-7296-4f51-91f4-141f5c6e3c01";
        let input = AssistantInput {
            content: "result".into(),
            expected_sequence: 1,
            model_id: "profile-a".into(),
            model_version: None,
            config_revision: 12,
        };
        let draft = fixture_group_draft();
        let append = |tx: &Fake| {
            run_append_inner(
                tx,
                1,
                id,
                &input.content,
                Some(&input),
                false,
                None,
                Some(1),
                Some(EvidenceGuard::Group(&draft, None)),
                &ModerationPolicy::new("", ""),
            )
        };
        let result = append(&tx).unwrap();
        assert_eq!((result.sequence_no, result.role), (2, "assistant"));
        assert_eq!(
            *tx.events.borrow(),
            vec![
                "schema",
                "lock",
                "read",
                "authorize",
                "group-lock",
                "skill-lock",
                "sequence",
                "message",
                "touch",
                "authorize",
                "group-recheck",
                "commit"
            ]
        );
        let revoked = Fake {
            events: RefCell::new(vec![]),
            checks: Cell::new(0),
            revoked: true,
        };
        assert_eq!(append(&revoked), Err(Error::Forbidden));
        assert_eq!(revoked.events.borrow().last(), Some(&"rollback"));
    }
    #[test]
    fn revoked_group_permission_rolls_back_before_commit() {
        let tx = Fake {
            events: RefCell::new(vec![]),
            checks: Cell::new(0),
            revoked: true,
        };
        let input = Input {
            purpose: "group".into(),
            group_id: Some(12),
            title: "hello".into(),
        };
        assert_eq!(
            run(
                &tx,
                1,
                "af9da41c-7296-4f51-91f4-141f5c6e3c01",
                Some(input),
                &ModerationPolicy::new("", "")
            ),
            Err(Error::Forbidden)
        );
        assert_eq!(
            *tx.events.borrow(),
            vec![
                "schema",
                "authorize",
                "insert",
                "read",
                "authorize",
                "rollback"
            ]
        );
    }
    #[test]
    fn group_creation_checks_permission_twice_before_commit() {
        let tx = Fake {
            events: RefCell::new(vec![]),
            checks: Cell::new(0),
            revoked: false,
        };
        let input = Input {
            purpose: "group".into(),
            group_id: Some(12),
            title: "hello".into(),
        };
        assert!(run(
            &tx,
            1,
            "af9da41c-7296-4f51-91f4-141f5c6e3c01",
            Some(input),
            &ModerationPolicy::new("", "")
        )
        .is_ok());
        assert_eq!(
            *tx.events.borrow(),
            vec![
                "schema",
                "authorize",
                "insert",
                "read",
                "authorize",
                "commit"
            ]
        );
    }
    #[test]
    fn malformed_inputs_never_reach_storage() {
        let tx = Fake {
            events: RefCell::new(vec![]),
            checks: Cell::new(0),
            revoked: false,
        };
        let policy = ModerationPolicy::new("", "");
        let input = Input {
            purpose: "group".into(),
            group_id: None,
            title: "".into(),
        };
        assert_eq!(
            run(
                &tx,
                1,
                "af9da41c-7296-4f51-91f4-141f5c6e3c01",
                Some(input),
                &policy
            ),
            Err(Error::Invalid)
        );
        assert_eq!(run(&tx, 1, "invalid", None, &policy), Err(Error::NotFound));
        assert_eq!(
            run(
                &tx,
                0,
                "af9da41c-7296-4f51-91f4-141f5c6e3c01",
                None,
                &policy
            ),
            Err(Error::Invalid)
        );
        assert!(tx.events.borrow().is_empty());
    }
    #[test]
    fn input_limits_utf16_title_and_normalizes_policy() {
        let mut input = Input {
            purpose: "writing".into(),
            group_id: None,
            title: format!("  {}  ", "😀".repeat(100)),
        };
        assert_eq!(
            validate(input.clone())
                .unwrap()
                .title
                .encode_utf16()
                .count(),
            200
        );
        input.title.push('a');
        assert!(matches!(validate(input), Err(Error::Invalid)));
        let policy = ModerationPolicy::new(" YES ", " Alice, BOB ");
        assert!(
            policy.allow_all
                && policy.accounts.contains("alice")
                && policy.accounts.contains("bob")
        );
        assert!(ModerationPolicy::new("", "").accounts.is_empty());
    }
}
