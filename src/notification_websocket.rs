use crate::{
    auth::{
        sessions::{named_cookie, CorsPolicy, NativeState},
        TokenKind,
    },
    httpx::errors::ApiError,
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
    if (!deleted && event.kind != "direct_message") || !valid_timestamp(&event.timestamp) {
        return None;
    }
    let data = serde_json::from_str::<Value>(event.data.get()).ok()?;
    let conversation = positive_socket_id(&data["conversation_id"])?;
    if deleted {
        let fields = data.as_object()?;
        if fields.keys().any(|key| !matches!(key.as_str(), "conversation_id" | "message_id" | "server_id")) { return None; }
        if fields.get("server_id").is_some_and(|value| value.as_str().is_none_or(str::is_empty)) { return None; }
        let message = positive_socket_id(&data["message_id"])?;
        return Some((conversation, message, true));
    }
    let message = &data["direct_message"];
    let message_id = positive_socket_id(&message["message_id"])?;
    (positive_socket_id(&message["conversation_id"]) == Some(conversation))
        .then_some((conversation, message_id, false))
}

pub(crate) fn valid_chat_event(channel_id: u64, body: &[u8]) -> bool {
    let Ok(event) = serde_json::from_slice::<NotificationEnvelope<'_>>(body) else {
        return false;
    };
    if !matches!(
        event.kind.as_str(),
        "chat_message"
            | "chat_message_updated"
            | "chat_message_deleted"
            | "chat_reaction_updated"
            | "chat_channel_updated"
            | "room_message"
    ) || !valid_timestamp(&event.timestamp)
        || event
            .room
            .is_some_and(|room| room != format!("chat:channel:{channel_id}"))
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
    (channel == user_channel && (is_notification(&event.kind) || direct_message_ids(&event).is_some()))
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
async fn handle(
    mut socket: WebSocket,
    state: NativeState,
    token: String,
    user: u64,
    session: String,
    mut events: mpsc::Receiver<Vec<u8>>,
) {
    let now = || chrono::Utc::now().timestamp_millis();
    let welcome = json!({
        "type": "system_notification",
        "data": {
            "message": "WebSocket connected",
            "session_id": format!("ws_{}", uuid::Uuid::new_v4()),
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
    let mut rooms = HashMap::new();
    let (room_tx, mut room_rx) = mpsc::channel::<RoomDelivery>(16);
    let mut room_tasks = JoinSet::new();
    loop {
        tokio::select! {
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
                        if let Some((_, task)) = command_channel_id(&value["data"]).and_then(|id| rooms.remove(&id)) {
                            tokio::task::AbortHandle::abort(&task);
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
                                    (membership, task)
                                });
                                ("system_notification", json!({"message":"chat channel joined","channel_id":channel,"room":format!("chat:channel:{channel}")}))
                            }
                            Ok(true) => ("error", json!({"message":"加入的聊天频道已达上限","channel_id":channel})),
                            Ok(false) => ("error", json!({"message":"无权访问该聊天频道","channel_id":channel})),
                            Err(()) => ("error", json!({"message":"服务暂不可用","channel_id":channel})),
                        }
                    }
                    Some(other) => ("error", json!({"message":"不支持的 WebSocket 消息类型","type":other})),
                    None => ("error", json!({"message":"消息格式错误"})),
                };
                if !send(&mut socket, json!({"type": kind, "data": data, "timestamp": now()})).await { break; }
            },
            Some(delivery) = room_rx.recv() => {
                if !rooms.get(&delivery.channel).is_some_and(|(membership, _)| Arc::ptr_eq(membership, &delivery.membership)) {
                    continue;
                }
                if !alive(&state, &token, user, &session).await { break; }
                if room_access(&state, user, delivery.channel).await != Ok(true) {
                    if let Some((_, task)) = rooms.remove(&delivery.channel) {
                        task.abort();
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
                let Ok(text) = String::from_utf8(body) else { continue };
                if !send_text(&mut socket, text).await { break; }
            },
            event = events.recv() => {
                let Some(body) = event else { break };
                if body.len() > 262144 { continue; }
                let Ok(value) = serde_json::from_slice::<NotificationEnvelope<'_>>(&body) else { continue };
                let direct = direct_message_ids(&value);
                if !valid_timestamp(&value.timestamp)
                    || !(is_notification(&value.kind) || valid_presence_frame(&value) || direct.is_some() || valid_realtime_status(&value, user))
                    || !value.data.get().trim_start().starts_with('{') { continue; }
                if !alive(&state, &token, user, &session).await { break; }
                if let Some((conversation, message, deleted)) = direct {
                    if !matches!(tokio::time::timeout(Duration::from_secs(5),
                        state.repository.can_deliver_direct_message(user, conversation, message, deleted)).await, Ok(Ok(true))) {
                        continue;
                    }
                }
                let Ok(text) = String::from_utf8(body) else { continue };
                if !send_text(&mut socket, text).await { break; }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
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
