use axum::{body::Body, http::Request};
use http_body_util::BodyExt;
use nekotribe_backend::{
    auth::{
        session_repository::{OracleSessions, SessionExecutor, TOUCH_SQL},
        sessions::{build_native_router, CorsPolicy, SessionStoreError, StoreFuture},
        TokenCodec,
    },
    db::{oracle::BindMap, row::DbRow, value::DbValue},
    recommendation_feedback::{FeedbackInput, FeedbackOutcome},
};
use serde_json::Value;
use std::sync::Arc;
use tower::ServiceExt;

struct Executor(Value);
impl SessionExecutor for Executor {
    fn execute(&self, statement: &'static str, binds: BindMap) -> StoreFuture<'_, u64> {
        assert_eq!(statement, TOUCH_SQL);
        assert_eq!(binds["user_id"], DbValue::I64(42));
        Box::pin(async { Ok(1) })
    }
    fn preflight(&self, _: &'static str) -> StoreFuture<'_, ()> {
        Box::pin(async { Ok(()) })
    }
    fn query(&self, _: &'static str, _: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
        panic!("the route must call the feedback transaction")
    }
    fn write_recommendation_feedback(
        &self,
        actor: u64,
        input: FeedbackInput,
    ) -> StoreFuture<'_, FeedbackOutcome> {
        assert_eq!(actor, 42);
        if let Some(expected) = self.0["normalized"].as_object() {
            assert_eq!(input.resource_type, expected["type"].as_str().unwrap());
            assert_eq!(input.resource_id, expected["id"].as_i64().unwrap());
            assert_eq!(input.action, expected["action"].as_str().unwrap());
            assert_eq!(input.reason, expected["reason"].as_str().unwrap());
        }
        Box::pin(async move {
            if self.0["writeFailure"] == true {
                return Err(SessionStoreError);
            }
            if self.0["schemaMissing"] == true {
                return Ok(FeedbackOutcome::SchemaUnavailable);
            }
            if matches!(input.resource_id, 2 | 9) {
                return Ok(FeedbackOutcome::Missing);
            }
            assert_eq!(self.0["status"], 200, "unexpected call to storage");
            Ok(FeedbackOutcome::Saved)
        })
    }
}

#[tokio::test]
async fn shared_recommendation_feedback_payloads_reach_only_native_transactions() {
    let spec: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/recommendation-feedback.json"
    ))
    .unwrap();
    let tokens: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let access = tokens["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|case| case["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    for scenario in spec["cases"].as_array().unwrap() {
        let codec = TokenCodec::new(
            tokens["keys"]["access"].as_str().unwrap().as_bytes(),
            tokens["keys"]["refresh"].as_str().unwrap().as_bytes(),
        )
        .unwrap();
        let app = build_native_router(
            codec,
            Arc::new(OracleSessions {
                executor: Executor(scenario.clone()),
            }),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
        );
        let mut request = Request::builder()
            .method("POST")
            .uri(scenario["path"].as_str().unwrap())
            .header("content-type", "application/json");
        if scenario["anonymous"] != true {
            request = request.header("authorization", format!("Bearer {access}"));
        }
        let response = app
            .oneshot(
                request
                    .body(Body::from(scenario["body"].to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            u64::from(response.status().as_u16()),
            scenario["status"].as_u64().unwrap(),
            "{}",
            scenario["id"]
        );
        assert_eq!(response.headers()["cache-control"], "private, no-store");
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        let body: Value = serde_json::from_slice(&bytes).unwrap();
        if scenario["status"] == 200 {
            assert_eq!(body["data"]["accepted"], true);
        }
    }
}
