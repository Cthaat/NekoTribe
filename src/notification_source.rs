use crate::{
    cache::tags::REDIS_CHANNELS, config::env::RedisConfig, notification_events::EventError,
};
use futures_util::StreamExt;
use std::{future::Future, pin::Pin, sync::Arc, time::Duration};
use tokio::sync::{mpsc, Semaphore};

pub type SubscriptionFuture<'a> =
    Pin<Box<dyn Future<Output = Result<mpsc::Receiver<Vec<u8>>, EventError>> + Send + 'a>>;
pub trait NotificationSource: Send + Sync {
    fn subscribe(&self, user: u64) -> SubscriptionFuture<'_>;
    fn subscribe_chat_channel(&self, _channel_id: u64) -> SubscriptionFuture<'_> {
        Box::pin(async { Err(EventError) })
    }
}
pub struct RedisNotificationSource {
    client: redis::Client,
    slots: Arc<Semaphore>,
}
impl RedisNotificationSource {
    pub fn new(config: &RedisConfig) -> Result<Self, EventError> {
        let client = redis::Client::open(config.connection_url()).map_err(|_| EventError)?;
        Ok(Self {
            client,
            slots: Arc::new(Semaphore::new(1024)),
        })
    }
    async fn subscribe_channels(
        &self,
        channels: Vec<String>,
        matches: impl Fn(&str, &[u8]) -> bool + Send + 'static,
    ) -> Result<mpsc::Receiver<Vec<u8>>, EventError> {
        let permit = self
            .slots
            .clone()
            .try_acquire_owned()
            .map_err(|_| EventError)?;
        let mut pubsub =
            tokio::time::timeout(Duration::from_millis(1500), self.client.get_async_pubsub())
                .await
                .map_err(|_| EventError)?
                .map_err(|_| EventError)?;
        for channel in channels {
            tokio::time::timeout(Duration::from_millis(1500), pubsub.subscribe(channel))
                .await
                .map_err(|_| EventError)?
                .map_err(|_| EventError)?;
        }
        let (tx, rx) = mpsc::channel(16);
        tokio::spawn(async move {
            let _permit = permit;
            let mut stream = pubsub.on_message();
            loop {
                tokio::select! {
                    _=tx.closed()=>break,
                    message=stream.next()=>{
                        let Some(message)=message else {break};
                        let payload=message.get_payload_bytes();if payload.len()>262144 || !matches(message.get_channel_name(), payload) {continue;}
                        if tx.try_send(payload.to_vec()).is_err(){break;}
                    }
                }
            }
        });
        Ok(rx)
    }
}
impl NotificationSource for RedisNotificationSource {
    fn subscribe(&self, user: u64) -> SubscriptionFuture<'_> {
        Box::pin(async move {
            if user == 0 || user > crate::notification_websocket::MAX_SOCKET_ID {
                return Err(EventError);
            }
            let channel = format!("{}{user}", REDIS_CHANNELS.user_prefix);
            self.subscribe_channels(
                vec![channel.clone(), "ws:presence".into()],
                move |received, payload| {
                    crate::notification_websocket::event_matches_channel(
                        received, &channel, payload,
                    )
                },
            )
            .await
        })
    }
    fn subscribe_chat_channel(&self, channel_id: u64) -> SubscriptionFuture<'_> {
        Box::pin(async move {
            if channel_id == 0 || channel_id > crate::notification_websocket::MAX_SOCKET_ID {
                return Err(EventError);
            }
            let channel = format!("{}{channel_id}", REDIS_CHANNELS.chat_channel_prefix);
            self.subscribe_channels(vec![channel.clone()], move |received, payload| {
                received == channel
                    && crate::notification_websocket::valid_chat_event(channel_id, payload)
            })
            .await
        })
    }
}
