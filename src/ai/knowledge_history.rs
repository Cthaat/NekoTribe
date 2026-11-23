//! Versioned knowledge answer storage and current-source checks.
use super::{
    knowledge_citations,
    knowledge_source::{self, Candidate, Source},
};
use serde::Serialize;
use serde_json::{Value, json};
use std::collections::HashSet;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HistoryError {
    Forbidden,
    Invalid,
    SourceChanged,
    Store,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Citation {
    pub kind: String,
    pub id: i64,
    pub version: String,
    #[serde(skip_serializing_if = "is_zero")]
    pub post_id: i64,
    #[serde(skip_serializing_if = "is_zero")]
    pub group_id: i64,
}
fn is_zero(value: &i64) -> bool {
    *value == 0
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Restored {
    pub answer: Option<String>,
    pub sources: Vec<Candidate>,
    pub dependencies: Option<Vec<Candidate>>,
    pub citations: Vec<Citation>,
}
pub fn encode(answer: &str, sources: &[Candidate]) -> Result<String, HistoryError> {
    encode_with_dependencies(answer, sources, None)
}

pub(crate) fn encode_with_dependencies(
    answer: &str,
    sources: &[Candidate],
    dependencies: Option<&[Candidate]>,
) -> Result<String, HistoryError> {
    if sources.is_empty()
        || knowledge_source::validate(1, sources).is_err()
        || crate::auth::login::js_trim(answer).is_empty()
        || answer.len() > 65536
    {
        return Err(HistoryError::Invalid);
    }
    let value = if let Some(dependencies) = dependencies {
        validate_dependencies(dependencies, sources)?;
        json!({"version":2,"answer":answer,"sources":sources,"dependencies":dependencies})
    } else {
        json!({"version":1,"answer":answer,"sources":sources})
    };
    let encoded = serde_json::to_string(&value).map_err(|_| HistoryError::Invalid)?;
    if encoded.len() > 65536 {
        return Err(HistoryError::Invalid);
    }
    Ok(encoded)
}

pub(crate) fn validate_dependencies(
    dependencies: &[Candidate],
    sources: &[Candidate],
) -> Result<(), HistoryError> {
    if dependencies.is_empty()
        || knowledge_source::validate(1, dependencies).is_err()
        || sources.iter().any(|source| !dependencies.contains(source))
    {
        return Err(HistoryError::Invalid);
    }
    Ok(())
}

pub fn restore(
    encoded: &str,
    hydrate: impl FnOnce(&[Candidate]) -> Result<Vec<Source>, HistoryError>,
) -> Result<Restored, HistoryError> {
    if encoded.len() > 65536 {
        return Err(HistoryError::Invalid);
    }
    let value: Value = serde_json::from_str(encoded).map_err(|_| HistoryError::Invalid)?;
    let body = value.as_object().ok_or(HistoryError::Invalid)?;
    let dependencies = match body.get("version").and_then(Value::as_f64) {
        Some(1.0) if body.len() == 3 => None,
        Some(2.0) if body.len() == 4 => Some(decode_references(body.get("dependencies"))?),
        _ => return Err(HistoryError::Invalid),
    };
    let answer = body
        .get("answer")
        .and_then(Value::as_str)
        .ok_or(HistoryError::Invalid)?;
    let candidates = decode_references(body.get("sources"))?;
    let answer = knowledge_citations::parse(
        &json!({"answer":answer,"citations":candidates}).to_string(),
        &candidates,
    )
    .map_err(|_| HistoryError::Invalid)?;
    if let Some(ref dependencies) = dependencies {
        validate_dependencies(dependencies, &answer.sources)?;
    }
    let refs = dependencies.as_deref().unwrap_or(&answer.sources);
    let rows = hydrate(refs)?;
    if rows.len() != refs.len() {
        return Err(HistoryError::SourceChanged);
    }
    let expected: HashSet<_> = refs
        .iter()
        .map(|s| (s.kind.as_str(), s.id, s.version.as_str()))
        .collect();
    let mut seen = HashSet::new();
    for row in &rows {
        let key = (row.kind.as_str(), row.id, row.version.as_str());
        if !expected.contains(&key)
            || !seen.insert(key)
            || !knowledge_source::valid_location(&row.kind, row.id, row.post_id, row.group_id)
        {
            return Err(HistoryError::SourceChanged);
        }
    }
    let citations = answer
        .sources
        .iter()
        .map(|reference| {
            let row = rows
                .iter()
                .find(|row| {
                    row.kind == reference.kind
                        && row.id == reference.id
                        && row.version == reference.version
                })
                .ok_or(HistoryError::SourceChanged)?;
            Ok(Citation {
                kind: reference.kind.clone(),
                id: reference.id,
                version: reference.version.clone(),
                post_id: row.post_id,
                group_id: row.group_id,
            })
        })
        .collect::<Result<Vec<_>, HistoryError>>()?;
    Ok(Restored {
        answer: answer.answer,
        sources: answer.sources,
        dependencies,
        citations,
    })
}

fn decode_references(value: Option<&Value>) -> Result<Vec<Candidate>, HistoryError> {
    let raw = value
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
    Ok(candidates)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn restricted_history_rechecks_uncited_dependencies_without_exposing_them() {
        let sources: Vec<_> = (1..=2)
            .map(|id| Source {
                kind: "group_post".into(),
                id,
                post_id: id,
                group_id: 9_007_199_254_740_991,
                content: "live".into(),
                version: "a".repeat(64),
            })
            .collect();
        let dependencies: Vec<_> = sources
            .iter()
            .map(|source| Candidate {
                kind: source.kind.clone(),
                id: source.id,
                version: source.version.clone(),
            })
            .collect();
        let citations = &dependencies[..1];
        let encoded = encode_with_dependencies("answer", citations, Some(&dependencies)).unwrap();
        let envelope: Value = serde_json::from_str(&encoded).unwrap();
        assert_eq!(
            envelope,
            json!({"version":2,"answer":"answer","sources":citations,"dependencies":dependencies})
        );
        let result = restore(&encoded, |refs| {
            assert_eq!(refs, dependencies);
            Ok(sources.clone())
        })
        .unwrap();
        assert_eq!(result.sources, citations);
        assert_eq!(result.citations.len(), 1);
        assert_eq!(result.citations[0].group_id, 9_007_199_254_740_991);
        assert_eq!(
            result.dependencies.as_deref(),
            Some(dependencies.as_slice())
        );
        assert_eq!(
            restore(&encoded, |_| Ok(vec![sources[0].clone()])),
            Err(HistoryError::SourceChanged)
        );
        assert_eq!(
            encode_with_dependencies("answer", citations, Some(&dependencies[1..])),
            Err(HistoryError::Invalid)
        );
    }
}
