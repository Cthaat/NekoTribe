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
    notifications::NotificationReadResult,
};
use serde_json::{json, Map, Value};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

struct Store {
    found: bool,
    fail: bool,
    calls: Mutex<Vec<(u64, u64, bool)>>,
}
impl SessionRepository for Store {
    fn batch_set_notification_read<'a>(&'a self, user: u64, ids: &'a [u64], read: bool) -> StoreFuture<'a, u64> {
        Box::pin(async move {
            if ids.is_empty() { self.calls.lock().unwrap().push((user, 0, read)); }
            else { for id in ids { self.calls.lock().unwrap().push((user, *id, read)); } }
            if self.fail { Err(SessionStoreError) } else { Ok(if ids.is_empty() { 4 } else { ids.len() as u64 }) }
        })
    }
    fn touch<'a>(&'a self, c: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async move { Ok(u64::from(c.user_id == 42)) })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn set_notification_read<'a>(
        &'a self,
        user: u64,
        id: u64,
        read: bool,
    ) -> StoreFuture<'a, Option<NotificationReadResult>> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((user, id, read));
            if self.fail {
                return Err(SessionStoreError);
            };
            Ok(self.found.then_some(NotificationReadResult {
                notification_id: id,
                is_read: u8::from(read),
                read_at: read.then_some("2026-01-02T03:04:05.000Z".into()),
            }))
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
                .push((user, kind.into(), data.clone()));
            if self.fail {
                Err(EventError)
            } else {
                Ok(())
            }
        })
    }
}
fn credentials() -> (TokenCodec, String) {
    let t: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = t["cases"]
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
            t["keys"]["access"].as_str().unwrap().as_bytes(),
            t["keys"]["refresh"].as_str().unwrap().as_bytes(),
        )
        .unwrap(),
        token,
    )
}

#[tokio::test]
async fn batch_read_rejects_invalid_selection_and_scopes_updates() {
    for (body, status, expected) in [
        (r#"{"is_read":true}"#, 200, vec![(42, 0, true)]),
        (r#"{"notification_ids":[7,7,8],"is_read":true}"#, 200, vec![(42, 7, true), (42, 7, true), (42, 8, true)]),
        (r#"{"notification_ids":"bad"}"#, 400, vec![]),
        (r#"{"notification_ids":null}"#, 400, vec![]),
        (r#"{"notification_ids":[1,null]}"#, 400, vec![]),
        (r#"{"notification_ids":[1.5]}"#, 400, vec![]),
        (r#"{"notification_ids":[9007199254740992]}"#, 400, vec![]),
    ] {
        let (codec, token) = credentials();
        let store = Arc::new(Store { found: true, fail: false, calls: Mutex::new(vec![]) });
        let publisher = Arc::new(Publisher::default());
        let app = build_native_router_with_realtime_and_publisher(
            codec, store.clone(), CorsPolicy::default(), Arc::new(|| 1_700_000_000),
            RefreshPolicy::default(), StorageUrlPolicy::default(), Arc::new(SmtpConfig::default()),
            None, Some(publisher.clone()),
        );
        let request = Request::builder().method("PUT").uri("/api/v2/notifications/read-status")
            .header("content-type", "application/json").header("authorization", format!("Bearer {token}"))
            .body(Body::from(body)).unwrap();
        let response = app.oneshot(request).await.unwrap();
        assert_eq!(response.status().as_u16(), status, "{body}");
        assert_eq!(*store.calls.lock().unwrap(), expected, "{body}");
        let events = publisher.events.lock().unwrap();
        assert_eq!(events.len(), usize::from(status == 200));
        if let Some((user, kind, _)) = events.first() {
            assert_eq!((*user, kind.as_str()), (42, "notifications_read_status_updated"));
        }
    }
}

#[tokio::test]
async fn read_status_is_user_scoped_and_emits_event() {
    for (
        path,
        body,
        content_type,
        authenticated,
        found,
        fail,
        publish_fail,
        status,
        expected,
        events,
    ) in [
        (
            "/api/v2/notifications/12/read-status",
            r#"{"is_read":true}"#,
            "application/json",
            false,
            true,
            false,
            false,
            401,
            false,
            0,
        ),
        (
            "/api/v2/notifications/01/read-status",
            r#"{"is_read":true}"#,
            "application/json",
            true,
            true,
            false,
            false,
            400,
            false,
            0,
        ),
        (
            "/api/v2/notifications/12/read-status",
            "[]",
            "application/json",
            true,
            true,
            false,
            false,
            400,
            false,
            0,
        ),
        (
            "/api/v2/notifications/12/read-status",
            r#"{"is_read":true}"#,
            "application/json",
            true,
            false,
            false,
            false,
            404,
            true,
            0,
        ),
        (
            "/api/v2/notifications/12/read-status",
            r#"{"is_read":true}"#,
            "application/json",
            true,
            true,
            true,
            false,
            500,
            true,
            0,
        ),
        (
            "/api/v2/notifications/12/read-status?user_id=99",
            r#"{"is_read":true}"#,
            "application/json",
            true,
            true,
            false,
            false,
            200,
            true,
            1,
        ),
        (
            "/api/v2/notifications/12/read-status",
            r#"{"is_read":false}"#,
            "application/json",
            true,
            true,
            false,
            false,
            200,
            false,
            1,
        ),
        (
            "/api/v2/notifications/12/read-status",
            "is_read=YES",
            "application/x-www-form-urlencoded",
            true,
            true,
            false,
            false,
            200,
            true,
            1,
        ),
        (
            "/api/v2/notifications/12/read-status",
            "{}",
            "application/json",
            true,
            true,
            false,
            false,
            200,
            false,
            1,
        ),
        (
            "/api/v2/notifications/12/read-status",
            r#"{"is_read":1}"#,
            "application/json",
            true,
            true,
            false,
            true,
            200,
            true,
            1,
        ),
    ] {
        let (codec, token) = credentials();
        let store = Arc::new(Store {
            found,
            fail,
            calls: Mutex::new(vec![]),
        });
        let publisher = Arc::new(Publisher {
            events: Mutex::new(vec![]),
            fail: publish_fail,
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
        let mut req = Request::builder()
            .method("PUT")
            .uri(path)
            .header("content-type", content_type);
        if authenticated {
            req = req.header("authorization", format!("Bearer {token}"));
        }
        let response = app
            .oneshot(req.body(Body::from(body)).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), status, "{path} {body}");
        if status == 200 {
            let data: Value =
                serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes())
                    .unwrap();
            assert_eq!(data["data"]["notification_id"], 12);
            assert_eq!(data["data"]["is_read"], u8::from(expected));
            assert_eq!(
                store.calls.lock().unwrap().as_slice(),
                &[(42, 12, expected)]
            );
        }
        let sent = publisher.events.lock().unwrap();
        assert_eq!(sent.len(), events);
        if let Some((user, kind, data)) = sent.first() {
            assert_eq!(
                (*user, kind.as_str()),
                (42, "notification_read_status_updated")
            );
            assert_eq!(data["notification_id"], json!(12));
        }
    }
}

struct RepoExecutor {
    affected: u64,
    missing: bool,
    fail_read: bool,
    calls: Mutex<Vec<(&'static str, BindMap)>>,
}
impl SessionExecutor for RepoExecutor {
    fn preflight(&self, _: &'static str) -> StoreFuture<'_, ()> {
        Box::pin(async { Ok(()) })
    }
    fn execute(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, u64> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((sql, binds));
            Ok(self.affected)
        })
    }
    fn query(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((sql, binds));
            if self.fail_read {
                return Err(SessionStoreError);
            };
            if self.missing {
                return Ok(vec![]);
            };
            Ok(vec![DbRow::from([
                ("NOTIFICATION_ID".into(), DbValue::I64(12)),
                ("IS_READ".into(), DbValue::I64(1)),
                (
                    "READ_AT".into(),
                    DbValue::String("2026-01-02T03:04:05Z".into()),
                ),
            ])])
        })
    }
}
#[tokio::test]
async fn read_repository_scopes_write_and_read_and_preserves_commit_boundary() {
    for (affected, missing, fail, found) in [
        (1, false, false, true),
        (0, false, false, false),
        (1, true, false, false),
        (1, false, true, false),
    ] {
        let repo = OracleSessions {
            executor: RepoExecutor {
                affected,
                missing,
                fail_read: fail,
                calls: Mutex::new(vec![]),
            },
        };
        let result = repo.set_notification_read(42, 12, true).await;
        assert_eq!(result.is_err(), fail);
        if let Ok(item) = result {
            assert_eq!(item.is_some(), found);
            if let Some(item) = item {
                assert_eq!(item.read_at.as_deref(), Some("2026-01-02T03:04:05.000Z"));
            }
        }
        let calls = repo.executor.calls.lock().unwrap();
        assert_eq!(calls.len(), if affected == 0 { 1 } else { 2 });
        for (sql, binds) in calls.iter() {
            assert!(
                sql.contains("user_id=:user_id")
                    && sql.contains("notification_id=:notification_id")
            );
            assert_eq!(binds["user_id"], DbValue::I64(42));
            assert_eq!(binds["notification_id"], DbValue::I64(12));
        }
        assert_eq!(calls[0].1["is_read"], DbValue::I64(1));
    }
}

#[tokio::test]
async fn batch_repository_uses_user_scope_and_expected_deleted_filter() {
    for (ids, all) in [(vec![], true), (vec![7, 7, 8], false)] {
        let repo = OracleSessions { executor: RepoExecutor { affected: 1, missing: false, fail_read: false, calls: Mutex::new(vec![]) } };
        let count = repo.batch_set_notification_read(42, &ids, true).await.unwrap();
        assert_eq!(count, if all { 1 } else { 3 });
        let calls = repo.executor.calls.lock().unwrap();
        assert_eq!(calls.len(), count as usize);
        for (index, (sql, binds)) in calls.iter().enumerate() {
            assert!(sql.contains("user_id=:user_id"));
            assert_eq!(sql.contains("deleted_at IS NULL"), all);
            assert_eq!(binds["user_id"], DbValue::I64(42));
            assert_eq!(binds["is_read"], DbValue::I64(1));
            if !all { assert_eq!(binds["notification_id"], DbValue::I64(ids[index] as i64)); }
        }
    }
}

struct FailingBatchExecutor { calls: Mutex<usize> }
impl SessionExecutor for FailingBatchExecutor {
    fn preflight(&self, _: &'static str) -> StoreFuture<'_, ()> { Box::pin(async { Ok(()) }) }
    fn execute(&self, _: &'static str, _: BindMap) -> StoreFuture<'_, u64> {
        Box::pin(async move {
            let mut calls = self.calls.lock().unwrap();
            *calls += 1;
            if *calls == 2 { Err(SessionStoreError) } else { Ok(1) }
        })
    }
}
#[tokio::test]
async fn batch_repository_stops_after_a_partial_failure() {
    let repo = OracleSessions { executor: FailingBatchExecutor { calls: Mutex::new(0) } };
    assert!(repo.batch_set_notification_read(42, &[7, 8, 9], true).await.is_err());
    assert_eq!(*repo.executor.calls.lock().unwrap(), 2);
}
