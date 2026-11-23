//! Optional read-only SentimentFlow transport, configured exclusively by the operator.
use futures_util::future::try_join_all;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex, OnceLock},
    time::Duration,
};
use tokio::time::Instant;

pub(crate) const TOOL_NAME: &str = "community_sentiment_summary";

#[derive(Deserialize)]
struct Contract {
    tool: Value,
    labels: HashMap<Label, Vec<String>>,
    old_scores: [Label; 6],
    timeout_ms: u64,
    failure_limit: u8,
    cooldown_ms: u64,
    max_reply_bytes: usize,
    sample_per_window: usize,
    max_samples: usize,
    queue_post_query: String,
}

fn contract() -> &'static Contract {
    static CONTRACT: OnceLock<Contract> = OnceLock::new();
    CONTRACT.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../../contracts/requirements/ai-sentiment.json"
        ))
        .expect("valid SentimentFlow contract")
    })
}

pub(crate) fn tool() -> &'static Value {
    &contract().tool
}
pub(crate) fn sample_per_window() -> usize {
    contract().sample_per_window
}
pub(crate) fn max_samples() -> usize {
    contract().max_samples
}
pub(crate) fn queue_post_query() -> &'static str {
    &contract().queue_post_query
}

#[derive(Debug, Clone, Copy, Hash, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum Label {
    Positive,
    Neutral,
    Negative,
}

#[derive(Debug, Clone, Copy, Serialize)]
pub(crate) struct Signal {
    pub label: Label,
    pub confidence: f64,
}

fn decode_prediction(raw: &Value) -> Option<Signal> {
    let outer = raw.as_object()?;
    let envelope = match outer.get("data") {
        Some(data) => data.as_object()?,
        None => outer,
    };
    let nested = envelope.get("prediction");
    let prediction = match nested {
        Some(prediction) => prediction.as_object()?,
        None => envelope,
    };
    let confidence = prediction
        .get("confidence")?
        .as_f64()
        .filter(|value| (0.0..=1.0).contains(value))?;
    let label = match prediction.get("label") {
        Some(value) => {
            let label = value.as_str()?;
            contract().labels.iter().find_map(|(&kind, aliases)| {
                aliases.iter().any(|alias| alias == label).then_some(kind)
            })?
        }
        None if nested.is_none() => {
            let score = prediction
                .get("score")?
                .as_f64()
                .filter(|value| (0.0..=5.0).contains(value) && value.fract() == 0.0)?;
            contract().old_scores[score as usize]
        }
        None => return None,
    };
    Some(Signal { label, confidence })
}

#[derive(Default)]
struct Breaker {
    failures: u8,
    open_until: Option<Instant>,
    epoch: u64,
}

impl Breaker {
    fn available(&self, now: Instant) -> bool {
        self.open_until.is_none_or(|until| now >= until)
    }

    fn begin(&mut self, now: Instant) -> Option<u64> {
        if !self.available(now) {
            return None;
        }
        if self.open_until.take().is_some() {
            self.failures = 0;
        }
        Some(self.epoch)
    }

    fn finish(&mut self, epoch: u64, success: bool, now: Instant) {
        if self.epoch != epoch {
            return;
        }
        if success {
            self.failures = 0;
        } else {
            self.failures += 1;
            if self.failures >= contract().failure_limit {
                self.open_until = Some(now + Duration::from_millis(contract().cooldown_ms));
                self.epoch = self.epoch.wrapping_add(1);
            }
        }
    }
}

struct Runtime {
    client: reqwest::Client,
    endpoint: reqwest::Url,
    token: Option<String>,
    breaker: Mutex<Breaker>,
}

#[derive(Clone)]
pub struct SentimentFlow(Arc<Runtime>);

pub(crate) fn configured() -> Option<&'static SentimentFlow> {
    static CLIENT: OnceLock<Option<SentimentFlow>> = OnceLock::new();
    CLIENT
        .get_or_init(|| SentimentFlow::from_lookup(|key| std::env::var(key).ok()))
        .as_ref()
}

impl SentimentFlow {
    pub fn from_lookup(get: impl Fn(&str) -> Option<String>) -> Option<Self> {
        if get("AI_SENTIMENTFLOW_ENABLED").as_deref() != Some("1") {
            return None;
        }
        let url = get("AI_SENTIMENTFLOW_URL")?;
        if url.len() > 2048 || !super::model_config::valid_url(&url) {
            return None;
        }
        let endpoint = reqwest::Url::parse(&url).ok()?;
        let token = get("AI_SENTIMENTFLOW_TOKEN").filter(|value| !value.is_empty());
        if token.as_ref().is_some_and(|value| {
            value.len() > 4096 || !value.bytes().all(|byte| (b'!'..=b'~').contains(&byte))
        }) {
            return None;
        }
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .retry(reqwest::retry::never())
            .build()
            .ok()?;
        Some(Self(Arc::new(Runtime {
            client,
            endpoint,
            token,
            breaker: Mutex::new(Breaker::default()),
        })))
    }

    pub(crate) fn available(&self) -> bool {
        self.0
            .breaker
            .lock()
            .is_ok_and(|breaker| breaker.available(Instant::now()))
    }

    pub(crate) async fn predict(&self, samples: &[&str]) -> Option<Vec<Signal>> {
        if !(1..=max_samples()).contains(&samples.len())
            || samples.iter().any(|sample| {
                crate::auth::login::js_trim(sample).is_empty() || sample.chars().count() > 400
            })
        {
            return None;
        }
        let epoch = self.0.breaker.lock().ok()?.begin(Instant::now())?;
        let limit = Duration::from_millis(contract().timeout_ms);
        let result = tokio::time::timeout(
            limit,
            try_join_all(samples.iter().map(|sample| self.predict_one(sample))),
        )
        .await
        .ok()
        .and_then(Result::ok);
        self.0
            .breaker
            .lock()
            .ok()?
            .finish(epoch, result.is_some(), Instant::now());
        result
    }

    async fn predict_one(&self, text: &str) -> Result<Signal, ()> {
        let mut request = self.0.client.post(self.0.endpoint.clone()).json(&json!({
            "text":text,"model":"lstm","return_probabilities":false,"include_metadata":false
        }));
        if let Some(token) = &self.0.token {
            request = request.bearer_auth(token);
        }
        let mut response = request.send().await.map_err(|_| ())?;
        let max = contract().max_reply_bytes;
        if !response.status().is_success()
            || response
                .content_length()
                .is_some_and(|size| size > max as u64)
        {
            return Err(());
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| ())? {
            if chunk.len() > max - bytes.len() {
                return Err(());
            }
            bytes.extend_from_slice(&chunk);
        }
        let raw = serde_json::from_slice(&bytes).map_err(|_| ())?;
        decode_prediction(&raw).ok_or(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn decodes_current_and_legacy_classification_without_fabricating_values() {
        let label = |response: Value| decode_prediction(&response).map(|signal| signal.label);
        assert_eq!(
            label(json!({"prediction":{"label":"clearly_positive","confidence":0.95}})),
            Some(Label::Positive)
        );
        assert_eq!(
            label(json!({"data":{"label":"neutral","confidence":0.5}})),
            Some(Label::Neutral)
        );
        for (score, expected) in [
            Label::Negative,
            Label::Negative,
            Label::Negative,
            Label::Neutral,
            Label::Positive,
            Label::Positive,
        ]
        .into_iter()
        .enumerate()
        {
            assert_eq!(
                label(json!({"score":score,"confidence":0.0})),
                Some(expected)
            );
        }
        for invalid in [
            json!({"score":0,"confidence":1.5}),
            json!({"score":3,"label":"unknown","confidence":0.4}),
            json!({"score":0.5,"confidence":1}),
            json!({"label":"negative"}),
        ] {
            assert!(label(invalid).is_none());
        }
    }

    #[test]
    fn consecutive_failures_open_circuit_for_fixed_cooldown() {
        let start = Instant::now();
        let mut breaker = Breaker::default();
        let first_epoch = breaker.begin(start).unwrap();
        breaker.finish(first_epoch, false, start);
        breaker.finish(first_epoch, false, start);
        breaker.finish(first_epoch, true, start);
        assert!(breaker.available(start));
        for _ in 0..3 {
            breaker.finish(first_epoch, false, start);
        }
        breaker.finish(first_epoch, true, start);
        assert!(
            breaker
                .begin(start + Duration::from_millis(29_999))
                .is_none()
        );
        let next = breaker.begin(start + Duration::from_secs(30)).unwrap();
        assert_ne!(next, first_epoch);
        assert_eq!(breaker.failures, 0);
    }

    #[tokio::test]
    async fn response_batches_bound_deadline_size_and_redirects() {
        use axum::{
            Json, Router,
            http::{HeaderMap, StatusCode},
            response::IntoResponse,
            routing::post,
        };
        use std::sync::atomic::{AtomicUsize, Ordering};
        let hits = Arc::new(AtomicUsize::new(0));
        let redirect_hits = hits.clone();
        let app = Router::new()
            .route("/predict/", post(|headers: HeaderMap, Json(body): Json<Value>| async move {
                assert_eq!(headers["authorization"], "Bearer fixture-token");
                assert_eq!(body, json!({"text":body["text"],"model":"lstm","return_probabilities":false,"include_metadata":false}));
                match body["text"].as_str() {
                    Some("redirect") => (StatusCode::TEMPORARY_REDIRECT, [("location", "/redirect-target")]).into_response(),
                    Some("large") => (StatusCode::OK, "x".repeat(17 * 1024)).into_response(),
                    Some("slow") => {
                        tokio::time::sleep(Duration::from_secs(4)).await;
                        StatusCode::OK.into_response()
                    }
                    _ => Json(json!({"prediction":{"label":"slightly_positive","confidence":0.5}})).into_response(),
                }
            }))
            .route("/redirect-target", post(move || async move {
                redirect_hits.fetch_add(1, Ordering::Relaxed);
                StatusCode::OK
            }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/predict/", listener.local_addr().unwrap());
        let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let client = SentimentFlow::from_lookup(|name| match name {
            "AI_SENTIMENTFLOW_ENABLED" => Some("1".into()),
            "AI_SENTIMENTFLOW_URL" => Some(url.clone()),
            "AI_SENTIMENTFLOW_TOKEN" => Some("fixture-token".into()),
            _ => None,
        })
        .unwrap();
        let result = client.predict(&["valid"; 8]).await.unwrap();
        assert_eq!(result.len(), 8);
        assert!(client.predict(&["valid"; 9]).await.is_none());
        assert!(client.predict(&["redirect"]).await.is_none());
        assert!(client.predict(&["large"]).await.is_none());
        let start = Instant::now();
        assert!(client.predict(&["valid", "slow"]).await.is_none());
        assert!(start.elapsed() < Duration::from_secs(3));
        assert!(!client.available());
        assert!(client.predict(&["valid"]).await.is_none());
        assert_eq!(hits.load(Ordering::Relaxed), 0);
        task.abort();
    }
}
