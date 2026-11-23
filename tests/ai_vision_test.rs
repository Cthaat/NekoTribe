#[path = "support/ai_model_quota.rs"]
mod ai_model_quota;

use axum::{
    Extension, Json, Router,
    body::{Body, to_bytes},
    http::Request,
    routing::post,
};
use nekotribe_backend::{
    ai::{
        conversation_store::{AiOperation, Error, ModerationPolicy},
        model_quota::{AiModelQuota, AiModelQuotaLimiter, QuotaFuture},
        writing::Settings,
    },
    auth::{
        TokenClaims, TokenCodec,
        sessions::{CorsPolicy, SessionRepository, StoreFuture, build_native_router},
    },
    media::vision::{AltTextUpdate, Asset},
    storage::local_http::LocalStorageConfig,
};
use serde_json::{Value, json};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicUsize, Ordering},
};
use tower::ServiceExt;

const PNG: &[u8] = b"\x89PNG\r\n\x1a\nfixture";
const PRIVATE_KEY: &str = "private/post/42/draft.png";
const PUBLIC_KEY: &str = "posts/images/42/published.png";
const GENERATE: &str =
    "/api/v2/ai/conversations/f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb/moderation-generate";
const DESCRIBE: &str = "/api/v2/ai/media/describe";

struct ExhaustedQuota;

impl AiModelQuotaLimiter for ExhaustedQuota {
    fn reserve(&self, actor: u64, cost: u64) -> QuotaFuture<'_> {
        assert_eq!((actor, cost), (42, 1));
        Box::pin(async { Ok(14) })
    }
}

#[derive(Default)]
struct Store {
    checks: AtomicUsize,
    writes: Mutex<Vec<(i64, Option<String>)>>,
    saved: Mutex<Option<Value>>,
    moderation: Option<&'static str>,
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
    fn owned_vision_image(&self, actor: i64, media_id: i64) -> StoreFuture<'_, Option<Asset>> {
        Box::pin(async move {
            assert_eq!(actor, 42);
            let checks = self.checks.fetch_add(1, Ordering::Relaxed);
            let (key, mime) = match media_id {
                7 => (PRIVATE_KEY, "image/png"),
                8 => (PRIVATE_KEY, "image/gif"),
                9 => ("private/post/42/broken.png", "image/png"),
                10 if checks < 2 => (PRIVATE_KEY, "image/png"),
                _ => return Ok(None),
            };
            Ok(Some(
                serde_json::from_value(asset(media_id, key, "post", mime)).unwrap(),
            ))
        })
    }
    fn update_media_alt_text(
        &self,
        actor: i64,
        media_id: i64,
        alt: Option<String>,
    ) -> StoreFuture<'_, AltTextUpdate> {
        Box::pin(async move {
            assert_eq!(actor, 42);
            Ok(match media_id {
                7 => {
                    self.writes.lock().unwrap().push((media_id, alt));
                    AltTextUpdate::Updated
                }
                8 => AltTextUpdate::Attached,
                _ => AltTextUpdate::Missing,
            })
        })
    }
    fn ai_conversation(
        &self,
        actor: u64,
        operation: AiOperation,
        _: ModerationPolicy,
    ) -> StoreFuture<'_, Result<Value, Error>> {
        Box::pin(async move {
            assert_eq!(actor, 42);
            let mode = self.moderation.unwrap();
            Ok(match operation {
                AiOperation::ModerationAdviceLoad {
                    request,
                    include_images,
                    ..
                } => {
                    assert_eq!(include_images, mode != "text");
                    let images = if include_images {
                        vec![asset(7, PUBLIC_KEY, "public", "image/png")]
                    } else {
                        Vec::new()
                    };
                    Ok(json!({"generation":4,"material":{
                        "target":{"target_type":request.kind,"target_id":request.id,"post_id":request.id,"group_id":null,"digest":"a".repeat(64)},
                        "content":if mode == "text" { "ordinary text" } else { "" },"terms_digest":"b".repeat(64),"terms_generation":9,
                        "images":images,"rules":[{"id":3,"version":"c".repeat(64),"title":"Conduct","blocks":["Rule"]}]
                    }}))
                }
                AiOperation::ModerationAdviceValidateImages {
                    sources, target, ..
                } => {
                    assert_eq!(sources[0].media_id, 7);
                    assert_eq!(target.id, 11);
                    if mode == "preflight-stale" {
                        Err(Error::Conflict)
                    } else {
                        Ok(Value::Null)
                    }
                }
                AiOperation::ModerationAdviceSave { record, .. } => {
                    if mode == "stale" {
                        return Ok(Err(Error::Conflict));
                    }
                    *self.saved.lock().unwrap() = Some(serde_json::to_value(record).unwrap());
                    Ok(json!({"role":"assistant","sequence_no":1}))
                }
                _ => panic!("unexpected operation"),
            })
        })
    }
}

fn asset(id: i64, key: &str, scope: &str, mime: &str) -> Value {
    json!({"media_id":id,"storage_key":key,"access_scope":scope,"mime_type":mime,"file_size":PNG.len()})
}

fn app(
    store: Arc<Store>,
    path: &std::path::Path,
    url: &str,
    vision: bool,
    quota: Option<AiModelQuota>,
) -> (Router, String) {
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
    let capabilities = if vision {
        vec!["structured-output", "tools", "vision"]
    } else {
        vec!["structured-output", "tools"]
    };
    let configuration = json!({"schemaVersion":1,"revision":7,"providers":[{"id":"fixture","adapter":"openai-compatible","baseUrl":url}],"models":[{"id":"fixture","providerId":"fixture","model":"fixture","capabilities":capabilities,"contextWindowTokens":8192,"maxOutputTokens":512}],"bindings":{"knowledge":"fixture","writing":"fixture","agent":"fixture","moderation":"fixture"}}).to_string();
    let app = build_native_router(
        codec,
        store,
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_000),
    )
    .layer(Extension(LocalStorageConfig {
        root: path.into(),
        unsupported: false,
        s3: None,
    }))
    .layer(Extension(
        quota.unwrap_or_else(ai_model_quota::single_call_quota),
    ))
    .layer(Extension(Settings::from_lookup(&|key| {
        (key == "AI_MODEL_CONFIG_JSON").then(|| configuration.clone())
    })));
    (app, format!("Bearer {token}"))
}

fn fixture_files() -> tempfile::TempDir {
    let root = tempfile::tempdir().unwrap();
    for key in [PRIVATE_KEY, PUBLIC_KEY, "private/post/42/broken.png"] {
        let path = root.path().join(key);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(
            path,
            if key.ends_with("broken.png") {
                vec![0; PNG.len()]
            } else {
                PNG.to_vec()
            },
        )
        .unwrap();
    }
    root
}

#[tokio::test]
async fn describe_only_authorized_valid_storage_and_bound_model_quota() {
    let root = fixture_files();
    let calls = Arc::new(AtomicUsize::new(0));
    let seen = calls.clone();
    let provider = Router::new().route("/chat/completions", post(move |Json(input): Json<Value>| {
        let seen = seen.clone();
        async move {
            seen.fetch_add(1, Ordering::Relaxed);
            assert_eq!(input["messages"][1]["content"][1]["image_url"]["url"], "data:image/png;base64,iVBORw0KGgpmaXh0dXJl");
            assert_eq!(input["stream"], false);
            Json(json!({"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":json!({"alt_text":" A kitten ","tags":["#cat","cat"]}).to_string()}}]}))
        }
    }));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move { axum::serve(listener, provider).await.unwrap() });
    for (body, model_vision, status, model_calls) in [
        (json!({"media_id":7,"locale":"en"}), true, 200, 1),
        (json!({"media_id":8,"locale":"en"}), true, 400, 0),
        (json!({"media_id":9,"locale":"en"}), true, 404, 0),
        (json!({"media_id":10,"locale":"en"}), true, 404, 1),
        (json!({"media_id":11,"locale":"en"}), true, 404, 0),
        (
            json!({"media_id":"https://example.com/a.png","locale":"en"}),
            true,
            400,
            0,
        ),
        (json!({"media_id":7,"locale":"en"}), false, 503, 0),
    ] {
        let last = calls.load(Ordering::Relaxed);
        let (app, token) = app(
            Arc::new(Store::default()),
            root.path(),
            &url,
            model_vision,
            None,
        );
        let response = app
            .oneshot(
                Request::post(DESCRIBE)
                    .header("authorization", token)
                    .body(Body::from(body.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), status);
        assert_eq!(response.headers()["cache-control"], "private, no-store");
        if status == 200 {
            let data: Value =
                serde_json::from_slice(&to_bytes(response.into_body(), 4096).await.unwrap())
                    .unwrap();
            assert_eq!(
                data["data"],
                json!({"media_id":7,"alt_text":"A kitten","tags":["cat"]})
            );
        }
        assert_eq!(calls.load(Ordering::Relaxed) - last, model_calls);
    }
    let before = calls.load(Ordering::Relaxed);
    let (app, token) = app(
        Arc::new(Store::default()),
        root.path(),
        &url,
        true,
        Some(AiModelQuota(Arc::new(ExhaustedQuota))),
    );
    let denied = app
        .oneshot(
            Request::post(DESCRIBE)
                .header("authorization", token)
                .body(Body::from(json!({"media_id":7,"locale":"en"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(denied.status(), 429);
    assert_eq!(denied.headers()["retry-after"], "14");
    assert_eq!(calls.load(Ordering::Relaxed), before);
    task.abort();
}

#[tokio::test]
async fn patch_only_unattached_owned_media_and_clears_empty_alt_text() {
    let root = fixture_files();
    let store = Arc::new(Store::default());
    let (app, token) = app(store.clone(), root.path(), "http://localhost", true, None);
    for (id, body, status) in [
        (7, r#"{"alt_text":" A cat "}"#, 200),
        (7, r#"{"alt_text":""}"#, 200),
        (7, r#"{"alt_text":"old","alt_text":"new"}"#, 400),
        (8, r#"{"alt_text":"cat"}"#, 409),
        (9, r#"{"alt_text":"cat"}"#, 404),
    ] {
        let response = app
            .clone()
            .oneshot(
                Request::patch(format!("/api/v2/media/{id}"))
                    .header("authorization", &token)
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), status);
    }
    assert_eq!(
        *store.writes.lock().unwrap(),
        vec![(7, Some("A cat".into())), (7, None)]
    );
}

#[tokio::test]
async fn image_only_moderation_revalidates_and_saves_version_two_without_deltas() {
    let root = fixture_files();
    let calls = Arc::new(AtomicUsize::new(0));
    let seen = calls.clone();
    let provider = Router::new().route("/chat/completions", post(move |Json(input): Json<Value>| {
        let seen = seen.clone();
        async move {
            seen.fetch_add(1, Ordering::Relaxed);
            let content = &input["messages"][1]["content"];
            if let Some(text) = content.as_str() {
                assert!(text.contains("ordinary text"));
            } else {
                assert_eq!(content[1]["image_url"]["url"], "data:image/png;base64,iVBORw0KGgpmaXh0dXJl");
            }
            assert_eq!(input["stream"], false);
            let text = json!({"risk":"none","reason":"Looks safe","recommendation":"no_action","rule_ids":[3]}).to_string();
            Json(json!({"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":text}}]}))
        }
    }));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move { axum::serve(listener, provider).await.unwrap() });
    for (mode, status, provider_calls) in [
        ("vision", 200, 1),
        ("stale", 409, 1),
        ("preflight-stale", 409, 0),
        ("text", 200, 1),
    ] {
        let before = calls.load(Ordering::Relaxed);
        let store = Arc::new(Store {
            moderation: Some(mode),
            ..Store::default()
        });
        let (app, token) = app(store.clone(), root.path(), &url, mode != "text", None);
        let mut request = Request::post(GENERATE).header("authorization", token);
        if mode != "text" {
            request = request.header("accept", "text/event-stream");
        }
        let response = app.oneshot(request
            .body(Body::from(json!({"target_type":"post","target_id":11,"expected_sequence":0,"locale":"zh"}).to_string())).unwrap()).await.unwrap();
        assert_eq!(response.status(), status);
        let body = to_bytes(response.into_body(), 4096).await.unwrap();
        assert!(!std::str::from_utf8(&body).unwrap().contains("event: delta"));
        assert_eq!(calls.load(Ordering::Relaxed) - before, provider_calls);
        let saved = store.saved.lock().unwrap();
        if mode == "text" {
            let saved = saved.as_ref().unwrap();
            assert_eq!(saved["version"], 1);
            assert!(saved.get("image_sources").is_none());
        } else if status == 200 {
            let saved = saved.as_ref().unwrap();
            assert_eq!(saved["version"], 2);
            assert_eq!(saved["image_sources"][0]["media_id"], 7);
            assert!(
                saved["image_sources"][0]["version"]
                    .as_str()
                    .is_some_and(|version| version.len() == 64)
            );
        } else {
            assert!(saved.is_none());
        }
    }
    task.abort();
}
