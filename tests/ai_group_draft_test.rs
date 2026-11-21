use axum::{
    body::{to_bytes, Body},
    http::Request,
    routing::post,
    Extension, Json, Router,
};
use nekotribe_backend::{
    ai::{
        conversation_store::{AiOperation, Error, ModerationPolicy},
        model_quota::{AiModelQuota, AiModelQuotaLimiter, QuotaError, QuotaFuture},
        writing::Settings,
    },
    auth::{
        sessions::{build_native_router, CorsPolicy, SessionRepository, StoreFuture},
        TokenClaims, TokenCodec,
    },
};
use serde_json::{json, Value};
use std::sync::{atomic::{AtomicUsize, Ordering}, Arc, Mutex};
use tower::ServiceExt;

struct Store {
    condition: String,
    evidence: Value,
    written: Mutex<Option<(String, Vec<String>, usize)>>,
    loads: AtomicUsize,
    reservations: AtomicUsize,
    retry_after: u64,
}

impl AiModelQuotaLimiter for Store {
    fn reserve(&self, actor: u64, cost: u64) -> QuotaFuture<'_> {
        Box::pin(async move {
            self.reservations.fetch_add(1, Ordering::Relaxed);
            assert_eq!((actor,cost),(42,2));
            if self.condition == "quota_unavailable" {
                Err(QuotaError::Unavailable)
            } else {
                Ok(self.retry_after)
            }
        })
    }
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
        op: AiOperation,
        _: ModerationPolicy,
    ) -> StoreFuture<'_, Result<Value, Error>> {
        Box::pin(async move {
            assert_eq!(actor, 42);
            Ok(match op {
                AiOperation::GroupDraftLoad { .. } => {
                    let load = self.loads.fetch_add(1,Ordering::Relaxed) + 1;
                    match (self.condition.as_str(),load) {
                        ("wrong_purpose",_) => Err(Error::Invalid),
                        ("forbidden",_) | ("revoked_after_proposal",2) => Err(Error::Forbidden),
                        ("skill_unavailable",_) | ("missing_tool_grant",_) => Err(Error::SchemaUnavailable),
                        ("empty",_) | ("evidence_gone",2) => {
                            let mut evidence = self.evidence.clone();
                            evidence["examples"] = json!([]);
                            Ok(json!({"evidence":evidence,"generation":6}))
                        }
                        ("skill_changed",2) => Ok(json!({"evidence":self.evidence,"generation":7})),
                        _ => Ok(json!({"evidence":self.evidence,"generation":6})),
                    }
                }
                AiOperation::GroupDraftSave { input, draft, .. } => {
                    assert_eq!((input.expected_sequence, draft.skill_generation), (0, 6));
                    if matches!(self.condition.as_str(), "focused_search" | "admin_search") {
                        assert_eq!(draft.search_term.as_deref(), Some("活动报名"));
                        assert!(draft.match_excerpt);
                    }
                    if self.condition == "changed" {
                        Err(Error::Conflict)
                    } else {
                        *self.written.lock().unwrap() = Some((
                            draft.source_digest,
                            draft.tools_used.unwrap(),
                            draft.example_count,
                        ));
                        Ok(json!({"sequence_no":1,"role":"assistant"}))
                    }
                }
                _ => panic!("unexpected AI operation"),
            })
        })
    }
}

#[tokio::test]
async fn group_draft_route_shared_scenarios() {
    let spec: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/ai-group-draft.json")).unwrap();
    let auth: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = auth["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|case| case["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    for entry in spec["cases"].as_array().unwrap() {
        let condition = entry["condition"].as_str().unwrap_or_default();
        let proposals = entry["tools"].as_array().or_else(|| spec["defaultTools"].as_array()).unwrap();
        let tools = proposals.clone();
        let mut storage_evidence=spec["evidence"].clone();
        let (digest, used_examples) = if condition == "trimmed" {
            let sample_count = spec["bulk"]["sampleCount"].as_u64().unwrap();
            let excerpt = spec["bulk"]["excerpt"].as_str().unwrap();
            let examples: Vec<_> = (10..10+sample_count).map(|id|json!({
                "kind":"post","source_id":id,"post_id":id,"excerpt":excerpt,
            })).collect();
            storage_evidence["examples"] = json!(examples);
            storage_evidence["posts_count"] = json!(sample_count);
            (&spec["bulk"]["digest"], spec["bulk"]["sampleUsed"].as_u64().unwrap() as usize)
        } else {
            (&spec["digest"], storage_evidence["examples"].as_array().unwrap().len())
        };
        let mut evidence=storage_evidence.clone();
        evidence["examples"].as_array_mut().unwrap().truncate(used_examples);
        let calls=Arc::new(AtomicUsize::new(0));
        let provider_calls=calls.clone();
        let continued = condition=="continued_tool";
        let expected_search = serde_json::from_str::<Value>(entry["body"].as_str().unwrap()).ok()
            .and_then(|value| value["search_term"].as_str().map(str::to_owned));
        let provider=Router::new().route("/chat/completions",post(move |Json(input):Json<Value>|{
            let count=provider_calls.fetch_add(1,Ordering::Relaxed)+1;
            let tools=tools.clone();
            let evidence=evidence.clone();
            let expected_search=expected_search.clone();
            async move {
                let messages=input["messages"].as_array().unwrap();
                if count==1 {
                    assert_eq!(input["tools"].as_array().unwrap().len(),2);
                    assert_eq!(messages.len(),2);
                    let user:Value=serde_json::from_str(messages[1]["content"].as_str().unwrap()).unwrap();
                    assert_eq!(user.as_object().unwrap().len(),1+usize::from(expected_search.is_some()));
                    assert_eq!(user["search_term"].as_str(),expected_search.as_deref());
                    assert!(user["kind"].is_string());
                } else {
                    assert!(input["tools"].is_null());
                    assert_eq!(messages.len(),3+tools.len());
                    for (proposal, message) in tools.iter().zip(&messages[3..]) {
                        assert_eq!(message["role"], "tool");
                        assert_eq!(message["tool_call_id"],proposal["id"]);
                        let result:Value=serde_json::from_str(message["content"].as_str().unwrap()).unwrap();
                        assert_eq!(result["window_start"],evidence["window_start"]);
                        assert_eq!(result["window_end"],evidence["window_end"]);
                        if proposal["name"]=="public_search" {
                            assert_eq!(result.as_object().unwrap().len(),3);
                            assert_eq!(result["examples"], evidence["examples"]);
                        } else {
                            assert_eq!(result.as_object().unwrap().len(),4);
                            assert_eq!(result["posts_count"], evidence["posts_count"]);
                            assert_eq!(result["comments_count"], evidence["comments_count"]);
                        }
                    }
                }
                if (count==1||continued)&&!tools.is_empty() {
                    let proposals:Vec<_>=tools.iter().map(|proposal|json!({"id":proposal["id"],"type":"function",
                        "function":{"name":proposal["name"],"arguments":proposal["arguments"].to_string()}})).collect();
                    Json(json!({"choices":[{"index":0,"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":proposals}}]}))
                } else {
                    Json(json!({"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"人工审阅草稿"}}]}))
                }
            }
        }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move { axum::serve(listener, provider).await.unwrap() });
        let capabilities=if condition=="tools_unsupported" { vec!["structured-output"] } else { vec!["tools","structured-output"] };
        let context=match condition {
            "low_budget" => 700,
            "trimmed" => spec["bulk"]["context"].as_u64().unwrap(),
            _ => 8192,
        };
        let config=json!({"schemaVersion":1,"revision":7,"providers":[{"id":"local","adapter":"openai-compatible","baseUrl":url}],"models":[{"id":"writer","providerId":"local","model":"test-model","capabilities":capabilities,"contextWindowTokens":context,"maxOutputTokens":512}],"bindings":{"knowledge":"writer","writing":"writer","agent":"writer","moderation":"writer"}}).to_string();
        let codec = TokenCodec::new(
            auth["keys"]["access"].as_str().unwrap().as_bytes(),
            auth["keys"]["refresh"].as_str().unwrap().as_bytes(),
        )
        .unwrap();
        let store = Arc::new(Store {
            condition: condition.into(),
            evidence: storage_evidence,
            written: Mutex::new(None),
            loads: AtomicUsize::new(0),
            reservations: AtomicUsize::new(0),
            retry_after: entry["retryAfter"].as_u64().unwrap_or(0),
        });
        let app = build_native_router(
            codec,
            store.clone(),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
        )
        .layer(Extension(Settings::from_lookup(&|key| {
            (key == "AI_MODEL_CONFIG_JSON").then(|| config.clone())
        })))
        .layer(Extension(AiModelQuota(store.clone())));
        let mut req = Request::post(
            "/api/v2/ai/conversations/f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb/group-generate",
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
            "{}",
            entry["id"]
        );
        assert_eq!(response.headers()["cache-control"], "private, no-store");
        assert_eq!(
            response.headers().get("retry-after").map(|value|value.to_str().unwrap().to_owned()),
            entry["retryAfter"].as_u64().map(|value|value.to_string()),
        );
        assert_eq!(store.reservations.load(Ordering::Relaxed) as u64,entry["reservations"].as_u64().unwrap());
        assert_eq!(store.loads.load(Ordering::Relaxed) as u64,entry["loads"].as_u64().unwrap());
        assert_eq!(calls.load(Ordering::Relaxed) as u64,entry["inferences"].as_u64().unwrap());
        let body: Value =
            serde_json::from_slice(&to_bytes(response.into_body(), 65536).await.unwrap()).unwrap();
        if let Some(status) = entry["status"].as_str() {
            assert_eq!(body["data"]["status"], status);
        }
        let written = store.written.lock().unwrap();
        if entry["status"] == "generated" {
            let (saved_digest,names,size)=written.as_ref().unwrap();
            assert_eq!(Some(saved_digest.as_str()), digest.as_str());
            assert_eq!(*size,used_examples);
            assert_eq!(names.iter().map(String::as_str).collect::<Vec<_>>(),
                proposals.iter().map(|call|call["name"].as_str().unwrap()).collect::<Vec<_>>());
        } else {
            assert!(written.is_none());
        }
        task.abort();
    }
}
