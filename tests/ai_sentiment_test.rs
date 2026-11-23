use axum::{
    Extension, Json, Router,
    body::{Body, to_bytes},
    http::{Request, StatusCode},
    response::IntoResponse,
    routing::post,
};
use nekotribe_backend::{
    ai::{
        conversation_store::{AiOperation, Error, ModerationPolicy},
        model_quota::{AiModelQuota, AiModelQuotaLimiter, QuotaFuture},
        sentiment::SentimentFlow,
        writing::Settings,
    },
    auth::{
        TokenClaims, TokenCodec,
        sessions::{CorsPolicy, SessionRepository, StoreFuture, build_native_router},
    },
    moderation::{appeals, content_queue},
};
use serde_json::{Value, json};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicUsize, Ordering},
};
use tower::ServiceExt;

const TOOL: &str = "community_sentiment_summary";
const GROUP_URL: &str =
    "/api/v2/ai/conversations/f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb/group-generate";
const QUEUE_URL: &str = "/api/v2/moderation/content";
const BOUNDARY: &str = "2026-11-15T00:00:00.000000";

struct Store {
    mode: &'static str,
    loads: AtomicUsize,
    sample_requests: AtomicUsize,
    draft: Mutex<Option<Value>>,
}

impl Store {
    fn new(mode: &'static str) -> Arc<Self> {
        Arc::new(Self {
            mode,
            loads: AtomicUsize::new(0),
            sample_requests: AtomicUsize::new(0),
            draft: Mutex::new(None),
        })
    }
}

fn evidence(previous: bool, verbose: bool) -> Value {
    let (start, end, label) = if previous {
        ("2026-11-08T00:00:00.000000", BOUNDARY, "prior")
    } else {
        (BOUNDARY, "2026-11-22T00:00:00.000000", "current")
    };
    let padding = if verbose {
        "雪".repeat(390)
    } else {
        String::new()
    };
    let examples: Vec<_> = (1..=5).map(|id| json!({"kind":"post","source_id":id,"post_id":id,"excerpt":format!("{label}-{padding}-{id}")})).collect();
    json!({"window_start":start,"window_end":end,"posts_count":5,"comments_count":0,"examples":examples})
}

impl AiModelQuotaLimiter for Store {
    fn reserve(&self, actor: u64, cost: u64) -> QuotaFuture<'_> {
        assert_eq!((actor, cost), (42, 2));
        Box::pin(async { Ok(0) })
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
        operation: AiOperation,
        _: ModerationPolicy,
    ) -> StoreFuture<'_, Result<Value, Error>> {
        Box::pin(async move {
            assert_eq!(actor, 42);
            Ok(match operation {
                AiOperation::GroupDraftLoad {
                    sentiment_requested,
                    request,
                    ..
                } => {
                    let load = self.loads.fetch_add(1, Ordering::Relaxed);
                    if self.mode == "forbidden" {
                        return Ok(Err(Error::Forbidden));
                    }
                    assert_eq!(
                        sentiment_requested,
                        load == 1
                            && matches!(self.mode, "group" | "stale" | "unavailable" | "budget")
                    );
                    assert_eq!(request.lookback().unwrap(), 7);
                    Ok(
                        json!({"evidence":evidence(false, self.mode == "budget"),"generation":4,"sentiment_previous":sentiment_requested.then(|| evidence(true, self.mode == "budget"))}),
                    )
                }
                AiOperation::GroupDraftSave { draft, .. } => {
                    assert_eq!(draft.version, 1);
                    if self.mode == "stale" {
                        assert!(draft.sentiment_source_digest.is_some());
                        return Ok(Err(Error::Conflict));
                    }
                    *self.draft.lock().unwrap() = Some(serde_json::to_value(draft).unwrap());
                    Ok(json!({"sequence_no":1,"role":"assistant"}))
                }
                _ => panic!("unexpected group operation"),
            })
        })
    }

    fn moderation_appeal(
        &self,
        actor: u64,
        op: appeals::Operation,
    ) -> StoreFuture<'_, appeals::Outcome> {
        assert_eq!(actor, 42);
        assert!(matches!(op, appeals::Operation::Authorize(_)));
        Box::pin(async { Ok(appeals::Outcome::Access(true)) })
    }

    fn moderation_content(
        &self,
        actor: u64,
        _: content_queue::Filters,
    ) -> StoreFuture<'_, (Vec<Value>, i64)> {
        assert_eq!(actor, 42);
        Box::pin(async {
            Ok((
                vec![
                    json!({"post_id":1,"content":"protected"}),
                    json!({"post_id":2}),
                    json!({"post_id":3}),
                    json!({"post_id":4}),
                ],
                90,
            ))
        })
    }

    fn moderation_sentiment_samples(
        &self,
        actor: u64,
        ids: Vec<i64>,
    ) -> StoreFuture<'_, Vec<content_queue::SentimentSample>> {
        Box::pin(async move {
            assert_eq!(actor, 42);
            let call = self.sample_requests.fetch_add(1, Ordering::Relaxed);
            assert_eq!(
                ids,
                if call == 0 {
                    vec![1, 2, 3, 4]
                } else {
                    vec![2, 3]
                }
            );
            let ids = if call == 0 { vec![2, 3] } else { vec![3] };
            Ok(ids
                .into_iter()
                .map(|id| content_queue::SentimentSample {
                    post_id: id,
                    excerpt: format!("public-{id}"),
                })
                .collect())
        })
    }
}

fn router(store: Arc<Store>, base_url: &str, enabled: bool) -> (Router, String) {
    let auth: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = auth["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    let codec = TokenCodec::new(
        auth["keys"]["access"].as_str().unwrap().as_bytes(),
        auth["keys"]["refresh"].as_str().unwrap().as_bytes(),
    )
    .unwrap();
    let context = if store.mode == "budget" { 4300 } else { 8192 };
    let config = json!({"schemaVersion":1,"revision":7,"providers":[{"id":"fixture","adapter":"openai-compatible","baseUrl":base_url}],
        "models":[{"id":"fixture","providerId":"fixture","model":"fixture","capabilities":["tools","structured-output"],"contextWindowTokens":context,"maxOutputTokens":512}],
        "bindings":{"knowledge":"fixture","writing":"fixture","agent":"fixture","moderation":"fixture"}}).to_string();
    let mut app = build_native_router(
        codec,
        store.clone(),
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_000),
    )
    .layer(Extension(AiModelQuota(store)))
    .layer(Extension(Settings::from_lookup(&|key| {
        (key == "AI_MODEL_CONFIG_JSON").then(|| config.clone())
    })));
    if enabled {
        app = app.layer(Extension(
            SentimentFlow::from_lookup(|key| match key {
                "AI_SENTIMENTFLOW_ENABLED" => Some("1".into()),
                "AI_SENTIMENTFLOW_URL" => Some(format!("{base_url}/predict/")),
                _ => None,
            })
            .unwrap(),
        ));
    }
    (app, format!("Bearer {token}"))
}

#[tokio::test]
async fn group_sentiment_is_optional_bounded_and_secret_free() {
    for (mode, enabled, expected) in [
        ("group", true, 200),
        ("stale", true, 409),
        ("budget", true, 200),
        ("unavailable", true, 200),
        ("invalid", true, 200),
        ("disabled", false, 200),
        ("forbidden", true, 403),
    ] {
        let prediction_texts = Arc::new(Mutex::new(Vec::new()));
        let observed_texts = prediction_texts.clone();
        let provider = Router::new().route("/predict/", post(move |Json(input): Json<Value>| {
            let seen = observed_texts.clone();
            async move {
                let text = input["text"].as_str().unwrap();
                seen.lock().unwrap().push(text.to_owned());
                if mode == "unavailable" { return StatusCode::SERVICE_UNAVAILABLE.into_response(); }
                assert!(!text.ends_with("-5"));
                let label = if text.starts_with("current") { "negative" } else { "positive" };
                Json(json!({"prediction":{"label":label,"confidence":0.8}})).into_response()
            }
        })).route("/chat/completions", post(move |Json(input): Json<Value>| async move {
            if let Some(tools) = input["tools"].as_array() {
                assert_eq!(tools.iter().any(|tool| tool["function"]["name"] == TOOL), enabled);
                let mut calls = vec![json!({"id":"search","type":"function","function":{"name":"public_search","arguments":"{}"}})];
                if enabled {
                    let args = if mode == "invalid" { "{\"group_id\":99}" } else { "{}" };
                    calls.push(json!({"id":"sentiment","type":"function","function":{"name":TOOL,"arguments":args}}));
                }
                return Json(json!({"choices":[{"index":0,"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":calls}}]}));
            }
            if mode == "budget" {
                assert_eq!(input["messages"][2]["tool_calls"].as_array().unwrap().len(), 1);
                assert_eq!(input["messages"].as_array().unwrap().len(), 4);
            } else if enabled {
                let payload: Value = serde_json::from_str(input["messages"][4]["content"].as_str().unwrap()).unwrap();
                if matches!(mode, "group" | "stale") {
                    assert_eq!(input["stream"], false);
                    assert_eq!(payload["status"], "available");
                    assert_eq!(payload["current"]["window_start"], BOUNDARY);
                    assert_eq!(payload["previous"]["window_end"], BOUNDARY);
                    assert_eq!(payload["current"]["negative"], 4);
                    assert_eq!(payload["previous"]["positive"], 4);
                    assert_eq!(payload["negative_share_change"], 1.0);
                    assert!(payload["current"].get("examples").is_none());
                } else { assert_eq!(payload, json!({"status":"unavailable"})); }
            }
            Json(json!({"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"reviewable draft"}}]}))
        }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move { axum::serve(listener, provider).await.unwrap() });
        let store = Store::new(mode);
        let (app, token) = router(store.clone(), &url, enabled);
        let mut request = Request::post(GROUP_URL).header("authorization", token);
        if matches!(mode, "group" | "stale") {
            request = request.header("accept", "text/event-stream");
        }
        let response = app
            .oneshot(
                request
                    .body(Body::from(
                        r#"{"kind":"weekly_report","expected_sequence":0,"search_term":"public"}"#,
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), expected, "{mode}");
        let bytes = to_bytes(response.into_body(), 4096).await.unwrap();
        assert!(!String::from_utf8_lossy(&bytes).contains("event: delta"));
        let submitted = prediction_texts.lock().unwrap();
        match mode {
            "group" | "stale" | "budget" => assert_eq!(submitted.len(), 8),
            "unavailable" => assert!(!submitted.is_empty()),
            _ => assert!(submitted.is_empty()),
        }
        if expected == 200 {
            let saved = store.draft.lock().unwrap();
            let saved = saved.as_ref().unwrap();
            assert_eq!(saved["search_term"], "public");
            assert_eq!(
                saved["tools_used"]
                    .as_array()
                    .unwrap()
                    .contains(&json!(TOOL)),
                mode == "group"
            );
            assert_eq!(
                saved.get("sentiment_source_digest").is_some(),
                mode == "group"
            );
        }
        task.abort();
    }
}

#[tokio::test]
async fn opted_in_queue_preserves_rows_and_revalidates_public_samples() {
    let submitted = Arc::new(Mutex::new(Vec::new()));
    let seen = submitted.clone();
    let provider = Router::new().route(
        "/predict/",
        post(move |Json(input): Json<Value>| {
            let seen = seen.clone();
            async move {
                seen.lock()
                    .unwrap()
                    .push(input["text"].as_str().unwrap().to_owned());
                Json(json!({"data":{"score":4,"confidence":0.98}}))
            }
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move { axum::serve(listener, provider).await.unwrap() });
    for (enabled, query, enriched) in [
        (true, "sentiment_signal=1", true),
        (true, "sentiment_signal=0", false),
        (false, "sentiment_signal=1", false),
    ] {
        let store = Store::new("queue");
        let (app, token) = router(store.clone(), &url, enabled);
        let response = app
            .oneshot(
                Request::get(format!("{QUEUE_URL}?{query}"))
                    .header("authorization", token)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
        let body: Value =
            serde_json::from_slice(&to_bytes(response.into_body(), 16384).await.unwrap()).unwrap();
        assert_eq!(body["meta"]["total"], 90);
        let items = body["data"].as_array().unwrap();
        assert_eq!(
            items
                .iter()
                .map(|item| item["post_id"].as_i64().unwrap())
                .collect::<Vec<_>>(),
            [1, 2, 3, 4]
        );
        for item in items {
            assert_eq!(
                item.get("sentiment_signal").is_some(),
                enriched && item["post_id"] == 3
            );
        }
        if enriched {
            assert_eq!(
                items[2]["sentiment_signal"],
                json!({"label":"positive","confidence":0.98})
            );
        }
        assert_eq!(
            store.sample_requests.load(Ordering::Relaxed),
            if enriched { 2 } else { 0 }
        );
    }
    let mut actual = submitted.lock().unwrap().clone();
    actual.sort();
    assert_eq!(actual, ["public-2", "public-3"]);
    task.abort();
}
