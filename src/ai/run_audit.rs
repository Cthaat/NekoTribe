use std::time::Instant;

use super::model_quota::QuotaError;
use crate::{
    middleware::request_id::{self, RequestId},
    observability::{metrics, AiResult},
};

pub(super) struct AiRunAudit {
    operation: &'static str,
    request_id: Option<RequestId>,
    pub stage: &'static str,
    pub config_revision: u64,
    skill_generation: i64,
    pub skill_selection: &'static str,
    pub tool_count: usize,
    started_at: Instant,
    finished: bool,
}

impl AiRunAudit {
    pub fn new(operation: &'static str, skill_generation: i64) -> Self {
        Self {
            operation,
            request_id: request_id::current(),
            stage: "validation",
            config_revision: 0,
            skill_generation,
            skill_selection: "purpose-default",
            tool_count: 0,
            started_at: Instant::now(),
            finished: false,
        }
    }

    pub fn finish<T, E>(
        &mut self,
        result: &Result<Option<T>, E>,
        cancelled: bool,
        quota_error: impl FnOnce(&E) -> Option<QuotaError>,
    ) {
        let outcome = match result {
            Ok(Some(_)) => "generated",
            Ok(None) => "insufficient_evidence",
            Err(_) if cancelled => "cancelled",
            Err(error) => match quota_error(error) {
                Some(QuotaError::Exhausted(_)) => "quota_exhausted",
                Some(QuotaError::Unavailable) => "quota_unavailable",
                None => "failed",
            },
        };
        self.finished = true;
        self.emit(outcome);
    }

    fn emit(&self, outcome: &'static str) {
        let elapsed = self.started_at.elapsed();
        let result = match outcome {
            "generated" | "insufficient_evidence" => AiResult::Success,
            "cancelled" => AiResult::Cancelled,
            _ => AiResult::Failure,
        };
        metrics().ai(
            self.operation,
            result,
            matches!(outcome, "quota_exhausted" | "quota_unavailable"),
            elapsed,
        );
        tracing::info!(
            event = "ai.run",
            version = 1,
            operation = self.operation,
            request_id = self.request_id.as_ref().map(|id| id.0.as_str()),
            stage = self.stage,
            outcome,
            config_revision = self.config_revision,
            skill_generation = self.skill_generation,
            skill_selection = self.skill_selection,
            tool_count = self.tool_count,
            elapsed_ms = elapsed.as_millis() as u64,
            "AI run finished"
        );
    }
}

impl Drop for AiRunAudit {
    fn drop(&mut self) {
        if !self.finished {
            self.emit(if std::thread::panicking() {
                "failed"
            } else {
                "cancelled"
            });
        }
    }
}

#[cfg(test)]
mod observability_tests {
    use super::*;
    use axum::{
        body::{to_bytes, Body},
        http::Request,
        middleware,
        routing::post,
        Json, Router,
    };
    use std::{
        collections::BTreeMap,
        fmt,
        sync::{Arc, Mutex},
    };
    use tower::ServiceExt;
    use tracing::{
        field::{Field, Visit},
        Event, Subscriber,
    };
    use tracing_subscriber::{layer::Context, prelude::*, Layer};

    #[derive(Default)]
    struct Fields(BTreeMap<&'static str, String>);

    impl Visit for Fields {
        fn record_debug(&mut self, field: &Field, value: &dyn fmt::Debug) {
            self.0.insert(field.name(), format!("{value:?}"));
        }

        fn record_str(&mut self, field: &Field, value: &str) {
            self.0.insert(field.name(), value.to_owned());
        }
    }

    #[derive(Clone, Default)]
    struct Capture(Arc<Mutex<Vec<Fields>>>);

    impl<S: Subscriber> Layer<S> for Capture {
        fn on_event(&self, event: &Event<'_>, _: Context<'_, S>) {
            let mut fields = Fields::default();
            event.record(&mut fields);
            self.0.lock().unwrap().push(fields);
        }
    }

    #[tokio::test]
    async fn sse_audit_and_http_completion_share_request_id_without_recording_body_or_query() {
        let capture = Capture::default();
        let _guard =
            tracing::subscriber::set_default(tracing_subscriber::registry().with(capture.clone()));
        let app = Router::new()
            .route(
                "/flows/{id}",
                post(|| async {
                    let mut audit = AiRunAudit::new("writing_draft", 0);
                    let result = Ok::<_, QuotaError>(Some(()));
                    super::super::stream_response::sender()
                        .unwrap()
                        .send(super::super::stream_response::delta(
                            "no-log-upstream-response",
                        ))
                        .await
                        .unwrap();
                    tokio::task::yield_now().await;
                    audit.finish(&result, false, |_| None);
                    Json("no-log-result-body")
                })
                .layer(middleware::from_fn(
                    super::super::stream_response::stream_response,
                )),
            )
            .layer(middleware::from_fn(
                crate::middleware::logging::observe_request,
            ))
            .layer(middleware::from_fn(request_id::request_id));
        let response = app
            .oneshot(
                Request::post("/flows/no-log-path?q=no-log-query")
                    .header("x-request-id", "stream:fixture")
                    .header("authorization", "Bearer no-log-authorization")
                    .header("accept", "text/event-stream")
                    .body(Body::from("no-log-input-body"))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.headers()["x-request-id"], "stream:fixture");
        let bytes = to_bytes(response.into_body(), 4096).await.unwrap();
        assert!(std::str::from_utf8(&bytes)
            .unwrap()
            .contains("no-log-upstream-response"));
        let events = capture.0.lock().unwrap();
        for expected in ["http.complete", "ai.run"] {
            let event = events
                .iter()
                .find(|fields| fields.0.get("event").is_some_and(|name| name == expected))
                .unwrap();
            assert_eq!(event.0["request_id"], "stream:fixture");
            if expected == "http.complete" {
                assert_eq!(event.0["path"], "/flows/{id}");
            }
            assert!(!event.0.values().any(|value| value.contains("no-log-")));
        }
    }
}
