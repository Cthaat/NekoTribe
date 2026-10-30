use crate::cache::{redis::RedisPool, tags::REDIS_CHANNELS};
use serde_json::{json, Map, Value};
use std::{future::Future, pin::Pin, time::Duration};

#[derive(Debug, Clone, Copy, thiserror::Error)]
#[error("notification event unavailable")]
pub struct EventError;

pub(crate) const RAW_METADATA_KEY: &str = "__nekotribe_metadata_raw";

/// Serialize a notification while preserving otherwise valid JSON containing
/// JavaScript's unpaired UTF-16 escapes. The internal marker never leaves the server.
pub(crate) fn notification_json_raw(
    value: &Value,
) -> Result<Box<serde_json::value::RawValue>, EventError> {
    let mut fields = value.as_object().ok_or(EventError)?.clone();
    let raw = fields.remove(RAW_METADATA_KEY);
    if let Some(raw) = raw {
        let metadata =
            serde_json::value::RawValue::from_string(raw.as_str().ok_or(EventError)?.to_owned())
                .map_err(|_| EventError)?;
        fields.remove("metadata");
        #[derive(serde::Serialize)]
        struct Notification<'a> {
            #[serde(flatten)]
            fields: Map<String, Value>,
            metadata: &'a serde_json::value::RawValue,
        }
        let text = serde_json::to_string(&Notification {
            fields,
            metadata: &metadata,
        })
        .map_err(|_| EventError)?;
        return serde_json::value::RawValue::from_string(text).map_err(|_| EventError);
    }
    serde_json::value::RawValue::from_string(serde_json::to_string(value).map_err(|_| EventError)?)
        .map_err(|_| EventError)
}

pub type PublishFuture<'a> = Pin<Box<dyn Future<Output = Result<(), EventError>> + Send + 'a>>;
pub trait NotificationPublisher: Send + Sync {
    fn publish_presence<'a>(&'a self, _data: &'a Map<String, Value>) -> PublishFuture<'a> {
        Box::pin(async { Err(EventError) })
    }
    fn publish<'a>(
        &'a self,
        user: u64,
        kind: &'a str,
        data: &'a Map<String, Value>,
    ) -> PublishFuture<'a>;
}

/// Lazy Redis publisher; creation validates configuration but does not connect.
pub struct RedisNotificationPublisher {
    client: redis::Client,
    server_id: String,
}
impl RedisNotificationPublisher {
    pub fn new(config: &crate::config::env::RedisConfig) -> Result<Self, EventError> {
        Ok(Self {
            client: redis::Client::open(config.connection_url()).map_err(|_| EventError)?,
            server_id: format!("rust_{}", uuid::Uuid::new_v4()),
        })
    }
}
impl NotificationPublisher for RedisNotificationPublisher {
    fn publish_presence<'a>(&'a self, data: &'a Map<String, Value>) -> PublishFuture<'a> {
        Box::pin(async move {
            let payload = encode_presence_event(
                data,
                &self.server_id,
                chrono::Utc::now().timestamp_millis(),
            )?;
            tokio::time::timeout(Duration::from_millis(1500), async {
                let mut conn = self
                    .client
                    .get_multiplexed_async_connection()
                    .await
                    .map_err(|_| EventError)?;
                redis::cmd("PUBLISH")
                    .arg("ws:presence")
                    .arg(payload)
                    .query_async::<usize>(&mut conn)
                    .await
                    .map_err(|_| EventError)?;
                Ok(())
            })
            .await
            .map_err(|_| EventError)?
        })
    }
    fn publish<'a>(
        &'a self,
        user: u64,
        kind: &'a str,
        data: &'a Map<String, Value>,
    ) -> PublishFuture<'a> {
        Box::pin(async move {
            let (channel, payload) = encode_notification_event(
                user,
                kind,
                data,
                &self.server_id,
                chrono::Utc::now().timestamp_millis(),
            )?;
            tokio::time::timeout(Duration::from_millis(1500), async {
                let mut conn = self
                    .client
                    .get_multiplexed_async_connection()
                    .await
                    .map_err(|_| EventError)?;
                redis::cmd("PUBLISH")
                    .arg(channel)
                    .arg(payload)
                    .query_async::<usize>(&mut conn)
                    .await
                    .map_err(|_| EventError)?;
                Ok(())
            })
            .await
            .map_err(|_| EventError)?
        })
    }
}

pub fn encode_presence_event(
    data: &Map<String, Value>,
    server_id: &str,
    timestamp: i64,
) -> Result<String, EventError> {
    let mut data = data.clone();
    let user = data
        .get("user_id")
        .and_then(Value::as_u64)
        .filter(|v| *v > 0 && *v <= 9_007_199_254_740_991)
        .ok_or(EventError)?;
    let status = data
        .get("online_status")
        .and_then(Value::as_str)
        .ok_or(EventError)?;
    if server_id.is_empty() || !matches!(status, "online" | "offline" | "hidden") {
        return Err(EventError);
    }
    if status == "hidden" {
        data.insert("last_seen_at".into(), Value::Null);
    } else if !data
        .get("last_seen_at")
        .is_some_and(|v| v.is_null() || v.is_string())
    {
        return Err(EventError);
    }
    data.insert("user_id".into(), user.into());
    data.insert("server_id".into(), server_id.into());
    serde_json::to_string(&json!({"type":"presence_update", "data":data, "timestamp":timestamp}))
        .map_err(|_| EventError)
}

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
    if body
        .get("notification")
        .and_then(Value::as_object)
        .is_some_and(|v| v.contains_key(RAW_METADATA_KEY))
    {
        let notification =
            notification_json_raw(body.remove("notification").as_ref().ok_or(EventError)?)?;
        #[derive(serde::Serialize)]
        struct EventData<'a> {
            #[serde(flatten)]
            fields: Map<String, Value>,
            notification: &'a serde_json::value::RawValue,
        }
        #[derive(serde::Serialize)]
        struct Event<'a> {
            #[serde(rename = "type")]
            kind: &'a str,
            data: EventData<'a>,
            timestamp: i64,
        }
        let payload = serde_json::to_string(&Event {
            kind,
            data: EventData {
                fields: body,
                notification: &notification,
            },
            timestamp,
        })
        .map_err(|_| EventError)?;
        return Ok((format!("{}{user}", REDIS_CHANNELS.user_prefix), payload));
    }
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
