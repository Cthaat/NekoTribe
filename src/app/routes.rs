use axum::{
    middleware as axum_middleware,
    response::IntoResponse,
    routing::{any, get},
    Json, Router,
};
use chrono::{SecondsFormat, Utc};
use serde::Serialize;

use crate::{
    app::state::AppState,
    config::env::AppConfig,
    httpx::errors::ApiError,
    middleware::{logging, request_id, security_headers},
    proxy::legacy,
};

#[derive(Debug, Serialize)]
struct HealthResponse {
    status: &'static str,
    service: &'static str,
    timestamp: String,
}

pub fn build_router(config: AppConfig) -> Router {
    let state = AppState::new(config.clone());

    Router::new()
        .route("/api/health", get(health))
        .route("/api/v2/{*path}", any(legacy::proxy_to_legacy))
        .route("/storage/{*path}", get(legacy::proxy_to_legacy))
        .route("/uploads/{*path}", get(legacy::proxy_to_legacy))
        .nest("/api/v2", Router::new().fallback(v2_route_not_found))
        .layer(axum_middleware::from_fn(logging::log_request_response))
        .layer(axum_middleware::from_fn_with_state(
            config.clone(),
            security_headers::security_headers,
        ))
        .layer(axum_middleware::from_fn(request_id::request_id))
        .with_state(state)
}

async fn health() -> Json<HealthResponse> {
    Json(HealthResponse {
        status: "ok",
        service: "nekotribe",
        timestamp: Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
    })
}

async fn v2_route_not_found() -> impl IntoResponse {
    ApiError::route_not_found()
}
