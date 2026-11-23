use crate::{
    notification_events::{
        encode_presence_event, encode_typing, typing_kind, EventError, NotificationPublisher, PublishFuture, TypingScope,
    },
    notification_source::{NotificationSource, SubscriptionFuture},
    notification_websocket::event_matches_channel,
};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio::sync::{mpsc, watch};

struct Subscriber {
    input: mpsc::Sender<Vec<u8>>,
    cancel: watch::Sender<bool>,
    user: u64,
    echoes: HashMap<[u8; 32], Instant>,
}
#[derive(Default)]
struct Registry {
    closed: bool,
    next: u64,
    subscribers: HashMap<u64, Subscriber>,
    rooms: HashMap<u64, HashMap<u64, mpsc::Sender<Vec<u8>>>>,
}
struct Inner {
    source: Option<Arc<dyn NotificationSource>>,
    publisher: Option<Arc<dyn NotificationPublisher>>,
    server_id: String,
    registry: Mutex<Registry>,
}

/// One instance serves both HTTP presence publication and local sockets.
/// Direct-message events also use a participant-scoped local queue.
pub struct LocalPresenceEvents {
    inner: Arc<Inner>,
}
struct Registration {
    inner: Arc<Inner>,
    id: u64,
}

struct RoomRegistration {
    inner: Arc<Inner>,
    channel: u64,
    id: u64,
}

impl Drop for RoomRegistration {
    fn drop(&mut self) {
        let mut registry = self.inner.registry.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(room) = registry.rooms.get_mut(&self.channel) {
            room.remove(&self.id);
            if room.is_empty() {
                registry.rooms.remove(&self.channel);
            }
        }
    }
}
impl Drop for Registration {
    fn drop(&mut self) {
        self.inner
            .registry
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .subscribers
            .remove(&self.id);
    }
}
impl LocalPresenceEvents {
    pub fn new(
        source: Option<Arc<dyn NotificationSource>>,
        publisher: Option<Arc<dyn NotificationPublisher>>,
    ) -> Result<Self, EventError> {
        let server_id = match &publisher {
            Some(remote) => remote
                .presence_server_id()
                .filter(|id| !id.is_empty())
                .ok_or(EventError)?
                .to_owned(),
            None => format!("rust_{}", uuid::Uuid::new_v4()),
        };
        Ok(Self {
            inner: Arc::new(Inner {
                source,
                publisher,
                server_id,
                registry: Mutex::new(Registry::default()),
            }),
        })
    }
    pub fn close(&self) {
        let mut registry = self
            .inner
            .registry
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        registry.closed = true;
        registry.rooms.clear();
        for (_, subscriber) in registry.subscribers.drain() {
            let _ = subscriber.cancel.send(true);
        }
    }
    fn enqueue_direct(&self, participants: &[u64], payload: &[u8]) -> Result<(), EventError> {
        let mut registry = self.inner.registry.lock().map_err(|_| EventError)?;
        if registry.closed { return Err(EventError); }
        let digest: [u8; 32] = Sha256::digest(payload).into();
        let now = Instant::now();
        registry.subscribers.retain(|_, sub| {
            if !participants.contains(&sub.user) { return true; }
            if sub.input.try_send(payload.to_vec()).is_err() {
                let _ = sub.cancel.send(true);
                return false;
            }
            sub.echoes.retain(|_, until| *until > now);
            if sub.echoes.len() >= 128 {
                if let Some(oldest) = sub.echoes.iter().min_by_key(|(_, until)| **until).map(|(key, _)| *key) {
                    sub.echoes.remove(&oldest);
                }
            }
            sub.echoes.insert(digest, now + Duration::from_secs(60));
            true
        });
        Ok(())
    }
}
impl Drop for LocalPresenceEvents {
    fn drop(&mut self) {
        self.close();
    }
}
fn status(inner: &Inner, user: u64, state: &str) -> Vec<u8> {
    json!({"type":"system_notification", "data":{"code":"realtime_status","user_id":user,"server_id":inner.server_id,"local_presence":true,"remote_events":state},"timestamp":chrono::Utc::now().timestamp_millis()}).to_string().into_bytes()
}

#[derive(serde::Deserialize)]
struct RemoteEnvelope<'a> {
    #[serde(rename = "type")]
    kind: String,
    #[serde(borrow)]
    data: &'a serde_json::value::RawValue,
}
fn same_typing_server(event: &RemoteEnvelope<'_>, server_id: &str) -> bool {
    typing_kind(&event.kind).is_some() && serde_json::from_str::<Value>(event.data.get())
        .is_ok_and(|data| data["server_id"].as_str() == Some(server_id))
}
fn remote_allowed(body: &[u8], user_channel: &str, server_id: &str) -> bool {
    if body.len() > 262144 {
        return false;
    }
    let Ok(event) = serde_json::from_slice::<RemoteEnvelope<'_>>(body) else {
        return false;
    };
    if event.kind == "presence_update" {
        let Ok(data) = serde_json::from_str::<Value>(event.data.get()) else {
            return false;
        };
        data["server_id"].as_str() != Some(server_id)
            && event_matches_channel("ws:presence", user_channel, body)
    } else {
        !same_typing_server(&event, server_id) && event_matches_channel(user_channel, user_channel, body)
    }
}
async fn remote(inner: Arc<Inner>, id: u64, user: u64, output: mpsc::Sender<Vec<u8>>) {
    let Some(source) = &inner.source else {
        std::future::pending::<()>().await;
        return;
    };
    let channel = format!("ws:user:{user}");
    let mut last = "connecting";
    let mut report = |state| {
        if last == state {
            return true;
        }
        last = state;
        output.try_send(status(&inner, user, state)).is_ok()
    };
    loop {
        if let Ok(mut events) = source.subscribe(user).await {
            if !report("connected") {
                return;
            }
            while let Some(body) = events.recv().await {
                if !remote_allowed(&body, &channel, &inner.server_id) {
                    continue;
                }
                let duplicate = inner.registry.lock().ok().is_some_and(|registry| {
                    registry.subscribers.get(&id).is_some_and(|sub| {
                        if sub.echoes.is_empty() {
                            return false;
                        }
                        let digest: [u8; 32] = Sha256::digest(&body).into();
                        sub.echoes
                            .get(&digest)
                            .is_some_and(|until| *until > Instant::now())
                    })
                });
                if !duplicate && output.try_send(body).is_err() {
                    return;
                }
            }
        }
        if !report("unavailable") {
            return;
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
}

async fn remote_room(
    inner: Arc<Inner>,
    channel: u64,
    output: mpsc::Sender<Vec<u8>>,
    initial: Option<mpsc::Receiver<Vec<u8>>>,
) {
    let Some(source) = &inner.source else {
        std::future::pending::<()>().await;
        return;
    };
    let mut incoming = initial;
    loop {
        if let Some(mut events) = incoming.take() {
            while let Some(body) = events.recv().await {
                let duplicate = serde_json::from_slice::<RemoteEnvelope<'_>>(&body)
                    .is_ok_and(|event| same_typing_server(&event, &inner.server_id));
                if !duplicate && output.try_send(body).is_err() {
                    return;
                }
            }
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
        incoming = source.subscribe_chat_channel(channel).await.ok();
    }
}

impl NotificationSource for LocalPresenceEvents {
    fn subscribe_chat_channel(&self, channel_id: u64) -> SubscriptionFuture<'_> {
        Box::pin(async move {
            if !(1..=crate::notification_websocket::MAX_SOCKET_ID).contains(&channel_id) {
                return Err(EventError);
            }
            let inner = self.inner.clone();
            let (input, mut local) = mpsc::channel(16);
            let (output, receiver) = mpsc::channel(16);
            let id = {
                let mut registry = inner.registry.lock().map_err(|_| EventError)?;
                if registry.closed { return Err(EventError); }
                registry.next = registry.next.checked_add(1).ok_or(EventError)?;
                let id = registry.next;
                registry.rooms.entry(channel_id).or_default().insert(id, input);
                id
            };
            let registration = RoomRegistration { inner: inner.clone(), channel: channel_id, id };
            let initial = match &inner.source {
                Some(source) => source.subscribe_chat_channel(channel_id).await.ok(),
                None => None,
            };
            tokio::spawn(async move {
                let _registration = registration;
                let remote = remote_room(inner, channel_id, output.clone(), initial);
                tokio::pin!(remote);
                loop {
                    tokio::select! {
                        _ = output.closed() => break,
                        _ = &mut remote => break,
                        frame = local.recv() => {
                            let Some(frame) = frame else { break; };
                            if output.try_send(frame).is_err() { break; }
                        }
                    }
                }
            });
            Ok(receiver)
        })
    }

    fn subscribe(&self, user: u64) -> SubscriptionFuture<'_> {
        Box::pin(async move {
            if user == 0 || user > 9_007_199_254_740_991 {
                return Err(EventError);
            }
            let inner = self.inner.clone();
            let (input, mut local) = mpsc::channel(16);
            let (output, receiver) = mpsc::channel(16);
            let (cancel, mut cancelled) = watch::channel(false);
            let id = {
                let mut registry = inner.registry.lock().map_err(|_| EventError)?;
                if registry.closed || registry.subscribers.len() >= 1024 {
                    return Err(EventError);
                }
                registry.next = registry.next.checked_add(1).ok_or(EventError)?;
                let id = registry.next;
                registry.subscribers.insert(
                    id,
                    Subscriber {
                        input,
                        cancel,
                        user,
                        echoes: HashMap::new(),
                    },
                );
                id
            };
            let initial = if inner.source.is_some() {
                "connecting"
            } else {
                "unavailable"
            };
            // The fresh output queue always has room for its initial capability frame.
            let _ = output.try_send(status(&inner, user, initial));
            let registration = Registration {
                inner: inner.clone(),
                id,
            };
            tokio::spawn(async move {
                let _registration = registration;
                let remote = remote(inner, id, user, output.clone());
                tokio::pin!(remote);
                loop {
                    tokio::select! {
                        _ = output.closed() => break,
                        _ = cancelled.changed() => break,
                        _ = &mut remote => break,
                        body = local.recv() => {
                            let Some(body) = body else { break; };
                            if output.try_send(body).is_err() { break; }
                        }
                    }
                }
            });
            Ok(receiver)
        })
    }
}
impl NotificationPublisher for LocalPresenceEvents {
    fn call_store(&self) -> Option<Arc<dyn crate::webrtc::Store>> {
        self.inner.publisher.as_deref()?.call_store()
    }
    fn publish_call_wire<'a>(&'a self, user: u64, payload: &'a [u8]) -> PublishFuture<'a> {
        Box::pin(async move {
            if payload.len() > 262144 || !crate::webrtc::valid_on_user_channel(&format!("ws:user:{user}"), payload) {
                return Err(EventError);
            }
            self.enqueue_direct(&[user], payload)?;
            if let Some(publisher) = &self.inner.publisher {
                publisher.publish_call_wire(user, payload).await?;
            }
            Ok(())
        })
    }
    fn publish_typing(&self, scope: TypingScope, user: u64, kind: &'static str) -> PublishFuture<'_> {
        Box::pin(async move {
            let payload = encode_typing(scope, user, kind, &self.inner.server_id)?;
            {
                let mut registry = self.inner.registry.lock().map_err(|_| EventError)?;
                if registry.closed { return Err(EventError); }
                let enqueue = |sender: &mpsc::Sender<Vec<u8>>| {
                    !matches!(sender.try_send(payload.clone()), Err(mpsc::error::TrySendError::Closed(_)))
                };
                match scope {
                    TypingScope::Direct { recipient, .. } => registry.subscribers.retain(|_, sub| sub.user != recipient || enqueue(&sub.input)),
                    TypingScope::Channel(channel) => {
                        if let Some(room) = registry.rooms.get_mut(&channel) {
                            room.retain(|_, sender| enqueue(sender));
                        }
                    }
                }
            }
            if let Some(remote) = &self.inner.publisher {
                remote.publish_typing(scope, user, kind).await?;
            }
            Ok(())
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
            let publisher = self.inner.publisher.as_ref().ok_or(EventError)?;
            publisher
                .publish_chat_room_event(channel, kind, id, message)
                .await
        })
    }
    fn publish_direct_event(
        &self,
        sender: u64,
        recipient: u64,
        kind: &'static str,
        mut data: Value,
    ) -> PublishFuture<'_> {
        Box::pin(async move {
            let max = crate::notification_websocket::MAX_SOCKET_ID;
            if sender == recipient
                || !(1..=max).contains(&sender)
                || !(1..=max).contains(&recipient)
            {
                return Err(EventError);
            }
            data.as_object_mut().ok_or(EventError)?.insert("server_id".into(), json!(self.inner.server_id));
            let payload = json!({
                "type":kind, "data":data,
                "timestamp":chrono::Utc::now().timestamp_millis()
            }).to_string().into_bytes();
            if payload.len() > 262144 || !event_matches_channel("ws:user", "ws:user", &payload) {
                return Err(EventError);
            }
            self.enqueue_direct(&[sender, recipient], &payload)?;
            self.inner
                .publisher
                .as_ref()
                .ok_or(EventError)?
                .publish_direct_wire(sender, recipient, &payload)
                .await
        })
    }
    fn presence_server_id(&self) -> Option<&str> {
        Some(&self.inner.server_id)
    }
    fn publish_presence<'a>(&'a self, data: &'a Map<String, Value>) -> PublishFuture<'a> {
        Box::pin(async move {
            let payload = encode_presence_event(
                data,
                &self.inner.server_id,
                chrono::Utc::now().timestamp_millis(),
            )?
            .into_bytes();
            {
                let mut registry = self.inner.registry.lock().map_err(|_| EventError)?;
                if registry.closed {
                    return Err(EventError);
                }
                registry.subscribers.retain(|_, sub| {
                    if sub.input.try_send(payload.clone()).is_ok() {
                        true
                    } else {
                        let _ = sub.cancel.send(true);
                        false
                    }
                });
            }
            tokio::time::timeout(
                Duration::from_millis(1500),
                self.inner
                    .publisher
                    .as_ref()
                    .ok_or(EventError)?
                    .publish_presence(data),
            )
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
            self.inner
                .publisher
                .as_ref()
                .ok_or(EventError)?
                .publish(user, kind, data)
                .await
        })
    }
}
