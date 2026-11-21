use crate::{config::env::RedisConfig, httpx::errors::ApiError};
use axum::{
    http::{header::RETRY_AFTER, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
};
use serde::Deserialize;
use std::{future::Future, pin::Pin, sync::{Arc, OnceLock}, time::Duration};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Contract {
    key_prefix: String,
    window_milliseconds: u64,
    actor_limit: u64,
    service_limit: u64,
    max_limit: u64,
    lua: String,
}

fn contract() -> &'static Contract {
    static CONTRACT: OnceLock<Contract> = OnceLock::new();
    CONTRACT.get_or_init(|| {
        serde_json::from_str(include_str!("../../contracts/requirements/ai-model-quota.json"))
            .expect("valid AI quota contract")
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QuotaError {
    Unavailable,
    Exhausted(u64),
}

impl IntoResponse for QuotaError {
    fn into_response(self) -> Response {
        match self {
            Self::Unavailable => ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE, 50301, "服务暂不可用，请稍后重试。",
            ).into_response(),
            Self::Exhausted(seconds) => {
                let mut response = ApiError::new(
                    StatusCode::TOO_MANY_REQUESTS, 42901, "AI 请求额度已用完，请稍后重试",
                ).into_response();
                response.headers_mut().insert(
                    RETRY_AFTER, HeaderValue::from_str(&seconds.to_string()).expect("integer retry"),
                );
                response
            }
        }
    }
}

pub type QuotaFuture<'a> = Pin<Box<dyn Future<Output = Result<u64, QuotaError>> + Send + 'a>>;

pub trait AiModelQuotaLimiter: Send + Sync {
    fn reserve(&self, actor: u64, cost: u64) -> QuotaFuture<'_>;
}

#[derive(Clone)]
pub struct AiModelQuota(pub Arc<dyn AiModelQuotaLimiter>);

struct RedisQuota {
    client: redis::Client,
    actor_limit: Option<u64>,
    service_limit: Option<u64>,
}

fn limit(value: Option<String>, fallback: u64) -> Option<u64> {
    let Some(value) = value else { return Some(fallback); };
    let parsed = value.parse::<u64>().ok()?;
    (parsed >= 2 && parsed <= contract().max_limit && parsed.to_string() == value).then_some(parsed)
}

impl AiModelQuota {
    pub fn from_redis(
        config: &RedisConfig,
        lookup: &impl Fn(&str) -> Option<String>,
    ) -> Result<Self, QuotaError> {
        let spec = contract();
        let client = redis::Client::open(config.connection_url()).map_err(|_| QuotaError::Unavailable)?;
        Ok(Self(Arc::new(RedisQuota {
            client,
            actor_limit: limit(lookup("AI_QUOTA_ACTOR_PER_MINUTE"), spec.actor_limit),
            service_limit: limit(lookup("AI_QUOTA_SERVICE_PER_MINUTE"), spec.service_limit),
        })))
    }
}

impl AiModelQuotaLimiter for RedisQuota {
    fn reserve(&self, actor: u64, cost: u64) -> QuotaFuture<'_> {
        Box::pin(async move {
            if !(1..=9_007_199_254_740_991).contains(&actor) || !(1..=2).contains(&cost) {
                return Err(QuotaError::Unavailable);
            }
            let actor_limit = self.actor_limit.ok_or(QuotaError::Unavailable)?;
            let service_limit = self.service_limit.ok_or(QuotaError::Unavailable)?;
            let spec = contract();
            let prefix = &spec.key_prefix;
            tokio::time::timeout(Duration::from_secs(2), async {
                let mut connection = self.client.get_multiplexed_async_connection().await?;
                redis::cmd("EVAL")
                    .arg(&spec.lua)
                    .arg(2)
                    .arg(format!("{prefix}:actor:{actor}"))
                    .arg(format!("{prefix}:service"))
                    .arg(cost)
                    .arg(actor_limit)
                    .arg(service_limit)
                    .arg(spec.window_milliseconds)
                    .arg(spec.max_limit)
                    .query_async::<u64>(&mut connection)
                    .await
            })
            .await
            .map_err(|_| QuotaError::Unavailable)?
            .map_err(|_| QuotaError::Unavailable)
        })
    }
}

pub(super) async fn require(quota: Option<&AiModelQuota>, actor: u64, cost: u64) -> Result<(), QuotaError> {
    let retry = quota.ok_or(QuotaError::Unavailable)?.0.reserve(actor, cost).await?;
    if retry == 0 {
        Ok(())
    } else if retry <= contract().window_milliseconds / 1000 {
        Err(QuotaError::Exhausted(retry))
    } else {
        Err(QuotaError::Unavailable)
    }
}
