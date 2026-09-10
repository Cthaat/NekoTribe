use redis::{aio::ConnectionManager, AsyncCommands, Client};

use crate::config::env::RedisConfig;

#[derive(Debug, thiserror::Error)]
pub enum RedisError {
    #[error("redis unavailable: {0}")]
    Unavailable(String),
    #[error(transparent)]
    Driver(#[from] redis::RedisError),
}

#[derive(Clone)]
pub struct RedisPool {
    manager: Option<ConnectionManager>,
    unavailable_reason: Option<String>,
}

impl RedisPool {
    pub async fn connect(config: &RedisConfig) -> Self {
        let url = config.connection_url();
        match Client::open(url.as_str()) {
            Ok(client) => match client.get_connection_manager().await {
                Ok(manager) => Self {
                    manager: Some(manager),
                    unavailable_reason: None,
                },
                Err(error) => Self::degraded(error.to_string()),
            },
            Err(error) => Self::degraded(error.to_string()),
        }
    }

    pub fn degraded(reason: impl Into<String>) -> Self {
        Self {
            manager: None,
            unavailable_reason: Some(reason.into()),
        }
    }

    pub fn is_available(&self) -> bool {
        self.manager.is_some()
    }

    pub fn unavailable_reason(&self) -> Option<&str> {
        self.unavailable_reason.as_deref()
    }

    pub async fn ping(&self) -> Result<String, RedisError> {
        let mut manager = self.manager()?;
        redis::cmd("PING")
            .query_async(&mut manager)
            .await
            .map_err(Into::into)
    }

    pub async fn get(&self, key: &str) -> Result<Option<String>, RedisError> {
        let mut manager = self.manager()?;
        manager.get(key).await.map_err(Into::into)
    }

    pub async fn set_ex(&self, key: &str, value: &str, ttl_seconds: u64) -> Result<(), RedisError> {
        let mut manager = self.manager()?;
        manager
            .set_ex(key, value, ttl_seconds)
            .await
            .map_err(Into::into)
    }

    pub async fn incr_tag(&self, key: &str, ttl_seconds: i64) -> Result<i64, RedisError> {
        let mut manager = self.manager()?;
        let value = manager.incr(key, 1).await?;
        let _: bool = manager.expire(key, ttl_seconds).await?;
        Ok(value)
    }

    fn manager(&self) -> Result<ConnectionManager, RedisError> {
        self.manager.clone().ok_or_else(|| {
            RedisError::Unavailable(
                self.unavailable_reason
                    .clone()
                    .unwrap_or_else(|| "connection manager missing".to_string()),
            )
        })
    }
}
