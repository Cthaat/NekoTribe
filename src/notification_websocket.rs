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
use std::time::Duration;
use tokio::sync::mpsc;

#[derive(serde::Deserialize)]
struct NotificationEnvelope<'a> {
    #[serde(rename = "type")]
    kind: String,
    #[serde(borrow)]
    data: &'a serde_json::value::RawValue,
    timestamp: serde_json::Number,
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

pub(crate) fn event_matches_channel(channel: &str, user_channel: &str, body: &[u8]) -> bool {
    let Ok(event) = serde_json::from_slice::<NotificationEnvelope<'_>>(body) else {
        return false;
    };
    if !event.data.get().trim_start().starts_with('{') {
        return false;
    }
    (channel == user_channel && is_notification(&event.kind))
        || (channel == "ws:presence"
            && event.kind == "presence_update"
            && valid_presence(event.data.get()))
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
fn origin_allowed(headers: &HeaderMap, policy: &CorsPolicy) -> bool {
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
    if url.scheme() != "http" || url.origin().ascii_serialization() != origin {
        return false;
    }
    let host = headers
        .get("host")
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default();
    origin == format!("http://{host}")
}
pub(crate) async fn upgrade(
    ws: WebSocketUpgrade,
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    if !origin_allowed(&headers, &state.cors) {
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
    tokio::time::timeout(
        Duration::from_secs(5),
        socket.send(Message::Text(value.to_string().into())),
    )
    .await
    .is_ok_and(|r| r.is_ok())
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
    loop {
        tokio::select! {
            _ = interval.tick() => {
                if !alive(&state, &token, user, &session).await { break; }
            },
            incoming = socket.recv() => {
                let text = match incoming {
                    Some(Ok(Message::Text(text))) => text,
                    Some(Ok(Message::Ping(_) | Message::Pong(_) | Message::Binary(_))) => continue,
                    _ => break,
                };
                let kind = match serde_json::from_str::<Value>(&text) {
                    Ok(value) => value.get("type").and_then(Value::as_str).map(str::to_owned),
                    Err(_) if text.contains("ping") => Some("ping".into()),
                    Err(_) => None,
                };
                let (kind, data) = match kind.as_deref() {
                    Some("ping") => {
                        if !alive(&state, &token, user, &session).await { break; }
                        ("pong", json!({"timestamp": now()}))
                    },
                    Some(other) => ("error", json!({"message":"不支持的 WebSocket 消息类型","type":other})),
                    None => ("error", json!({"message":"消息格式错误"})),
                };
                if !send(&mut socket, json!({"type": kind, "data": data, "timestamp": now()})).await { break; }
            },
            event = events.recv() => {
                let Some(body) = event else { break };
                if body.len() > 262144 { continue; }
                let Ok(value) = serde_json::from_slice::<NotificationEnvelope<'_>>(&body) else { continue };
                if !(is_notification(&value.kind) || (value.kind == "presence_update" && valid_presence(value.data.get())))
                    || !value.data.get().trim_start().starts_with('{') { continue; }
                let _ = value.timestamp;
                if !alive(&state, &token, user, &session).await { break; }
                let Ok(text) = String::from_utf8(body) else { continue };
                if !tokio::time::timeout(Duration::from_secs(5), socket.send(Message::Text(text.into())))
                    .await.is_ok_and(|result| result.is_ok()) { break; }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
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
    }
}
