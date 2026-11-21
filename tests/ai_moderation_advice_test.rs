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
        conversation_store::{AiOperation, Error, ModerationPolicy},
        writing::Settings,
    },
    auth::{
        sessions::{build_native_router, CorsPolicy, SessionRepository, StoreFuture},
        TokenClaims, TokenCodec,
    },
};
use serde_json::{json, Value};
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc, Mutex,
};
use tower::ServiceExt;

struct Store {
    condition: String,
    content: String,
    written: Mutex<Option<(Value, i64, i64)>>,
    feedback_calls: AtomicUsize,
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
        actor: u64,
        operation: AiOperation,
        _: ModerationPolicy,
    ) -> StoreFuture<'_, Result<Value, Error>> {
        Box::pin(async move {
            assert_eq!(actor, 42);
            Ok(match operation {
                AiOperation::ModerationAdviceLoad { request, .. } => {
                    match self.condition.as_str() {
                        "forbidden" => Err(Error::Forbidden),
                        "wrong_purpose" => Err(Error::Invalid),
                        "terms_unavailable" | "disabled" => Err(Error::SchemaUnavailable),
                        "empty" => Ok(json!({"generation":4,"material":null})),
                        _ => Ok(json!({"generation":4,"material":{
                            "target":{"target_type":request.kind,"target_id":request.id,"post_id":request.id,"group_id":null,"digest":"a".repeat(64)},
                            "content":self.content,"terms_digest":"b".repeat(64),"terms_generation":9,
                            "rules":[{"id":3,"version":"c".repeat(64),"title":"Conduct","blocks":["Rule"]}]
                        }})),
                    }
                }
                AiOperation::ModerationAdviceSave { record, input, .. } => {
                    assert_eq!(input.expected_sequence, 0);
                    if self.condition == "changed" {
                        Err(Error::Conflict)
                    } else {
                        *self.written.lock().unwrap() = Some((
                            json!(record.advice),
                            record.skill_generation,
                            record.terms_generation,
                        ));
                        Ok(json!({"role":"assistant","sequence_no":1}))
                    }
                }
                AiOperation::ModerationFeedbackSave { id, message_id, rating } => {
                    self.feedback_calls.fetch_add(1, Ordering::Relaxed);
                    assert_eq!(id, "f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb");
                    assert_eq!(message_id, "e7dd4d7f-8462-45b6-9bf4-a630d0ba7478");
                    match self.condition.as_str() {
                        "forbidden" => Err(Error::Forbidden),
                        "not_owner" | "not_message" => Err(Error::NotFound),
                        "redacted" | "changed" => Err(Error::Conflict),
                        "old_schema" => Err(Error::SchemaUnavailable),
                        _ => Ok(json!({"message_id":message_id,"rating":rating})),
                    }
                }
                _ => panic!("unexpected AI operation"),
            })
        })
    }
}

#[tokio::test]
async fn moderation_advice_shared_scenarios() {
    let spec: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/ai-moderation-advice-http.json"
    ))
    .unwrap();
    let auth: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = auth["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    for entry in spec["cases"].as_array().unwrap() {
        let calls = Arc::new(AtomicUsize::new(0));
        let called = calls.clone();
        let condition = entry["condition"].as_str().unwrap();
        let mut opinion = spec["goodAdvice"].clone();
        if condition == "fabricated_rule" {
            opinion["rule_ids"] = json!([999]);
        }
        if condition == "wrong_locale" {
            opinion["rule_ids"] = json!([7]);
        }
        let tool = condition == "tool_proposal";
        let provider=Router::new().route("/chat/completions",post(move |Json(sent):Json<Value>|{
            let opinion=opinion.clone();
            let called=called.clone();
            async move {
                called.fetch_add(1,Ordering::Relaxed);
                assert_eq!(sent["model"],"test-model");
                assert_eq!(sent["response_format"]["type"],"json_schema");
                if tool {
                    Json(json!({"choices":[{"index":0,"finish_reason":"tool_calls","message":{"role":"assistant","tool_calls":[{"id":"x","type":"function","function":{"name":"delete","arguments":"{}"}}]}}]}))
                } else {
                    Json(json!({"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":opinion.to_string()}}]}))
                }
            }
        }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move { axum::serve(listener, provider).await.unwrap() });
        let config=json!({"schemaVersion":1,"revision":7,"providers":[{"id":"local","adapter":"openai-compatible","baseUrl":url}],"models":[{"id":"reviewer","providerId":"local","model":"test-model","capabilities":["tools","structured-output"],"contextWindowTokens":8192,"maxOutputTokens":512}],"bindings":{"knowledge":"reviewer","writing":"reviewer","agent":"reviewer","moderation":"reviewer"}}).to_string();
        let codec = TokenCodec::new(
            auth["keys"]["access"].as_str().unwrap().as_bytes(),
            auth["keys"]["refresh"].as_str().unwrap().as_bytes(),
        )
        .unwrap();
        let store = Arc::new(Store {
            condition: condition.into(),
            content: spec["text"].as_str().unwrap().into(),
            written: Mutex::new(None),
            feedback_calls: AtomicUsize::new(0),
        });
        let app = build_native_router(
            codec,
            store.clone(),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
        )
        .layer(Extension(ai_model_quota::single_call_quota()))
        .layer(Extension(Settings::from_lookup(&|key| {
            (key == "AI_MODEL_CONFIG_JSON").then(|| config.clone())
        })));
        let mut req = Request::post(
            "/api/v2/ai/conversations/f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb/moderation-generate",
        );
        if condition != "anonymous" {
            req = req.header("authorization", format!("Bearer {token}"));
        }
        let response = app
            .oneshot(
                req.body(Body::from(entry["body"].as_str().unwrap().to_owned()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            response.status().as_u16(),
            entry["http"].as_u64().unwrap() as u16,
            "scenario {condition}"
        );
        assert_eq!(response.headers()["cache-control"], "private, no-store");
        let body: Value =
            serde_json::from_slice(&to_bytes(response.into_body(), 65536).await.unwrap()).unwrap();
        if let Some(status) = entry["status"].as_str() {
            assert_eq!(body["data"]["status"], status);
        }
        let saved = store.written.lock().unwrap();
        if entry["status"] == "generated" {
            assert_eq!(saved.as_ref(), Some(&(spec["goodAdvice"].clone(), 4, 9)));
        } else {
            assert!(saved.is_none());
        }
        if matches!(
            condition,
            "anonymous"
                | "forbidden"
                | "invalid"
                | "wrong_purpose"
                | "disabled"
                | "terms_unavailable"
                | "empty"
        ) {
            assert_eq!(calls.load(Ordering::Relaxed), 0);
        }
        task.abort();
    }
}

#[tokio::test]
async fn moderation_feedback_shared_scenarios() {
    let spec: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/ai-moderation-feedback-http.json"
    ))
    .unwrap();
    let auth: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = auth["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    let id = spec["conversationId"].as_str().unwrap();
    let expected_message = spec["messageId"].as_str().unwrap();
    for scenario in spec["cases"].as_array().unwrap() {
        let condition = scenario["condition"].as_str().unwrap();
        let store = Arc::new(Store {
            condition: condition.into(),
            content: String::new(),
            written: Mutex::new(None),
            feedback_calls: AtomicUsize::new(0),
        });
        let codec = TokenCodec::new(
            auth["keys"]["access"].as_str().unwrap().as_bytes(),
            auth["keys"]["refresh"].as_str().unwrap().as_bytes(),
        )
        .unwrap();
        let app = build_native_router(
            codec,
            store.clone(),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
        );
        let message = if condition == "invalid_id" { "invalid" } else { expected_message };
        let mut req = Request::put(format!("/api/v2/ai/conversations/{id}/messages/{message}/moderation-feedback"));
        if condition != "anonymous" {
            req = req.header("authorization", format!("Bearer {token}"));
        }
        let response = app
            .oneshot(req.body(Body::from(scenario["body"].as_str().unwrap().to_owned())).unwrap())
            .await
            .unwrap();
        let status = response.status().as_u16();
        assert_eq!(u64::from(status), scenario["http"].as_u64().unwrap(), "{}", scenario["id"]);
        assert_eq!(response.headers()["cache-control"], "private, no-store");
        if status == 200 {
            let body: Value = serde_json::from_slice(&to_bytes(response.into_body(), 65536).await.unwrap()).unwrap();
            assert_eq!(body["data"], json!({"message_id":expected_message,"rating":scenario["rating"]}));
        }
        let expected_calls = usize::from(!matches!(condition, "anonymous" | "invalid_id" | "invalid"));
        assert_eq!(store.feedback_calls.load(Ordering::Relaxed), expected_calls);
    }
}
