//! Bounded, untrusted conversation context for knowledge generation.
use super::knowledge_source::{self, Candidate};
use serde_json::{Value, json};
use std::collections::HashMap;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ContextError {
    Invalid,
    TooLarge,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Context {
    pub question: String,
    pub history: Vec<Value>,
    pub sources: Vec<Candidate>,
    pub snapshot: Vec<Value>,
}

/// Validate all supplied messages, then retain a contiguous recent suffix within both limits.
pub fn select(
    messages: &[Value],
    max_bytes: usize,
    max_sources: usize,
) -> Result<Context, ContextError> {
    if messages.is_empty() || messages.len() > 50 || max_sources > 20 {
        return Err(ContextError::Invalid);
    }
    let mut previous = 0;
    let mut normalized = Vec::with_capacity(messages.len());
    for message in messages {
        let seq = message
            .get("sequence_no")
            .and_then(Value::as_i64)
            .filter(|n| *n > previous && *n <= 9_999_999_999)
            .ok_or(ContextError::Invalid)?;
        previous = seq;
        let role = message
            .get("role")
            .and_then(Value::as_str)
            .filter(|s| matches!(*s, "user" | "assistant"))
            .ok_or(ContextError::Invalid)?;
        let content = message
            .get("content")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .ok_or(ContextError::Invalid)?;
        let mut item = json!({"sequence_no":seq,"role":role,"content":content});
        if role == "assistant" {
            let citations = message
                .get("citations")
                .and_then(Value::as_array)
                .filter(|a| !a.is_empty() && a.len() <= 20)
                .ok_or(ContextError::Invalid)?;
            let mut refs = Vec::new();
            let mut clean = Vec::new();
            for citation in citations {
                let kind = citation
                    .get("kind")
                    .and_then(Value::as_str)
                    .ok_or(ContextError::Invalid)?;
                let id = citation
                    .get("id")
                    .and_then(Value::as_i64)
                    .ok_or(ContextError::Invalid)?;
                let version = citation
                    .get("version")
                    .and_then(Value::as_str)
                    .ok_or(ContextError::Invalid)?;
                let post_id = if kind == "terms" {
                    if citation.get("post_id").is_some() {
                        return Err(ContextError::Invalid);
                    }
                    None
                } else {
                    let n = citation
                        .get("post_id")
                        .and_then(Value::as_i64)
                        .filter(|n| (1..=999_999_999_999_999).contains(n))
                        .ok_or(ContextError::Invalid)?;
                    Some(n)
                };
                let group_id = citation
                    .get("group_id")
                    .map(|value| {
                        value
                            .as_i64()
                            .filter(|n| *n > 0)
                            .ok_or(ContextError::Invalid)
                    })
                    .transpose()?;
                if !knowledge_source::valid_location(
                    kind,
                    id,
                    post_id.unwrap_or(0),
                    group_id.unwrap_or(0),
                ) {
                    return Err(ContextError::Invalid);
                }
                refs.push(Candidate {
                    kind: kind.into(),
                    id,
                    version: version.into(),
                });
                let mut entry = json!({"kind":kind,"id":id,"version":version});
                if let Some(post_id) = post_id {
                    entry["post_id"] = json!(post_id)
                }
                if let Some(group_id) = group_id {
                    entry["group_id"] = json!(group_id);
                }
                clean.push(entry);
            }
            knowledge_source::validate(1, &refs).map_err(|_| ContextError::Invalid)?;
            item["citations"] = Value::Array(clean);
            if let Some(value) = message.get("knowledge_dependencies") {
                let dependencies: Vec<Candidate> =
                    serde_json::from_value(value.clone()).map_err(|_| ContextError::Invalid)?;
                super::knowledge_history::validate_dependencies(&dependencies, &refs)
                    .map_err(|_| ContextError::Invalid)?;
                item["knowledge_dependencies"] = value.clone();
            }
        } else if message.get("citations").is_some()
            || message.get("knowledge_dependencies").is_some()
        {
            return Err(ContextError::Invalid);
        }
        normalized.push(item);
    }
    let last = normalized.last().ok_or(ContextError::Invalid)?;
    if last["role"] != "user" {
        return Err(ContextError::Invalid);
    }
    let question = last["content"]
        .as_str()
        .ok_or(ContextError::Invalid)?
        .to_owned();
    let mut history = Vec::new();
    let size = |h: &Vec<Value>| {
        serde_json::to_vec(&json!({"question":question,"history":h}))
            .map(|b| b.len())
            .map_err(|_| ContextError::Invalid)
    };
    if size(&history)? > max_bytes {
        return Err(ContextError::TooLarge);
    }
    let mut sources = Vec::new();
    let mut versions = HashMap::new();
    let mut first = normalized.len() - 1;
    for i in (0..first).rev() {
        let msg = &normalized[i];
        let mut next = history.clone();
        next.insert(0, json!({"role":msg["role"],"content":msg["content"]}));
        if size(&next)? > max_bytes {
            break;
        }
        let mut new = Vec::new();
        if let Some(citations) = msg
            .get("knowledge_dependencies")
            .or_else(|| msg.get("citations"))
            .and_then(Value::as_array)
        {
            for c in citations {
                let r = Candidate {
                    kind: c["kind"].as_str().unwrap_or_default().to_owned(),
                    id: c["id"].as_i64().unwrap_or_default(),
                    version: c["version"].as_str().unwrap_or_default().to_owned(),
                };
                let key = (r.kind.clone(), r.id);
                if let Some(version) = versions.get(&key) {
                    if version != &r.version {
                        return Err(ContextError::Invalid);
                    };
                    continue;
                }
                new.push(r);
            }
        }
        if sources.len() + new.len() > max_sources {
            break;
        }
        for r in new {
            versions.insert((r.kind.clone(), r.id), r.version.clone());
            sources.push(r)
        }
        history = next;
        first = i;
    }
    Ok(Context {
        question,
        history,
        sources,
        snapshot: normalized[first..].to_vec(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn selects_recent_history_and_copies_its_sources() {
        let version = "a".repeat(64);
        let messages = vec![
            json!({"sequence_no":1,"role":"user","content":"之前的问题"}),
            json!({"sequence_no":2,"role":"assistant","content":"之前的回答","citations":[{"kind":"post","id":1,"version":version,"post_id":1}]}),
            json!({"sequence_no":3,"role":"user","content":"新的问题"}),
        ];
        let result = select(&messages, 10000, 20).unwrap();
        assert_eq!(result.question, "新的问题");
        assert_eq!(
            result.history,
            vec![
                json!({"role":"user","content":"之前的问题"}),
                json!({"role":"assistant","content":"之前的回答"})
            ]
        );
        assert_eq!(result.sources.len(), 1);
        assert_eq!(result.snapshot, messages);
    }
    #[test]
    fn terms_history_never_accepts_post_id() {
        let terms = json!({"kind":"terms","id":3,"version":"b".repeat(64)});
        let mut messages = vec![
            json!({"sequence_no":1,"role":"assistant","content":"old","citations":[terms]}),
            json!({"sequence_no":2,"role":"user","content":"q"}),
        ];
        assert_eq!(
            select(&messages, 10000, 20).unwrap().sources[0].kind,
            "terms"
        );
        messages[0]["citations"][0]["post_id"] = json!(3);
        assert_eq!(select(&messages, 10000, 20), Err(ContextError::Invalid));
    }

    #[test]
    fn enforces_bytes_sources_and_fails_closed() {
        let version = "a".repeat(64);
        let mut messages = vec![
            json!({"sequence_no":1,"role":"assistant","content":"older","citations":[{"kind":"post","id":1,"version":version,"post_id":1}]}),
            json!({"sequence_no":2,"role":"user","content":"\"\\猫\u{2028}"}),
        ];
        assert_eq!(select(&messages, 37, 20), Err(ContextError::TooLarge));
        assert_eq!(select(&messages, 38, 20).unwrap().history.len(), 0);
        assert_eq!(select(&messages, 10000, 0).unwrap().history.len(), 0);
        messages[0]["citations"] = json!([]);
        assert_eq!(select(&messages, 10000, 20), Err(ContextError::Invalid));
    }

    #[test]
    fn rejects_conflicting_versions_and_trims_oldest_for_source_limit() {
        let a = "a".repeat(64);
        let b = "b".repeat(64);
        let mut messages = vec![
            json!({"sequence_no":1,"role":"assistant","content":"old","citations":[{"kind":"post","id":1,"version":a,"post_id":1}]}),
            json!({"sequence_no":2,"role":"assistant","content":"recent","citations":[{"kind":"post","id":1,"version":b,"post_id":1}]}),
            json!({"sequence_no":3,"role":"user","content":"question"}),
        ];
        assert_eq!(select(&messages, 10000, 20), Err(ContextError::Invalid));
        messages[0]["citations"][0]["kind"] = json!("comment");
        messages[0]["citations"][0]["id"] = json!(2);
        let result = select(&messages, 10000, 1).unwrap();
        assert_eq!(result.history.len(), 1);
        assert_eq!(result.snapshot[0]["sequence_no"], 2);
    }
}
