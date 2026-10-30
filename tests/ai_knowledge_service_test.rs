use nekotribe_backend::ai::{
    knowledge_service::{
        generate_with_transport, generate_with_transport_and_search, KnowledgeStore,
        KnowledgeTransport,
    },
    knowledge_source::{Candidate, Source},
    knowledge_turn::{TurnError, TurnFuture},
    model_config::SelectionSnapshot,
};
use serde_json::Value;
use std::sync::{Arc, Mutex};

fn source() -> Source {
    Source {
        kind: "post".into(),
        id: 1,
        post_id: 1,
        content: "公开资料".into(),
        version: "a".repeat(64),
    }
}
fn selection() -> SelectionSnapshot {
    SelectionSnapshot {
        configuration_revision: 1,
        role: "knowledge".into(),
        profile_id: "test".into(),
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
struct Store {
    events: Arc<Mutex<Vec<&'static str>>>,
    stale: bool,
    large: bool,
}
impl KnowledgeStore for Store {
    fn discover<'a>(&'a self, viewer: i64, query: &'a str) -> TurnFuture<'a, Vec<Source>> {
        Box::pin(async move {
            assert_eq!((viewer, query), (42, "猫"));
            self.events.lock().unwrap().push("discover");
            let mut s = source();
            if self.large {
                s.content = "x".repeat(20000)
            }
            Ok(vec![s])
        })
    }
    fn hydrate<'a>(&'a self, viewer: i64, _: &'a [Candidate]) -> TurnFuture<'a, Vec<Source>> {
        Box::pin(async move {
            assert_eq!(viewer, 42);
            let mut events = self.events.lock().unwrap();
            events.push("hydrate");
            if self.stale && events.contains(&"infer") {
                return Ok(vec![]);
            }
            let mut s = source();
            if self.large {
                s.content = "x".repeat(20000)
            }
            Ok(vec![s])
        })
    }
}
struct Transport {
    events: Arc<Mutex<Vec<&'static str>>>,
}
struct QuestionTransport;
impl KnowledgeTransport for QuestionTransport {
    fn infer<'a>(&'a self, _: &'a SelectionSnapshot, input: &'a Value) -> TurnFuture<'a, String> {
        Box::pin(async move {
            let data: Value =
                serde_json::from_str(input["messages"][1]["content"].as_str().unwrap()).unwrap();
            assert_eq!(data["question"], "社区里有哪些猫咪？");
            Ok(serde_json::json!({"answer":"answer","citations":[{"kind":"post","id":1,"version":"a".repeat(64)}]}).to_string())
        })
    }
}
#[tokio::test]
async fn searches_separately_from_the_original_question() {
    let store = Store {
        events: Arc::new(Mutex::new(vec![])),
        stale: false,
        large: false,
    };
    let result = generate_with_transport_and_search(
        &store,
        42,
        "社区里有哪些猫咪？",
        Some("猫"),
        selection(),
        &QuestionTransport,
        None,
    )
    .await
    .unwrap();
    assert_eq!(result.answer.as_deref(), Some("answer"));
}
impl KnowledgeTransport for Transport {
    fn infer<'a>(
        &'a self,
        selected: &'a SelectionSnapshot,
        input: &'a Value,
    ) -> TurnFuture<'a, String> {
        Box::pin(async move {
            assert_eq!(selected.role, "knowledge");
            assert_eq!(input["messages"][0]["role"], "system");
            assert!(input["messages"][0]["content"]
                .as_str()
                .unwrap()
                .contains("不可信"));
            assert_eq!(input["messages"][1]["role"], "user");
            self.events.lock().unwrap().push("infer");
            Ok(serde_json::json!({"answer":"answer","citations":[{"kind":"post","id":1,"version":"a".repeat(64)}]}).to_string())
        })
    }
}
#[tokio::test]
async fn connects_retrieval_inference_and_rechecks() {
    let events = Arc::new(Mutex::new(vec![]));
    let store = Store {
        events: events.clone(),
        stale: false,
        large: false,
    };
    let transport = Transport {
        events: events.clone(),
    };
    let result = generate_with_transport(&store, 42, "猫", selection(), &transport, None)
        .await
        .unwrap();
    assert_eq!(result.answer.as_deref(), Some("answer"));
    assert_eq!(
        *events.lock().unwrap(),
        vec!["discover", "hydrate", "infer", "hydrate"]
    );
}
#[tokio::test]
async fn rejects_oversized_input_and_revoked_sources() {
    let events = Arc::new(Mutex::new(vec![]));
    let transport = Transport {
        events: events.clone(),
    };
    let large = Store {
        events: events.clone(),
        stale: false,
        large: true,
    };
    assert_eq!(
        generate_with_transport(&large, 42, "猫", selection(), &transport, None).await,
        Err(TurnError::ContextTooLarge)
    );
    assert!(!events.lock().unwrap().contains(&"infer"));
    events.lock().unwrap().clear();
    let stale = Store {
        events: events.clone(),
        stale: true,
        large: false,
    };
    assert_eq!(
        generate_with_transport(&stale, 42, "猫", selection(), &transport, None).await,
        Err(TurnError::SourceChanged)
    );
}
