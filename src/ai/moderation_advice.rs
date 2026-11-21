use super::{
    conversation_store::{AiOperation, AssistantInput, Error as StoreError, ModerationPolicy},
    model_config::ModelRouter,
    public_terms_authority, public_terms_source,
    transport::{CredentialResolver, Transport, TransportError},
};
use crate::{
    auth::{login::js_trim, sessions::SessionRepository},
    db::{
        oracle::{BindMap, bind_refs, bind_values},
        value::DbValue,
    },
};
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
    queries: HashMap<String, String>,
    system: String,
    response_schema: Value,
}
fn contract() -> &'static Contract {
    static CONTRACT: OnceLock<Contract> = OnceLock::new();
    CONTRACT.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../../contracts/requirements/ai-moderation-advice.json"
        ))
        .expect("valid moderation advice contract")
    })
}
fn catalog() -> &'static Value {
    static CATALOG: OnceLock<Value> = OnceLock::new();
    CATALOG.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../../contracts/requirements/ai-public-terms-catalog.json"
        ))
        .expect("valid rules catalog JSON")
    })
}
#[derive(Clone)]
pub struct Request {
    pub kind: String,
    pub id: i64,
    pub sequence: i64,
    pub locale: String,
    pub skill_id: Option<&'static str>,
}
fn valid_id(id: i64) -> bool {
    (1..=999_999_999_999_999).contains(&id)
}
fn integer(value: &Value) -> Option<i64> {
    let n = value.as_f64()?;
    ((0.0..=999_999_999_999_999.0).contains(&n) && n.fract() == 0.0).then_some(n as i64)
}
impl Request {
    pub fn parse(raw: &[u8]) -> Option<Self> {
        let data: Value = serde_json::from_slice(raw).ok()?;
        let body = data.as_object()?;
        let skill_id = match body.get("skill_id") {
            None => None,
            Some(skill) if skill.as_str() == Some("moderation-advice") => Some("moderation-advice"),
            _ => return None,
        };
        let field_count = if skill_id.is_some() { 5 } else { 4 };
        if body.len() != field_count
            || super::knowledge_search_body::has_too_many_members(raw, field_count)
        {
            return None;
        }
        let kind = data["target_type"].as_str()?;
        let locale = data["locale"].as_str()?;
        let id = integer(&data["target_id"]).filter(|id| valid_id(*id))?;
        let sequence = integer(&data["expected_sequence"]).filter(|n| *n < 9_999_999_999)?;
        (contract().queries.contains_key(kind) && matches!(locale, "zh" | "en")).then(|| Self {
            kind: kind.into(),
            id,
            sequence,
            locale: locale.into(),
            skill_id,
        })
    }
}

#[derive(Clone, Deserialize, Serialize)]
pub struct Target {
    #[serde(rename = "target_type")]
    pub kind: String,
    #[serde(rename = "target_id")]
    pub id: i64,
    pub post_id: i64,
    pub group_id: Option<i64>,
    pub digest: String,
}
impl Target {
    fn valid(&self) -> bool {
        contract().queries.contains_key(&self.kind)
            && valid_id(self.id)
            && valid_id(self.post_id)
            && (!matches!(self.kind.as_str(), "post" | "group_post") || self.id == self.post_id)
            && self.kind.starts_with("group_") == self.group_id.is_some()
            && self.group_id.is_none_or(valid_id)
    }
}
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
pub struct Opinion {
    pub risk: String,
    pub reason: String,
    pub recommendation: String,
    pub rule_ids: Vec<i64>,
}
fn parse_opinion(raw: &str, locale: &str) -> Option<Opinion> {
    let value: Value = serde_json::from_str(raw).ok()?;
    if value.as_object()?.len() != 4
        || raw.len() > 4096
        || super::knowledge_search_body::has_too_many_members(raw.as_bytes(), 4)
    {
        return None;
    }
    let opinion = Opinion {
        risk: value["risk"].as_str()?.into(),
        reason: value["reason"].as_str()?.into(),
        recommendation: value["recommendation"].as_str()?.into(),
        rule_ids: value["rule_ids"]
            .as_array()?
            .iter()
            .map(integer)
            .collect::<Option<_>>()?,
    };
    valid_opinion(&opinion, locale).then_some(opinion)
}
fn valid_opinion(value: &Opinion, locale: &str) -> bool {
    let allowed = match locale {
        "zh" => 1..=4,
        "en" => 5..=8,
        _ => return false,
    };
    let mut seen = HashSet::new();
    let permitted = |field: &str, value: &str| {
        contract().response_schema["properties"][field]["enum"]
            .as_array()
            .is_some_and(|items| items.iter().any(|item| item.as_str() == Some(value)))
    };
    permitted("risk", &value.risk)
        && permitted("recommendation", &value.recommendation)
        && (value.risk != "none" || value.recommendation != "consider_removal")
        && !js_trim(&value.reason).is_empty()
        && value.reason.len() <= 1200
        && (1..=4).contains(&value.rule_ids.len())
        && value
            .rule_ids
            .iter()
            .all(|id| allowed.contains(id) && seen.insert(*id))
}
#[derive(Clone, Deserialize, Serialize)]
pub struct AdviceRecord {
    pub version: u8,
    pub target: Target,
    pub locale: String,
    pub terms_digest: String,
    pub terms_generation: i64,
    pub skill_generation: i64,
    pub advice: Opinion,
}
pub fn decode_record(content: &str) -> Option<AdviceRecord> {
    let record: AdviceRecord = serde_json::from_str(content).ok()?;
    let digest_ok = |digest: &str| {
        digest.len() == 64
            && digest
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    };
    (record.version == 1
        && record.target.valid()
        && digest_ok(&record.target.digest)
        && valid_id(record.terms_generation)
        && valid_id(record.skill_generation)
        && digest_ok(&record.terms_digest)
        && valid_opinion(&record.advice, &record.locale))
    .then_some(record)
}
fn target_digest(target: &Target, content: &str) -> String {
    let mut hash = Sha256::new();
    for field in [
        "moderation-target-v1",
        &target.kind,
        &target.id.to_string(),
        &target.post_id.to_string(),
        &target
            .group_id
            .map(|group| group.to_string())
            .unwrap_or_default(),
        content,
    ] {
        hash.update(format!("{}:", field.len()));
        hash.update(field);
    }
    hex::encode(hash.finalize())
}
#[derive(Serialize, Deserialize)]
pub struct Rule {
    pub id: i64,
    pub version: String,
    pub title: String,
    pub blocks: Vec<String>,
}
#[derive(Serialize, Deserialize)]
pub struct Material {
    pub target: Target,
    pub content: String,
    pub terms_digest: String,
    pub terms_generation: i64,
    pub rules: Vec<Rule>,
}
pub fn read_material(
    conn: &oracle::Connection,
    actor: i64,
    request: &Request,
    lock: bool,
) -> Result<Option<Material>, StoreError> {
    let query = contract()
        .queries
        .get(&request.kind)
        .ok_or(StoreError::Invalid)?;
    let values = bind_values(BindMap::from([
        ("actor_id".into(), DbValue::I64(actor)),
        ("target_id".into(), DbValue::I64(request.id)),
    ]));
    let mut rows = conn
        .query_named(query, &bind_refs(&values))
        .map_err(|_| StoreError::Store)?;
    let Some(row) = rows.next().transpose().map_err(|_| StoreError::Store)? else {
        return Ok(None);
    };
    let mut target = Target {
        kind: request.kind.clone(),
        id: request.id,
        post_id: row.get("POST_ID").map_err(|_| StoreError::Store)?,
        group_id: row.get("GROUP_ID").map_err(|_| StoreError::Store)?,
        digest: String::new(),
    };
    if !target.valid() {
        return Err(StoreError::Store);
    }
    let length: Option<i64> = row.get("TEXT_LENGTH").map_err(|_| StoreError::Store)?;
    let content: Option<String> = row.get("CONTENT").map_err(|_| StoreError::Store)?;
    let Some(content) = content.filter(|text| {
        text.len() <= 4000
            && !js_trim(text).is_empty()
            && length.is_some_and(|n| (1..=1000).contains(&n))
    }) else {
        return Ok(None);
    };
    drop(rows);
    target.digest = target_digest(&target, &content);
    let authority = public_terms_authority::read(
        &public_terms_authority::OracleReader(conn, lock),
        actor,
        catalog(),
    )
    .map_err(|_| StoreError::SchemaUnavailable)?;
    let rules = public_terms_source::parse(catalog())
        .map_err(|_| StoreError::SchemaUnavailable)?
        .into_iter()
        .filter(|rule| rule.locale == request.locale)
        .map(|rule| Rule {
            id: rule.id,
            version: rule.version,
            title: rule.title,
            blocks: rule.blocks,
        })
        .collect();
    Ok(Some(Material {
        target,
        content,
        terms_digest: authority.digest,
        terms_generation: authority.generation,
        rules,
    }))
}

pub fn current_advice(
    conn: &oracle::Connection,
    actor: i64,
    record: &AdviceRecord,
    lock: bool,
) -> Result<Value, StoreError> {
    let request = Request {
        kind: record.target.kind.clone(),
        id: record.target.id,
        sequence: 0,
        locale: record.locale.clone(),
        skill_id: None,
    };
    let current = read_material(conn, actor, &request, lock)?.ok_or(StoreError::Conflict)?;
    if current.target.digest != record.target.digest
        || current.terms_digest != record.terms_digest
        || current.terms_generation != record.terms_generation
    {
        return Err(StoreError::Conflict);
    }
    let rules: Vec<_> = current
        .rules
        .into_iter()
        .filter(|rule| record.advice.rule_ids.contains(&rule.id))
        .map(|rule| json!({"kind":"terms","id":rule.id,"version":rule.version}))
        .collect();
    Ok(json!({
        "risk":record.advice.risk,"reason":record.advice.reason,"recommendation":record.advice.recommendation,
        "rule_ids":record.advice.rule_ids,"rules":rules,"target":{
            "kind":record.target.kind,"id":record.target.id,"post_id":record.target.post_id,"group_id":record.target.group_id
        }
    }))
}

#[derive(Serialize, Deserialize)]
pub struct Loaded {
    pub material: Option<Material>,
    pub generation: i64,
}
#[derive(Debug)]
pub enum Error {
    Unavailable,
    Store(StoreError),
    Quota(super::model_quota::QuotaError),
}

pub async fn generate(
    repository: &dyn SessionRepository,
    actor: u64,
    id: &str,
    policy: ModerationPolicy,
    settings: &super::writing::Settings,
    request: Request,
    cancel: Option<watch::Receiver<bool>>,
    quota: Option<&super::model_quota::AiModelQuota>,
) -> Result<Option<Value>, Error> {
    let check_cancel = || {
        if cancel.as_ref().is_some_and(|s| *s.borrow()) {
            Err(Error::Unavailable)
        } else {
            Ok(())
        }
    };
    check_cancel()?;
    let loaded = repository
        .ai_conversation(
            actor,
            AiOperation::ModerationAdviceLoad {
                id: id.into(),
                request: request.clone(),
            },
            policy.clone(),
        )
        .await
        .map_err(|_| Error::Unavailable)?
        .map_err(Error::Store)?;
    let loaded: Loaded = serde_json::from_value(loaded).map_err(|_| Error::Unavailable)?;
    let mut audit = super::run_audit::AiRunAudit::new("moderation_advice", loaded.generation);
    if request.skill_id.is_some() {
        audit.skill_selection = "explicit";
    }
    let result = async {
        check_cancel()?;
        let Some(material) = loaded.material else {
            return Ok(None);
        };
        audit.stage = "configuration";
        let config = settings.configuration().await.ok_or(Error::Unavailable)?;
        if config.is_empty() || config.len() > 65536 {
            return Err(Error::Unavailable);
        }
        let model = ModelRouter::from_json(&config)
            .and_then(|r| r.select("moderation", &["structured-output"]))
            .map_err(|_| Error::Unavailable)?;
        audit.config_revision = model.configuration_revision;
        let prompt=json!({"target_type":request.kind,"locale":request.locale,"content":material.content,"rules":material.rules}).to_string();
        let contract = contract();
        let budget =
            (i64::from(model.context_window_tokens) - i64::from(model.max_output_tokens) - 512)
                .min(16384);
        if (prompt.len() + contract.system.len() + contract.response_schema.to_string().len() + 64)
            as i64
            > budget
        {
            return Err(Error::Unavailable);
        }
        let resolver: CredentialResolver = Arc::new(|reference| {
            std::env::var(reference).map_err(|_| TransportError("MISSING_CREDENTIAL"))
        });
        let transport = Transport::new(Some(resolver), None).map_err(|_| Error::Unavailable)?;
        let input = json!({"responseSchema":contract.response_schema,"messages":[
            {"role":"system","content":contract.system},{"role":"user","content":prompt}
        ]});
        check_cancel()?;
        audit.stage = "quota";
        super::model_quota::require(quota, actor, 1).await.map_err(Error::Quota)?;
        check_cancel()?;
        audit.stage = "inference";
        let result = transport
            .infer(&model, &input, cancel.clone())
            .await
            .map_err(|_| Error::Unavailable)?;
        check_cancel()?;
        if result.finish_reason != "stop" || !result.tool_calls.is_empty() {
            return Err(Error::Unavailable);
        }
        let advice = parse_opinion(&result.text, &request.locale).ok_or(Error::Unavailable)?;
        if advice
            .rule_ids
            .iter()
            .any(|id| !material.rules.iter().any(|rule| rule.id == *id))
        {
            return Err(Error::Unavailable);
        }
        let record = AdviceRecord {
            version: 1,
            target: material.target,
            locale: request.locale,
            terms_digest: material.terms_digest,
            terms_generation: material.terms_generation,
            skill_generation: loaded.generation,
            advice,
        };
        audit.stage = "persist";
        let saved = repository
            .ai_conversation(
                actor,
                AiOperation::ModerationAdviceSave {
                    id: id.into(),
                    record,
                    cancel: cancel.clone(),
                    input: AssistantInput {
                        content: String::new(),
                        expected_sequence: request.sequence,
                        model_id: model.profile_id,
                        model_version: model.model_version,
                        config_revision: model.configuration_revision as i64,
                    },
                },
                policy,
            )
            .await
            .map_err(|_| Error::Unavailable)?
            .map_err(Error::Store)?;
        Ok(Some(saved))
    }
    .await;
    audit.finish(&result, check_cancel().is_err(), |error| match error {
        Error::Quota(error) => Some(*error),
        _ => None,
    });
    result
}
