use nekotribe_backend::{
    ai::{
        conversation_store::{AiOperation, Error as StoreError, ModerationPolicy},
        knowledge_conversation::{
            Error, generate_with_transport, generate_with_transport_and_search,
        },
        knowledge_service::{KnowledgeStore, KnowledgeTransport},
        knowledge_source::{Candidate, Scope, Source},
        knowledge_turn::{TurnError, TurnFuture},
        model_config::SelectionSnapshot,
    },
    auth::{
        TokenClaims,
        sessions::{SessionRepository, StoreFuture},
    },
};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};

struct Store {
    events: Arc<Mutex<Vec<&'static str>>>,
    empty: bool,
    wrong: bool,
    skill_disabled: bool,
    question: &'static str,
    scope: Scope,
    failure: Option<&'static str>,
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
        actor: u64,
        operation: AiOperation,
        _: ModerationPolicy,
    ) -> StoreFuture<'_, Result<Value, StoreError>> {
        Box::pin(async move {
            assert_eq!(actor, 42);
            Ok(match operation {
                AiOperation::Read(_) => {
                    self.events.lock().unwrap().push("read");
                    if self.failure == Some("read") {
                        Err(StoreError::Forbidden)
                    } else {
                        let (name, group_id) = match self.scope {
                            Scope::Public => ("public", None),
                            Scope::Personal => ("personal", None),
                            Scope::Group(group_id) => ("group", Some(group_id)),
                        };
                        Ok(
                            json!({"purpose":if self.wrong{"writing"}else{"knowledge"},"knowledge_scope":name,"group_id":group_id}),
                        )
                    }
                }
                AiOperation::Recent(_) => {
                    self.events.lock().unwrap().push("history");
                    Ok(json!([{"sequence_no":1,"role":"user","content":self.question}]))
                }
                AiOperation::KnowledgeSkill(_, _) => {
                    self.events.lock().unwrap().push("skill");
                    if self.skill_disabled {
                        Err(StoreError::SchemaUnavailable)
                    } else {
                        Ok(json!(7))
                    }
                }
                AiOperation::KnowledgeAssistant {
                    input,
                    sources,
                    dependencies,
                    scope,
                    context_snapshot,
                    skill_generation,
                    ..
                } => {
                    self.events.lock().unwrap().push("append");
                    assert_eq!(skill_generation, 7);
                    assert_eq!(input.model_version.as_deref(), Some("fixture-v2"));
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
                    assert_eq!(sources.len(), 1);
                    assert_eq!(scope, self.scope);
                    if let Some(dependencies) = dependencies {
                        assert_ne!(scope, Scope::Public);
                        assert_eq!(
                            dependencies
                                .iter()
                                .map(|reference| reference.id)
                                .collect::<Vec<_>>(),
                            [1, 2]
                        );
                    } else {
                        assert_eq!(scope, Scope::Public);
                    }
                    assert_eq!(
                        context_snapshot,
                        vec![json!({"sequence_no":1,"role":"user","content":self.question})]
                    );
                    if self.failure == Some("append") {
                        Err(StoreError::Forbidden)
                    } else {
                        Ok(json!({"sequence_no":2}))
                    }
                }
                _ => panic!("unexpected"),
            })
        })
    }
}
impl KnowledgeStore for Store {
    fn discover<'a>(&'a self, _: i64, query: &'a str) -> TurnFuture<'a, Vec<Source>> {
        Box::pin(async move {
            assert_eq!(self.scope, Scope::Public);
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
            assert_eq!(self.scope, Scope::Public);
            self.events.lock().unwrap().push("hydrate");
            if self.empty {
                Ok(vec![])
            } else {
                Ok(vec![source()])
            }
        })
    }
    fn discover_scoped<'a>(
        &'a self,
        actor: i64,
        scope: Scope,
        query: &'a str,
    ) -> TurnFuture<'a, Vec<Source>> {
        if scope == Scope::Public {
            return self.discover(actor, query);
        }
        Box::pin(async move {
            assert_eq!((actor, scope, query), (42, self.scope, "猫"));
            self.events.lock().unwrap().push("discover");
            Ok(vec![scoped_source(scope, 1), scoped_source(scope, 2)])
        })
    }
    fn hydrate_scoped<'a>(
        &'a self,
        actor: i64,
        scope: Scope,
        candidates: &'a [Candidate],
    ) -> TurnFuture<'a, Vec<Source>> {
        if scope == Scope::Public {
            return self.hydrate(actor, candidates);
        }
        Box::pin(async move {
            assert_eq!((actor, scope), (42, self.scope));
            assert_eq!(candidates.len(), 2);
            let mut events = self.events.lock().unwrap();
            events.push("hydrate");
            if self.failure == Some("after-infer") && events.contains(&"infer") {
                return Err(TurnError::Forbidden);
            }
            let source_scope = if self.failure == Some("cross-group") {
                Scope::Group(77)
            } else {
                scope
            };
            Ok(vec![
                scoped_source(source_scope, 1),
                scoped_source(source_scope, 2),
            ])
        })
    }
}
fn source() -> Source {
    Source {
        kind: "post".into(),
        id: 1,
        post_id: 1,
        group_id: 0,
        content: "资料".into(),
        version: "a".repeat(64),
    }
}

fn scoped_source(scope: Scope, id: i64) -> Source {
    let mut source = source();
    source.id = id;
    source.post_id = id;
    if let Scope::Group(group_id) = scope {
        source.kind = "group_post".into();
        source.group_id = group_id;
    }
    source
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
        model_version: Some("fixture-v2".into()),
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
        skill_disabled: false,
        question: "社区里有哪些猫咪？",
        scope: Scope::Public,
        failure: None,
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
        &nekotribe_backend::ai::knowledge_search_body::KnowledgeSearchBody {
            phrase: Some("猫".into()),
            skill_id: Some("knowledge-answer"),
            expected_sequence: Some(1),
        },
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
        skill_disabled: false,
        question: "猫",
        scope: Scope::Public,
        failure: None,
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
        vec![
            "read", "history", "skill", "discover", "hydrate", "infer", "hydrate", "append"
        ]
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
        skill_disabled: false,
        question: "猫",
        scope: Scope::Public,
        failure: None,
    };
    assert!(
        generate_with_transport(
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
        .is_none()
    );
    assert!(!events.lock().unwrap().contains(&"append"));
    let bad = Store {
        events: events.clone(),
        empty: false,
        wrong: true,
        skill_disabled: false,
        question: "猫",
        scope: Scope::Public,
        failure: None,
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

#[tokio::test]
async fn disabled_skill_blocks_inference() {
    let events = Arc::new(Mutex::new(vec![]));
    let store = Store {
        events: events.clone(),
        empty: false,
        wrong: false,
        skill_disabled: true,
        question: "猫",
        scope: Scope::Public,
        failure: None,
    };
    let result = generate_with_transport(
        &store,
        &store,
        42,
        "id",
        ModerationPolicy::new("", ""),
        selection(),
        &Transport(events.clone()),
        None,
    )
    .await;
    assert!(matches!(
        result,
        Err(Error::Store(StoreError::SchemaUnavailable))
    ));
    assert!(!events.lock().unwrap().contains(&"infer"));
    assert!(!events.lock().unwrap().contains(&"append"));
}

struct ScopedTransport<'a>(&'a Store);

impl KnowledgeTransport for ScopedTransport<'_> {
    fn infer<'a>(&'a self, _: &'a SelectionSnapshot, input: &'a Value) -> TurnFuture<'a, String> {
        Box::pin(async move {
            self.0.events.lock().unwrap().push("infer");
            let data: Value =
                serde_json::from_str(input["messages"][1]["content"].as_str().unwrap()).unwrap();
            let sources = data["sources"].as_array().unwrap();
            assert_eq!(sources.len(), 2);
            for (index, value) in sources.iter().enumerate() {
                let source = scoped_source(self.0.scope, (index + 1) as i64);
                assert_eq!(*value, serde_json::to_value(source).unwrap());
            }
            let source = &sources[0];
            Ok(json!({"answer":"answer","citations":[{"kind":source["kind"],"id":source["id"],"version":source["version"]}]}).to_string())
        })
    }
}

#[tokio::test]
async fn scoped_generation_rechecks_membership_and_preserves_uncited_dependencies() {
    for (scope, failure) in [
        (Scope::Personal, None),
        (Scope::Group(9_007_199_254_740_991), None),
        (Scope::Group(7), Some("read")),
        (Scope::Group(7), Some("cross-group")),
        (Scope::Group(7), Some("after-infer")),
        (Scope::Group(7), Some("append")),
    ] {
        let store = Store {
            events: Arc::new(Mutex::new(vec![])),
            empty: false,
            wrong: false,
            skill_disabled: false,
            question: "猫",
            scope,
            failure,
        };
        let result = generate_with_transport(
            &store,
            &store,
            42,
            "id",
            ModerationPolicy::new("", ""),
            selection(),
            &ScopedTransport(&store),
            None,
        )
        .await;
        let events = store.events.lock().unwrap();
        match failure {
            Some("read") => {
                assert!(matches!(result, Err(Error::Store(StoreError::Forbidden))));
                assert_eq!(*events, ["read"]);
            }
            Some("cross-group") => {
                assert!(matches!(
                    result,
                    Err(Error::Knowledge(TurnError::InvalidSource))
                ));
                assert!(!events.contains(&"infer"));
            }
            Some("after-infer") => {
                assert!(matches!(
                    result,
                    Err(Error::Knowledge(TurnError::Forbidden))
                ));
                assert!(events.contains(&"infer"));
                assert!(!events.contains(&"append"));
            }
            Some("append") => assert!(matches!(result, Err(Error::Store(StoreError::Forbidden)))),
            None => {
                assert_eq!(result.unwrap().unwrap()["sequence_no"], 2);
                assert_eq!(
                    *events,
                    [
                        "read", "history", "skill", "discover", "hydrate", "infer", "hydrate",
                        "append"
                    ]
                );
            }
            _ => unreachable!(),
        }
    }
}
