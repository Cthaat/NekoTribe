use nekotribe_backend::{
    ai::{
        conversation_store::{AiOperation, Error as StoreError, ModerationPolicy},
        knowledge_conversation::{generate_with_transport, Error},
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
                    Ok(json!([{"sequence_no":1,"role":"user","content":"猫"}]))
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
#[tokio::test]
async fn persists_after_generation_with_fixed_sequence_and_model() {
    let events = Arc::new(Mutex::new(vec![]));
    let store = Store {
        events: events.clone(),
        empty: false,
        wrong: false,
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
