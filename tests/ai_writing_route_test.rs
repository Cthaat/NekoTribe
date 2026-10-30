use axum::{body::Body, extract::State, http::Request, routing::post, Extension, Json, Router};
use nekotribe_backend::{
    ai::{
        conversation_store::{AiOperation, Error, ModerationPolicy},
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

struct Store {
    purpose: &'static str,
    conflict: bool,
    writes: Mutex<Vec<(String, i64, String, i64)>>,
}
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
                AiOperation::Recent(_) => Ok(
                    json!([{"sequence_no":3,"role":"assistant","content":"old"},{"sequence_no":4,"role":"user","content":"write"}]),
                ),
                AiOperation::Assistant { input, .. } => {
                    if self.conflict {
                        Err(Error::Conflict)
                    } else {
                        self.writes.lock().unwrap().push((
                            input.content,
                            input.expected_sequence,
                            input.model_id,
                            input.config_revision,
                        ));
                        Ok(json!({"role":"assistant","sequence_no":5}))
                    }
                }
                _ => panic!("unexpected operation"),
            })
        })
    }
}

async fn provider(State(finish): State<&'static str>, Json(input): Json<Value>) -> Json<Value> {
    assert_eq!(input["model"], "test-model");
    assert_eq!(input["messages"][2]["content"], "write");
    Json(
        json!({"choices":[{"index":0,"finish_reason":finish,"message":{"role":"assistant","content":"draft"}}]}),
    )
}

async fn run_case(
    purpose: &'static str,
    conflict: bool,
    finish: &'static str,
) -> (u16, Arc<Store>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let service = Router::new()
        .route("/chat/completions", post(provider))
        .with_state(finish);
    let task = tokio::spawn(async move { axum::serve(listener, service).await.unwrap() });
    let config = json!({"schemaVersion":1,"revision":7,"providers":[{"id":"local","adapter":"openai-compatible","baseUrl":url}],"models":[{"id":"writer","providerId":"local","model":"test-model","capabilities":["tools","structured-output"],"contextWindowTokens":4096,"maxOutputTokens":512}],"bindings":{"knowledge":"writer","writing":"writer","agent":"writer","moderation":"writer"}}).to_string();
    let settings =
        Settings::from_lookup(&|key| (key == "AI_MODEL_CONFIG_JSON").then(|| config.clone()));
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
    let store = Arc::new(Store {
        purpose,
        conflict,
        writes: Mutex::new(vec![]),
    });
    let app = build_native_router(
        codec,
        store.clone(),
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_000),
    )
    .layer(Extension(settings));
    let req =
        Request::post("/api/v2/ai/conversations/f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb/generate")
            .header("authorization", format!("Bearer {token}"))
            .body(Body::empty())
            .unwrap();
    let response = app.oneshot(req).await.unwrap();
    assert_eq!(response.headers()["cache-control"], "private, no-store");
    task.abort();
    (response.status().as_u16(), store)
}

#[tokio::test]
async fn generates_and_stores_a_reply_with_fixed_model_and_sequence() {
    let (status, store) = run_case("writing", false, "stop").await;
    assert_eq!(status, 200);
    assert_eq!(
        *store.writes.lock().unwrap(),
        vec![("draft".into(), 4, "writer".into(), 7)]
    );
}

#[tokio::test]
async fn rejects_non_writing_stale_and_truncated_responses() {
    for (purpose, conflict, finish, expected) in [
        ("knowledge", false, "stop", 400),
        ("writing", true, "stop", 409),
        ("writing", false, "length", 503),
    ] {
        let (status, store) = run_case(purpose, conflict, finish).await;
        assert_eq!(status, expected);
        assert!(store.writes.lock().unwrap().is_empty());
    }
}
