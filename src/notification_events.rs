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

#[derive(Clone, Copy)]
pub enum TypingScope {
    Direct { conversation: u64, recipient: u64 },
    Channel(u64),
}

pub(crate) fn typing_kind(kind: &str) -> Option<&'static str> {
    match kind {
        "typing_start" => Some("typing_start"),
        "typing_stop" => Some("typing_stop"),
        _ => None,
    }
}

pub(crate) fn encode_typing(scope: TypingScope, user: u64, kind: &'static str, server_id: &str) -> Result<Vec<u8>, EventError> {
    let safe = |id| (1..=crate::notification_websocket::MAX_SOCKET_ID).contains(&id);
    if typing_kind(kind).is_none() || !safe(user) || server_id.is_empty() {
        return Err(EventError);
    }
    let mut data = json!({"user_id":user,"server_id":server_id});
    match scope {
        TypingScope::Direct { conversation, recipient } if safe(conversation) && safe(recipient) && user != recipient => {
            data["conversation_id"] = conversation.into();
        }
        TypingScope::Channel(channel) if safe(channel) => {
            data["channel_id"] = channel.into();
        }
        _ => return Err(EventError),
    }
    let frame = json!({"type":kind,"timestamp":chrono::Utc::now().timestamp_millis(),"data":data});
    Ok(frame.to_string().into_bytes())
}

pub trait NotificationPublisher: Send + Sync {
    fn call_store(&self) -> Option<std::sync::Arc<dyn crate::webrtc::Store>> {
        None
    }
    fn publish_call_wire<'a>(&'a self, _user: u64, _payload: &'a [u8]) -> PublishFuture<'a> {
        Box::pin(async { Err(EventError) })
    }
    fn publish_chat_message<'a>(&'a self, channel: u64, message: &'a Value) -> PublishFuture<'a> {
        self.publish_chat_room_event(
            channel,
            "chat_message",
            message["message_id"].as_u64().unwrap_or(0),
            message,
        )
    }
    fn publish_chat_room_event<'a>(
        &'a self,
        _channel: u64,
        _kind: &'a str,
        _id: u64,
        _message: &'a Value,
    ) -> PublishFuture<'a> {
        Box::pin(async { Err(EventError) })
    }
    fn publish_direct<'a>(
        &'a self,
        sender: u64,
        recipient: u64,
        message: &'a Value,
    ) -> PublishFuture<'a> {
        self.publish_direct_event(sender, recipient, "direct_message", serde_json::json!({
            "conversation_id":message["conversation_id"], "direct_message":message
        }))
    }
    fn publish_direct_deleted(&self, sender: u64, recipient: u64, conversation: u64, message: u64) -> PublishFuture<'_> {
        self.publish_direct_event(sender, recipient, "direct_message_deleted", serde_json::json!({
            "conversation_id":conversation, "message_id":message
        }))
    }
    fn publish_direct_updated(&self, sender: u64, recipient: u64, conversation: u64, message: u64) -> PublishFuture<'_> {
        self.publish_direct_event(sender, recipient, "direct_message_updated", serde_json::json!({
            "conversation_id":conversation, "message_id":message
        }))
    }
    fn publish_direct_read(&self, reader: u64, recipient: u64, conversation: u64, message: u64) -> PublishFuture<'_> {
        self.publish_direct_event(reader, recipient, "direct_read_updated", json!({
            "conversation_id":conversation, "reader_id":reader, "last_read_message_id":message
        }))
    }
    fn publish_typing(&self, _scope: TypingScope, _user: u64, _kind: &'static str) -> PublishFuture<'_> {
        Box::pin(async { Err(EventError) })
    }
    fn publish_direct_event(&self, _sender: u64, _recipient: u64, _kind: &'static str, _data: Value) -> PublishFuture<'_> {
        Box::pin(async { Err(EventError) })
    }
    fn publish_direct_wire<'a>(
        &'a self,
        _sender: u64,
        _recipient: u64,
        _payload: &'a [u8],
    ) -> PublishFuture<'a> {
        Box::pin(async { Err(EventError) })
    }
    fn presence_server_id(&self) -> Option<&str> {
        None
    }
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
    async fn publish_user_wire(&self, user: u64, payload: &[u8]) -> Result<(), EventError> {
        let mut conn = self.client.get_multiplexed_async_connection().await.map_err(|_| EventError)?;
        redis::cmd("PUBLISH").arg(format!("{}{user}", REDIS_CHANNELS.user_prefix))
            .arg(payload).query_async::<usize>(&mut conn).await.map_err(|_| EventError)?;
        Ok(())
    }
}
impl NotificationPublisher for RedisNotificationPublisher {
    fn call_store(&self) -> Option<std::sync::Arc<dyn crate::webrtc::Store>> {
        Some(std::sync::Arc::new(crate::webrtc::RedisStore(self.client.clone())))
    }
    fn publish_call_wire<'a>(&'a self, user: u64, payload: &'a [u8]) -> PublishFuture<'a> {
        Box::pin(async move {
            let channel = format!("{}{user}", REDIS_CHANNELS.user_prefix);
            if payload.len() > 262144 || !crate::webrtc::valid_on_user_channel(&channel, payload) {
                return Err(EventError);
            }
            tokio::time::timeout(Duration::from_millis(1500), self.publish_user_wire(user, payload))
                .await.map_err(|_| EventError)?
        })
    }
    fn publish_typing(&self, scope: TypingScope, user: u64, kind: &'static str) -> PublishFuture<'_> {
        Box::pin(async move {
            let payload = encode_typing(scope, user, kind, &self.server_id)?;
            let channel = match scope {
                TypingScope::Direct { recipient, .. } => format!("{}{recipient}", REDIS_CHANNELS.user_prefix),
                TypingScope::Channel(id) => format!("{}{id}", REDIS_CHANNELS.chat_channel_prefix),
            };
            tokio::time::timeout(Duration::from_millis(1500), async {
                let mut conn = self.client.get_multiplexed_async_connection().await.map_err(|_| EventError)?;
                redis::cmd("PUBLISH").arg(channel).arg(payload).query_async::<usize>(&mut conn).await.map_err(|_| EventError)?;
                Ok(())
            }).await.map_err(|_| EventError)?
        })
    }
    fn publish_chat_room_event<'a>(
        &'a self,
        channel: u64,
        kind: &'a str,
        id: u64,
        message: &'a Value,
    ) -> PublishFuture<'a> {
        Box::pin(async move {
            let max = crate::notification_websocket::MAX_SOCKET_ID;
            if !(1..=max).contains(&channel) || !(1..=max).contains(&id) {
                return Err(EventError);
            }
            let mut data = serde_json::json!({"channel_id":channel,"server_id":self.server_id});
            match kind {
                "chat_message_deleted" if message.is_null() => data["message_id"] = id.into(),
                "chat_message" | "chat_message_updated" | "chat_reaction_updated"
                    if message["channel_id"].as_u64() == Some(channel) =>
                {
                    let mut message = message.clone();
                    message["can_delete"] = false.into();
                    message["can_pin"] = false.into();
                    message["author"]["relationship"] = serde_json::json!({
                        "relation":"none","is_self":false,"is_following":false,"is_blocked":false,"is_blocking":false
                    });
                    if let Some(reactions) = message["reactions"].as_array_mut() {
                        for reaction in reactions {
                            reaction["reacted_by_me"] = false.into();
                        }
                    }
                    data["message"] = message;
                    data["viewer_neutral"] = true.into();
                }
                _ => return Err(EventError),
            }
            let payload = serde_json::to_vec(&serde_json::json!({
                "type":kind,"room":format!("chat:channel:{channel}"),
                "timestamp":chrono::Utc::now().timestamp_millis(),"data":data
            }))
            .map_err(|_| EventError)?;
            if payload.len() > 262144 {
                return Err(EventError);
            }
            tokio::time::timeout(Duration::from_millis(1500), async {
                let mut conn = self
                    .client
                    .get_multiplexed_async_connection()
                    .await
                    .map_err(|_| EventError)?;
                redis::cmd("PUBLISH")
                    .arg(format!("ws:chat:channel:{channel}"))
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
    fn publish_direct_wire<'a>(
        &'a self,
        sender: u64,
        recipient: u64,
        payload: &'a [u8],
    ) -> PublishFuture<'a> {
        Box::pin(async move {
            tokio::time::timeout(Duration::from_millis(1500), async {
                let (first, second) = tokio::join!(self.publish_user_wire(sender, payload), self.publish_user_wire(recipient, payload));
                first.and(second)
            })
            .await
            .map_err(|_| EventError)?
        })
    }
    fn presence_server_id(&self) -> Option<&str> {
        Some(&self.server_id)
    }
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
    let user = data
        .get("user_id")
        .and_then(Value::as_u64)
        .filter(|v| *v > 0 && *v <= 9_007_199_254_740_991)
        .ok_or(EventError)?;
    let status = data
        .get("online_status")
        .and_then(Value::as_str)
        .ok_or(EventError)?;
    if server_id.is_empty()
        || !(0..=9_007_199_254_740_991).contains(&timestamp)
        || !matches!(status, "online" | "offline" | "hidden")
    {
        return Err(EventError);
    }
    if status != "hidden"
        && !data
            .get("last_seen_at")
            .is_some_and(|v| v.is_null() || v.is_string())
    {
        return Err(EventError);
    }
    serde_json::to_string(&json!({
        "type": "presence_update",
        "data": {
            "user_id": user,
            "online_status": status,
            "last_seen_at": if status == "hidden" { Value::Null } else { data["last_seen_at"].clone() },
            "server_id": server_id,
        },
        "timestamp": timestamp,
    })).map_err(|_| EventError)
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
