use axum::{
    extract::State,
    http::{header, HeaderMap, HeaderValue, Method, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    Router,
};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashMap},
    fmt::{self, Write},
    sync::{
        atomic::{AtomicU64, Ordering},
        Mutex, MutexGuard, OnceLock,
    },
    time::Duration,
};
use subtle::ConstantTimeEq;

#[cfg(test)]
mod tests;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Contract {
    pub request_id_pattern: String,
    pub metrics_path: String,
    token_environment_variable: String,
    content_type: String,
    buckets_seconds: Vec<f64>,
    http_methods: Vec<String>,
    ai_operations: Vec<String>,
    metric_families: BTreeMap<String, MetricFamily>,
}

#[derive(Deserialize)]
struct MetricFamily {
    #[serde(rename = "type")]
    kind: String,
}

pub(crate) fn contract() -> &'static Contract {
    static CONTRACT: OnceLock<Contract> = OnceLock::new();
    CONTRACT.get_or_init(|| {
        serde_json::from_str(include_str!("../contracts/requirements/observability.json"))
            .expect("synchronized observability contract")
    })
}

const HTTP_REQUESTS: &str = "nekotribe_http_requests_total";
const HTTP_SECONDS: &str = "nekotribe_http_request_duration_seconds";
const ORACLE: &str = "nekotribe_oracle_pool_connections";
const REDIS: &str = "nekotribe_redis_operations_total";
const SOCKETS: &str = "nekotribe_websocket_connections";
const CHANNELS: &str = "nekotribe_websocket_channels";
const AI_REQUESTS: &str = "nekotribe_ai_requests_total";
const AI_SECONDS: &str = "nekotribe_ai_request_duration_seconds";
const AI_QUOTA: &str = "nekotribe_ai_quota_rejections_total";

#[derive(Clone)]
struct Histogram {
    buckets: Vec<u64>,
    count: u64,
    sum: f64,
}

impl Default for Histogram {
    fn default() -> Self {
        Self {
            buckets: vec![0; contract().buckets_seconds.len()],
            count: 0,
            sum: 0.0,
        }
    }
}

impl Histogram {
    fn record(&mut self, elapsed: Duration) {
        let seconds = elapsed.as_secs_f64();
        self.count += 1;
        self.sum += seconds;
        for (bound, count) in contract().buckets_seconds.iter().zip(&mut self.buckets) {
            *count += u64::from(seconds <= *bound);
        }
    }

    fn write(&self, out: &mut String, name: &str, labels: &str) {
        for (bound, count) in contract().buckets_seconds.iter().zip(&self.buckets) {
            let _ = writeln!(out, "{name}_bucket{{{labels},le=\"{bound}\"}} {count}");
        }
        let _ = writeln!(out, "{name}_bucket{{{labels},le=\"+Inf\"}} {}", self.count);
        let _ = writeln!(out, "{name}_count{{{labels}}} {}", self.count);
        let _ = writeln!(out, "{name}_sum{{{labels}}} {}", self.sum);
    }
}

#[derive(Clone, Copy)]
pub(crate) enum CacheResult {
    Hit,
    Miss,
    Degraded,
}

#[derive(Clone, Copy)]
pub(crate) enum AiResult {
    Success,
    Failure,
    Cancelled,
}

#[derive(Clone, Default)]
struct AiStats {
    elapsed: Histogram,
    requests: [u64; 3],
    quota_rejections: u64,
}

#[derive(Clone, Default)]
struct Counters {
    http: BTreeMap<(&'static str, u16), Histogram>,
    redis: [u64; 3],
    ai: BTreeMap<&'static str, AiStats>,
}

#[derive(Default)]
struct WebsocketState {
    active: u64,
    channels: HashMap<u64, u64>,
}

impl WebsocketState {
    fn subscribe(&mut self, channel: u64) {
        *self.channels.entry(channel).or_default() += 1;
    }

    fn unsubscribe(&mut self, channel: u64) {
        if let std::collections::hash_map::Entry::Occupied(mut entry) = self.channels.entry(channel)
        {
            *entry.get_mut() -= 1;
            if *entry.get() == 0 {
                entry.remove();
            }
        }
    }
}

#[derive(Default)]
pub(crate) struct Metrics {
    counters: Mutex<Counters>,
    oracle: AtomicU64,
    websocket: Mutex<WebsocketState>,
}

pub(crate) fn metrics() -> &'static Metrics {
    static METRICS: OnceLock<Metrics> = OnceLock::new();
    METRICS.get_or_init(Metrics::default)
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|error| error.into_inner())
}

impl Metrics {
    pub(crate) fn http(&self, method: &Method, status: StatusCode, elapsed: Duration) {
        let method = contract()
            .http_methods
            .iter()
            .find(|candidate| candidate.as_str() == method.as_str())
            .map_or("OTHER", String::as_str);
        lock(&self.counters)
            .http
            .entry((method, status.as_u16()))
            .or_default()
            .record(elapsed);
    }

    pub(crate) fn cache(&self, result: CacheResult) {
        lock(&self.counters).redis[result as usize] += 1;
    }

    pub(crate) fn ai(
        &self,
        operation: &'static str,
        result: AiResult,
        quota: bool,
        elapsed: Duration,
    ) {
        if !contract().ai_operations.iter().any(|op| op == operation) {
            return;
        }
        let mut counters = lock(&self.counters);
        let stats = counters.ai.entry(operation).or_default();
        stats.requests[result as usize] += 1;
        stats.quota_rejections += u64::from(quota);
        stats.elapsed.record(elapsed);
    }

    pub(crate) fn oracle_connection(&self) -> OracleConnection<'_> {
        self.oracle.fetch_add(1, Ordering::Relaxed);
        OracleConnection(self)
    }

    pub(crate) fn socket(&self) -> SocketObservation<'_> {
        lock(&self.websocket).active += 1;
        SocketObservation(self)
    }

    pub(crate) fn room(&self, room: u64) -> RoomObservation<'_> {
        lock(&self.websocket).subscribe(room);
        RoomObservation {
            metrics: self,
            room,
        }
    }

    fn render(&self) -> String {
        let counters = lock(&self.counters).clone();
        let oracle = self.oracle.load(Ordering::Relaxed);
        let (sockets, channels) = {
            let ws = lock(&self.websocket);
            (ws.active, ws.channels.len())
        };
        let mut out = String::new();
        metric_type(&mut out, HTTP_REQUESTS);
        for ((method, status), histogram) in &counters.http {
            let _ = writeln!(
                out,
                "{HTTP_REQUESTS}{{method=\"{method}\",status=\"{status}\"}} {}",
                histogram.count
            );
        }
        metric_type(&mut out, HTTP_SECONDS);
        for ((method, status), histogram) in &counters.http {
            histogram.write(
                &mut out,
                HTTP_SECONDS,
                &format!("method=\"{method}\",status=\"{status}\""),
            );
        }
        metric_type(&mut out, ORACLE);
        for (state, value) in [("open", oracle), ("in_use", oracle), ("idle", 0)] {
            let _ = writeln!(out, "{ORACLE}{{state=\"{state}\"}} {value}");
        }
        metric_type(&mut out, REDIS);
        for (result, value) in ["hit", "miss", "degraded"].into_iter().zip(counters.redis) {
            let _ = writeln!(out, "{REDIS}{{result=\"{result}\"}} {value}");
        }
        metric_type(&mut out, SOCKETS);
        let _ = writeln!(out, "{SOCKETS} {sockets}");
        metric_type(&mut out, CHANNELS);
        let _ = writeln!(out, "{CHANNELS} {channels}");
        let empty = AiStats::default();
        metric_type(&mut out, AI_REQUESTS);
        for operation in &contract().ai_operations {
            let stats = counters.ai.get(operation.as_str()).unwrap_or(&empty);
            for (result, value) in ["success", "failure", "cancelled"]
                .into_iter()
                .zip(stats.requests)
            {
                let _ = writeln!(
                    out,
                    "{AI_REQUESTS}{{operation=\"{operation}\",result=\"{result}\"}} {value}"
                );
            }
        }
        metric_type(&mut out, AI_SECONDS);
        for operation in &contract().ai_operations {
            counters
                .ai
                .get(operation.as_str())
                .unwrap_or(&empty)
                .elapsed
                .write(&mut out, AI_SECONDS, &format!("operation=\"{operation}\""));
        }
        metric_type(&mut out, AI_QUOTA);
        for operation in &contract().ai_operations {
            let stats = counters.ai.get(operation.as_str()).unwrap_or(&empty);
            let _ = writeln!(
                out,
                "{AI_QUOTA}{{operation=\"{operation}\"}} {}",
                stats.quota_rejections
            );
        }
        out
    }
}

fn metric_type(out: &mut String, metric: &str) {
    let _ = writeln!(
        out,
        "# TYPE {metric} {}",
        contract().metric_families[metric].kind
    );
}

pub(crate) struct OracleConnection<'a>(&'a Metrics);

impl Drop for OracleConnection<'_> {
    fn drop(&mut self) {
        self.0.oracle.fetch_sub(1, Ordering::Relaxed);
    }
}

pub(crate) struct SocketObservation<'a>(&'a Metrics);

impl Drop for SocketObservation<'_> {
    fn drop(&mut self) {
        lock(&self.0.websocket).active -= 1;
    }
}

pub(crate) struct RoomObservation<'a> {
    metrics: &'a Metrics,
    room: u64,
}

impl Drop for RoomObservation<'_> {
    fn drop(&mut self) {
        lock(&self.metrics.websocket).unsubscribe(self.room);
    }
}

#[derive(Clone, Default, Eq, PartialEq)]
pub(crate) struct ScrapeAccess(Option<[u8; 32]>);

impl fmt::Debug for ScrapeAccess {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("ScrapeAccess [redacted]")
    }
}

impl ScrapeAccess {
    pub(crate) fn from_lookup(lookup: &impl Fn(&str) -> Option<String>) -> Self {
        Self(
            lookup(&contract().token_environment_variable)
                .filter(|token| !token.trim().is_empty())
                .map(|token| Sha256::digest(token.as_bytes()).into()),
        )
    }

    fn status(&self, headers: &HeaderMap) -> StatusCode {
        let Some(expected) = self.0 else {
            return StatusCode::NOT_FOUND;
        };
        let all = headers.get_all(header::AUTHORIZATION);
        let mut values = all.iter();
        if let Some(token) = values
            .next()
            .and_then(|value| value.as_bytes().strip_prefix(b"Bearer "))
        {
            if values.next().is_none() {
                let actual: [u8; 32] = Sha256::digest(token).into();
                if bool::from(actual.ct_eq(&expected)) {
                    return StatusCode::OK;
                }
            }
        }
        StatusCode::UNAUTHORIZED
    }
}

pub(crate) fn router(access: ScrapeAccess) -> Router {
    Router::new()
        .route(&contract().metrics_path, get(scrape))
        .with_state(access)
}

async fn scrape(State(access): State<ScrapeAccess>, headers: HeaderMap) -> Response {
    let status = access.status(&headers);
    let mut response = if status == StatusCode::OK {
        (
            status,
            [(header::CONTENT_TYPE, contract().content_type.as_str())],
            metrics().render(),
        )
            .into_response()
    } else {
        status.into_response()
    };
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response
}
