use axum::{body::Body, http::Request};
use http_body_util::BodyExt;
use nekotribe_backend::{
    auth::{
        session_repository::{OracleSessions, SessionExecutor},
        sessions::{
            build_native_router, CorsPolicy, SessionRepository, SessionStoreError, StoreFuture,
        },
        TokenClaims, TokenCodec,
    },
    db::{oracle::BindMap, row::DbRow, value::DbValue},
    notifications::{parse_notification_query, NotificationQuery},
};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;
#[derive(Default)]
struct Store {
    query: Mutex<Option<(u64, NotificationQuery)>>,
    raw_metadata: Mutex<Option<String>>,
}
impl SessionRepository for Store {
    fn touch<'a>(&'a self, c: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async move { Ok(u64::from(c.user_id == 42)) })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn list_notifications<'a>(
        &'a self,
        user: u64,
        query: &'a NotificationQuery,
    ) -> StoreFuture<'a, (Vec<Value>, u64)> {
        Box::pin(async move {
            *self.query.lock().unwrap() = Some((user, query.clone()));
            let mut item = json!({"notification_id":12,"actor_id":7,"type":"like","metadata":{"event":"post_like"}});
            if let Some(raw) = self.raw_metadata.lock().unwrap().clone() {
                item["metadata"] = Value::Null;
                item["__nekotribe_metadata_raw"] = Value::String(raw);
            }
            Ok((vec![item], 3))
        })
    }
    fn public_profile<'a>(&'a self, viewer: u64, target: u64) -> StoreFuture<'a, Option<Value>> {
        Box::pin(async move {
            if viewer != 42 || target != 7 {
                return Err(SessionStoreError);
            };
            Ok(Some(json!({"user_id":7,"avatar_url":""})))
        })
    }
}

#[tokio::test]
async fn notification_list_preserves_raw_utf16_metadata_without_internal_marker() {
    let tokens: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = tokens["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    let codec = TokenCodec::new(
        tokens["keys"]["access"].as_str().unwrap().as_bytes(),
        tokens["keys"]["refresh"].as_str().unwrap().as_bytes(),
    )
    .unwrap();
    let store = Arc::new(Store::default());
    *store.raw_metadata.lock().unwrap() = Some(r#"{"post_excerpt":"prefix\ud83d..."}"#.into());
    let app = build_native_router(
        codec,
        store,
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_000),
    );
    let response = app
        .oneshot(
            Request::builder()
                .uri("/api/v2/notifications")
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status().as_u16(), 200);
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    let body = std::str::from_utf8(&bytes).unwrap();
    assert!(
        body.contains(r#""metadata":{"post_excerpt":"prefix\ud83d..."}"#),
        "{body}"
    );
    assert!(!body.contains("__nekotribe_metadata_raw"));
}
#[tokio::test]
async fn notification_route_auth_scoping_filters_and_actor() {
    let tokens: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let valid = tokens["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|x| x["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    let codec = TokenCodec::new(
        tokens["keys"]["access"].as_str().unwrap().as_bytes(),
        tokens["keys"]["refresh"].as_str().unwrap().as_bytes(),
    )
    .unwrap();
    let store = Arc::new(Store::default());
    let app = build_native_router(
        codec,
        store.clone(),
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_000),
    );
    for (path,token,status) in [("/api/v2/notifications","",401),("/api/v2/notifications","bad",401),("/api/v2/notifications?type=like&unread_only=true&show_deleted=true&page=2&page_size=1&user_id=99",valid,200)]{
        let mut req=Request::builder().uri(path);if !token.is_empty(){req=req.header("authorization",format!("Bearer {token}"));}
        let response=app.clone().oneshot(req.body(Body::empty()).unwrap()).await.unwrap();assert_eq!(response.status().as_u16(),status);assert_eq!(response.headers()["cache-control"],"private, no-store");
        if status==200 {let body:Value=serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes()).unwrap();assert_eq!(body["data"][0]["actor"]["user_id"],7);assert!(body["data"][0].get("actor_id").is_none());assert_eq!(body["meta"]["total"],3);assert_eq!(body["meta"]["has_next"],true);let guard=store.query.lock().unwrap();let (viewer,q)=guard.as_ref().unwrap();assert_eq!(*viewer,42);assert_eq!(q.kind,"like");assert!(q.unread_only&&q.show_deleted);assert_eq!(q.page.start,2.0);}
    }
    let q = parse_notification_query("type=like&type=other&unread_only=true&unread_only=false");
    assert_eq!(q.kind, "all");
    assert!(!q.unread_only);
}
struct Executor {
    calls: Mutex<Vec<(&'static str, BindMap)>>,
    metadata: String,
}
impl SessionExecutor for Executor {
    fn preflight(&self, _: &'static str) -> StoreFuture<'_, ()> {
        Box::pin(async { Ok(()) })
    }
    fn execute(&self, _: &'static str, _: BindMap) -> StoreFuture<'_, u64> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn query(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((sql, binds));
            if sql.starts_with("SELECT COUNT") {
                return Ok(vec![DbRow::from([("TOTAL".into(), DbValue::I64(3))])]);
            }
            if self.metadata == "fixture-missing" {
                return Ok(vec![]);
            }
            if self.metadata == "fixture-error" {
                return Err(SessionStoreError);
            }
            Ok(vec![DbRow::from([
                ("NOTIFICATION_ID".into(), DbValue::I64(12)),
                ("ACTOR_ID".into(), DbValue::I64(7)),
                ("TYPE".into(), DbValue::String("like".into())),
                ("RESOURCE_ID".into(), DbValue::I64(9)),
                (
                    "METADATA_JSON".into(),
                    DbValue::String(self.metadata.clone()),
                ),
            ])])
        })
    }
}

#[tokio::test]
async fn notification_by_id_scopes_recipient_and_reuses_list_mapping() {
    for metadata in [
        r#"{"event":"post_like"}"#,
        "invalid",
        "",
        "fixture-missing",
        "fixture-error",
    ] {
        let repo = OracleSessions {
            executor: Executor {
                calls: Mutex::new(vec![]),
                metadata: metadata.into(),
            },
        };
        let result = repo.notification_by_id(42, 12).await;
        if metadata == "fixture-error" {
            assert!(result.is_err());
            continue;
        }
        let item = result.unwrap();
        if metadata == "fixture-missing" {
            assert!(item.is_none());
            continue;
        }
        let item = item.unwrap();
        assert_eq!(item["notification_id"], 12);
        assert_eq!(item["actor_id"], 7);
        match metadata {
            "invalid" => assert_eq!(item["metadata"], "invalid"),
            "" => assert!(item["metadata"].is_null()),
            _ => assert_eq!(item["metadata"]["event"], "post_like"),
        }
        let calls = repo.executor.calls.lock().unwrap();
        assert_eq!(calls.len(), 1);
        assert!(
            calls[0].0.contains("user_id=:user_id")
                && calls[0].0.contains("notification_id=:notification_id")
        );
        assert_eq!(calls[0].1["user_id"], DbValue::I64(42));
        assert_eq!(calls[0].1["notification_id"], DbValue::I64(12));
    }
}

#[tokio::test]
async fn repository_unpaired_metadata_can_be_serialized_as_notification_event() {
    let repo = OracleSessions {
        executor: Executor {
            calls: Mutex::new(vec![]),
            metadata: r#"{"post_excerpt":"prefix\ud83d..."}"#.into(),
        },
    };
    let item = repo.notification_by_id(42, 12).await.unwrap().unwrap();
    let data = serde_json::Map::from_iter([("notification".into(), item)]);
    let (_, body) = nekotribe_backend::notification_events::encode_notification_event(
        42,
        "notification_created",
        &data,
        "server",
        1,
    )
    .unwrap();
    assert!(
        body.contains(r#""metadata":{"post_excerpt":"prefix\ud83d..."}"#),
        "{body}"
    );
    assert!(!body.contains("__nekotribe_metadata_raw"));
}
#[tokio::test]
async fn repository_scopes_filters_binds_and_metadata() {
    for metadata in [r#"{"event":"post_like"}"#, "invalid", ""] {
        let repo = OracleSessions {
            executor: Executor {
                calls: Mutex::new(vec![]),
                metadata: metadata.into(),
            },
        };
        let query = parse_notification_query(
            "type=like&unread_only=true&show_deleted=true&page=2&page_size=1",
        );
        let (items, total) = repo.list_notifications(42, &query).await.unwrap();
        assert_eq!(total, 3);
        assert_eq!(items[0]["actor_id"], 7);
        match metadata {
            "invalid" => assert_eq!(items[0]["metadata"], "invalid"),
            "" => assert!(items[0]["metadata"].is_null()),
            _ => assert_eq!(items[0]["metadata"]["event"], "post_like"),
        };
        let calls = repo.executor.calls.lock().unwrap();
        assert_eq!(calls.len(), 2);
        for (sql, binds) in calls.iter() {
            assert!(
                sql.contains("user_id=:user_id")
                    && sql.contains("deleted_at IS NOT NULL")
                    && sql.contains("is_read=0")
                    && sql.contains("type=:type")
            );
            assert!(!sql.contains("like"));
            assert_eq!(binds["user_id"], DbValue::I64(42));
            assert_eq!(binds["type"], DbValue::String("like".into()));
        }
    }
}
