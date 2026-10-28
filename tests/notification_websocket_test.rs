use futures_util::{SinkExt, StreamExt};
use nekotribe_backend::{
    auth::{
        otp::SmtpConfig,
        sessions::{
            build_native_router_with_realtime, CorsPolicy, RefreshPolicy, SessionRepository,
            StoreFuture,
        },
        storage_urls::StorageUrlPolicy,
        IssuedToken, TokenClaims, TokenCodec, TokenKind,
    },
    notification_events::EventError,
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
struct Repository(AtomicBool);
impl SessionRepository for Repository {
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
    unavailable: AtomicBool,
}
impl NotificationSource for Source {
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
    repo: Arc<Repository>,
    source: Arc<Source>,
    clock: Arc<AtomicU64>,
) -> (
    String,
    String,
    String,
    oneshot::Sender<()>,
    tokio::task::JoinHandle<()>,
) {
    let codec = TokenCodec::new(b"test-access-key", b"test-refresh-key").unwrap();
    let first = token(&codec, 42);
    let second = token(&codec, 9);
    let router = build_native_router_with_realtime(
        codec,
        repo,
        CorsPolicy::default(),
        Arc::new(move || clock.load(Ordering::SeqCst)),
        RefreshPolicy::default(),
        StorageUrlPolicy::default(),
        Arc::new(SmtpConfig::default()),
        Some(source),
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
    assert!(tokio::time::timeout(Duration::from_millis(100), b.next())
        .await
        .is_err());
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
