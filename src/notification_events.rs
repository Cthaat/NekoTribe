use crate::cache::{redis::RedisPool, tags::REDIS_CHANNELS};
use serde_json::{json, Map, Value};
use std::time::Duration;

#[derive(Debug, Clone, Copy, thiserror::Error)]
#[error("notification event unavailable")]
pub struct EventError;

pub fn encode_notification_event(
    user: u64,
    kind: &str,
    data: &Map<String, Value>,
    server_id: &str,
    timestamp: i64,
) -> Result<(String, String), EventError> {
    if user == 0 || user > 9_007_199_254_740_991 || server_id.is_empty() {
        return Err(EventError);
    }
    if !matches!(
        kind,
        "notification_created"
            | "notification_read_status_updated"
            | "notifications_read_status_updated"
            | "notification_deleted"
            | "notification_restored"
    ) {
        return Err(EventError);
    }
    let mut body = data.clone();
    body.insert("server_id".into(), server_id.into());
    let payload = serde_json::to_string(&json!({"type":kind,"data":body,"timestamp":timestamp}))
        .map_err(|_| EventError)?;
    Ok((format!("{}{user}", REDIS_CHANNELS.user_prefix), payload))
}

pub struct UserEventPublisher {
    pool: RedisPool,
    server_id: String,
}
impl UserEventPublisher {
    pub fn new(pool: RedisPool) -> Self {
        Self {
            pool,
            server_id: format!("rust_{}", uuid::Uuid::new_v4()),
        }
    }
    pub async fn publish(
        &self,
        user: u64,
        kind: &str,
        data: &Map<String, Value>,
    ) -> Result<(), EventError> {
        let (channel, payload) = encode_notification_event(
            user,
            kind,
            data,
            &self.server_id,
            chrono::Utc::now().timestamp_millis(),
        )?;
        tokio::time::timeout(
            Duration::from_millis(1500),
            self.pool.publish(&channel, &payload),
        )
        .await
        .map_err(|_| EventError)?
        .map_err(|_| EventError)?;
        Ok(())
    }
}
