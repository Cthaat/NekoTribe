use super::contract;
use crate::notification_websocket::MAX_SOCKET_ID;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    Voice,
    Video,
}

impl Mode {
    pub(crate) fn wire(self) -> &'static str {
        match self {
            Self::Voice => "voice",
            Self::Video => "video",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Invite,
    Accept,
    Reject,
    Cancel,
    Offer,
    Answer,
    Ice,
    Hangup,
    Expire,
    Disconnect,
}

impl Action {
    pub(crate) fn from_input(kind: &str) -> Option<Self> {
        Some(match kind {
            "call_invite" => Self::Invite,
            "call_accept" => Self::Accept,
            "call_reject" => Self::Reject,
            "call_cancel" => Self::Cancel,
            "call_sdp_offer" => Self::Offer,
            "call_sdp_answer" => Self::Answer,
            "call_ice" => Self::Ice,
            "call_hangup" => Self::Hangup,
            _ => return None,
        })
    }

    pub(crate) fn redis(self) -> &'static str {
        match self {
            Self::Invite => "invite",
            Self::Accept => "accept",
            Self::Reject => "reject",
            Self::Cancel => "cancel",
            Self::Offer => "offer",
            Self::Answer => "answer",
            Self::Ice => "ice",
            Self::Hangup => "hangup",
            Self::Expire => "expire",
            Self::Disconnect => "disconnect",
        }
    }
}

pub(crate) fn uuid(text: &str) -> bool {
    uuid::Uuid::parse_str(text).is_ok_and(|id| id.hyphenated().to_string() == text)
}

pub(crate) fn id(value: &Value) -> Option<u64> {
    let value = value.as_f64()?;
    ((1.0..=MAX_SOCKET_ID as f64).contains(&value) && value.fract() == 0.0).then_some(value as u64)
}

pub(crate) fn timestamp_ms() -> u64 {
    chrono::Utc::now().timestamp_millis().max(0) as u64
}

fn sdp(data: &Map<String, Value>) -> Option<&Value> {
    data.get("sdp").filter(|value| {
        value
            .as_str()
            .is_some_and(|text| !text.is_empty() && text.len() <= contract().max_sdp_bytes)
    })
}

fn ice(data: &Map<String, Value>) -> Option<&Value> {
    let value = data.get("candidates")?;
    let candidates = value.as_array()?;
    if candidates.is_empty() || candidates.len() > contract().max_ice_candidates {
        return None;
    }
    for candidate in candidates {
        let fields = candidate.as_object()?;
        if fields
            .keys()
            .any(|key| !matches!(key.as_str(), "candidate" | "sdp_mid" | "sdp_mline_index"))
            || !fields.get("candidate")?.as_str().is_some_and(|text| {
                !text.is_empty() && text.len() <= contract().max_ice_candidate_bytes
            })
            || fields
                .get("sdp_mid")
                .is_some_and(|mid| mid.as_str().is_none_or(|value| value.chars().count() > 128))
            || fields.get("sdp_mline_index").is_some_and(|index| {
                index
                    .as_f64()
                    .is_none_or(|value| !(0.0..=65_535.0).contains(&value) || value.fract() != 0.0)
            })
        {
            return None;
        }
    }
    Some(value)
}

pub(crate) struct Command<'a> {
    pub action: Action,
    pub kind: &'a str,
    pub call_id: &'a str,
    pub conversation: u64,
    pub client: &'a str,
    pub mode: Option<Mode>,
    pub media: Option<(&'static str, &'a Value)>,
}

pub(crate) fn command(value: &Value) -> Option<Command<'_>> {
    if value.as_object()?.len() != 2 {
        return None;
    }
    let kind = value.get("type")?.as_str()?;
    let action = Action::from_input(kind)?;
    let data = value.get("data")?.as_object()?;
    let call_id = data.get("call_id")?.as_str().filter(|value| uuid(value))?;
    let client = data
        .get("client_id")?
        .as_str()
        .filter(|value| uuid(value))?;
    let conversation = id(data.get("conversation_id")?)?;
    let (mode, media) = match action {
        Action::Invite => (
            Some(serde_json::from_value(data.get("mode")?.clone()).ok()?),
            None,
        ),
        Action::Offer | Action::Answer => (None, Some(("sdp", sdp(data)?))),
        Action::Ice => (None, Some(("candidates", ice(data)?))),
        _ => (None, None),
    };
    if data.len() != 3 + usize::from(mode.is_some() || media.is_some()) {
        return None;
    }
    Some(Command {
        action,
        kind,
        call_id,
        conversation,
        client,
        mode,
        media,
    })
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Metadata {
    pub call_id: String,
    pub conversation_id: u64,
    pub caller_id: u64,
    pub callee_id: u64,
    pub mode: Mode,
    pub caller_client_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub callee_client_id: Option<String>,
}

impl Metadata {
    pub(crate) fn peer(&self, user: u64) -> Option<u64> {
        if self.caller_id == user {
            Some(self.callee_id)
        } else if self.callee_id == user {
            Some(self.caller_id)
        } else {
            None
        }
    }

    pub(crate) fn frame(
        &self,
        kind: &str,
        media: Option<(&str, &Value)>,
        server_id: Option<&str>,
    ) -> Value {
        let mut data = json!(self);
        if let Some((key, value)) = media {
            data[key] = value.clone();
        }
        if let Some(server_id) = server_id.filter(|value| !value.is_empty()) {
            data["server_id"] = server_id.into();
        }
        json!({"type":kind,"timestamp":timestamp_ms(),"data":data})
    }
}

pub(crate) struct Event {
    pub metadata: Metadata,
    pub kind: String,
}

impl Event {
    pub(crate) fn parse(body: &[u8]) -> Option<Self> {
        let value: Value = serde_json::from_slice(body).ok()?;
        if value.as_object()?.len() != 3 {
            return None;
        }
        let kind = value.get("type")?.as_str()?;
        if Action::from_input(kind).is_none() && kind != "call_timeout" {
            return None;
        }
        let timestamp = value.get("timestamp")?.as_f64()?;
        if !(0.0..=MAX_SOCKET_ID as f64).contains(&timestamp) || timestamp.fract() != 0.0 {
            return None;
        }
        let data = value.get("data")?.as_object()?;
        let uuid_field = |name| {
            data.get(name)?
                .as_str()
                .filter(|value| uuid(value))
                .map(str::to_owned)
        };
        let caller_id = id(data.get("caller_id")?)?;
        let callee_id = id(data.get("callee_id")?)?;
        if caller_id == callee_id {
            return None;
        }
        let callee_client_id = if data.contains_key("callee_client_id") {
            Some(uuid_field("callee_client_id")?)
        } else {
            None
        };
        let has_server_id = if let Some(value) = data.get("server_id") {
            if value.as_str().is_none_or(str::is_empty) {
                return None;
            }
            true
        } else {
            false
        };
        let media = match kind {
            "call_sdp_offer" | "call_sdp_answer" => {
                sdp(data)?;
                true
            }
            "call_ice" => {
                ice(data)?;
                true
            }
            _ => false,
        };
        if (media || kind == "call_accept") && callee_client_id.is_none() {
            return None;
        }
        if data.len()
            != 6 + usize::from(callee_client_id.is_some())
                + usize::from(has_server_id)
                + usize::from(media)
        {
            return None;
        }
        Some(Self {
            kind: kind.to_owned(),
            metadata: Metadata {
                call_id: uuid_field("call_id")?,
                conversation_id: id(data.get("conversation_id")?)?,
                caller_id,
                callee_id,
                mode: serde_json::from_value(data.get("mode")?.clone()).ok()?,
                caller_client_id: uuid_field("caller_client_id")?,
                callee_client_id,
            },
        })
    }

    pub(crate) fn media(&self) -> bool {
        matches!(
            self.kind.as_str(),
            "call_sdp_offer" | "call_sdp_answer" | "call_ice"
        )
    }
}
