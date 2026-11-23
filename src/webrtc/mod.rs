pub(crate) mod ice;
mod protocol;
mod store;
#[cfg(test)]
mod tests;

use crate::{auth::sessions::NativeState, notification_events::NotificationPublisher};
pub use protocol::{Action, Metadata, Mode};
use protocol::{Event, command, timestamp_ms};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    sync::{Arc, OnceLock},
    time::Duration,
};
pub(crate) use store::RedisStore;
pub use store::{Outcome, Record, Stage, Store, StoreError, StoreFuture, Transition};
use tokio::time::Instant;

#[derive(Deserialize)]
struct Environment {
    stun_urls: String,
    turn_urls: String,
    turn_shared_secret: String,
}

#[derive(Deserialize)]
struct Contract {
    ring_ms: u64,
    active_ms: u64,
    turn_ttl_seconds: u64,
    max_sdp_bytes: usize,
    max_ice_candidates: usize,
    max_ice_candidate_bytes: usize,
    redis_key_prefix: String,
    environment: Environment,
}

fn contract() -> &'static Contract {
    static SPEC: OnceLock<Contract> = OnceLock::new();
    SPEC.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../../contracts/requirements/webrtc-calls.json"
        ))
        .expect("valid shared WebRTC contract")
    })
}

#[derive(Clone)]
pub(crate) struct Runtime {
    ice: Arc<Result<ice::Config, ()>>,
    store: Option<Arc<dyn Store>>,
}

impl Runtime {
    pub(crate) fn new(publisher: Option<&dyn NotificationPublisher>) -> Self {
        Self {
            ice: Arc::new(ice::Config::from_lookup(|key| std::env::var(key).ok())),
            store: publisher.and_then(NotificationPublisher::call_store),
        }
    }
}

pub(crate) fn control(kind: &str) -> bool {
    Action::from_input(kind).is_some()
}

pub(crate) fn valid_on_user_channel(channel: &str, body: &[u8]) -> bool {
    let user = channel
        .strip_prefix("ws:user:")
        .and_then(|raw| raw.parse::<u64>().ok());
    user.is_some_and(|user| {
        Event::parse(body).is_some_and(|event| event.metadata.peer(user).is_some())
    })
}

async fn current_peer(state: &NativeState, user: u64, conversation: u64) -> Option<u64> {
    crate::notification_websocket::typing_peer(state, user, conversation).await
}

async fn publish(
    state: &NativeState,
    meta: &Metadata,
    kind: &str,
    media: Option<(&str, &Value)>,
    target: Option<u64>,
) {
    let Some(publisher) = &state.notification_publisher else {
        return;
    };
    let bytes = meta
        .frame(kind, media, publisher.presence_server_id())
        .to_string()
        .into_bytes();
    if let Some(user) = target {
        let _ = publisher.publish_call_wire(user, &bytes).await;
    } else {
        let _ = tokio::join!(
            publisher.publish_call_wire(meta.caller_id, &bytes),
            publisher.publish_call_wire(meta.callee_id, &bytes)
        );
    }
}

fn error() -> Value {
    json!({"type":"error","data":{"message":"通话操作无效"},"timestamp":timestamp_ms()})
}

pub(crate) struct Socket {
    connection: String,
    bound: Option<Record>,
    ring_at: Option<Instant>,
}

impl Socket {
    pub(crate) fn new() -> Self {
        Self {
            connection: format!("ws_{}", uuid::Uuid::new_v4()),
            bound: None,
            ring_at: None,
        }
    }

    pub(crate) fn id(&self) -> &str {
        &self.connection
    }

    pub(crate) fn deadline(&self) -> Option<Instant> {
        self.ring_at
    }

    fn clear(&mut self, call_id: &str) {
        if self
            .bound
            .as_ref()
            .is_some_and(|call| call.metadata.call_id == call_id)
        {
            self.bound = None;
            self.ring_at = None;
        }
    }

    pub(crate) async fn incoming(
        &mut self,
        state: &NativeState,
        user: u64,
        value: &Value,
    ) -> Option<Value> {
        let Some(command) = command(value) else {
            return Some(error());
        };
        let Some(peer) = current_peer(state, user, command.conversation).await else {
            return Some(error());
        };
        let invite_meta = command.mode.map(|mode| Metadata {
            call_id: command.call_id.into(),
            conversation_id: command.conversation,
            caller_id: user,
            callee_id: peer,
            mode,
            caller_client_id: command.client.into(),
            callee_client_id: None,
        });
        let unavailable = || {
            invite_meta
                .as_ref()
                .map(|meta| meta.frame("call_unavailable", None, None))
                .unwrap_or_else(error)
        };
        let Some(store) = &state.calls.store else {
            return Some(unavailable());
        };
        let transition = Transition {
            action: command.action,
            call_id: command.call_id.into(),
            conversation: command.conversation,
            actor: user,
            peer,
            client: command.client.into(),
            connection: self.connection.clone(),
            mode: command.mode,
        };
        match store.transition(transition).await {
            Err(_) => Some(unavailable()),
            Ok(Outcome::Busy) => Some(
                invite_meta
                    .as_ref()
                    .map(|meta| meta.frame("call_busy", None, None))
                    .unwrap_or_else(error),
            ),
            Ok(Outcome::Missing | Outcome::Denied) => Some(error()),
            Ok(Outcome::Timeout(record)) => {
                self.clear(&record.metadata.call_id);
                publish(state, &record.metadata, "call_timeout", None, None).await;
                None
            }
            Ok(Outcome::Ok(record)) => {
                match command.action {
                    Action::Invite | Action::Accept => {
                        if record.connection(user)
                            != Some((self.connection.as_str(), command.client))
                        {
                            return Some(error());
                        }
                        self.ring_at = (command.action == Action::Invite).then(|| {
                            Instant::now()
                                + Duration::from_millis(
                                    record.deadline.saturating_sub(timestamp_ms()),
                                )
                        });
                        self.bound = Some(record.clone());
                    }
                    Action::Reject | Action::Cancel | Action::Hangup => self.clear(command.call_id),
                    _ => {}
                }
                let target = command.media.is_some().then_some(peer);
                publish(state, &record.metadata, command.kind, command.media, target).await;
                None
            }
        }
    }

    async fn close_bound(&mut self, state: &NativeState, user: u64, action: Action) {
        self.ring_at = None;
        let (Some(store), Some(bound)) = (&state.calls.store, self.bound.as_ref()) else {
            return;
        };
        let (Some(peer), Some((_, client))) = (bound.metadata.peer(user), bound.connection(user))
        else {
            return;
        };
        // A revoked participant still releases the binding. Deliveries are fenced separately.
        let outcome = store
            .transition(Transition {
                action,
                call_id: bound.metadata.call_id.clone(),
                conversation: bound.metadata.conversation_id,
                actor: user,
                peer,
                client: client.to_owned(),
                connection: self.connection.clone(),
                mode: None,
            })
            .await;
        match outcome {
            Ok(Outcome::Timeout(record)) => {
                self.clear(&record.metadata.call_id);
                publish(state, &record.metadata, "call_timeout", None, None).await;
            }
            Ok(Outcome::Ok(record)) if action == Action::Disconnect => {
                self.clear(&record.metadata.call_id);
                let kind = if record.stage == Stage::Ringing {
                    "call_cancel"
                } else {
                    "call_hangup"
                };
                publish(state, &record.metadata, kind, None, None).await;
            }
            Ok(Outcome::Missing) => self.bound = None,
            _ => {}
        }
    }

    pub(crate) async fn expire(&mut self, state: &NativeState, user: u64) {
        self.close_bound(state, user, Action::Expire).await;
    }

    pub(crate) async fn disconnect(&mut self, state: &NativeState, user: u64) {
        self.close_bound(state, user, Action::Disconnect).await;
    }

    pub(crate) async fn can_receive(
        &mut self,
        state: &NativeState,
        user: u64,
        body: &[u8],
    ) -> bool {
        let Some(event) = Event::parse(body) else {
            return false;
        };
        let Some(peer) = event.metadata.peer(user) else {
            return false;
        };
        if current_peer(state, user, event.metadata.conversation_id).await != Some(peer) {
            return false;
        }
        if matches!(
            event.kind.as_str(),
            "call_cancel" | "call_reject" | "call_hangup" | "call_timeout"
        ) {
            self.clear(&event.metadata.call_id);
            return true;
        }
        let Some(store) = &state.calls.store else {
            return false;
        };
        let Ok(Some(record)) = store.current(&event.metadata.call_id).await else {
            return false;
        };
        if record.metadata != event.metadata || record.deadline <= timestamp_ms() {
            return false;
        }
        if event.kind == "call_invite" {
            return record.stage == Stage::Ringing;
        }
        if event.kind == "call_accept" {
            if self
                .bound
                .as_ref()
                .is_some_and(|old| old.metadata.call_id == record.metadata.call_id)
            {
                self.ring_at = None;
                self.bound = Some(record);
            }
            return true;
        }
        if !event.media() || record.stage == Stage::Ringing {
            return false;
        }
        let Some((connection, _)) = record.connection(user) else {
            return false;
        };
        if connection != self.connection {
            return false;
        }
        match event.kind.as_str() {
            "call_sdp_offer" => {
                user == event.metadata.callee_id && record.stage != Stage::AwaitOffer
            }
            "call_sdp_answer" => {
                user == event.metadata.caller_id && record.stage == Stage::Connected
            }
            "call_ice" => true,
            _ => false,
        }
    }
}

pub(crate) async fn ring_timer(deadline: Option<Instant>) {
    match deadline {
        Some(deadline) => tokio::time::sleep_until(deadline).await,
        None => std::future::pending().await,
    }
}
