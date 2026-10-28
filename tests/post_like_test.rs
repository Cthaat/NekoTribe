use axum::{body::Body, http::Request};
use http_body_util::BodyExt;
use nekotribe_backend::{
    auth::session_repository::{OracleSessions, SessionExecutor},
    db::{oracle::BindMap, row::DbRow, value::DbValue},
};
use nekotribe_backend::{
    auth::{
        otp::SmtpConfig,
        sessions::{
            build_native_router_with_realtime_and_publisher, CorsPolicy, RefreshPolicy,
            SessionRepository, SessionStoreError, StoreFuture,
        },
        storage_urls::StorageUrlPolicy,
        TokenClaims, TokenCodec,
    },
    notification_events::{EventError, NotificationPublisher, PublishFuture},
    posts::like::{PostLikeOutcome, StoredLikeNotification},
};
use serde_json::{json, Map, Value};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

struct Store {
    inserted: bool,
    visible: bool,
    notify: bool,
    push: bool,
    fail: bool,
    fail_stage: Option<&'static str>,
    calls: Mutex<Vec<&'static str>>,
}
impl SessionRepository for Store {
    fn touch<'a>(&'a self, claims: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async move { Ok(u64::from(claims.user_id == 42)) })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn add_post_like<'a>(
        &'a self,
        viewer: u64,
        id: u64,
    ) -> StoreFuture<'a, Option<PostLikeOutcome>> {
        Box::pin(async move {
            self.calls.lock().unwrap().push("like");
            if self.fail {
                return Err(SessionStoreError);
            };
            assert_eq!((viewer, id), (42, 1));
            Ok(self.visible.then_some(PostLikeOutcome {
                count: 3.0,
                inserted: self.inserted,
            }))
        })
    }
    fn prepare_post_like_notification<'a>(
        &'a self,
        viewer: u64,
        id: u64,
    ) -> StoreFuture<'a, Option<StoredLikeNotification>> {
        Box::pin(async move {
            self.calls.lock().unwrap().push("prepare");
            if self.fail_stage == Some("prepare") {
                return Err(SessionStoreError);
            }
            assert_eq!((viewer, id), (42, 1));
            Ok(self.notify.then_some(StoredLikeNotification {
                recipient: 9,
                id: 12,
                push_enabled: self.push,
            }))
        })
    }
    fn read_notification<'a>(&'a self, user: u64, id: u64) -> StoreFuture<'a, Option<Value>> {
        Box::pin(async move {
            self.calls.lock().unwrap().push("read");
            if self.fail_stage == Some("read") {
                return Err(SessionStoreError);
            }
            assert_eq!((user, id), (9, 12));
            Ok(Some(
                json!({"notification_id":12,"actor_id":42,"type":"like","metadata":{"event":"post_like"}}),
            ))
        })
    }
    fn public_profile<'a>(&'a self, viewer: u64, target: u64) -> StoreFuture<'a, Option<Value>> {
        Box::pin(async move {
            if self.fail_stage == Some("profile") {
                return Err(SessionStoreError);
            }
            assert_eq!((viewer, target), (9, 42));
            Ok(Some(json!({"user_id":42,"avatar_url":""})))
        })
    }
}
#[derive(Default)]
struct Publisher {
    events: Mutex<Vec<(u64, String, Map<String, Value>)>>,
    fail: bool,
}
impl NotificationPublisher for Publisher {
    fn publish<'a>(
        &'a self,
        user: u64,
        kind: &'a str,
        data: &'a Map<String, Value>,
    ) -> PublishFuture<'a> {
        Box::pin(async move {
            self.events
                .lock()
                .unwrap()
                .push((user, kind.to_owned(), data.clone()));
            if self.fail {
                Err(EventError)
            } else {
                Ok(())
            }
        })
    }
}
fn credentials() -> (TokenCodec, String) {
    let tokens: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = tokens["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap()
        .to_owned();
    (
        TokenCodec::new(
            tokens["keys"]["access"].as_str().unwrap().as_bytes(),
            tokens["keys"]["refresh"].as_str().unwrap().as_bytes(),
        )
        .unwrap(),
        token,
    )
}
#[tokio::test]
async fn like_auth_visibility_idempotence_and_complete_notification() {
    for (inserted, visible, notify, push, fail, publisher_fail, status, prepares, publishes) in [
        (true, true, true, true, false, false, 200, 1, 1),
        (false, true, true, true, false, false, 200, 0, 0),
        (true, true, true, false, false, false, 200, 1, 0),
        (true, true, false, false, false, false, 200, 1, 0),
        (false, false, false, false, false, false, 404, 0, 0),
        (true, true, true, true, false, true, 200, 1, 1),
        (false, false, false, false, true, false, 500, 0, 0),
    ] {
        let (codec, token) = credentials();
        let store = Arc::new(Store {
            inserted,
            visible,
            notify,
            push,
            fail,
            fail_stage: None,
            calls: Mutex::new(vec![]),
        });
        let publisher = Arc::new(Publisher {
            events: Mutex::new(vec![]),
            fail: publisher_fail,
        });
        let app = build_native_router_with_realtime_and_publisher(
            codec,
            store.clone(),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
            RefreshPolicy::default(),
            StorageUrlPolicy::default(),
            Arc::new(SmtpConfig::default()),
            None,
            Some(publisher.clone()),
        );
        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/v2/posts/1/likes?user_id=99")
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), status);
        if status == 200 {
            let body: Value =
                serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes())
                    .unwrap();
            assert_eq!(
                body["data"],
                json!({"post_id":1,"is_liked":true,"likes_count":3.0})
            );
        }
        let calls = store.calls.lock().unwrap();
        assert_eq!(calls.iter().filter(|v| **v == "prepare").count(), prepares);
        let events = publisher.events.lock().unwrap();
        assert_eq!(events.len(), publishes);
        if let Some((user, kind, data)) = events.first() {
            assert_eq!((*user, kind.as_str()), (9, "notification_created"));
            assert_eq!(data["notification_type"], "like");
            assert_eq!(data["notification"]["actor"]["user_id"], 42);
            assert!(data["notification"].get("actor_id").is_none());
        }
    }
}

#[tokio::test]
async fn failures_after_like_commit_return_error_without_publishing() {
    for stage in ["prepare", "read", "profile"] {
        let (codec, token) = credentials();
        let store = Arc::new(Store {
            inserted: true,
            visible: true,
            notify: true,
            push: true,
            fail: false,
            fail_stage: Some(stage),
            calls: Mutex::new(vec![]),
        });
        let publisher = Arc::new(Publisher::default());
        let app = build_native_router_with_realtime_and_publisher(
            codec,
            store.clone(),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
            RefreshPolicy::default(),
            StorageUrlPolicy::default(),
            Arc::new(SmtpConfig::default()),
            None,
            Some(publisher.clone()),
        );
        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/v2/posts/1/likes")
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), 500, "{stage}");
        assert!(publisher.events.lock().unwrap().is_empty());
        assert_eq!(store.calls.lock().unwrap().first(), Some(&"like"));
    }
}

struct RealRepositoryFixture {
    inserted: u64,
    fail_notification: bool,
    writes: Mutex<Vec<&'static str>>,
}
impl SessionExecutor for RealRepositoryFixture {
    fn preflight(&self, _: &'static str) -> StoreFuture<'_, ()> {
        Box::pin(async { Ok(()) })
    }
    fn execute(&self, sql: &'static str, _: BindMap) -> StoreFuture<'_, u64> {
        Box::pin(async move {
            self.writes.lock().unwrap().push(sql);
            if sql.starts_with("INSERT INTO n_notifications") && self.fail_notification {
                return Err(SessionStoreError);
            }
            Ok(if sql.starts_with("INSERT INTO n_post_likes") {
                self.inserted
            } else {
                1
            })
        })
    }
    fn query(&self, sql: &'static str, _: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
        Box::pin(async move {
            let row = if sql.starts_with("SELECT p.post_id") {
                DbRow::from([("POST_ID".into(), DbValue::I64(1))])
            } else if sql.contains("n_post_stats") {
                DbRow::from([("LIKES_COUNT".into(), DbValue::I64(3))])
            } else if sql.starts_with("SELECT author_id") {
                DbRow::from([("AUTHOR_ID".into(), DbValue::I64(9))])
            } else if sql.starts_with("SELECT COALESCE") {
                DbRow::from([("NAME".into(), DbValue::String("小猫".into()))])
            } else if sql.starts_with("SELECT DBMS_LOB.SUBSTR(content") {
                DbRow::from([("CONTENT".into(), DbValue::String(" hello world ".into()))])
            } else if sql.contains("notification_preferences") {
                DbRow::from([
                    ("TYPE_ENABLED".into(), DbValue::I64(1)),
                    ("PUSH_NOTIFICATION_ENABLED".into(), DbValue::I64(1)),
                ])
            } else if sql.contains("seq_notification_id") {
                DbRow::from([("ID".into(), DbValue::I64(44))])
            } else if sql.contains(
                "FROM n_notifications WHERE user_id=:user_id AND notification_id=:notification_id",
            ) {
                DbRow::from([
                    ("NOTIFICATION_ID".into(), DbValue::I64(44)),
                    ("ACTOR_ID".into(), DbValue::I64(42)),
                    ("TYPE".into(), DbValue::String("like".into())),
                    (
                        "METADATA_JSON".into(),
                        DbValue::String(
                            r#"{"event":"post_like","post_excerpt":"hello world"}"#.into(),
                        ),
                    ),
                ])
            } else if sql.contains("FROM v_user_profile_public") {
                DbRow::from([
                    ("USER_ID".into(), DbValue::I64(42)),
                    ("USERNAME".into(), DbValue::String("actor".into())),
                ])
            } else {
                return Err(SessionStoreError);
            };
            Ok(vec![row])
        })
    }
}

#[tokio::test]
async fn like_route_through_oracle_repository_and_publisher() {
    for (inserted, fail_notification, status, published) in
        [(1, false, 200, 1), (0, false, 200, 0), (1, true, 500, 0)]
    {
        let (codec, token) = credentials();
        let repo = Arc::new(OracleSessions {
            executor: RealRepositoryFixture {
                inserted,
                fail_notification,
                writes: Mutex::new(vec![]),
            },
        });
        let publisher = Arc::new(Publisher::default());
        let app = build_native_router_with_realtime_and_publisher(
            codec,
            repo.clone(),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
            RefreshPolicy::default(),
            StorageUrlPolicy::default(),
            Arc::new(SmtpConfig::default()),
            None,
            Some(publisher.clone()),
        );
        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/v2/posts/1/likes")
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), status);
        let events = publisher.events.lock().unwrap();
        assert_eq!(events.len(), published);
        if let Some((user, _, data)) = events.first() {
            assert_eq!(*user, 9);
            assert_eq!(data["notification"]["notification_id"], 44);
            assert_eq!(data["notification"]["actor"]["user_id"], 42);
        }
        let writes = repo.executor.writes.lock().unwrap();
        assert!(writes
            .iter()
            .any(|v| v.starts_with("INSERT INTO n_post_likes")));
    }
}

#[tokio::test]
async fn like_requires_authentication_and_valid_post_id() {
    let (codec, token) = credentials();
    let store = Arc::new(Store {
        inserted: true,
        visible: true,
        notify: true,
        push: true,
        fail: false,
        fail_stage: None,
        calls: Mutex::new(vec![]),
    });
    let app = build_native_router_with_realtime_and_publisher(
        codec,
        store.clone(),
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_000),
        RefreshPolicy::default(),
        StorageUrlPolicy::default(),
        Arc::new(SmtpConfig::default()),
        None,
        None,
    );
    for (path, auth, status) in [
        ("/api/v2/posts/1/likes", false, 401),
        ("/api/v2/posts/01/likes", true, 400),
    ] {
        let mut request = Request::builder().method("POST").uri(path);
        if auth {
            request = request.header("authorization", format!("Bearer {token}"));
        }
        let response = app
            .clone()
            .oneshot(request.body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), status);
    }
    assert!(store.calls.lock().unwrap().is_empty());
}
