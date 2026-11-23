use crate::{config::env::RedisConfig, httpx::errors::ApiError};
use axum::{
    http::{header::RETRY_AFTER, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
};
use serde::{Deserialize, Serialize};
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

#[derive(Serialize)]
pub(crate) struct AccountQuotaUsage {
    used_units: Option<u64>,
    limit_units: Option<u64>,
    window_seconds: u64,
}

#[doc(hidden)]
pub type QuotaReadFuture<'a> = Pin<Box<dyn Future<Output = Option<u64>> + Send + 'a>>;

pub trait AiModelQuotaLimiter: Send + Sync {
    fn reserve(&self, actor: u64, cost: u64) -> QuotaFuture<'_>;
    fn read_actor_units(&self, _actor: u64) -> QuotaReadFuture<'_> {
        Box::pin(async { None })
    }
    fn actor_limit(&self) -> Option<u64> {
        limit(std::env::var("AI_QUOTA_ACTOR_PER_MINUTE").ok(), contract().actor_limit)
    }
    fn read_service_units(&self) -> QuotaReadFuture<'_> {
        Box::pin(async { None })
    }
    fn service_limit(&self) -> Option<u64> {
        limit(std::env::var("AI_QUOTA_SERVICE_PER_MINUTE").ok(), contract().service_limit)
    }
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

impl RedisQuota {
    async fn read_units(&self, scope: String) -> Option<u64> {
            let spec = contract();
            let units = tokio::time::timeout(Duration::from_secs(2), async {
                let mut connection = self.client.get_multiplexed_async_connection().await?;
                redis::cmd("GET")
                    .arg(format!("{}:{scope}", spec.key_prefix))
                    .query_async::<Option<u64>>(&mut connection)
                    .await
            })
            .await
            .ok()?
            .ok()?
            .unwrap_or(0);
            (units <= spec.max_limit).then_some(units)
    }
}

impl AiModelQuotaLimiter for RedisQuota {
    fn read_actor_units(&self, actor: u64) -> QuotaReadFuture<'_> {
        Box::pin(self.read_units(format!("actor:{actor}")))
    }

    fn actor_limit(&self) -> Option<u64> {
        self.actor_limit
    }

    fn read_service_units(&self) -> QuotaReadFuture<'_> {
        Box::pin(self.read_units("service".into()))
    }

    fn service_limit(&self) -> Option<u64> {
        self.service_limit
    }

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

pub(crate) async fn account_usage(quota: Option<&AiModelQuota>, actor: u64) -> AccountQuotaUsage {
    let (used_units, limit_units) = match quota {
        Some(quota) => (quota.0.read_actor_units(actor).await, quota.0.actor_limit()),
        None => (None, limit(std::env::var("AI_QUOTA_ACTOR_PER_MINUTE").ok(), contract().actor_limit)),
    };
    AccountQuotaUsage { used_units, limit_units, window_seconds: contract().window_milliseconds / 1000 }
}

pub(crate) async fn service_usage(quota: Option<&AiModelQuota>) -> AccountQuotaUsage {
    let (used_units, limit_units) = match quota {
        Some(quota) => (quota.0.read_service_units().await, quota.0.service_limit()),
        None => (None, limit(std::env::var("AI_QUOTA_SERVICE_PER_MINUTE").ok(), contract().service_limit)),
    };
    AccountQuotaUsage { used_units, limit_units, window_seconds: contract().window_milliseconds / 1000 }
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
