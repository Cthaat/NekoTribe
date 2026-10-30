use nekotribe_backend::{
    ai::{
        conversation_store::{AiOperation, Error as StoreError, ModerationPolicy},
        knowledge_conversation::{
            generate_with_transport, generate_with_transport_and_search, Error,
        },
        knowledge_service::{KnowledgeStore, KnowledgeTransport},
        knowledge_source::{Candidate, Source},
        knowledge_turn::TurnFuture,
        model_config::SelectionSnapshot,
    },
    auth::{
        sessions::{SessionRepository, StoreFuture},
        TokenClaims,
    },
};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};

struct Store {
    events: Arc<Mutex<Vec<&'static str>>>,
    empty: bool,
    wrong: bool,
    question: &'static str,
}
impl SessionRepository for Store {
    fn touch<'a>(&'a self, _: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(1) })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn ai_conversation(
        &self,
        _: u64,
        operation: AiOperation,
        _: ModerationPolicy,
    ) -> StoreFuture<'_, Result<Value, StoreError>> {
        Box::pin(async move {
            Ok(match operation {
                AiOperation::Read(_) => {
                    self.events.lock().unwrap().push("read");
                    Ok(json!({"purpose":if self.wrong{"writing"}else{"knowledge"}}))
                }
                AiOperation::Recent(_) => {
                    self.events.lock().unwrap().push("history");
                    Ok(json!([{"sequence_no":1,"role":"user","content":self.question}]))
                }
                AiOperation::KnowledgeAssistant { input, sources, .. } => {
                    self.events.lock().unwrap().push("append");
                    assert_eq!(
                        (
                            input.content.as_str(),
                            input.expected_sequence,
                            input.model_id.as_str(),
                            input.config_revision
                        ),
                        ("answer", 1, "profile", 3)
                    );
                    assert_eq!(sources[0].id, 1);
                    Ok(json!({"sequence_no":2}))
                }
                _ => panic!("unexpected"),
            })
        })
    }
}
impl KnowledgeStore for Store {
    fn discover<'a>(&'a self, _: i64, query: &'a str) -> TurnFuture<'a, Vec<Source>> {
        Box::pin(async move {
            assert_eq!(query, "猫");
            self.events.lock().unwrap().push("discover");
            if self.empty {
                Ok(vec![])
            } else {
                Ok(vec![source()])
            }
        })
    }
    fn hydrate<'a>(&'a self, _: i64, _: &'a [Candidate]) -> TurnFuture<'a, Vec<Source>> {
        Box::pin(async move {
            self.events.lock().unwrap().push("hydrate");
            if self.empty {
                Ok(vec![])
            } else {
                Ok(vec![source()])
            }
        })
    }
}
fn source() -> Source {
    Source {
        kind: "post".into(),
        id: 1,
        post_id: 1,
        content: "资料".into(),
        version: "a".repeat(64),
    }
}
struct Transport(Arc<Mutex<Vec<&'static str>>>);
impl KnowledgeTransport for Transport {
    fn infer<'a>(&'a self, _: &'a SelectionSnapshot, _: &'a Value) -> TurnFuture<'a, String> {
        Box::pin(async move {
            self.0.lock().unwrap().push("infer");
            Ok(json!({"answer":"answer","citations":[{"kind":"post","id":1,"version":"a".repeat(64)}]}).to_string())
        })
    }
}
fn selection() -> SelectionSnapshot {
    SelectionSnapshot {
        configuration_revision: 3,
        role: "knowledge".into(),
        profile_id: "profile".into(),
        provider_id: "test".into(),
        adapter: "ollama".into(),
        base_url: "http://localhost".into(),
        model: "test".into(),
        api_key_env: None,
        capabilities: vec![],
        context_window_tokens: 8192,
        max_output_tokens: 512,
    }
}
struct QuestionTransport;
impl KnowledgeTransport for QuestionTransport {
    fn infer<'a>(&'a self, _: &'a SelectionSnapshot, input: &'a Value) -> TurnFuture<'a, String> {
        Box::pin(async move {
            let data: Value =
                serde_json::from_str(input["messages"][1]["content"].as_str().unwrap()).unwrap();
            assert_eq!(data["question"], "社区里有哪些猫咪？");
            Ok(json!({"answer":"answer","citations":[{"kind":"post","id":1,"version":"a".repeat(64)}]}).to_string())
        })
    }
}
#[tokio::test]
async fn retains_question_when_search_phrase_is_separate() {
    let store = Store {
        events: Arc::new(Mutex::new(vec![])),
        empty: false,
        wrong: false,
        question: "社区里有哪些猫咪？",
    };
    let result = generate_with_transport_and_search(
        &store,
        &store,
        42,
        "id",
        ModerationPolicy::new("", ""),
        selection(),
        &QuestionTransport,
        None,
        Some("猫"),
    )
    .await
    .unwrap();
    assert_eq!(result.unwrap()["sequence_no"], 2);
}
#[tokio::test]
async fn persists_after_generation_with_fixed_sequence_and_model() {
    let events = Arc::new(Mutex::new(vec![]));
    let store = Store {
        events: events.clone(),
        empty: false,
        wrong: false,
        question: "猫",
    };
    let transport = Transport(events.clone());
    let result = generate_with_transport(
        &store,
        &store,
        42,
        "id",
        ModerationPolicy::new("", ""),
        selection(),
        &transport,
        None,
    )
    .await
    .unwrap();
    assert_eq!(result.unwrap()["sequence_no"], 2);
    assert_eq!(
        *events.lock().unwrap(),
        vec!["read", "history", "discover", "hydrate", "infer", "hydrate", "append"]
    );
}
#[tokio::test]
async fn no_evidence_or_wrong_purpose_never_writes() {
    let events = Arc::new(Mutex::new(vec![]));
    let transport = Transport(events.clone());
    let store = Store {
        events: events.clone(),
        empty: true,
        wrong: false,
        question: "猫",
    };
    assert!(generate_with_transport(
        &store,
        &store,
        42,
        "id",
        ModerationPolicy::new("", ""),
        selection(),
        &transport,
        None
    )
    .await
    .unwrap()
    .is_none());
    assert!(!events.lock().unwrap().contains(&"append"));
    let bad = Store {
        events: events.clone(),
        empty: false,
        wrong: true,
        question: "猫",
    };
    assert!(matches!(
        generate_with_transport(
            &bad,
            &bad,
            42,
            "id",
            ModerationPolicy::new("", ""),
            selection(),
            &transport,
            None
        )
        .await,
        Err(Error::Context)
    ));
}
