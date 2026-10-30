//! Versioned knowledge answer storage and current-source checks.
use super::{
    knowledge_citations,
    knowledge_source::{self, Candidate, Source},
    knowledge_turn::TurnResult,
};
use serde_json::{json, Value};
use std::collections::HashSet;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HistoryError {
    Invalid,
    SourceChanged,
    Store,
}
pub fn encode(answer: &str, sources: &[Candidate]) -> Result<String, HistoryError> {
    if sources.is_empty()
        || knowledge_source::validate(1, sources).is_err()
        || crate::auth::login::js_trim(answer).is_empty()
        || answer.len() > 65536
    {
        return Err(HistoryError::Invalid);
    }
    let encoded = serde_json::to_string(&json!({"version":1,"answer":answer,"sources":sources}))
        .map_err(|_| HistoryError::Invalid)?;
    if encoded.len() > 65536 {
        return Err(HistoryError::Invalid);
    }
    Ok(encoded)
}
pub fn restore(
    encoded: &str,
    hydrate: impl FnOnce(&[Candidate]) -> Result<Vec<Source>, HistoryError>,
) -> Result<TurnResult, HistoryError> {
    if encoded.len() > 65536 {
        return Err(HistoryError::Invalid);
    }
    let value: Value = serde_json::from_str(encoded).map_err(|_| HistoryError::Invalid)?;
    let body = value
        .as_object()
        .filter(|o| o.len() == 3 && o.get("version").and_then(Value::as_f64) == Some(1.0))
        .ok_or(HistoryError::Invalid)?;
    let answer = body
        .get("answer")
        .and_then(Value::as_str)
        .ok_or(HistoryError::Invalid)?;
    let raw = body
        .get("sources")
        .and_then(Value::as_array)
        .filter(|s| !s.is_empty() && s.len() <= 20)
        .ok_or(HistoryError::Invalid)?;
    let mut candidates = Vec::with_capacity(raw.len());
    for value in raw {
        let item = value
            .as_object()
            .filter(|o| o.len() == 3)
            .ok_or(HistoryError::Invalid)?;
        let kind = item
            .get("kind")
            .and_then(Value::as_str)
            .ok_or(HistoryError::Invalid)?;
        let id = item
            .get("id")
            .and_then(Value::as_f64)
            .filter(|n| *n >= 1.0 && *n <= 999_999_999_999_999.0 && n.fract() == 0.0)
            .ok_or(HistoryError::Invalid)? as i64;
        let version = item
            .get("version")
            .and_then(Value::as_str)
            .ok_or(HistoryError::Invalid)?;
        candidates.push(Candidate {
            kind: kind.into(),
            id,
            version: version.into(),
        });
    }
    knowledge_source::validate(1, &candidates).map_err(|_| HistoryError::Invalid)?;
    let answer = knowledge_citations::parse(
        &json!({"answer":answer,"citations":raw}).to_string(),
        &candidates,
    )
    .map_err(|_| HistoryError::Invalid)?;
    let rows = hydrate(&answer.sources)?;
    if rows.len() != answer.sources.len() {
        return Err(HistoryError::SourceChanged);
    }
    let expected: HashSet<_> = answer
        .sources
        .iter()
        .map(|s| (s.kind.as_str(), s.id, s.version.as_str()))
        .collect();
    let mut seen = HashSet::new();
    for row in &rows {
        let key = (row.kind.as_str(), row.id, row.version.as_str());
        if !expected.contains(&key) || !seen.insert(key) {
            return Err(HistoryError::SourceChanged);
        }
    }
    Ok(answer)
}
