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
}
impl NotificationSource for RedisNotificationSource {
    fn subscribe(&self, user: u64) -> SubscriptionFuture<'_> {
        Box::pin(async move {
            if user == 0 || user > 9_007_199_254_740_991 {
                return Err(EventError);
            }
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
            let channel = format!("{}{user}", REDIS_CHANNELS.user_prefix);
            tokio::time::timeout(Duration::from_millis(1500), pubsub.subscribe(channel))
                .await
                .map_err(|_| EventError)?
                .map_err(|_| EventError)?;
            let (tx, rx) = mpsc::channel(16);
            tokio::spawn(async move {
                let _permit = permit;
                let mut stream = pubsub.on_message();
                loop {
                    tokio::select! {
                        _=tx.closed()=>break,
                        message=stream.next()=>{
                            let Some(message)=message else {break};
                            let payload=message.get_payload_bytes();if payload.len()>262144 {continue;}
                            if tx.try_send(payload.to_vec()).is_err(){break;}
                        }
                    }
                }
            });
            Ok(rx)
        })
    }
}
