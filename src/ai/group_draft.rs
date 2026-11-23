use super::{
    conversation_store::{AiOperation, AssistantInput, Error as StoreError, ModerationPolicy},
    group_evidence::{self, EvidenceQuery, GroupEvidence},
    model_config::ModelRouter,
    model_quota::{self, AiModelQuota, QuotaError},
    sentiment::{self, Label, SentimentFlow, Signal},
    transport::{CredentialResolver, ToolProposal, Transport, TransportError},
};
use crate::auth::{login::js_trim, sessions::SessionRepository};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    sync::{Arc, OnceLock},
};
use tokio::sync::watch;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Contract {
    system: String,
    activity_plan_instruction: String,
    lookback_days: HashMap<String, i64>,
    required_tool: String,
    tools: Vec<ToolDefinition>,
}

#[derive(Deserialize, Serialize)]
struct ToolDefinition {
    name: String,
    description: String,
    parameters: Value,
}

fn contract() -> &'static Contract {
    static CONTRACT: OnceLock<Contract> = OnceLock::new();
    CONTRACT.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../../contracts/requirements/ai-group-draft.json"
        ))
        .expect("valid group draft contract")
    })
}

#[derive(Clone)]
pub struct Request {
    pub kind: String,
    pub expected_sequence: i64,
    pub explicit_skill: bool,
    pub(crate) search_term: Option<String>,
}

impl Request {
    pub fn parse(bytes: &[u8]) -> Option<Self> {
        let value: Value = serde_json::from_slice(bytes).ok()?;
        let fields = value.as_object()?;
        let explicit_skill = match fields.get("skill_id") {
            None => false,
            Some(value) if value.as_str() == Some("group-brief") => true,
            Some(_) => return None,
        };
        let search_term = match fields.get("search_term") {
            None => None,
            Some(value) => Some(
                value
                    .as_str()
                    .filter(|term| valid_search_term(term))?
                    .to_owned(),
            ),
        };
        if fields.len() != 2 + usize::from(explicit_skill) + usize::from(search_term.is_some())
            || super::knowledge_search_body::has_too_many_members(bytes, fields.len())
        {
            return None;
        }
        let kind = fields.get("kind")?.as_str()?;
        let sequence = fields.get("expected_sequence")?.as_f64()?;
        if !contract().lookback_days.contains_key(kind)
            || !(0.0..9_999_999_999.0).contains(&sequence)
            || sequence.fract() != 0.0
        {
            return None;
        }
        Some(Self {
            kind: kind.into(),
            expected_sequence: sequence as i64,
            explicit_skill,
            search_term,
        })
    }
    pub fn lookback(&self) -> Result<i64, StoreError> {
        contract()
            .lookback_days
            .get(&self.kind)
            .copied()
            .ok_or(StoreError::Invalid)
    }
}

#[derive(Clone, Deserialize, Serialize)]
pub struct DraftRecord {
    pub version: u8,
    pub kind: String,
    pub window_end: String,
    pub source_digest: String,
    pub example_count: usize,
    pub skill_generation: i64,
    pub draft: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tools_used: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub search_term: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub match_excerpt: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sentiment_source_digest: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct GroupSource {
    pub kind: String,
    pub source_id: i64,
    pub post_id: i64,
}

pub fn evidence_digest(data: &GroupEvidence) -> String {
    evidence_digest_for_examples(data, data.examples.len())
}

fn evidence_digest_for_examples(data: &GroupEvidence, limit: usize) -> String {
    let mut hash = Sha256::new();
    let mut add = |text: &str| {
        hash.update(format!("{}:", text.len()));
        hash.update(text);
    };
    for field in [
        "group-evidence-v1",
        &data.window_start,
        &data.window_end,
        &data.posts_count.to_string(),
        &data.comments_count.to_string(),
    ] {
        add(field);
    }
    for row in data.examples.iter().take(limit) {
        for field in [
            &row.kind,
            &row.source_id.to_string(),
            &row.post_id.to_string(),
            &row.excerpt,
        ] {
            add(field);
        }
    }
    hex::encode(hash.finalize())
}

fn sentiment_digest(current: &GroupEvidence, previous: &GroupEvidence) -> String {
    let limit = sentiment::sample_per_window();
    let joined = format!(
        "{}\n{}",
        evidence_digest_for_examples(current, limit),
        evidence_digest_for_examples(previous, limit)
    );
    hex::encode(Sha256::digest(joined.as_bytes()))
}

pub fn decode_record(content: &str) -> Option<DraftRecord> {
    let draft: DraftRecord = serde_json::from_str(content).ok()?;
    (draft.version == 1
        && contract().lookback_days.contains_key(&draft.kind)
        && group_evidence::valid_timestamp(&draft.window_end)
        && draft.source_digest.len() == 64
        && (1..=8).contains(&draft.example_count)
        && draft
            .source_digest
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        && draft.skill_generation > 0
        && !draft.draft.is_empty()
        && draft.draft.len() <= 8192
        && draft.search_term.as_deref().is_none_or(valid_search_term)
        && (!draft.match_excerpt || draft.search_term.is_some())
        && draft
            .tools_used
            .as_ref()
            .is_none_or(|names| valid_tools(names, true))
        && draft
            .sentiment_source_digest
            .as_deref()
            .is_none_or(|digest| {
                digest.len() == 64
                    && digest
                        .bytes()
                        .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
            })
        && draft.sentiment_source_digest.is_some()
            == draft
                .tools_used
                .as_ref()
                .is_some_and(|names| names.iter().any(|name| name == sentiment::TOOL_NAME)))
    .then_some(draft)
}

fn valid_search_term(term: &str) -> bool {
    !term.is_empty()
        && term.len() <= 256
        && js_trim(term) == term
        && !term.chars().any(|ch| ch < '\u{20}' || ch == '\u{7f}')
}

fn valid_tools(names: &[String], sentiment_enabled: bool) -> bool {
    let spec = contract();
    names.len() <= spec.tools.len() + usize::from(sentiment_enabled)
        && names.contains(&spec.required_tool)
        && names.iter().collect::<HashSet<_>>().len() == names.len()
        && names.iter().all(|name| {
            spec.tools.iter().any(|tool| &tool.name == name)
                || sentiment_enabled && name == sentiment::TOOL_NAME
        })
}

pub(super) fn tool_grants_match(names: &[String]) -> bool {
    contract()
        .tools
        .iter()
        .all(|tool| names.contains(&tool.name))
}

pub fn read_evidence(
    conn: &oracle::Connection,
    actor: i64,
    group: i64,
    query: EvidenceQuery<'_>,
) -> Result<GroupEvidence, StoreError> {
    group_evidence::read_group_evidence(conn, actor, group, query).map_err(|error| match error {
        group_evidence::Error::Invalid => StoreError::Invalid,
        group_evidence::Error::Forbidden => StoreError::Forbidden,
        group_evidence::Error::Store => StoreError::Store,
    })
}

pub(super) fn read_previous_evidence<'a>(
    conn: &oracle::Connection,
    actor: i64,
    group: i64,
    current: &'a GroupEvidence,
    mut query: EvidenceQuery<'a>,
) -> Result<GroupEvidence, StoreError> {
    query.window_end = Some(&current.window_start);
    read_evidence(conn, actor, group, query)
}

pub fn recheck(
    conn: &oracle::Connection,
    actor: i64,
    group: i64,
    draft: &DraftRecord,
) -> Result<GroupEvidence, StoreError> {
    let days = contract()
        .lookback_days
        .get(&draft.kind)
        .copied()
        .ok_or(StoreError::Invalid)?;
    let mut data = read_evidence(
        conn,
        actor,
        group,
        EvidenceQuery {
            lookback_days: days,
            window_end: Some(&draft.window_end),
            search_term: draft.search_term.as_deref(),
            match_excerpt: draft.match_excerpt,
        },
    )?;
    if let Some(ref expected) = draft.sentiment_source_digest {
        let previous = read_previous_evidence(
            conn,
            actor,
            group,
            &data,
            EvidenceQuery {
                lookback_days: days,
                window_end: None,
                search_term: draft.search_term.as_deref(),
                match_excerpt: draft.match_excerpt,
            },
        )?;
        if sentiment_digest(&data, &previous) != *expected {
            return Err(StoreError::Conflict);
        }
    }
    data.examples.truncate(draft.example_count);
    if evidence_digest(&data) != draft.source_digest {
        return Err(StoreError::Conflict);
    }
    Ok(data)
}

#[derive(Serialize, Deserialize)]
pub struct Loaded {
    pub evidence: GroupEvidence,
    pub generation: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sentiment_previous: Option<GroupEvidence>,
}

#[derive(Debug)]
pub enum Error {
    Unavailable,
    Store(StoreError),
    Quota(QuotaError),
}

async fn load(
    repository: &dyn SessionRepository,
    actor: u64,
    id: &str,
    policy: &ModerationPolicy,
    request: &Request,
    sentiment_requested: bool,
) -> Result<Loaded, Error> {
    let value = repository
        .ai_conversation(
            actor,
            AiOperation::GroupDraftLoad {
                id: id.into(),
                request: request.clone(),
                sentiment_requested,
            },
            policy.clone(),
        )
        .await
        .map_err(|_| Error::Unavailable)?
        .map_err(Error::Store)?;
    serde_json::from_value(value).map_err(|_| Error::Unavailable)
}

fn followup(
    messages: &[Value],
    calls: &[&ToolProposal],
    evidence: &GroupEvidence,
    sentiment: Option<&Value>,
) -> Value {
    let mut messages = messages.to_vec();
    messages.push(json!({"role":"assistant","content":"","toolCalls":calls}));
    for call in calls {
        let data = if call.name == contract().required_tool {
            json!({"window_start":evidence.window_start,"window_end":evidence.window_end,"examples":evidence.examples})
        } else if call.name == sentiment::TOOL_NAME {
            sentiment
                .cloned()
                .unwrap_or_else(|| json!({"status":"unavailable"}))
        } else {
            json!({"window_start":evidence.window_start,"window_end":evidence.window_end,
                "posts_count":evidence.posts_count,"comments_count":evidence.comments_count})
        };
        messages
            .push(json!({"role":"tool","content":encode_group_input(&data),"toolCallId":call.id}));
    }
    json!({"messages":messages})
}

async fn sentiment_summary(
    client: &SentimentFlow,
    current: &GroupEvidence,
    previous: &GroupEvidence,
) -> Option<Value> {
    if current.window_start != previous.window_end {
        return None;
    }
    let samples = |window: &GroupEvidence| {
        window
            .examples
            .iter()
            .take(sentiment::sample_per_window())
            .filter(|example| !js_trim(&example.excerpt).is_empty())
            .count()
    };
    let current_size = samples(current);
    let texts: Vec<_> = [current, previous]
        .into_iter()
        .flat_map(|window| {
            window
                .examples
                .iter()
                .take(sentiment::sample_per_window())
                .map(|example| example.excerpt.as_str())
                .filter(|text| !js_trim(text).is_empty())
        })
        .collect();
    let results = client.predict(&texts).await?;
    let (now, before) = results.split_at(current_size);
    fn aggregate(window: &GroupEvidence, predictions: &[Signal]) -> (Value, Option<f64>) {
        let count = |label| {
            predictions
                .iter()
                .filter(|prediction| prediction.label == label)
                .count()
        };
        let negative = count(Label::Negative);
        let share = (!predictions.is_empty()).then(|| negative as f64 / predictions.len() as f64);
        (
            json!({"window_start":window.window_start,"window_end":window.window_end,"sample_size":predictions.len(),
            "positive":count(Label::Positive),"neutral":count(Label::Neutral),"negative":negative}),
            share,
        )
    }
    let (current, now_share) = aggregate(current, now);
    let (previous, before_share) = aggregate(previous, before);
    Some(
        json!({"status":"available","current":current,"previous":previous,
        "negative_share_change":now_share.zip(before_share).map(|(current, previous)| current - previous)}),
    )
}

fn encode_group_input(value: &Value) -> String {
    value
        .to_string()
        .replace('\u{2028}', "\\u2028")
        .replace('\u{2029}', "\\u2029")
}

pub async fn generate(
    repository: &dyn SessionRepository,
    actor: u64,
    id: &str,
    policy: ModerationPolicy,
    settings: &super::writing::Settings,
    mut request: Request,
    cancel: Option<watch::Receiver<bool>>,
    quota: Option<&AiModelQuota>,
    sentiment_client: Option<&SentimentFlow>,
) -> Result<Option<Value>, Error> {
    let check_cancelled = || {
        if cancel.as_ref().is_some_and(|s| *s.borrow()) {
            Err(Error::Unavailable)
        } else {
            Ok(())
        }
    };
    check_cancelled()?;
    let initial = load(repository, actor, id, &policy, &request, false).await?;
    let mut audit = super::run_audit::AiRunAudit::new("group_draft", initial.generation);
    if request.explicit_skill {
        audit.skill_selection = "explicit";
    }
    let result = async {
        check_cancelled()?;
        if initial.evidence.examples.is_empty() {
            return Ok(None);
        }
        audit.stage = "configuration";
        let configuration = settings.configuration().await.ok_or(Error::Unavailable)?;
        if configuration.is_empty() || configuration.len() > 65536 {
            return Err(Error::Unavailable);
        }
        let selection = ModelRouter::from_json(&configuration)
            .and_then(|r| r.select("agent", &["tools"]))
            .map_err(|_| Error::Unavailable)?;
        audit.config_revision = selection.configuration_revision;
        let system = if request.kind == "activity_plan" {
            format!(
                "{}\n{}",
                contract().system,
                contract().activity_plan_instruction
            )
        } else {
            contract().system.clone()
        };
        let budget = (i64::from(selection.context_window_tokens)
            - i64::from(selection.max_output_tokens)
            - 512)
            .min(16384);
        let mut task = json!({"kind":request.kind});
        if let Some(term) = &request.search_term {
            task["search_term"] = json!(term);
        }
        let base_messages = [
            json!({"role":"system","content":system}),
            json!({"role":"user","content":encode_group_input(&task)}),
        ];
        let fits = |packet: &Value| (encode_group_input(packet).len() + 64) as i64 <= budget;
        let mut messages = base_messages.clone();
        let mut intro = json!({"messages":messages,"tools":contract().tools});
        if !fits(&intro) {
            return Err(Error::Unavailable);
        }
        let mut sentiment_advertised = false;
        if sentiment_client.is_some() {
            let mut optional = intro.clone();
            optional["tools"].as_array_mut().ok_or(Error::Unavailable)?.push(sentiment::tool().clone());
            let instruction = "需要了解样本情绪趋势时，可同时以空对象请求 community_sentiment_summary。情绪统计只反映已采样公开讨论。工具不可用时不推断情绪趋势。";
            let extended_system = json!(format!("{system}\n{instruction}"));
            optional["messages"][0]["content"] = extended_system.clone();
            if fits(&optional) {
                messages[0]["content"] = extended_system;
                intro = optional;
                sentiment_advertised = true;
            }
        }
        let resolver: CredentialResolver = Arc::new(|reference| {
            std::env::var(reference).map_err(|_| TransportError("MISSING_CREDENTIAL"))
        });
        let transport = Transport::new(Some(resolver), None).map_err(|_| Error::Unavailable)?;
        check_cancelled()?;
        audit.stage = "quota";
        model_quota::require(quota, actor, 2)
            .await
            .map_err(Error::Quota)?;
        check_cancelled()?;
        audit.stage = "proposal";
        let proposal = transport
            .infer(&selection, &intro, cancel.clone())
            .await
            .map_err(|_| Error::Unavailable)?;
        check_cancelled()?;
        let mut names: Vec<_> = proposal
            .tool_calls
            .iter()
            .map(|call| call.name.clone())
            .collect();
        if proposal.finish_reason != "tool-calls" || !valid_tools(&names, sentiment_advertised) {
            return Err(Error::Unavailable);
        }
        for call in &proposal.tool_calls {
            if call.arguments.is_empty() || call.name == sentiment::TOOL_NAME {
                continue;
            }
            if call.name != contract().required_tool || call.arguments.len() != 1 {
                return Err(Error::Unavailable);
            }
            let term = call
                .arguments
                .get("search_term")
                .and_then(Value::as_str)
                .filter(|term| {
                    valid_search_term(term)
                        && request
                            .search_term
                            .as_deref()
                            .is_none_or(|expected| expected == *term)
                })
                .ok_or(Error::Unavailable)?;
            request.search_term = Some(term.to_owned());
        }
        let sentiment_client = sentiment_client.filter(|client| sentiment_advertised && client.available() && proposal.tool_calls.iter().any(|call| {
            call.name == sentiment::TOOL_NAME && call.arguments.is_empty()
        }));
        audit.stage = "evidence";
        let Loaded {
            mut evidence,
            generation,
            sentiment_previous,
        } = load(repository, actor, id, &policy, &request, sentiment_client.is_some()).await?;
        check_cancelled()?;
        if generation != initial.generation {
            return Err(Error::Store(StoreError::Conflict));
        }
        if evidence.examples.is_empty() {
            return Ok(None);
        }
        let mut sentiment_source_digest = None;
        let summary = if let Some((client, previous)) = sentiment_client.zip(sentiment_previous.as_ref()) {
            let summary = sentiment_summary(client, &evidence, previous).await;
            if summary.is_some() { sentiment_source_digest = Some(sentiment_digest(&evidence, previous)); }
            summary
        } else { None };
        check_cancelled()?;
        let mut calls = proposal.tool_calls.iter().collect::<Vec<_>>();
        let packet = loop {
            let packet = followup(&messages, &calls, &evidence, summary.as_ref());
            if fits(&packet) {
                break packet;
            }
            if sentiment_advertised {
                sentiment_advertised = false;
                sentiment_source_digest = None;
                calls.retain(|call| call.name != sentiment::TOOL_NAME);
                messages = base_messages.clone();
                continue;
            }
            if evidence.examples.len() <= 1 {
                return Err(Error::Unavailable);
            }
            evidence.examples.pop();
        };
        if sentiment_source_digest.is_none() { names.retain(|name| name != sentiment::TOOL_NAME); }
        audit.tool_count = names.len();
        audit.stage = "inference";
        let inference = transport.infer(&selection, &packet, cancel.clone());
        let result = if sentiment_source_digest.is_some() {
            super::stream_response::without_deltas(inference).await
        } else {
            inference.await
        }
        .map_err(|_| Error::Unavailable)?;
        check_cancelled()?;
        if result.finish_reason != "stop"
            || !result.tool_calls.is_empty()
            || js_trim(&result.text).is_empty()
            || result.text.len() > 8192
        {
            return Err(Error::Unavailable);
        }
        let digest = evidence_digest(&evidence);
        let draft = DraftRecord {
            version: 1,
            kind: request.kind,
            window_end: evidence.window_end,
            source_digest: digest,
            example_count: evidence.examples.len(),
            skill_generation: generation,
            draft: result.text,
            tools_used: Some(names),
            match_excerpt: request.search_term.is_some(),
            search_term: request.search_term,
            sentiment_source_digest,
        };
        audit.stage = "persist";
        let message = repository
            .ai_conversation(
                actor,
                AiOperation::GroupDraftSave {
                    id: id.into(),
                    draft,
                    cancel: cancel.clone(),
                    input: AssistantInput {
                        content: String::new(),
                        expected_sequence: request.expected_sequence,
                        model_id: selection.profile_id,
                        model_version: selection.model_version,
                        config_revision: selection.configuration_revision as i64,
                    },
                },
                policy,
            )
            .await
            .map_err(|_| Error::Unavailable)?
            .map_err(Error::Store)?;
        Ok(Some(message))
    }
    .await;
    audit.finish(&result, check_cancelled().is_err(), |error| match error {
        Error::Quota(error) => Some(*error),
        _ => None,
    });
    result
}

#[cfg(test)]
mod sentiment_tests {
    use super::super::group_evidence::EvidenceExample;
    use super::*;

    #[test]
    fn digest_covers_both_windows_and_only_the_first_four_examples() {
        let sample = |start: &str, end: &str| GroupEvidence {
            window_start: start.into(),
            window_end: end.into(),
            posts_count: 5,
            comments_count: 0,
            examples: (1..=5)
                .map(|id| EvidenceExample {
                    kind: "post".into(),
                    source_id: id,
                    post_id: id,
                    excerpt: format!("evidence-{id}"),
                })
                .collect(),
        };
        let mut current = sample("2026-11-15T00:00:00.000000", "2026-11-22T00:00:00.000000");
        let mut previous = sample("2026-11-08T00:00:00.000000", "2026-11-15T00:00:00.000000");
        let digest = sentiment_digest(&current, &previous);
        current.examples[4].excerpt = "unused".into();
        assert_eq!(sentiment_digest(&current, &previous), digest);
        previous.examples[3].excerpt = "changed".into();
        assert_ne!(sentiment_digest(&current, &previous), digest);

        let mut record = json!({"version":1,"kind":"weekly_report","window_end":current.window_end,
            "source_digest":evidence_digest(&current),"example_count":5,"skill_generation":4,"draft":"review",
            "tools_used":["public_search",sentiment::TOOL_NAME],"sentiment_source_digest":digest});
        assert!(decode_record(&record.to_string()).is_some());
        record["tools_used"] = json!(["public_search"]);
        assert!(decode_record(&record.to_string()).is_none());
    }
}
