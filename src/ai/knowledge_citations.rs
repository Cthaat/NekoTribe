//! Verify model citation identifiers against sources already checked for this turn.
use super::{
    knowledge_source::Candidate,
    knowledge_turn::{TurnError, TurnResult},
};
use serde_json::Value;
use std::collections::{HashMap, HashSet};

pub fn parse(text: &str, verified: &[Candidate]) -> Result<TurnResult, TurnError> {
    let fail = || TurnError::InvalidCitations;
    let value: Value = serde_json::from_str(text).map_err(|_| fail())?;
    let object = value
        .as_object()
        .filter(|o| o.len() == 2)
        .ok_or_else(fail)?;
    let answer = object
        .get("answer")
        .and_then(Value::as_str)
        .filter(|s| !crate::auth::login::js_trim(s).is_empty() && s.len() <= 65536)
        .ok_or_else(fail)?;
    let citations = object
        .get("citations")
        .and_then(Value::as_array)
        .filter(|a| !a.is_empty() && a.len() <= 20)
        .ok_or_else(fail)?;
    let allowed: HashMap<_, _> = verified
        .iter()
        .map(|c| ((c.kind.as_str(), c.id, c.version.as_str()), c))
        .collect();
    let mut seen = HashSet::new();
    let mut sources = Vec::new();
    for citation in citations {
        let item = citation
            .as_object()
            .filter(|o| o.len() == 3)
            .ok_or_else(fail)?;
        let kind = item
            .get("kind")
            .and_then(Value::as_str)
            .filter(|v| matches!(*v, "post" | "comment"))
            .ok_or_else(fail)?;
        let id = item
            .get("id")
            .and_then(Value::as_f64)
            .filter(|v| *v >= 1.0 && *v <= 999_999_999_999_999.0 && v.fract() == 0.0)
            .ok_or_else(fail)? as i64;
        let version = item
            .get("version")
            .and_then(Value::as_str)
            .ok_or_else(fail)?;
        let key = (kind, id, version);
        if !seen.insert(key) {
            return Err(fail());
        }
        let source = allowed.get(&key).ok_or_else(fail)?;
        sources.push((*source).clone());
    }
    Ok(TurnResult {
        answer: Some(answer.to_owned()),
        sources,
    })
}
