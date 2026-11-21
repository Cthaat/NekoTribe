use axum::{
    middleware as axum_middleware,
    response::IntoResponse,
    routing::{any, get},
    Json, Router,
};
use chrono::{SecondsFormat, Utc};
use serde::Serialize;
use std::sync::Arc;

use crate::{
    app::state::AppState,
    auth::{
        session_repository::OracleSessions,
        sessions::{self, SessionRepository, SessionStoreError},
    },
    config::env::{AppConfig, BackendMode},
    db::pool::OraclePool,
    httpx::errors::ApiError,
    middleware::{cache, logging, request_id, security_headers},
    proxy::legacy,
};

#[derive(Debug, Serialize)]
struct HealthResponse {
    status: &'static str,
    service: &'static str,
    timestamp: String,
}

pub fn build_router(config: AppConfig) -> Router {
    if config.backend_mode == BackendMode::Native {
        let pool = OraclePool::new(config.oracle.clone());
        let repository = Arc::new(OracleSessions {
            executor: pool.clone(),
        });
        return native_router(config, repository, pool).unwrap_or_else(|_| {
            Router::new().fallback(|| async { ApiError::server_error("服务器内部错误") })
        });
    }
    let state = AppState::new(config.clone());

    Router::new()
        .route("/api/health", get(health))
        .route("/api/ready", get(super::readiness::compat_unavailable))
        .route("/api/v2/{*path}", any(legacy::proxy_to_legacy))
        .route("/storage/{*path}", get(legacy::proxy_to_legacy))
        .route("/uploads/{*path}", get(legacy::proxy_to_legacy))
        .nest("/api/v2", Router::new().fallback(v2_route_not_found))
        .layer(axum_middleware::from_fn(cache::api_no_store))
        .layer(axum_middleware::from_fn(logging::log_request_response))
        .layer(axum_middleware::from_fn_with_state(
            config.clone(),
            security_headers::security_headers,
        ))
        .layer(axum_middleware::from_fn(request_id::request_id))
        .with_state(state)
}

// Startup preflight precedes binding a listening socket. Unit/HTTP tests can
// inject a SessionRepository without touching Oracle or a legacy upstream.
pub async fn prepare_router(
    config: AppConfig,
) -> Result<(Router, Option<tokio::task::JoinHandle<()>>), SessionStoreError> {
    if config.backend_mode == BackendMode::Compat {
        return Ok((build_router(config), None));
    }
    let pool = OraclePool::new(config.oracle.clone());
    let repository = Arc::new(OracleSessions {
        executor: pool.clone(),
    });
    tokio::time::timeout(std::time::Duration::from_secs(15), repository.preflight())
        .await
        .map_err(|_| SessionStoreError)??;
    let router = native_router(config, repository, pool.clone())?;
    let sweep = tokio::spawn(crate::moderation::ban_expiry::run_sweep(pool));
    Ok((router, Some(sweep)))
}
fn native_router(
    config: AppConfig,
    repository: Arc<dyn SessionRepository>,
    pool: OraclePool,
) -> Result<Router, SessionStoreError> {
    let options = config.native.as_ref().ok_or(SessionStoreError)?;
    let codec = options.keys.codec().map_err(|_| SessionStoreError)?;
    let source = Arc::new(
        crate::notification_source::RedisNotificationSource::new(&config.redis)
            .map_err(|_| SessionStoreError)?,
    );
    let publisher = Arc::new(
        crate::notification_events::RedisNotificationPublisher::new(&config.redis)
            .map_err(|_| SessionStoreError)?,
    );
    let otp_limiter = Arc::new(
        crate::auth::otp_send_limit::RedisOtpSendLimiter::new(&config.redis)
            .map_err(|_| SessionStoreError)?,
    );
    let ai_quota = crate::ai::model_quota::AiModelQuota::from_redis(
        &config.redis, &|key| std::env::var(key).ok(),
    ).map_err(|_| SessionStoreError)?;
    let redis = redis::Client::open(config.redis.connection_url()).map_err(|_| SessionStoreError)?;
    let readiness = super::readiness::native_route(pool.clone(), redis);
    let realtime = Arc::new(
        crate::local_presence::LocalPresenceEvents::new(Some(source), Some(publisher))
            .map_err(|_| SessionStoreError)?,
    );
    Ok(sessions::build_native_router_with_realtime_and_publisher(
        codec,
        repository,
        options.cors.clone(),
        Arc::new(|| Utc::now().timestamp().max(0) as u64),
        options.refresh_policy,
        options.storage_urls.clone(),
        Arc::new(options.smtp.clone()),
        Some(realtime.clone()),
        Some(realtime),
    )
    .merge(readiness.layer(axum_middleware::from_fn_with_state(
        options.cors.clone(), sessions::cors_middleware,
    )))
    .merge(
        crate::storage::local_http::router(options.local_storage.clone()).layer(
            axum_middleware::from_fn_with_state(options.cors.clone(), sessions::cors_middleware),
        ),
    )
    .layer(axum::Extension(options.local_storage.clone()))
    .layer(axum::Extension(crate::auth::otp_send_limit::OtpSendLimit(otp_limiter.clone())))
    .layer(axum::Extension(crate::auth::otp_attempt_limit::OtpAttemptLimit(otp_limiter)))
    .layer(axum::Extension(ai_quota))
    .layer(axum::Extension(options.ai_moderation.clone()))
    .layer(axum::Extension(options.ai_writing.clone()))
    .layer(axum::Extension(
        crate::ai::conversation_http::KnowledgeRuntime(Arc::new(
            crate::ai::knowledge_service::OracleKnowledgeStore(pool),
        )),
    ))
    .layer(axum_middleware::from_fn_with_state(
        config,
        security_headers::security_headers,
    ))
    .layer(axum_middleware::from_fn(request_id::request_id)))
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
