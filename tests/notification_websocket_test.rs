use futures_util::{SinkExt, StreamExt};
use nekotribe_backend::{
    auth::{
        otp::SmtpConfig,
        sessions::{
            build_native_router_with_realtime_and_publisher, CorsPolicy, RefreshPolicy, SessionRepository,
            StoreFuture,
        },
        storage_urls::StorageUrlPolicy,
        IssuedToken, TokenClaims, TokenCodec, TokenKind,
    },
    local_presence::LocalPresenceEvents,
    notification_events::{EventError, NotificationPublisher, TypingScope},
    notification_source::{NotificationSource, SubscriptionFuture},
};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};
use tokio::sync::{mpsc, oneshot};
use tokio_tungstenite::{
    connect_async,
    tungstenite::{client::IntoClientRequest, http::StatusCode, Error, Message},
};

#[derive(Default)]
struct Repository(AtomicBool, AtomicBool);
impl SessionRepository for Repository {
    fn can_read_chat_channel(&self, user: u64, channel: u64) -> StoreFuture<'_, bool> {
        Box::pin(async move { Ok(user == 42 && channel == 7 && self.1.load(Ordering::SeqCst)) })
    }
    fn can_deliver_direct_message(&self, user: u64, conversation: u64, message: u64, deleted: bool) -> StoreFuture<'_, bool> {
        Box::pin(async move { Ok(user == 42 && conversation == 11 && message == if deleted { 13 } else { 12 }) })
    }
    fn can_deliver_direct_read(&self, user: u64, conversation: u64, reader: u64, cursor: u64) -> StoreFuture<'_, bool> {
        Box::pin(async move { Ok((user, conversation, reader, cursor) == (42, 11, 9, 12)) })
    }
    fn touch<'a>(&'a self, _claims: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async move { Ok(u64::from(!self.0.load(Ordering::SeqCst))) })
    }
    fn revoke<'a>(&'a self, _user: u64, _id: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async move {
            self.0.store(true, Ordering::SeqCst);
            Ok(1)
        })
    }
    fn revoke_others<'a>(&'a self, _user: u64, _id: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
}
#[derive(Default)]
struct Source {
    subscribers: Mutex<HashMap<u64, mpsc::Sender<Vec<u8>>>>,
    rooms: Mutex<HashMap<u64, mpsc::Sender<Vec<u8>>>>,
    unavailable: AtomicBool,
}
impl NotificationSource for Source {
    fn subscribe_chat_channel(&self, channel: u64) -> SubscriptionFuture<'_> {
        Box::pin(async move {
            let (sender, receiver) = mpsc::channel(16);
            self.rooms.lock().unwrap().insert(channel, sender);
            Ok(receiver)
        })
    }
    fn subscribe(&self, user: u64) -> SubscriptionFuture<'_> {
        Box::pin(async move {
            if self.unavailable.load(Ordering::SeqCst) {
                return Err(EventError);
            }
            let (sender, receiver) = mpsc::channel(16);
            self.subscribers.lock().unwrap().insert(user, sender);
            Ok(receiver)
        })
    }
}

#[tokio::test]
async fn chat_channel_rechecks_permission_and_delivers_only_matching_events() {
    let repo = Arc::new(Repository::default());
    let source = Arc::new(Source::default());
    let (url, first, _, stop, task) =
        server(repo.clone(), source.clone(), Arc::new(AtomicU64::new(150))).await;
    let (mut socket, _) = connect_async(format!("{url}?token={first}")).await.unwrap();
    let _welcome = receive(&mut socket).await;
    let join = || {
        Message::Text(
            json!({"type":"chat_join_channel","data":{"channelId":7}})
                .to_string()
                .into(),
        )
    };
    socket.send(join()).await.unwrap();
    assert_eq!(receive(&mut socket).await["type"], "error");
    assert!(source.rooms.lock().unwrap().is_empty());
    repo.1.store(true, Ordering::SeqCst);
    socket.send(join()).await.unwrap();
    assert_eq!(receive(&mut socket).await["data"]["room"], "chat:channel:7");
    assert_eq!(receive(&mut socket).await["data"]["code"], "chat_channel_ready");
    let room = tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            if let Some(sender) = source.rooms.lock().unwrap().get(&7).cloned() {
                break sender;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    for id in [8, 7] {
        room.send(
            json!({"type":"chat_message","data":{"channel_id":id},"timestamp":1})
                .to_string()
                .into_bytes(),
        )
        .await
        .unwrap();
    }
    assert_eq!(receive(&mut socket).await["data"]["channel_id"], 7);
    for message in [10, 12] {
        source.publish(42, json!({"type":"direct_message","data":{"conversation_id":11,"direct_message":{"conversation_id":11,"message_id":message}},"timestamp":1})).await;
    }
    let direct = receive(&mut socket).await;
    assert_eq!(direct["type"], "direct_message");
    assert_eq!(direct["data"]["direct_message"]["message_id"], 12);
    for message in [12, 13] {
        source.publish(42, json!({"type":"direct_message_deleted","data":{"conversation_id":11,"message_id":message},"timestamp":1})).await;
    }
    let deletion = receive(&mut socket).await;
    assert_eq!(deletion["type"], "direct_message_deleted");
    assert_eq!(deletion["data"]["message_id"], 13);
    for data in [
        json!({"conversation_id":44,"message_id":12}),
        json!({"conversation_id":11,"message_id":13}),
        json!({"conversation_id":11,"message_id":12,"content":"forged"}),
        json!({"conversation_id":11,"message_id":12,"server_id":""}),
        json!({"conversation_id":11,"message_id":12,"server_id":"remote"}),
    ] {
        source.publish(42, json!({"type":"direct_message_updated","data":data,"timestamp":1})).await;
    }
    let update = receive(&mut socket).await;
    assert_eq!(update["type"], "direct_message_updated");
    assert_eq!(update["data"], json!({"conversation_id":11,"message_id":12,"server_id":"remote"}));
    for (reader, cursor) in [(91, 12), (9, 13), (9, 12)] {
        source.publish(42, json!({"type":"direct_read_updated","data":{"conversation_id":11,"reader_id":reader,"last_read_message_id":cursor},"timestamp":1})).await;
    }
    assert_eq!(receive(&mut socket).await["data"], json!({"conversation_id":11,"reader_id":9,"last_read_message_id":12}));
    repo.1.store(false, Ordering::SeqCst);
    room.send(
        json!({"type":"chat_message","data":{"channel_id":7},"timestamp":1})
            .to_string()
            .into_bytes(),
    )
    .await
    .unwrap();
    tokio::time::timeout(Duration::from_secs(3), room.closed())
        .await
        .unwrap();
    socket
        .send(Message::Text(json!({"type":"ping"}).to_string().into()))
        .await
        .unwrap();
    assert_eq!(receive(&mut socket).await["type"], "pong");
    drop(socket);
    let _ = stop.send(());
    tokio::time::timeout(Duration::from_secs(3), task)
        .await
        .unwrap()
        .unwrap();
}
impl Source {
    async fn publish(&self, user: u64, event: Value) {
        let sender = self.subscribers.lock().unwrap().get(&user).unwrap().clone();
        sender.send(event.to_string().into_bytes()).await.unwrap();
    }
}
fn token(codec: &TokenCodec, user: u64) -> String {
    codec
        .sign(&IssuedToken {
            user_id: user,
            user_name: format!("user{user}"),
            session_id: format!("session{user}"),
            kind: TokenKind::Access,
            issued_at: 100,
            expires_at: 300,
            jti: format!("token{user}"),
        })
        .unwrap()
}
async fn server(
    repo: Arc<dyn SessionRepository>,
    source: Arc<dyn NotificationSource>,
    clock: Arc<AtomicU64>,
) -> Harness {
    server_with_publisher(repo, source, clock, None).await
}

type Harness = (
    String, String, String, oneshot::Sender<()>, tokio::task::JoinHandle<()>,
);

async fn server_with_publisher(
    repo: Arc<dyn SessionRepository>,
    source: Arc<dyn NotificationSource>,
    clock: Arc<AtomicU64>,
    publisher: Option<Arc<dyn NotificationPublisher>>,
) -> Harness {
    let codec = TokenCodec::new(b"test-access-key", b"test-refresh-key").unwrap();
    let first = token(&codec, 42);
    let second = token(&codec, 9);
    let router = build_native_router_with_realtime_and_publisher(
        codec,
        repo,
        CorsPolicy::default(),
        Arc::new(move || clock.load(Ordering::SeqCst)),
        RefreshPolicy::default(),
        StorageUrlPolicy::default(),
        Arc::new(SmtpConfig::default()),
        Some(source),
        publisher,
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let (stop, stopped) = oneshot::channel();
    let task = tokio::spawn(async move {
        axum::serve(listener, router)
            .with_graceful_shutdown(async {
                let _ = stopped.await;
            })
            .await
            .unwrap();
    });
    (format!("ws://{address}/_ws"), first, second, stop, task)
}

#[tokio::test]
async fn typing_delivers_locally_to_current_peers_and_joined_members_only() {
    struct ChatRepository { direct: AtomicBool, channel: AtomicBool }
    impl SessionRepository for ChatRepository {
        fn touch<'a>(&'a self, _: &'a TokenClaims) -> StoreFuture<'a, u64> { Box::pin(async { Ok(1) }) }
        fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> { Box::pin(async { Ok(0) }) }
        fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> { Box::pin(async { Ok(0) }) }
        fn can_read_chat_channel(&self, user: u64, channel: u64) -> StoreFuture<'_, bool> {
            Box::pin(async move { Ok(channel == 7 && (user == 42 || user == 9 && self.channel.load(Ordering::SeqCst))) })
        }
        fn direct_typing_peer(&self, user: u64, conversation: u64) -> StoreFuture<'_, Option<u64>> {
            Box::pin(async move {
                if conversation == 11 && self.direct.load(Ordering::SeqCst) {
                    Ok(match user { 42 => Some(9), 9 => Some(42), _ => None })
                } else {
                    Ok(None)
                }
            })
        }
    }
    let repo = Arc::new(ChatRepository { direct: AtomicBool::new(true), channel: AtomicBool::new(true) });
    let hub = Arc::new(LocalPresenceEvents::new(None, None).unwrap());
    let (url, first, second, stop, task) = server_with_publisher(repo.clone(), hub.clone(), Arc::new(AtomicU64::new(150)), Some(hub.clone())).await;
    let (mut left, _) = connect_async(format!("{url}?token={first}")).await.unwrap();
    let (mut right, _) = connect_async(format!("{url}?token={second}")).await.unwrap();
    let command = |kind, data| Message::Text(json!({"type":kind,"data":data}).to_string().into());
    for socket in [&mut left, &mut right] {
        assert_eq!(receive(socket).await["data"]["message"], "WebSocket connected");
        assert_eq!(receive(socket).await["data"]["code"], "realtime_status");
    }
    left.send(command("typing_start", json!({"conversation_id":11,"user_id":9}))).await.unwrap();
    left.send(command("typing_start", json!({"conversation_id":11}))).await.unwrap();
    let started = receive(&mut right).await;
    assert_eq!(started["type"], "typing_start");
    assert_eq!(started["data"]["user_id"], 42);
    left.send(command("typing_start", json!({"conversation_id":11}))).await.unwrap();
    left.send(command("typing_stop", json!({"conversation_id":11}))).await.unwrap();
    assert_eq!(receive(&mut right).await["type"], "typing_stop");
    assert!(tokio::time::timeout(Duration::from_millis(100), left.next()).await.is_err());

    for socket in [&mut left, &mut right] {
        socket.send(command("chat_join_channel", json!({"channel_id":7}))).await.unwrap();
        assert_eq!(receive(socket).await["data"]["message"], "chat channel joined");
        assert_eq!(receive(socket).await["data"]["code"], "chat_channel_ready");
    }
    right.send(command("typing_start", json!({"channel_id":7}))).await.unwrap();
    let room = receive(&mut left).await;
    assert_eq!(room["type"], "typing_start");
    assert_eq!(room["data"]["user_id"], 9);
    assert_eq!(room["data"]["channel_id"], 7);

    repo.direct.store(false, Ordering::SeqCst);
    repo.channel.store(false, Ordering::SeqCst);
    hub.publish_typing(TypingScope::Direct { conversation: 11, recipient: 9 }, 42, "typing_stop").await.unwrap();
    hub.publish_typing(TypingScope::Channel(7), 42, "typing_stop").await.unwrap();
    assert!(tokio::time::timeout(Duration::from_millis(100), right.next()).await.is_err());
    drop(left);
    drop(right);
    let _ = stop.send(());
    tokio::time::timeout(Duration::from_secs(3), task).await.unwrap().unwrap();
}
async fn receive<S>(socket: &mut tokio_tungstenite::WebSocketStream<S>) -> Value
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let message = tokio::time::timeout(Duration::from_secs(3), socket.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    serde_json::from_str(message.to_text().unwrap()).unwrap()
}
fn status(error: Error) -> StatusCode {
    match error {
        Error::Http(response) => response.status(),
        other => panic!("unexpected error: {other}"),
    }
}

struct PendingSource;
impl NotificationSource for PendingSource {
    fn subscribe(&self, _: u64) -> SubscriptionFuture<'_> {
        Box::pin(std::future::pending())
    }
}

#[tokio::test]
async fn local_presence_degraded_socket_reports_status_and_checks_revocation() {
    for pending in [false, true] {
        let repo = Arc::new(Repository::default());
        let source: Arc<dyn NotificationSource> = if pending {
            Arc::new(PendingSource)
        } else {
            let source = Source::default();
            source.unavailable.store(true, Ordering::SeqCst);
            Arc::new(source)
        };
        let hub = Arc::new(LocalPresenceEvents::new(Some(source), None).unwrap());
        let (url, first, _, stop, task) =
            server(repo.clone(), hub.clone(), Arc::new(AtomicU64::new(150))).await;
        let (mut socket, _) = connect_async(format!("{url}?token={first}")).await.unwrap();
        assert_eq!(receive(&mut socket).await["data"]["user_id"], 42);
        let expected = if pending { "connecting" } else { "unavailable" };
        loop {
            let event = receive(&mut socket).await;
            assert_eq!(event["type"], "system_notification");
            assert_eq!(event["data"]["code"], "realtime_status");
            assert_eq!(event["data"]["local_presence"], true);
            assert_eq!(event["data"]["user_id"], 42);
            if event["data"]["remote_events"] == expected {
                break;
            }
        }
        let hidden = json!({"user_id":9,"online_status":"hidden","last_seen_at":"private"});
        let _ = hub.publish_presence(hidden.as_object().unwrap()).await;
        let event = receive(&mut socket).await;
        assert_eq!(event["type"], "presence_update");
        assert!(event["data"]["last_seen_at"].is_null());
        repo.0.store(true, Ordering::SeqCst);
        let _ = hub.publish_presence(hidden.as_object().unwrap()).await;
        let event = tokio::time::timeout(Duration::from_secs(3), socket.next())
            .await
            .unwrap();
        assert!(event.is_none() || matches!(event, Some(Ok(Message::Close(_))) | Some(Err(_))));
        drop(socket);
        hub.close();
        let _ = stop.send(());
        tokio::time::timeout(Duration::from_secs(3), task)
            .await
            .unwrap()
            .unwrap();
    }
}

#[tokio::test]
async fn notifications_are_user_scoped_and_revoked_sessions_cannot_receive() {
    let repo = Arc::new(Repository::default());
    let source = Arc::new(Source::default());
    let (url, first, second, stop, task) =
        server(repo.clone(), source.clone(), Arc::new(AtomicU64::new(150))).await;
    let (mut a, _) = connect_async(format!("{url}?token={first}")).await.unwrap();
    let (mut b, _) = connect_async(format!("{url}?token={second}"))
        .await
        .unwrap();
    assert_eq!(receive(&mut a).await["data"]["user_id"], 42);
    assert_eq!(receive(&mut b).await["data"]["user_id"], 9);
    a.send(Message::Text(json!({"type":"ping"}).to_string().into()))
        .await
        .unwrap();
    assert_eq!(receive(&mut a).await["type"], "pong");
    let event = json!({"type":"notification_created","data":{"id":123},"timestamp":151});
    source
        .publish(
            42,
            json!({"type":"direct_message","data":{},"timestamp":151}),
        )
        .await;
    source
        .publish(
            42,
            json!({"type":"notification_created","data":"invalid","timestamp":151}),
        )
        .await;
    source.publish(42, event.clone()).await;
    assert_eq!(receive(&mut a).await, event);
    let raw = r#"{"type":"notification_created","data":{"notification":{"metadata":{"post_excerpt":"prefix\ud83d..."}}},"timestamp":151}"#;
    let sender = source.subscribers.lock().unwrap().get(&42).unwrap().clone();
    sender.send(raw.as_bytes().to_vec()).await.unwrap();
    let raw_message = tokio::time::timeout(Duration::from_secs(3), a.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(raw_message.to_text().unwrap(), raw);
    assert!(tokio::time::timeout(Duration::from_millis(100), b.next())
        .await
        .is_err());
    let presence = json!({"type":"presence_update","data":{"user_id":9,"online_status":"hidden","last_seen_at":null,"server_id":"peer"},"timestamp":151});
    source.publish(42, presence.clone()).await;
    source.publish(9, presence.clone()).await;
    assert_eq!(receive(&mut a).await, presence);
    assert_eq!(receive(&mut b).await, presence);
    repo.0.store(true, Ordering::SeqCst);
    source.publish(42, event).await;
    let result = tokio::time::timeout(Duration::from_secs(3), a.next())
        .await
        .unwrap();
    assert!(result.is_none() || matches!(result, Some(Ok(Message::Close(_))) | Some(Err(_))));
    drop(a);
    drop(b);
    let _ = stop.send(());
    tokio::time::timeout(Duration::from_secs(3), task)
        .await
        .unwrap()
        .unwrap();
}

#[tokio::test]
async fn rejects_bad_origin_invalid_credentials_and_unavailable_subscription() {
    let repo = Arc::new(Repository::default());
    let source = Arc::new(Source::default());
    let (url, first, _, stop, task) =
        server(repo, source.clone(), Arc::new(AtomicU64::new(150))).await;
    assert_eq!(
        status(connect_async(&url).await.unwrap_err()),
        StatusCode::UNAUTHORIZED
    );
    let mut request = format!("{url}?token={first}")
        .into_client_request()
        .unwrap();
    request
        .headers_mut()
        .insert("origin", "https://evil.example".parse().unwrap());
    assert_eq!(
        status(connect_async(request).await.unwrap_err()),
        StatusCode::FORBIDDEN
    );
    let mut request = format!("{url}?token=invalid")
        .into_client_request()
        .unwrap();
    request
        .headers_mut()
        .insert("authorization", format!("Bearer {first}").parse().unwrap());
    assert_eq!(
        status(connect_async(request).await.unwrap_err()),
        StatusCode::UNAUTHORIZED
    );
    source.unavailable.store(true, Ordering::SeqCst);
    assert_eq!(
        status(
            connect_async(format!("{url}?token={first}"))
                .await
                .unwrap_err()
        ),
        StatusCode::SERVICE_UNAVAILABLE
    );
    let _ = stop.send(());
    task.await.unwrap();
}

#[tokio::test]
async fn same_origin_cookie_is_accepted_and_expired_session_stops_delivery() {
    let repo = Arc::new(Repository::default());
    let source = Arc::new(Source::default());
    let clock = Arc::new(AtomicU64::new(150));
    let (url, first, _, stop, task) = server(repo, source.clone(), clock.clone()).await;
    let mut request = url.clone().into_client_request().unwrap();
    let origin = url.replace("ws://", "http://").replace("/_ws", "");
    request
        .headers_mut()
        .insert("origin", origin.parse().unwrap());
    request
        .headers_mut()
        .insert("cookie", format!("access_token={first}").parse().unwrap());
    let (mut socket, _) = connect_async(request).await.unwrap();
    assert_eq!(receive(&mut socket).await["data"]["user_id"], 42);
    clock.store(301, Ordering::SeqCst);
    source
        .publish(
            42,
            json!({"type":"notification_created","data":{},"timestamp":301}),
        )
        .await;
    let result = tokio::time::timeout(Duration::from_secs(3), socket.next())
        .await
        .unwrap();
    assert!(result.is_none() || matches!(result, Some(Ok(Message::Close(_))) | Some(Err(_))));
    drop(socket);
    let _ = stop.send(());
    task.await.unwrap();
}
