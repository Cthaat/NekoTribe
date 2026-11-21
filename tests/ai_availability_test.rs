use axum::{
    body::{to_bytes, Body},
    http::Request,
};
use nekotribe_backend::{
    ai::{
        conversation_store::{AiOperation, Error, ModerationPolicy},
        skill_selection::Registry,
    },
    auth::{
        sessions::{build_native_router, CorsPolicy, SessionRepository, StoreFuture},
        TokenClaims, TokenCodec,
    },
};
use serde_json::{json, Value};
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};
use tower::ServiceExt;

#[test]
fn shared_configuration_vectors_only_expose_released_skills() {
    let fixture: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/ai-availability.json")).unwrap();
    for c in fixture["cases"].as_array().unwrap() {
        if c["authenticated"] != true {
            continue;
        }
        let result = if c["unavailable"] == true {
            None
        } else {
            serde_json::from_value::<Vec<String>>(c["enabled"].clone())
                .ok()
                .and_then(|v| Registry::new(&v).ok())
        };
        assert_eq!(result.is_some(), c["status"] == 200, "{}", c["id"]);
        if let Some(registry) = result {
            assert_eq!(
                serde_json::to_value(registry.user_availability()).unwrap(),
                c["data"],
                "{}",
                c["id"]
            )
        }
    }
}
struct Store {
    calls: AtomicUsize,
    fail: bool,
}
impl SessionRepository for Store {
    fn touch<'a>(&'a self, c: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async move { Ok(u64::from(c.user_id == 42)) })
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
        op: AiOperation,
        _: ModerationPolicy,
    ) -> StoreFuture<'_, Result<Value, Error>> {
        Box::pin(async move {
            assert!(matches!(op, AiOperation::Availability));
            self.calls.fetch_add(1, Ordering::SeqCst);
            Ok(if self.fail {
                Err(Error::SchemaUnavailable)
            } else {
                Ok(json!({"knowledge":true,"writing":false,"group":true,"moderation":false}))
            })
        })
    }
}
#[tokio::test]
async fn route_requires_login_disables_cache_and_sanitizes_unavailability() {
    let f: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = f["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    for (authorized, fail, status) in [(false, false, 401), (true, false, 200), (true, true, 503)] {
        let codec = TokenCodec::new(
            f["keys"]["access"].as_str().unwrap().as_bytes(),
            f["keys"]["refresh"].as_str().unwrap().as_bytes(),
        )
        .unwrap();
        let store = Arc::new(Store {
            calls: AtomicUsize::new(0),
            fail,
        });
        let app = build_native_router(
            codec,
            store.clone(),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
        );
        let mut request = Request::get("/api/v2/ai/availability");
        if authorized {
            request = request.header("authorization", format!("Bearer {token}"))
        }
        let response = app
            .oneshot(request.body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), status);
        assert_eq!(response.headers()["cache-control"], "private, no-store");
        let body: Value =
            serde_json::from_slice(&to_bytes(response.into_body(), 65536).await.unwrap()).unwrap();
        if status == 200 {
            assert_eq!(body["data"]["knowledge"], true);
            assert_eq!(body["data"]["writing"], false);
            assert_eq!(body["data"]["group"], true);
            assert_eq!(body["data"]["moderation"], false);
            assert_eq!(
                body["data"]["skills"],
                json!([
                    {"id":"knowledge-answer","purpose":"knowledge","version":1,"enabled":true,"explicit_selection":true},
                    {"id":"writing-draft","purpose":"writing","version":1,"enabled":false,"explicit_selection":true},
                    {"id":"group-brief","purpose":"group","version":1,"enabled":true,"explicit_selection":true},
                    {"id":"moderation-advice","purpose":"moderation","version":1,"enabled":false,"explicit_selection":true}
                ])
            );
            assert_eq!(
                body["data"]["inference"],
                json!({"knowledge":false,"writing":false,"group":false,"moderation":false})
            );
            assert_eq!(
                body["data"].get("model_config_revision"),
                Some(&serde_json::Value::Null)
            );
        };
        if status == 503 {
            assert_eq!(body["code"], 50301)
        }
        assert_eq!(store.calls.load(Ordering::SeqCst), usize::from(authorized));
    }
}
