use std::{
    sync::{Arc, Mutex},
    time::Duration,
};

use axum::{
    http::{header, StatusCode},
    response::IntoResponse,
    routing::get,
    Json, Router,
};
use serde_json::json;
use tokio::{
    sync::watch,
    time::{timeout_at, Instant},
};

use crate::db::{oracle::BindMap, pool::OraclePool};

const PROBE_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Clone)]
struct Probe {
    result: watch::Receiver<Option<bool>>,
    deadline: Instant,
}

pub fn native_route(pool: OraclePool, redis: redis::Client) -> Router {
    let active = Arc::new(Mutex::new(None));
    Router::new().route(
        "/api/ready",
        get(move || {
            let probe = start_probe(&active, &pool, &redis);
            async move {
                let mut result = probe.result;
                let ready = timeout_at(probe.deadline, result.wait_for(Option::is_some))
                    .await
                    .is_ok_and(|result| result.is_ok_and(|value| *value == Some(true)));
                response(ready)
            }
        }),
    )
}

fn start_probe(active: &Mutex<Option<Probe>>, pool: &OraclePool, redis: &redis::Client) -> Probe {
    let mut active = active.lock().unwrap_or_else(|error| error.into_inner());
    if let Some(probe) = active
        .as_ref()
        .filter(|probe| probe.result.has_changed().is_ok())
    {
        return probe.clone();
    }

    let (send, result) = watch::channel(None);
    let deadline = Instant::now() + PROBE_TIMEOUT;
    let probe = Probe { result, deadline };
    *active = Some(probe.clone());
    let pool = pool.clone();
    let redis = redis.clone();
    tokio::spawn(async move {
        // Wait for the Oracle task to settle, including any blocking driver work,
        // before the next request can start a new probe.
        let (oracle, redis) = tokio::join!(
            pool.query_one("SELECT 1 AS READY FROM dual", BindMap::new()),
            timeout_at(deadline, check_redis(redis)),
        );
        let ready = Instant::now() < deadline
            && matches!(oracle, Ok(Some(_)))
            && matches!(redis, Ok(Ok(true)));
        let _ = send.send(Some(ready));
    });
    probe
}

async fn check_redis(redis: redis::Client) -> redis::RedisResult<bool> {
    let mut connection = redis.get_multiplexed_async_connection().await?;
    let reply = redis::cmd("PING")
        .query_async::<String>(&mut connection)
        .await?;
    Ok(reply == "PONG")
}

pub async fn compat_unavailable() -> impl IntoResponse {
    response(false)
}

fn response(ready: bool) -> impl IntoResponse {
    let (code, status) = if ready {
        (StatusCode::OK, "ready")
    } else {
        (StatusCode::SERVICE_UNAVAILABLE, "unavailable")
    };
    (
        code,
        [(header::CACHE_CONTROL, "no-store")],
        Json(json!({ "status": status })),
    )
}
