use nekotribe_backend::ai::{
    knowledge_citations::parse,
    knowledge_source::Candidate,
    knowledge_turn::{TurnError, TurnResult},
};
use serde_json::json;

#[test]
fn matches_shared_cross_backend_vectors() {
    let vectors: serde_json::Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/ai-knowledge-citation-vectors.json"
    ))
    .unwrap();
    let verified: Vec<Candidate> = serde_json::from_value(vectors["verified"].clone()).unwrap();
    for row in vectors["cases"].as_array().unwrap() {
        assert_eq!(
            parse(row["output"].as_str().unwrap(), &verified).is_ok(),
            row["accepted"].as_bool().unwrap(),
            "{}",
            row["id"]
        );
    }
}

fn source() -> Candidate {
    Candidate {
        kind: "post".into(),
        id: 1,
        version: "a".repeat(64),
    }
}
#[test]
fn accepts_only_explicit_verified_unique_sources() {
    let s = source();
    let text = json!({"answer":"答案","citations":[{"kind":"post","id":1,"version":s.version}]})
        .to_string();
    assert_eq!(
        parse(&text, std::slice::from_ref(&s)),
        Ok(TurnResult {
            answer: Some("答案".into()),
            sources: vec![s]
        })
    );
}
#[test]
fn rejects_fabricated_duplicate_missing_and_extra_citations() {
    let s = source();
    let cit = json!({"kind":"post","id":1,"version":s.version});
    for v in [
        json!({"answer":"答案","citations":[]}),
        json!({"answer":"答案","citations":[cit,cit]}),
        json!({"answer":"答案","citations":[{"kind":"post","id":2,"version":s.version}]}),
        json!({"answer":"答案","citations":[{"kind":"post","id":1,"version":s.version,"extra":true}]}),
        json!({"answer":" ","citations":[cit]}),
    ] {
        assert_eq!(
            parse(&v.to_string(), std::slice::from_ref(&s)),
            Err(TurnError::InvalidCitations)
        );
    }
    assert_eq!(parse("not json", &[s]), Err(TurnError::InvalidCitations));
}
