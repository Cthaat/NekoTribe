#[path = "support/ai_model_quota.rs"]
mod ai_model_quota;

use axum::{
    body::{to_bytes, Body},
    http::Request,
    routing::post,
    Extension, Json, Router,
};
use nekotribe_backend::{
    ai::{
        conversation_http::KnowledgeRuntime,
        conversation_store::{AiOperation, Error, ModerationPolicy},
        knowledge_service::KnowledgeStore,
        knowledge_source::{Candidate, Source},
        knowledge_turn::TurnFuture,
        writing::Settings,
    },
    auth::{
        sessions::{build_native_router, CorsPolicy, SessionRepository, StoreFuture},
        TokenClaims, TokenCodec,
    },
};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

struct Store;
impl SessionRepository for Store {
    fn touch<'a>(&'a self, claims: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async move { Ok(u64::from(claims.user_id == 42)) })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
}

struct LiveStore {
    empty: bool,
    purpose: &'static str,
    question: &'static str,
    conflict: bool,
    writes: Mutex<usize>,
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
impl SessionRepository for LiveStore {
    fn touch<'a>(&'a self, claims: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async move { Ok(u64::from(claims.user_id == 42)) })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn ai_conversation(
        &self,
        user: u64,
        operation: AiOperation,
        _: ModerationPolicy,
    ) -> StoreFuture<'_, Result<Value, Error>> {
        Box::pin(async move {
            assert_eq!(user, 42);
            Ok(match operation {
                AiOperation::Read(_) => Ok(json!({"purpose":self.purpose})),
                AiOperation::Recent(_) => {
                    Ok(json!([{"sequence_no":1,"role":"user","content":self.question}]))
                }
                AiOperation::KnowledgeSkill(_, _) => {
                    if self.question == "技能关闭" {
                        Err(Error::SchemaUnavailable)
                    } else {
                        Ok(json!(7))
                    }
                }
                AiOperation::KnowledgeAssistant {
                    input,
                    sources,
                    cancel,
                    ..
                } => {
                    assert!(cancel.is_some_and(|signal| !*signal.borrow()));
                    assert_eq!(
                        (
                            input.content.as_str(),
                            input.expected_sequence,
                            input.model_id.as_str(),
                            input.config_revision
                        ),
                        ("answer", 1, "writer", 7)
                    );
                    assert_eq!(sources[0].id, 1);
                    if self.conflict {
                        Err(Error::Conflict)
                    } else {
                        *self.writes.lock().unwrap() += 1;
                        Ok(json!({"role":"assistant","sequence_no":2}))
                    }
                }
                _ => panic!("unexpected operation"),
            })
        })
    }
}
impl KnowledgeStore for LiveStore {
    fn discover<'a>(&'a self, viewer: i64, query: &'a str) -> TurnFuture<'a, Vec<Source>> {
        Box::pin(async move {
            assert_eq!((viewer, query), (42, "猫"));
            Ok(if self.empty { vec![] } else { vec![source()] })
        })
    }
    fn hydrate<'a>(&'a self, viewer: i64, _: &'a [Candidate]) -> TurnFuture<'a, Vec<Source>> {
        Box::pin(async move {
            assert_eq!(viewer, 42);
            Ok(if self.empty { vec![] } else { vec![source()] })
        })
    }
}

#[tokio::test]
async fn knowledge_route_generates_or_rejects_without_false_writes() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let provider = Router::new().route("/chat/completions", post(|Json(request): Json<Value>| async move {
        assert_eq!(request["response_format"]["json_schema"]["schema"]["properties"]["citations"]["items"]["enum"], json!([1]));
        let content = json!({"answer":"answer","citations":[1]}).to_string();
        Json(json!({"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":content}}]}))
    }));
    let task = tokio::spawn(async move { axum::serve(listener, provider).await.unwrap() });
    let config = json!({"schemaVersion":1,"revision":7,"providers":[{"id":"local","adapter":"openai-compatible","baseUrl":url}],"models":[{"id":"writer","providerId":"local","model":"test-model","capabilities":["tools","structured-output"],"contextWindowTokens":8192,"maxOutputTokens":512}],"bindings":{"knowledge":"writer","writing":"writer","agent":"writer","moderation":"writer"}}).to_string();
    let fixture: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = fixture["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    let oversized = " ".repeat(4097);
    for (purpose, empty, conflict, expected, result, writes, question, input) in [
        ("knowledge", false, false, 200, "generated", 1, "猫", ""),
        (
            "knowledge",
            true,
            false,
            200,
            "insufficient_evidence",
            0,
            "猫",
            "",
        ),
        ("writing", false, false, 400, "", 0, "猫", ""),
        ("knowledge", false, true, 409, "", 0, "猫", ""),
        ("knowledge", false, false, 503, "", 0, "技能关闭", ""),
        (
            "knowledge",
            false,
            false,
            200,
            "generated",
            1,
            "关于猫的问题",
            "{\"search_phrase\":\"猫\"}",
        ),
        (
            "knowledge",
            false,
            false,
            400,
            "",
            0,
            "猫",
            "{\"search_phrase\":\"猫\",\"search_phrase\":\"猫\"}",
        ),
        (
            "knowledge",
            false,
            false,
            400,
            "",
            0,
            "猫",
            oversized.as_str(),
        ),
    ] {
        let codec = TokenCodec::new(
            fixture["keys"]["access"].as_str().unwrap().as_bytes(),
            fixture["keys"]["refresh"].as_str().unwrap().as_bytes(),
        )
        .unwrap();
        let store = Arc::new(LiveStore {
            empty,
            purpose,
            question,
            conflict,
            writes: Mutex::new(0),
        });
        let settings =
            Settings::from_lookup(&|key| (key == "AI_MODEL_CONFIG_JSON").then(|| config.clone()));
        let app = build_native_router(
            codec,
            store.clone(),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
        )
        .layer(Extension(KnowledgeRuntime(store.clone())))
        .layer(Extension(settings))
        .layer(Extension(ai_model_quota::single_call_quota()));
        let response = app.oneshot(Request::post("/api/v2/ai/conversations/f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb/knowledge-generate").header("authorization",format!("Bearer {token}")).body(Body::from(input.to_owned())).unwrap()).await.unwrap();
        assert_eq!(response.status(), expected);
        assert_eq!(response.headers()["cache-control"], "private, no-store");
        let body: Value =
            serde_json::from_slice(&to_bytes(response.into_body(), 65536).await.unwrap()).unwrap();
        if expected == 200 {
            assert_eq!(body["data"]["status"], result);
        }
        assert_eq!(*store.writes.lock().unwrap(), writes);
    }
    task.abort();
}

#[tokio::test]
async fn missing_runtime_fails_closed_after_authentication() {
    let fixture: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = fixture["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    let codec = TokenCodec::new(
        fixture["keys"]["access"].as_str().unwrap().as_bytes(),
        fixture["keys"]["refresh"].as_str().unwrap().as_bytes(),
    )
    .unwrap();
    let app = build_native_router(
        codec,
        Arc::new(Store),
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_000),
    );
    let uri = "/api/v2/ai/conversations/f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb/knowledge-generate";
    let unauthorized = app
        .clone()
        .oneshot(Request::post(uri).body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(unauthorized.status(), 401);
    assert_eq!(unauthorized.headers()["cache-control"], "private, no-store");
    let response = app
        .oneshot(
            Request::post(uri)
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), 503);
    assert_eq!(response.headers()["cache-control"], "private, no-store");
}
