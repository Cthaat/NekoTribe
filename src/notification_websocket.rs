use crate::{
    auth::{
        sessions::{named_cookie, CorsPolicy, NativeState},
        TokenKind,
    },
    httpx::errors::ApiError,
    notification_events::{typing_kind, TypingScope},
};
use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        OriginalUri, State,
    },
    http::{HeaderMap, StatusCode, Uri},
    response::Response,
};
use serde_json::{json, Value};
use std::{collections::HashMap, sync::Arc, time::Duration};
use tokio::sync::mpsc;
use tokio::task::JoinSet;

pub(crate) const MAX_SOCKET_ID: u64 = 9_007_199_254_740_991;
const MAX_CHAT_CHANNELS: usize = 64;

#[derive(serde::Deserialize)]
struct NotificationEnvelope<'a> {
    #[serde(rename = "type")]
    kind: String,
    #[serde(borrow)]
    data: &'a serde_json::value::RawValue,
    timestamp: serde_json::Number,
    #[serde(default)]
    room: Option<String>,
}

fn positive_socket_id(value: &Value) -> Option<u64> {
    let id = value.as_f64()?;
    ((1.0..=MAX_SOCKET_ID as f64).contains(&id) && id.fract() == 0.0).then_some(id as u64)
}

fn command_channel_id(data: &Value) -> Option<u64> {
    let primary = &data["channelId"];
    let value = if primary.is_null() {
        &data["channel_id"]
    } else {
        primary
    };
    positive_socket_id(value).or_else(|| {
        value
            .as_str()?
            .parse()
            .ok()
            .filter(|id| (1..=MAX_SOCKET_ID).contains(id))
    })
}

fn direct_message_ids(event: &NotificationEnvelope<'_>) -> Option<(u64, u64, bool)> {
    let deleted = event.kind == "direct_message_deleted";
    let receipt_refresh = deleted || event.kind == "direct_message_updated";
    if (!receipt_refresh && event.kind != "direct_message") || !valid_timestamp(&event.timestamp) {
        return None;
    }
    let data = serde_json::from_str::<Value>(event.data.get()).ok()?;
    let conversation = positive_socket_id(&data["conversation_id"])?;
    if receipt_refresh {
        let fields = data.as_object()?;
        if fields.keys().any(|key| !matches!(key.as_str(), "conversation_id" | "message_id" | "server_id")) { return None; }
        if fields.get("server_id").is_some_and(|value| value.as_str().is_none_or(str::is_empty)) { return None; }
        let message = positive_socket_id(&data["message_id"])?;
        return Some((conversation, message, deleted));
    }
    let message = &data["direct_message"];
    let message_id = positive_socket_id(&message["message_id"])?;
    (positive_socket_id(&message["conversation_id"]) == Some(conversation))
        .then_some((conversation, message_id, false))
}

fn valid_server_id(fields: &serde_json::Map<String, Value>) -> bool {
    fields
        .get("server_id")
        .is_none_or(|id| id.as_str().is_some_and(|id| !id.is_empty()))
}

#[derive(Clone, Copy)]
enum TypingTarget {
    Direct(u64),
    Channel(u64),
}

fn typing_target(data: &Value) -> Option<TypingTarget> {
    match (data.get("conversation_id"), data.get("channel_id")) {
        (Some(id), None) => positive_socket_id(id).map(TypingTarget::Direct),
        (None, Some(id)) => positive_socket_id(id).map(TypingTarget::Channel),
        _ => None,
    }
}

fn typing_command(data: &Value) -> Option<TypingTarget> {
    if data.as_object()?.len() != 1 {
        return None;
    }
    typing_target(data)
}

fn strict_detail_data(event: &NotificationEnvelope<'_>, body: &[u8]) -> Option<Value> {
    if !valid_timestamp(&event.timestamp) {
        return None;
    }
    let mut frame = serde_json::from_slice::<Value>(body).ok()?;
    let fields = frame.as_object_mut()?;
    if fields.len() != 3 || !fields.contains_key("type") || !fields.contains_key("timestamp") {
        return None;
    }
    fields.remove("data")
}

fn typing_event(event: &NotificationEnvelope<'_>, body: &[u8]) -> Option<(TypingTarget, u64)> {
    typing_kind(&event.kind)?;
    let data = strict_detail_data(event, body)?;
    let fields = data.as_object()?;
    if !valid_server_id(fields)
        || fields.keys().any(|key| !matches!(key.as_str(), "user_id" | "conversation_id" | "channel_id" | "server_id"))
    {
        return None;
    }
    Some((typing_target(&data)?, positive_socket_id(&data["user_id"])?))
}

fn direct_read_ids(event: &NotificationEnvelope<'_>, body: &[u8]) -> Option<(u64, u64, u64)> {
    if event.kind != "direct_read_updated" {
        return None;
    }
    let data = strict_detail_data(event, body)?;
    let fields = data.as_object()?;
    if !valid_server_id(fields)
        || fields.keys().any(|key| !matches!(key.as_str(), "conversation_id" | "reader_id" | "last_read_message_id" | "server_id"))
    {
        return None;
    }
    Some((
        positive_socket_id(&data["conversation_id"])?,
        positive_socket_id(&data["reader_id"])?,
        positive_socket_id(&data["last_read_message_id"])?,
    ))
}

pub(crate) fn valid_chat_event(channel_id: u64, body: &[u8]) -> bool {
    let Ok(event) = serde_json::from_slice::<NotificationEnvelope<'_>>(body) else {
        return false;
    };
    if event.room.as_deref().is_some_and(|room| room != format!("chat:channel:{channel_id}")) {
        return false;
    }
    if typing_kind(&event.kind).is_some() {
        return matches!(typing_event(&event, body), Some((TypingTarget::Channel(id), _)) if id == channel_id);
    }
    if !matches!(
        event.kind.as_str(),
        "chat_message"
            | "chat_message_updated"
            | "chat_message_deleted"
            | "chat_reaction_updated"
            | "chat_channel_updated"
            | "room_message"
    ) || !valid_timestamp(&event.timestamp)
    {
        return false;
    }
    serde_json::from_str::<Value>(event.data.get())
        .is_ok_and(|data| positive_socket_id(&data["channel_id"]) == Some(channel_id))
}

fn is_notification(kind: &str) -> bool {
    matches!(
        kind,
        "notification_created"
            | "notification_read_status_updated"
            | "notifications_read_status_updated"
            | "notification_deleted"
            | "notification_restored"
    )
}

fn valid_presence(raw: &str) -> bool {
    let Ok(data) = serde_json::from_str::<Value>(raw) else {
        return false;
    };
    if !data.as_object().is_some_and(|fields| fields.len() == 4) {
        return false;
    }
    let Some(id) = data.get("user_id").and_then(Value::as_u64) else {
        return false;
    };
    if id == 0
        || id > 9_007_199_254_740_991
        || data
            .get("server_id")
            .and_then(Value::as_str)
            .is_none_or(str::is_empty)
    {
        return false;
    }
    let Some(status) = data.get("online_status").and_then(Value::as_str) else {
        return false;
    };
    let Some(last_seen) = data.get("last_seen_at") else {
        return false;
    };
    match status {
        "hidden" => last_seen.is_null(),
        "online" | "offline" => last_seen.is_null() || last_seen.is_string(),
        _ => false,
    }
}

fn valid_timestamp(timestamp: &serde_json::Number) -> bool {
    timestamp
        .as_f64()
        .is_some_and(|n| (0.0..=9_007_199_254_740_991.0).contains(&n) && n.fract() == 0.0)
}

fn valid_presence_frame(event: &NotificationEnvelope<'_>) -> bool {
    event.kind == "presence_update"
        && valid_presence(event.data.get())
        && valid_timestamp(&event.timestamp)
}

fn valid_realtime_status(event: &NotificationEnvelope<'_>, user: u64) -> bool {
    if event.kind != "system_notification" || !valid_timestamp(&event.timestamp) {
        return false;
    }
    let Ok(data) = serde_json::from_str::<Value>(event.data.get()) else {
        return false;
    };
    data.as_object().is_some_and(|map| map.len() == 5)
        && data["code"] == "realtime_status"
        && user > 0
        && user <= 9_007_199_254_740_991
        && data["user_id"].as_u64() == Some(user)
        && data["server_id"].as_str().is_some_and(|v| !v.is_empty())
        && data["local_presence"] == true
        && matches!(
            data["remote_events"].as_str(),
            Some("connecting" | "connected" | "unavailable")
        )
}

pub(crate) fn event_matches_channel(channel: &str, user_channel: &str, body: &[u8]) -> bool {
    let Ok(event) = serde_json::from_slice::<NotificationEnvelope<'_>>(body) else {
        return false;
    };
    if !event.data.get().trim_start().starts_with('{') || !valid_timestamp(&event.timestamp) {
        return false;
    }
    if event.kind.starts_with("call_") {
        return channel == user_channel && crate::webrtc::valid_on_user_channel(channel, body);
    }
    (channel == user_channel && (is_notification(&event.kind) || direct_message_ids(&event).is_some()
        || direct_read_ids(&event, body).is_some() || matches!(typing_event(&event, body), Some((TypingTarget::Direct(_), _)))))
        || (channel == "ws:presence" && valid_presence_frame(&event))
}

fn access_token(uri: &Uri, headers: &HeaderMap) -> String {
    let query = reqwest::Url::parse(&format!(
        "http://localhost/?{}",
        uri.query().unwrap_or_default()
    ))
    .expect("fixed URL");
    if let Some((_, token)) = query.query_pairs().find(|(key, _)| key == "token") {
        if !token.is_empty() {
            return token.into_owned();
        }
    }
    let header = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default();
    static BEARER: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let bearer = BEARER
        .get_or_init(|| regex::Regex::new(r"(?i)^Bearer\s+").expect("fixed regex"))
        .replace(header, "")
        .trim()
        .to_owned();
    if !bearer.is_empty() {
        return bearer;
    }
    named_cookie(headers, "access_token").unwrap_or_default()
}
fn origin_allowed(headers: &HeaderMap, policy: &CorsPolicy, site_base_url: &str) -> bool {
    let Some(header) = headers.get("origin") else {
        return true;
    };
    let Ok(origin) = header.to_str() else {
        return false;
    };
    if policy.allows(origin) {
        return true;
    }
    let Ok(url) = reqwest::Url::parse(origin) else {
        return false;
    };
    if url.origin().ascii_serialization() != origin {
        return false;
    }
    if url.scheme() == "https" {
        return origin == site_base_url;
    }
    let host = headers
        .get("host")
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default();
    url.scheme() == "http" && origin == format!("http://{host}")
}
pub(crate) async fn upgrade(
    ws: WebSocketUpgrade,
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    if !origin_allowed(&headers, &state.cors, state.storage_urls.site_base_url()) {
        return Err(ApiError::forbidden("Forbidden"));
    }
    let token = access_token(&uri, &headers);
    if token.is_empty() {
        return Err(ApiError::unauthorized("请先登录"));
    }
    let claims = state
        .codec
        .verify(&token, TokenKind::Access, (state.clock)())
        .map_err(|_| ApiError::unauthorized("Token无效或已过期"))?;
    if state.repository.touch(&claims).await.unwrap_or(0) != 1 {
        return Err(ApiError::unauthorized("Token无效或已过期"));
    }
    let source = state.notification_source.as_ref().ok_or_else(|| {
        ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            50301,
            "服务暂不可用，请稍后重试。",
        )
    })?;
    let events = source.subscribe(claims.user_id).await.map_err(|_| {
        ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            50301,
            "服务暂不可用，请稍后重试。",
        )
    })?;
    Ok(ws
        .max_message_size(65536)
        .max_frame_size(65536)
        .on_upgrade(move |socket| {
            handle(
                socket,
                state,
                token,
                claims.user_id,
                claims.session_id,
                events,
            )
        }))
}
async fn alive(state: &NativeState, token: &str, user: u64, session: &str) -> bool {
    let Ok(claims) = state
        .codec
        .verify(token, TokenKind::Access, (state.clock)())
    else {
        return false;
    };
    if claims.user_id != user || claims.session_id != session {
        return false;
    }
    state.repository.touch(&claims).await.is_ok_and(|n| n == 1)
}
async fn send(socket: &mut WebSocket, value: Value) -> bool {
    send_text(socket, value.to_string()).await
}

async fn send_text(socket: &mut WebSocket, text: String) -> bool {
    tokio::time::timeout(
        Duration::from_secs(5),
        socket.send(Message::Text(text.into())),
    )
    .await
    .is_ok_and(|r| r.is_ok())
}

struct RoomDelivery {
    channel: u64,
    membership: Arc<()>,
    body: Option<Vec<u8>>,
}

struct RoomMembership {
    marker: Arc<()>,
    task: tokio::task::AbortHandle,
    _observation: crate::observability::RoomObservation<'static>,
}

async fn relay_room(
    channel: u64,
    membership: Arc<()>,
    source: Arc<dyn crate::notification_source::NotificationSource>,
    out: mpsc::Sender<RoomDelivery>,
) {
    loop {
        if let Ok(mut events) = source.subscribe_chat_channel(channel).await {
            if out.try_send(RoomDelivery { channel, membership: membership.clone(), body: None }).is_err() {
                return;
            }
            while let Some(body) = events.recv().await {
                if body.len() <= 262144
                    && valid_chat_event(channel, &body)
                    && out
                        .try_send(RoomDelivery {
                            channel,
                            membership: membership.clone(),
                            body: Some(body),
                        })
                        .is_err()
                {
                    // The socket supervises each room task and closes on overflow.
                    return;
                }
            }
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
}

async fn room_access(state: &NativeState, user: u64, channel: u64) -> Result<bool, ()> {
    tokio::time::timeout(
        Duration::from_secs(5),
        state.repository.can_read_chat_channel(user, channel),
    )
    .await
    .map_err(|_| ())?
    .map_err(|_| ())
}

pub(crate) async fn typing_peer(state: &NativeState, user: u64, conversation: u64) -> Option<u64> {
    tokio::time::timeout(Duration::from_secs(5), state.repository.direct_typing_peer(user, conversation))
        .await.ok()?.ok()?.filter(|peer| *peer != user)
}

#[derive(Default)]
struct TypingRate([Option<tokio::time::Instant>; 2]);

impl TypingRate {
    fn take(&mut self, kind: &str, now: tokio::time::Instant) -> bool {
        let slot = &mut self.0[usize::from(kind == "typing_stop")];
        let interval = Duration::from_millis(crate::direct_read::contract().typing_min_interval_ms);
        if slot.is_some_and(|previous| now.duration_since(previous) < interval) {
            return false;
        }
        *slot = Some(now);
        true
    }
}
async fn handle(
    mut socket: WebSocket,
    state: NativeState,
    token: String,
    user: u64,
    session: String,
    mut events: mpsc::Receiver<Vec<u8>>,
) {
    let metrics = crate::observability::metrics();
    let _socket = metrics.socket();
    let mut calls = crate::webrtc::Socket::new();
    let now = || chrono::Utc::now().timestamp_millis();
    let welcome = json!({
        "type": "system_notification",
        "data": {
            "message": "WebSocket connected",
            "session_id": calls.id(),
            "user_id": user,
        },
        "timestamp": now(),
    });
    if !send(&mut socket, welcome).await {
        return;
    }
    let mut interval = tokio::time::interval_at(
        tokio::time::Instant::now() + Duration::from_secs(30),
        Duration::from_secs(30),
    );
    let Some(source) = state.notification_source.clone() else {
        return;
    };
    let mut rooms: HashMap<u64, RoomMembership> = HashMap::new();
    let mut typing_rate = TypingRate::default();
    let (room_tx, mut room_rx) = mpsc::channel::<RoomDelivery>(16);
    let mut room_tasks = JoinSet::new();
    loop {
        let call_deadline = calls.deadline();
        tokio::select! {
            _ = crate::webrtc::ring_timer(call_deadline) => {
                calls.expire(&state, user).await;
            },
            result = room_tasks.join_next(), if !room_tasks.is_empty() => {
                if !result.is_some_and(|result| result.is_err_and(|error| error.is_cancelled())) {
                    break;
                }
            }
            _ = interval.tick() => {
                if !alive(&state, &token, user, &session).await { break; }
            },
            incoming = socket.recv() => {
                let text = match incoming {
                    Some(Ok(Message::Text(text))) => text,
                    Some(Ok(Message::Ping(_) | Message::Pong(_) | Message::Binary(_))) => continue,
                    _ => break,
                };
                if !alive(&state, &token, user, &session).await { break; }
                let value = match serde_json::from_str::<Value>(&text) {
                    Ok(value) => value,
                    Err(_) if text.contains("ping") => json!({"type":"ping"}),
                    Err(_) => Value::Null,
                };
                let (kind, data) = match value["type"].as_str() {
                    Some("ping") => ("pong", json!({"timestamp": now()})),
                    Some("chat_leave_channel") => {
                        if let Some(room) = command_channel_id(&value["data"]).and_then(|id| rooms.remove(&id)) {
                            room.task.abort();
                        }
                        continue;
                    }
                    Some("chat_join_channel") => {
                        let Some(channel) = command_channel_id(&value["data"]) else {
                            if !send(&mut socket, json!({"type":"error","data":{"message":"channelId 参数错误"},"timestamp":now()})).await { break; }
                            continue;
                        };
                        match room_access(&state, user, channel).await {
                            Ok(true) if rooms.contains_key(&channel) || rooms.len() < MAX_CHAT_CHANNELS => {
                                rooms.entry(channel).or_insert_with(|| {
                                    let membership = Arc::new(());
                                    let task = room_tasks.spawn(relay_room(channel, membership.clone(), source.clone(), room_tx.clone()));
                                    RoomMembership { marker: membership, task, _observation: metrics.room(channel) }
                                });
                                ("system_notification", json!({"message":"chat channel joined","channel_id":channel,"room":format!("chat:channel:{channel}")}))
                            }
                            Ok(true) => ("error", json!({"message":"加入的聊天频道已达上限","channel_id":channel})),
                            Ok(false) => ("error", json!({"message":"无权访问该聊天频道","channel_id":channel})),
                            Err(()) => ("error", json!({"message":"服务暂不可用","channel_id":channel})),
                        }
                    }
                    Some(raw_kind @ ("typing_start" | "typing_stop")) => {
                        if !value.as_object().is_some_and(|fields| fields.len() == 2 && fields.contains_key("data")) { continue; }
                        let (Some(kind), Some(target), Some(publisher)) = (
                            typing_kind(raw_kind), typing_command(&value["data"]), &state.notification_publisher,
                        ) else { continue; };
                        if !typing_rate.take(kind, tokio::time::Instant::now()) { continue; }
                        let scope = match target {
                            TypingTarget::Direct(conversation) => {
                                let Some(recipient) = typing_peer(&state, user, conversation).await else { continue; };
                                TypingScope::Direct { conversation, recipient }
                            }
                            TypingTarget::Channel(channel) => {
                                if !rooms.contains_key(&channel) || room_access(&state, user, channel).await != Ok(true) { continue; }
                                TypingScope::Channel(channel)
                            }
                        };
                        let _ = publisher.publish_typing(scope, user, kind).await;
                        continue;
                    }
                    Some(kind) if crate::webrtc::control(kind) => {
                        if let Some(reply) = calls.incoming(&state, user, &value).await {
                            if !send(&mut socket, reply).await { break; }
                        }
                        continue;
                    }
                    Some(other) => ("error", json!({"message":"不支持的 WebSocket 消息类型","type":other})),
                    None => ("error", json!({"message":"消息格式错误"})),
                };
                if !send(&mut socket, json!({"type": kind, "data": data, "timestamp": now()})).await { break; }
            },
            Some(delivery) = room_rx.recv() => {
                if !rooms.get(&delivery.channel).is_some_and(|room| Arc::ptr_eq(&room.marker, &delivery.membership)) {
                    continue;
                }
                if !alive(&state, &token, user, &session).await { break; }
                if room_access(&state, user, delivery.channel).await != Ok(true) {
                    if let Some(room) = rooms.remove(&delivery.channel) {
                        room.task.abort();
                    }
                    continue;
                }
                let Some(body) = delivery.body else {
                    if !send(&mut socket, json!({"type":"system_notification","data":{
                        "code":"chat_channel_ready","channel_id":delivery.channel,
                        "room":format!("chat:channel:{}", delivery.channel)
                    },"timestamp":now()})).await { break; }
                    continue;
                };
                if let Ok(event) = serde_json::from_slice::<NotificationEnvelope<'_>>(&body) {
                    if let Some((TypingTarget::Channel(_), actor)) = typing_event(&event, &body) {
                        if actor == user || room_access(&state, actor, delivery.channel).await != Ok(true) { continue; }
                    }
                }
                let Ok(text) = String::from_utf8(body) else { continue };
                if !send_text(&mut socket, text).await { break; }
            },
            event = events.recv() => {
                let Some(body) = event else { break };
                if body.len() > 262144 { continue; }
                let Ok(value) = serde_json::from_slice::<NotificationEnvelope<'_>>(&body) else { continue };
                if value.kind.starts_with("call_") {
                    if !alive(&state, &token, user, &session).await { break; }
                    if calls.can_receive(&state, user, &body).await {
                        let Ok(text) = String::from_utf8(body) else { continue };
                        if !send_text(&mut socket, text).await { break; }
                    }
                    continue;
                }
                let direct = direct_message_ids(&value);
                let receipt = direct_read_ids(&value, &body);
                let typing = match typing_event(&value, &body) {
                    Some((TypingTarget::Direct(conversation), actor)) => Some((conversation, actor)),
                    _ => None,
                };
                if !valid_timestamp(&value.timestamp)
                    || !(is_notification(&value.kind) || valid_presence_frame(&value) || direct.is_some()
                        || receipt.is_some() || typing.is_some() || valid_realtime_status(&value, user))
                    || !value.data.get().trim_start().starts_with('{') { continue; }
                if !alive(&state, &token, user, &session).await { break; }
                if let Some((conversation, message, deleted)) = direct {
                    if !matches!(tokio::time::timeout(Duration::from_secs(5),
                        state.repository.can_deliver_direct_message(user, conversation, message, deleted)).await, Ok(Ok(true))) {
                        continue;
                    }
                }
                if let Some((conversation, reader, cursor)) = receipt {
                    if !matches!(tokio::time::timeout(Duration::from_secs(5),
                        state.repository.can_deliver_direct_read(user, conversation, reader, cursor)).await, Ok(Ok(true))) {
                        continue;
                    }
                }
                if let Some((conversation, actor)) = typing {
                    if actor == user || typing_peer(&state, user, conversation).await != Some(actor) { continue; }
                }
                let Ok(text) = String::from_utf8(body) else { continue };
                if !send_text(&mut socket, text).await { break; }
            }
        }
    }
    calls.disconnect(&state, user).await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn typing_commands_have_one_scope_and_per_type_throttle() {
        assert!(typing_command(&json!({"conversation_id":9})).is_some());
        assert!(typing_command(&json!({"channel_id":9})).is_some());
        for data in [json!({"channel_id":"9"}), json!({"channel_id":9,"user_id":42}), json!({"channel_id":9,"conversation_id":1}), json!({"conversation_id":0})] {
            assert!(typing_command(&data).is_none());
        }
        let now = tokio::time::Instant::now();
        let mut limiter = TypingRate::default();
        assert!(limiter.take("typing_start", now));
        assert!(limiter.take("typing_stop", now));
        assert!(!limiter.take("typing_start", now + Duration::from_millis(1199)));
        assert!(limiter.take("typing_start", now + Duration::from_millis(1200)));
    }

    #[test]
    fn typing_and_receipts_only_admit_their_scoped_broker_channels() {
        let input = |kind, data| json!({"type":kind,"data":data,"timestamp":1}).to_string();
        let typing = |data| input("typing_start", data);
        let direct = typing(json!({"conversation_id":11,"user_id":9}));
        let room = typing(json!({"channel_id":7,"user_id":9}));
        let receipt = input("direct_read_updated", json!({"conversation_id":11,"reader_id":9,"last_read_message_id":13}));
        for frame in [&direct, &receipt] {
            assert!(event_matches_channel("ws:user:42", "ws:user:42", frame.as_bytes()));
            assert!(!event_matches_channel("ws:user:9", "ws:user:42", frame.as_bytes()));
            assert!(!event_matches_channel("ws:presence", "ws:user:42", frame.as_bytes()));
            assert!(!valid_chat_event(7, frame.as_bytes()));
        }
        assert!(valid_chat_event(7, room.as_bytes()));
        assert!(!valid_chat_event(9, room.as_bytes()));
        assert!(!event_matches_channel("ws:user:42", "ws:user:42", room.as_bytes()));
        let extra = input("direct_read_updated", json!({"conversation_id":11,"reader_id":9,"last_read_message_id":13,"unread_count":8}));
        assert!(!event_matches_channel("ws:user:42", "ws:user:42", extra.as_bytes()));
        let extra = br#"{"type":"typing_start","data":{"channel_id":7,"user_id":9},"timestamp":1,"room":"chat:channel:7"}"#;
        assert!(!valid_chat_event(7, extra));
    }
    #[test]
    fn broker_event_admission_follows_shared_contract() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../contracts/scenarios/notification-websocket.json"
        ))
        .unwrap();
        let cases = fixture["brokerCases"].as_array().unwrap();
        assert!(!cases.is_empty());
        for entry in cases {
            let raw = entry["raw"].as_str().unwrap().as_bytes();
            let accepted = match entry["channel_id"].as_u64() {
                Some(channel) => valid_chat_event(channel, raw),
                None => event_matches_channel(entry["channel"].as_str().unwrap(), "ws:user:42", raw),
            };
            assert_eq!(accepted, entry["valid"].as_bool().unwrap(), "{}", entry["id"]);
        }
    }

    #[test]
    fn shared_remote_presence_rejects_extra_fields_and_invalid_clocks() {
        let fixture: Value =
            serde_json::from_str(include_str!("../contracts/scenarios/local-presence.json"))
                .unwrap();
        for case in fixture["remoteCases"].as_array().unwrap() {
            let body = case["frame"].to_string();
            assert_eq!(
                event_matches_channel("ws:presence", "ws:user:42", body.as_bytes()),
                case["valid"].as_bool().unwrap(),
                "{}",
                case["id"]
            );
        }
    }
    #[test]
    fn only_configured_public_https_origin_is_allowed_behind_proxy() {
        let mut headers = HeaderMap::new();
        headers.insert("host", "backend.internal:8080".parse().unwrap());
        headers.insert("x-forwarded-proto", "https".parse().unwrap());
        let policy = CorsPolicy::default();
        let public = "https://neko.example:8443";
        for (origin, allowed) in [
            (public, true),
            ("https://neko.example", false),
            ("https://neko.example:8443/path", false),
            ("https://backend.internal:8080", false),
            ("http://backend.internal:8080", true),
        ] {
            headers.insert("origin", origin.parse().unwrap());
            assert_eq!(origin_allowed(&headers, &policy, public), allowed, "{origin}");
        }
    }

    #[test]
    fn channel_checks_preserve_notification_json_and_hide_last_seen() {
        let raw = br#"{"type":"notification_created","data":{"text":"\ud83d"},"timestamp":1}"#;
        let valid = br#"{"type":"presence_update","data":{"user_id":9,"online_status":"hidden","last_seen_at":null,"server_id":"peer"},"timestamp":1}"#;
        let leaked = br#"{"type":"presence_update","data":{"user_id":9,"online_status":"hidden","last_seen_at":"secret","server_id":"peer"},"timestamp":1}"#;
        assert!(event_matches_channel("ws:user:42", "ws:user:42", raw));
        assert!(!event_matches_channel("ws:presence", "ws:user:42", raw));
        assert!(event_matches_channel("ws:presence", "ws:user:42", valid));
        assert!(!event_matches_channel("ws:user:42", "ws:user:42", valid));
        assert!(!event_matches_channel("ws:presence", "ws:user:42", leaked));
        let dm = br#"{"type":"direct_message","data":{"conversation_id":12,"direct_message":{"conversation_id":12,"message_id":1}},"timestamp":1}"#;
        assert!(event_matches_channel("ws:user:42", "ws:user:42", dm));
        assert!(!event_matches_channel("ws:user:9", "ws:user:42", dm));
        assert!(!event_matches_channel("ws:presence", "ws:user:42", dm));
    }

    #[test]
    fn shared_local_presence_status_is_strict_and_never_accepted_from_broker() {
        let fixture: Value =
            serde_json::from_str(include_str!("../contracts/scenarios/local-presence.json"))
                .unwrap();
        for case in fixture["statusCases"].as_array().unwrap() {
            let body = json!({"type":"system_notification", "data":{"code":"realtime_status","user_id":42,"server_id":"instance","local_presence":case["local_presence"],"remote_events":case["remote_events"]},"timestamp":1234}).to_string();
            let event = serde_json::from_str::<NotificationEnvelope<'_>>(&body).unwrap();
            assert_eq!(
                valid_realtime_status(&event, 42),
                case["valid"].as_bool().unwrap(),
                "{}",
                case["id"]
            );
            assert!(!valid_realtime_status(&event, 9));
            assert!(!event_matches_channel(
                "ws:user:42",
                "ws:user:42",
                body.as_bytes()
            ));
            assert!(!event_matches_channel(
                "ws:presence",
                "ws:user:42",
                body.as_bytes()
            ));
        }
        for timestamp in [-1.0, 0.5, 9_007_199_254_740_992.0] {
            let body = json!({"type":"system_notification", "data":{"code":"realtime_status","user_id":42,"server_id":"instance","local_presence":true,"remote_events":"connected"},"timestamp":timestamp}).to_string();
            let event = serde_json::from_str::<NotificationEnvelope<'_>>(&body).unwrap();
            assert!(!valid_realtime_status(&event, 42));
        }
    }
}
