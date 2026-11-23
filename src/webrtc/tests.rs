use super::*;
use crate::{
    auth::{
        TokenCodec,
        otp::SmtpConfig,
        sessions::{CorsPolicy, RefreshPolicy, SessionRepository, StoreFuture as SessionFuture},
        storage_urls::StorageUrlPolicy,
    },
    notification_events::{NotificationPublisher, PublishFuture},
};
use serde_json::Map;
use std::sync::{
    Mutex,
    atomic::{AtomicBool, Ordering},
};

const CALL: &str = "20000000-0000-0000-0000-000000000001";
const CALLER: &str = "30000000-0000-0000-0000-000000000042";
const CALLEE: &str = "30000000-0000-0000-0000-000000000009";

struct Repository(AtomicBool);
impl SessionRepository for Repository {
    fn direct_typing_peer(&self, user: u64, conversation: u64) -> SessionFuture<'_, Option<u64>> {
        Box::pin(async move {
            Ok(match (user, conversation, self.0.load(Ordering::SeqCst)) {
                (42, 7, true) => Some(9),
                (9, 7, true) => Some(42),
                _ => None,
            })
        })
    }
    fn touch<'a>(&'a self, _: &'a crate::auth::TokenClaims) -> SessionFuture<'a, u64> {
        Box::pin(async { Ok(1) })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> SessionFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> SessionFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
}

#[derive(Default)]
struct CallStore {
    next: Mutex<Option<(Action, Result<Outcome, StoreError>)>>,
    record: Mutex<Option<Record>>,
    invoked: Mutex<Vec<Transition>>,
}

impl CallStore {
    fn reply(&self, action: Action, outcome: Result<Outcome, StoreError>) {
        self.next.lock().unwrap().replace((action, outcome));
    }
}

impl Store for CallStore {
    fn transition(&self, request: Transition) -> StoreFuture<'_, Outcome> {
        Box::pin(async move {
            let (action, outcome) = self
                .next
                .lock()
                .unwrap()
                .take()
                .expect("expected call transition");
            assert_eq!(
                (
                    request.action,
                    request.call_id.as_str(),
                    request.conversation
                ),
                (action, CALL, 7)
            );
            self.invoked.lock().unwrap().push(request);
            outcome
        })
    }
    fn current<'a>(&'a self, call_id: &'a str) -> StoreFuture<'a, Option<Record>> {
        Box::pin(async move {
            assert_eq!(call_id, CALL);
            Ok(self.record.lock().unwrap().clone())
        })
    }
}

#[derive(Default)]
struct Publisher(Mutex<Vec<(u64, Vec<u8>)>>);
impl NotificationPublisher for Publisher {
    fn publish<'a>(&'a self, _: u64, _: &'a str, _: &'a Map<String, Value>) -> PublishFuture<'a> {
        Box::pin(async { Ok(()) })
    }
    fn publish_call_wire<'a>(&'a self, user: u64, bytes: &'a [u8]) -> PublishFuture<'a> {
        Box::pin(async move {
            assert!(valid_on_user_channel(&format!("ws:user:{user}"), bytes));
            self.0.lock().unwrap().push((user, bytes.to_vec()));
            Ok(())
        })
    }
}

fn state(repo: Arc<Repository>, store: Arc<CallStore>, publisher: Arc<Publisher>) -> NativeState {
    NativeState {
        codec: Arc::new(TokenCodec::new(b"test-access-key", b"test-refresh-key").unwrap()),
        repository: repo,
        clock: Arc::new(|| 50),
        refresh_policy: RefreshPolicy::default(),
        storage_urls: StorageUrlPolicy::default(),
        otp_mailer: Arc::new(SmtpConfig::default()),
        cors: CorsPolicy::default(),
        notification_source: None,
        notification_publisher: Some(publisher),
        calls: Runtime {
            ice: Arc::new(ice::Config::from_lookup(|_| None)),
            store: Some(store),
        },
    }
}

fn input(kind: &str, client: &str, extra: Option<(&str, Value)>) -> Value {
    let mut data = json!({"call_id":CALL,"conversation_id":7,"client_id":client});
    if let Some((name, value)) = extra {
        data[name] = value;
    }
    json!({"type":kind,"data":data})
}

fn ringing(caller: &Socket) -> Record {
    Record {
        metadata: Metadata {
            call_id: CALL.into(),
            conversation_id: 7,
            caller_id: 42,
            callee_id: 9,
            mode: Mode::Voice,
            caller_client_id: CALLER.into(),
            callee_client_id: None,
        },
        stage: Stage::Ringing,
        deadline: timestamp_ms() + 30000,
        caller_connection: caller.id().into(),
        callee_connection: None,
    }
}

#[tokio::test]
async fn only_selected_connections_receive_media_and_disconnect_releases_call() {
    let repo = Arc::new(Repository(AtomicBool::new(true)));
    let store = Arc::new(CallStore::default());
    let publisher = Arc::new(Publisher::default());
    let context = state(repo.clone(), store.clone(), publisher.clone());
    let (mut caller, mut callee, mut alternate) = (Socket::new(), Socket::new(), Socket::new());
    let mut record = ringing(&caller);

    store.reply(Action::Invite, Ok(Outcome::Ok(record.clone())));
    let invite = input("call_invite", CALLER, Some(("mode", json!("voice"))));
    assert!(caller.incoming(&context, 42, &invite).await.is_none());
    assert!(caller.deadline().is_some());
    assert_eq!(publisher.0.lock().unwrap().len(), 2);

    record.stage = Stage::AwaitOffer;
    record.callee_connection = Some(callee.id().into());
    record.metadata.callee_client_id = Some(CALLEE.into());
    store.reply(Action::Accept, Ok(Outcome::Ok(record.clone())));
    assert!(
        callee
            .incoming(&context, 9, &input("call_accept", CALLEE, None))
            .await
            .is_none()
    );
    assert_eq!(publisher.0.lock().unwrap().len(), 4);

    record.stage = Stage::AwaitAnswer;
    *store.record.lock().unwrap() = Some(record.clone());
    store.reply(Action::Offer, Ok(Outcome::Ok(record.clone())));
    let offer = input(
        "call_sdp_offer",
        CALLER,
        Some(("sdp", json!("v=0 fixture"))),
    );
    assert!(caller.incoming(&context, 42, &offer).await.is_none());
    let (user, payload) = publisher.0.lock().unwrap().last().unwrap().clone();
    assert_eq!(user, 9);
    assert_eq!(publisher.0.lock().unwrap().len(), 5);
    assert!(callee.can_receive(&context, 9, &payload).await);
    assert!(!alternate.can_receive(&context, 9, &payload).await);
    assert!(!caller.can_receive(&context, 42, &payload).await);
    assert!(!valid_on_user_channel("ws:user:98", &payload));
    assert!(crate::notification_websocket::event_matches_channel(
        "ws:user:9",
        "ws:user:9",
        &payload
    ));
    assert!(!crate::notification_websocket::event_matches_channel(
        "ws:presence",
        "ws:user:9",
        &payload
    ));
    assert!(
        !String::from_utf8(payload.clone())
            .unwrap()
            .contains("connection")
    );

    repo.0.store(false, Ordering::SeqCst);
    assert!(!callee.can_receive(&context, 9, &payload).await);
    assert_eq!(
        caller.incoming(&context, 42, &offer).await.unwrap()["type"],
        "error"
    );
    assert_eq!(store.invoked.lock().unwrap().len(), 3);
    store.reply(Action::Disconnect, Ok(Outcome::Ok(record)));
    caller.disconnect(&context, 42).await;
    assert_eq!(publisher.0.lock().unwrap().len(), 7);
    let closed: Value =
        serde_json::from_slice(&publisher.0.lock().unwrap().last().unwrap().1).unwrap();
    assert_eq!(closed["type"], "call_hangup");
    assert!(caller.bound.is_none());
}

#[tokio::test]
async fn busy_and_unavailable_are_connection_local_and_ring_timeout_is_shared() {
    let repo = Arc::new(Repository(AtomicBool::new(true)));
    let store = Arc::new(CallStore::default());
    let publisher = Arc::new(Publisher::default());
    let context = state(repo, store.clone(), publisher.clone());
    let mut caller = Socket::new();
    let invite = input("call_invite", CALLER, Some(("mode", json!("voice"))));
    store.reply(Action::Invite, Ok(Outcome::Busy));
    assert_eq!(
        caller.incoming(&context, 42, &invite).await.unwrap()["type"],
        "call_busy"
    );
    store.reply(Action::Invite, Err(StoreError));
    assert_eq!(
        caller.incoming(&context, 42, &invite).await.unwrap()["type"],
        "call_unavailable"
    );
    assert!(publisher.0.lock().unwrap().is_empty());
    let record = ringing(&caller);
    store.reply(Action::Invite, Ok(Outcome::Ok(record.clone())));
    assert!(caller.incoming(&context, 42, &invite).await.is_none());
    store.reply(Action::Expire, Ok(Outcome::Timeout(record)));
    caller.expire(&context, 42).await;
    assert!(caller.bound.is_none());
    let events = publisher.0.lock().unwrap();
    assert_eq!(events.len(), 4);
    for (_, payload) in &events[2..] {
        assert_eq!(Event::parse(payload).unwrap().kind, "call_timeout");
    }
}

#[test]
fn signaling_rejects_spoofed_scopes_and_oversized_payloads() {
    let mut request = input("call_invite", CALLER, Some(("mode", json!("video"))));
    assert!(command(&request).is_some());
    request["data"]["caller_id"] = 42.into();
    assert!(command(&request).is_none());
    assert!(command(&input("call_accept", "BAD-UUID", None)).is_none());
    let oversized = json!("a".repeat(contract().max_sdp_bytes + 1));
    assert!(command(&input("call_sdp_offer", CALLER, Some(("sdp", oversized)))).is_none());
    let bad_candidate = json!([{"candidate":"candidate:fixture","sdp_mline_index":65536}]);
    assert!(
        command(&input(
            "call_ice",
            CALLEE,
            Some(("candidates", bad_candidate))
        ))
        .is_none()
    );
}

#[tokio::test]
async fn ice_endpoint_requires_a_session_and_is_private() {
    use crate::auth::{IssuedToken, TokenKind};
    use axum::{
        extract::State,
        http::{HeaderMap, StatusCode},
    };
    use http_body_util::BodyExt;
    let context = state(
        Arc::new(Repository(AtomicBool::new(true))),
        Arc::new(CallStore::default()),
        Arc::new(Publisher::default()),
    );
    let denied = ice::get(State(context.clone()), HeaderMap::new()).await;
    assert_eq!(denied.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(denied.headers()["cache-control"], "private, no-store");
    let token = context
        .codec
        .sign(&IssuedToken {
            user_id: 42,
            user_name: "fixture".into(),
            session_id: "fixture-session".into(),
            kind: TokenKind::Access,
            issued_at: 10,
            expires_at: 100,
            jti: "fixture-token".into(),
        })
        .unwrap();
    let mut headers = HeaderMap::new();
    headers.insert("authorization", format!("Bearer {token}").parse().unwrap());
    let response = ice::get(State(context), headers).await;
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.headers()["cache-control"], "private, no-store");
    let body: Value =
        serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(body["data"], json!({"ice_servers":[],"expires_at":null}));
}
