use super::{
    Action, Metadata, Mode, contract,
    protocol::{timestamp_ms, uuid},
};
use crate::notification_websocket::MAX_SOCKET_ID;
use serde::Deserialize;
use std::{future::Future, pin::Pin, sync::OnceLock, time::Duration};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Stage {
    Ringing,
    AwaitOffer,
    AwaitAnswer,
    Connected,
}

#[derive(Clone, Debug)]
pub struct Record {
    pub metadata: Metadata,
    pub stage: Stage,
    pub deadline: u64,
    pub caller_connection: String,
    pub callee_connection: Option<String>,
}

impl Record {
    pub(crate) fn connection(&self, user: u64) -> Option<(&str, &str)> {
        if user == self.metadata.caller_id {
            Some((&self.caller_connection, &self.metadata.caller_client_id))
        } else if user == self.metadata.callee_id {
            Some((
                self.callee_connection.as_deref()?,
                self.metadata.callee_client_id.as_deref()?,
            ))
        } else {
            None
        }
    }

    fn decode(raw: &str) -> Result<Self, StoreError> {
        #[derive(Deserialize)]
        struct Raw {
            call_id: String,
            conversation_id: String,
            caller_id: String,
            callee_id: String,
            mode: Mode,
            caller_client_id: String,
            callee_client_id: Option<String>,
            caller_connection: String,
            callee_connection: Option<String>,
            stage: Stage,
            deadline: u64,
        }
        let raw: Raw = serde_json::from_str(raw).map_err(|_| StoreError)?;
        let safe = |text: &str| {
            text.parse::<u64>()
                .ok()
                .filter(|id| (1..=MAX_SOCKET_ID).contains(id))
                .ok_or(StoreError)
        };
        let caller_id = safe(&raw.caller_id)?;
        let callee_id = safe(&raw.callee_id)?;
        let conversation_id = safe(&raw.conversation_id)?;
        let valid_connection = |id: &str| !id.is_empty() && id.len() <= 256;
        if caller_id == callee_id
            || !uuid(&raw.call_id)
            || !uuid(&raw.caller_client_id)
            || !valid_connection(&raw.caller_connection)
            || raw.deadline == 0
            || raw.deadline > MAX_SOCKET_ID
        {
            return Err(StoreError);
        }
        match (&raw.callee_client_id, &raw.callee_connection, raw.stage) {
            (None, None, Stage::Ringing) => {}
            (Some(client), Some(connection), stage)
                if stage != Stage::Ringing && uuid(client) && valid_connection(connection) => {}
            _ => return Err(StoreError),
        }
        Ok(Self {
            metadata: Metadata {
                call_id: raw.call_id,
                conversation_id,
                caller_id,
                callee_id,
                mode: raw.mode,
                caller_client_id: raw.caller_client_id,
                callee_client_id: raw.callee_client_id,
            },
            stage: raw.stage,
            deadline: raw.deadline,
            caller_connection: raw.caller_connection,
            callee_connection: raw.callee_connection,
        })
    }
}

#[derive(Clone)]
pub struct Transition {
    pub action: Action,
    pub call_id: String,
    pub conversation: u64,
    pub actor: u64,
    pub peer: u64,
    pub client: String,
    pub connection: String,
    pub mode: Option<Mode>,
}

pub enum Outcome {
    Ok(Record),
    Busy,
    Timeout(Record),
    Denied,
    Missing,
}
#[derive(Debug)]
pub struct StoreError;
pub type StoreFuture<'a, T> = Pin<Box<dyn Future<Output = Result<T, StoreError>> + Send + 'a>>;

pub trait Store: Send + Sync {
    fn transition(&self, request: Transition) -> StoreFuture<'_, Outcome>;
    fn current<'a>(&'a self, call_id: &'a str) -> StoreFuture<'a, Option<Record>>;
}

pub(crate) struct RedisStore(pub redis::Client);

fn redis_script() -> &'static str {
    #[derive(Deserialize)]
    struct Spec {
        lines: Vec<String>,
    }
    static SCRIPT: OnceLock<String> = OnceLock::new();
    SCRIPT.get_or_init(|| {
        serde_json::from_str::<Spec>(include_str!(
            "../../contracts/requirements/webrtc-call-state.json"
        ))
        .expect("valid shared WebRTC call state script")
        .lines
        .join("\n")
    })
}

fn redis_key(namespace: &str, id: impl std::fmt::Display) -> String {
    format!("{}{namespace}:{id}", &contract().redis_key_prefix)
}

impl Store for RedisStore {
    fn transition(&self, request: Transition) -> StoreFuture<'_, Outcome> {
        Box::pin(async move {
            let (status, raw): (String, String) =
                tokio::time::timeout(Duration::from_millis(1500), async {
                    let mut connection = self.0.get_multiplexed_async_connection().await?;
                    redis::cmd("EVAL")
                        .arg(redis_script())
                        .arg(3)
                        .arg(redis_key("call", &request.call_id))
                        .arg(redis_key("user", request.actor))
                        .arg(redis_key("user", request.peer))
                        .arg(request.action.redis())
                        .arg(&request.call_id)
                        .arg(request.conversation)
                        .arg(request.actor)
                        .arg(request.peer)
                        .arg(&request.client)
                        .arg(&request.connection)
                        .arg(request.mode.map(Mode::wire).unwrap_or_default())
                        .arg(timestamp_ms())
                        .arg(contract().ring_ms)
                        .arg(contract().active_ms)
                        .query_async(&mut connection)
                        .await
                })
                .await
                .map_err(|_| StoreError)?
                .map_err(|_: redis::RedisError| StoreError)?;
            match status.as_str() {
                "ok" | "timeout" => {
                    let record = Record::decode(&raw)?;
                    if record.metadata.call_id != request.call_id
                        || record.metadata.conversation_id != request.conversation
                        || record.metadata.peer(request.actor) != Some(request.peer)
                    {
                        return Err(StoreError);
                    }
                    Ok(if status == "ok" {
                        Outcome::Ok(record)
                    } else {
                        Outcome::Timeout(record)
                    })
                }
                "busy" => Ok(Outcome::Busy),
                "not_found" => Ok(Outcome::Missing),
                "invalid_state" | "forbidden" => Ok(Outcome::Denied),
                _ => Err(StoreError),
            }
        })
    }

    fn current<'a>(&'a self, call_id: &'a str) -> StoreFuture<'a, Option<Record>> {
        Box::pin(async move {
            let raw: Option<String> = tokio::time::timeout(Duration::from_millis(1500), async {
                let mut connection = self.0.get_multiplexed_async_connection().await?;
                redis::cmd("GET")
                    .arg(redis_key("call", call_id))
                    .query_async(&mut connection)
                    .await
            })
            .await
            .map_err(|_| StoreError)?
            .map_err(|_: redis::RedisError| StoreError)?;
            let record = raw.as_deref().map(Record::decode).transpose()?;
            if record
                .as_ref()
                .is_some_and(|record| record.metadata.call_id != call_id)
            {
                return Err(StoreError);
            }
            Ok(record)
        })
    }
}
