use axum::{
    body::{Body, Bytes, to_bytes},
    http::{Request, header},
    middleware::Next,
    response::{IntoResponse, Response},
};
use serde_json::{Value, json};
use std::{convert::Infallible, future::Future};
use tokio::{sync::mpsc, task::JoinHandle};

tokio::task_local! {
    static DELTAS: Option<mpsc::Sender<Bytes>>;
}

pub(crate) fn sender() -> Option<mpsc::Sender<Bytes>> {
    DELTAS.try_with(Clone::clone).ok().flatten()
}

pub(crate) async fn without_deltas<T>(operation: impl Future<Output = T>) -> T {
    DELTAS.scope(None, operation).await
}

pub(crate) fn delta(text: &str) -> Bytes {
    frame("delta", &json!({ "text": text }))
}

fn frame(kind: &str, data: &Value) -> Bytes {
    Bytes::from(format!("event: {kind}\ndata: {data}\n\n"))
}

fn failed() -> Value {
    json!({ "code": 50001, "message": "服务器内部错误", "data": null, "meta": null })
}

async fn terminal(response: Response) -> Bytes {
    let success = response.status().is_success();
    let result = to_bytes(response.into_body(), 1024 * 1024)
        .await
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok());
    match result {
        Some(value) => frame(if success { "done" } else { "failed" }, &value),
        None => frame("failed", &failed()),
    }
}

fn event_response(body: Body) -> Response {
    (
        [
            (header::CONTENT_TYPE, "text/event-stream; charset=utf-8"),
            (header::CACHE_CONTROL, "private, no-store"),
            (header::HeaderName::from_static("x-accel-buffering"), "no"),
        ],
        body,
    )
        .into_response()
}

struct CancelOnDrop(JoinHandle<Response>);

impl Drop for CancelOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

pub(crate) async fn stream_response(request: Request<Body>, next: Next) -> Response {
    let accept = request
        .headers()
        .get(header::ACCEPT)
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default();
    let streamed = accept.split(',').any(|entry| {
        let mut parts = entry.split(';').map(str::trim);
        parts
            .next()
            .is_some_and(|kind| kind.eq_ignore_ascii_case("text/event-stream"))
            && !parts.any(|param| param == "q=0")
    });
    if !streamed {
        return next.run(request).await;
    }

    let (sender, mut events) = mpsc::channel(8);
    let id = request.extensions().get::<crate::middleware::request_id::RequestId>().cloned();
    let mut task = CancelOnDrop(tokio::spawn(crate::middleware::request_id::scope(
        id, DELTAS.scope(Some(sender), next.run(request)),
    )));
    // Prioritize queued deltas when a provider emits its last chunk and returns together.
    let first = tokio::select! {
        biased;
        Some(chunk) = events.recv() => chunk,
        result = &mut task.0 => {
            return match result {
                Ok(response) if response.status().is_success() => event_response(Body::from(terminal(response).await)),
                Ok(response) => response,
                Err(_) => (axum::http::StatusCode::INTERNAL_SERVER_ERROR, axum::Json(failed())).into_response(),
            };
        }
    };
    let remaining = futures_util::stream::unfold(
        (events, Some(task), Some(first)),
        |(mut events, mut task, first)| async move {
            if let Some(first) = first {
                return Some((Ok::<_, Infallible>(first), (events, task, None)));
            }
            if let Some(event) = events.recv().await {
                return Some((Ok(event), (events, task, None)));
            }
            let mut completed = task.take()?;
            let last = match (&mut completed.0).await {
                Ok(response) => terminal(response).await,
                Err(_) => frame("failed", &failed()),
            };
            Some((Ok(last), (events, None, None)))
        },
    );
    event_response(Body::from_stream(remaining))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{Json, Router, middleware, routing::post};
    use tower::ServiceExt;

    #[tokio::test]
    async fn generation_stream_terminates_after_the_handler_result() {
        let app = Router::new().route(
            "/",
            post(|| async {
                sender().unwrap().send(delta("draft")).await.unwrap();
                (
                    axum::http::StatusCode::CONFLICT,
                    Json(json!({"code":40901,"data":null})),
                )
            })
            .layer(middleware::from_fn(stream_response)),
        );
        let result = app
            .oneshot(
                Request::post("/")
                    .header(header::ACCEPT, "text/event-stream")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            result.headers()[header::CONTENT_TYPE],
            "text/event-stream; charset=utf-8"
        );
        let body = to_bytes(result.into_body(), 4096).await.unwrap();
        let body = std::str::from_utf8(&body).unwrap();
        assert!(body.starts_with("event: delta\ndata: {\"text\":\"draft\"}\n\n"));
        assert!(body.ends_with("event: failed\ndata: {\"code\":40901,\"data\":null}\n\n"));
    }

    #[tokio::test]
    async fn restricted_inference_cannot_access_the_response_delta_sender() {
        let (response_sender, mut events) = mpsc::channel(8);
        DELTAS
            .scope(Some(response_sender), async {
                without_deltas(async {
                    tokio::task::yield_now().await;
                    assert!(sender().is_none());
                })
                .await;
                sender().unwrap().send(delta("public draft")).await.unwrap();
            })
            .await;
        assert_eq!(events.recv().await.unwrap(), delta("public draft"));
        assert!(events.recv().await.is_none());
    }
}
