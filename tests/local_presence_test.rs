use nekotribe_backend::{
    local_presence::LocalPresenceEvents,
    notification_events::{
        encode_presence_event, EventError, NotificationPublisher, PublishFuture,
    },
    notification_source::{NotificationSource, SubscriptionFuture},
};
use serde_json::{json, Map, Value};
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};
use tokio::sync::mpsc;

struct Unavailable;
impl NotificationSource for Unavailable {
    fn subscribe(&self, _: u64) -> SubscriptionFuture<'_> {
        Box::pin(async { Err(EventError) })
    }
}
struct Blocked;
impl NotificationSource for Blocked {
    fn subscribe(&self, _: u64) -> SubscriptionFuture<'_> {
        Box::pin(std::future::pending())
    }
}
async fn receive(events: &mut mpsc::Receiver<Vec<u8>>) -> Value {
    let raw = tokio::time::timeout(Duration::from_secs(3), events.recv())
        .await
        .expect("event timed out")
        .expect("subscription closed");
    serde_json::from_slice(&raw).unwrap()
}
async fn status(events: &mut mpsc::Receiver<Vec<u8>>, expected: &str) {
    for _ in 0..4 {
        let message = receive(events).await;
        assert_eq!(message["type"], "system_notification");
        assert_eq!(message["data"]["code"], "realtime_status");
        assert_eq!(message["data"]["local_presence"], true);
        if message["data"]["remote_events"] == expected {
            return;
        }
    }
    panic!("status not reached: {expected}");
}

#[tokio::test]
async fn private_direct_events_stay_with_participants_during_remote_outage() {
    let hub = LocalPresenceEvents::new(None, None).unwrap();
    let mut sender = hub.subscribe(42).await.unwrap();
    let mut recipient = hub.subscribe(9).await.unwrap();
    let mut outsider = hub.subscribe(7).await.unwrap();
    status(&mut sender, "unavailable").await;
    status(&mut recipient, "unavailable").await;
    status(&mut outsider, "unavailable").await;
    let message = json!({"message_id":12,"conversation_id":11,"content":"fixture"});
    assert!(hub.publish_direct(42, 9, &message).await.is_err());
    for queue in [&mut sender, &mut recipient] {
        let event = receive(queue).await;
        assert_eq!(event["type"], "direct_message");
        assert_eq!(event["data"]["direct_message"], message);
    }
    assert!(
        tokio::time::timeout(Duration::from_millis(30), outsider.recv())
            .await
            .is_err()
    );
}

#[tokio::test]
async fn local_delivery_survives_remote_unavailability() {
    let hub = LocalPresenceEvents::new(Some(Arc::new(Unavailable)), None).unwrap();
    let mut events = hub
        .subscribe(42)
        .await
        .expect("local subscription unavailable");
    status(&mut events, "unavailable").await;
    let data = json!({"user_id":9,"online_status":"hidden","last_seen_at":"must-not-leak"});
    let _ = hub.publish_presence(data.as_object().unwrap()).await;
    let message = receive(&mut events).await;
    assert_eq!(message["type"], "presence_update");
    assert!(message["data"]["last_seen_at"].is_null());
}

#[tokio::test]
async fn pending_remote_subscription_does_not_block_local_delivery_or_close() {
    let hub = LocalPresenceEvents::new(Some(Arc::new(Blocked)), None).unwrap();
    let mut events = tokio::time::timeout(Duration::from_millis(500), hub.subscribe(42))
        .await
        .expect("remote blocked local subscription")
        .unwrap();
    status(&mut events, "connecting").await;
    let data = json!({"user_id":42,"online_status":"online","last_seen_at":null});
    let _ = hub.publish_presence(data.as_object().unwrap()).await;
    assert_eq!(receive(&mut events).await["type"], "presence_update");
    hub.close();
    assert!(tokio::time::timeout(Duration::from_secs(1), events.recv())
        .await
        .unwrap()
        .is_none());
}

#[derive(Default)]
struct Remote {
    subscribers: Mutex<HashMap<u64, mpsc::Sender<Vec<u8>>>>,
}
impl NotificationSource for Remote {
    fn subscribe(&self, user: u64) -> SubscriptionFuture<'_> {
        Box::pin(async move {
            let (tx, rx) = mpsc::channel(16);
            self.subscribers.lock().unwrap().insert(user, tx);
            Ok(rx)
        })
    }
}
impl Remote {
    async fn send(&self, user: u64, body: Vec<u8>) {
        let sender = self.subscribers.lock().unwrap().get(&user).unwrap().clone();
        sender.send(body).await.unwrap();
    }
}
#[derive(Default)]
struct Publisher {
    fail: bool,
    calls: AtomicUsize,
    payload: Mutex<Vec<u8>>,
    notification_users: Mutex<Vec<u64>>,
}
impl NotificationPublisher for Publisher {
    fn presence_server_id(&self) -> Option<&str> {
        Some("rust-test")
    }
    fn publish_presence<'a>(&'a self, data: &'a Map<String, Value>) -> PublishFuture<'a> {
        Box::pin(async move {
            self.calls.fetch_add(1, Ordering::SeqCst);
            *self.payload.lock().unwrap() =
                encode_presence_event(data, "rust-test", 1234)?.into_bytes();
            if self.fail {
                Err(EventError)
            } else {
                Ok(())
            }
        })
    }
    fn publish<'a>(
        &'a self,
        user: u64,
        _: &'a str,
        _: &'a Map<String, Value>,
    ) -> PublishFuture<'a> {
        Box::pin(async move {
            self.notification_users.lock().unwrap().push(user);
            Ok(())
        })
    }
}

#[tokio::test]
async fn redis_failure_does_not_prevent_local_delivery_or_replay_publication() {
    let publisher = Arc::new(Publisher {
        fail: true,
        ..Publisher::default()
    });
    let hub = LocalPresenceEvents::new(None, Some(publisher.clone())).unwrap();
    let mut events = hub.subscribe(42).await.unwrap();
    status(&mut events, "unavailable").await;
    let data = json!({"user_id":42,"online_status":"hidden","last_seen_at":null});
    assert!(hub
        .publish_presence(data.as_object().unwrap())
        .await
        .is_err());
    assert_eq!(receive(&mut events).await["type"], "presence_update");
    assert_eq!(publisher.calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn own_presence_echo_is_filtered_but_peer_presence_and_own_notifications_survive() {
    let source = Arc::new(Remote::default());
    let publisher = Arc::new(Publisher::default());
    let hub = LocalPresenceEvents::new(Some(source.clone()), Some(publisher.clone())).unwrap();
    let mut events = hub.subscribe(42).await.unwrap();
    status(&mut events, "connected").await;
    let data = json!({"user_id":9,"online_status":"hidden","last_seen_at":"secret"});
    hub.publish_presence(data.as_object().unwrap())
        .await
        .unwrap();
    let local = receive(&mut events).await;
    assert_eq!(local["data"]["server_id"], "rust-test");
    assert!(local["data"]["last_seen_at"].is_null());
    let own = publisher.payload.lock().unwrap().clone();
    let mut peer: Value = serde_json::from_slice(&own).unwrap();
    peer["data"]["server_id"] = "peer-instance".into();
    source.send(42, own).await;
    source.send(42, peer.to_string().into_bytes()).await;
    assert_eq!(receive(&mut events).await, peer);
    let raw = br#"{"type":"notification_created","data":{"server_id":"rust-test","notification":{"metadata":{"text":"prefix\ud83d..."}}},"timestamp":1}"#.to_vec();
    source.send(42, raw.clone()).await;
    assert_eq!(
        tokio::time::timeout(Duration::from_secs(2), events.recv())
            .await
            .unwrap()
            .unwrap(),
        raw
    );
}

#[tokio::test]
async fn private_remote_notifications_and_control_frames_do_not_cross_users() {
    let source = Arc::new(Remote::default());
    let publisher = Arc::new(Publisher::default());
    let hub = LocalPresenceEvents::new(Some(source.clone()), Some(publisher.clone())).unwrap();
    let mut a = hub.subscribe(42).await.unwrap();
    let mut b = hub.subscribe(9).await.unwrap();
    status(&mut a, "connected").await;
    status(&mut b, "connected").await;
    let forged = json!({"type":"system_notification","data":{"code":"realtime_status","user_id":42,"server_id":"peer","local_presence":true,"remote_events":"unavailable"},"timestamp":1});
    source.send(42, forged.to_string().into_bytes()).await;
    let notification =
        json!({"type":"notification_created","data":{"secret":"only-42"},"timestamp":1});
    source.send(42, notification.to_string().into_bytes()).await;
    assert_eq!(receive(&mut a).await, notification);
    hub.publish(42, "notification_created", json!({}).as_object().unwrap())
        .await
        .unwrap();
    assert_eq!(*publisher.notification_users.lock().unwrap(), [42]);
    let data = json!({"user_id":9,"online_status":"online","last_seen_at":null});
    hub.publish_presence(data.as_object().unwrap())
        .await
        .unwrap();
    assert_eq!(receive(&mut a).await["type"], "presence_update");
    assert_eq!(receive(&mut b).await["type"], "presence_update");
}

#[tokio::test]
async fn remote_disconnect_reports_degradation_and_recovers_while_local_flow_continues() {
    let source = Arc::new(Remote::default());
    let hub = LocalPresenceEvents::new(Some(source.clone()), None).unwrap();
    let mut events = hub.subscribe(42).await.unwrap();
    status(&mut events, "connected").await;
    source.subscribers.lock().unwrap().remove(&42);
    status(&mut events, "unavailable").await;
    let data = json!({"user_id":9,"online_status":"hidden","last_seen_at":null});
    let _ = hub.publish_presence(data.as_object().unwrap()).await;
    assert_eq!(receive(&mut events).await["type"], "presence_update");
    status(&mut events, "connected").await;
}

#[tokio::test]
async fn queue_overflow_closes_subscription_and_close_rejects_new_work() {
    let hub = LocalPresenceEvents::new(None, None).unwrap();
    let mut events = hub.subscribe(42).await.unwrap();
    let data = json!({"user_id":42,"online_status":"online","last_seen_at":null});
    for _ in 0..128 {
        let _ = hub.publish_presence(data.as_object().unwrap()).await;
    }
    tokio::time::timeout(Duration::from_secs(2), async {
        while events.recv().await.is_some() {}
    })
    .await
    .expect("slow subscription remained open");
    hub.close();
    hub.close();
    assert!(hub.subscribe(42).await.is_err());
    assert!(hub
        .publish_presence(data.as_object().unwrap())
        .await
        .is_err());
}

#[tokio::test]
async fn subscriber_limit_and_dropped_receivers_release_capacity() {
    let hub = LocalPresenceEvents::new(None, None).unwrap();
    assert!(hub.subscribe(0).await.is_err());
    assert!(hub.subscribe(9_007_199_254_740_992).await.is_err());
    let mut receivers = Vec::new();
    for _ in 0..1024 {
        receivers.push(hub.subscribe(42).await.unwrap());
    }
    assert!(hub.subscribe(42).await.is_err());
    drop(receivers);
    let mut receiver = tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            if let Ok(receiver) = hub.subscribe(42).await {
                break receiver;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("subscriber capacity leaked");
    status(&mut receiver, "unavailable").await;
    drop(hub);
    assert!(
        tokio::time::timeout(Duration::from_secs(2), receiver.recv())
            .await
            .unwrap()
            .is_none()
    );
}
