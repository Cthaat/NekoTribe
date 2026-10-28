use axum::{body::Body, http::Request};
use http_body_util::BodyExt;
use nekotribe_backend::auth::{
    sessions::{
        build_native_router, CorsPolicy, SessionRepository, SessionStoreError, StoreFuture,
    },
    TokenClaims, TokenCodec,
};
use nekotribe_backend::{
    auth::session_repository::{OracleSessions, SessionExecutor},
    db::{oracle::BindMap, row::DbRow, value::DbValue},
};
use serde_json::Value;
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

#[derive(Default)]
struct Store {
    saved: Mutex<bool>,
    calls: Mutex<Vec<(u64, u64, bool)>>,
}
impl SessionRepository for Store {
    fn remove_post_like<'a>(&'a self, viewer: u64, id: u64) -> StoreFuture<'a, Option<f64>> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((viewer, id, false));
            Ok((id == 1).then_some(3.0))
        })
    }
    fn touch<'a>(&'a self, claims: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async move { Ok(u64::from(claims.user_id == 42)) })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn set_post_bookmark<'a>(&'a self, viewer: u64, id: u64, saved: bool) -> StoreFuture<'a, bool> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((viewer, id, saved));
            if id == 500 {
                return Err(SessionStoreError);
            }
            if id != 1 {
                return Ok(false);
            }
            *self.saved.lock().unwrap() = saved;
            Ok(true)
        })
    }
}
#[tokio::test]
async fn bookmarks_auth_visibility_and_idempotence() {
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
    for (method, path, logged, status, saved) in [
        ("POST", "/api/v2/posts/1/bookmarks", false, 401, false),
        ("POST", "/api/v2/posts/01/bookmarks", true, 400, false),
        ("POST", "/api/v2/posts/2/bookmarks", true, 404, false),
        ("DELETE", "/api/v2/posts/2/bookmarks", true, 404, false),
        ("POST", "/api/v2/posts/500/bookmarks", true, 500, false),
        (
            "POST",
            "/api/v2/posts/1/bookmarks?user_id=99",
            true,
            200,
            true,
        ),
        ("POST", "/api/v2/posts/1/bookmarks", true, 200, true),
        ("DELETE", "/api/v2/posts/1/bookmarks", true, 200, false),
        ("DELETE", "/api/v2/posts/1/bookmarks", true, 200, false),
    ] {
        let mut req = Request::builder().method(method).uri(path);
        if logged {
            req = req.header("authorization", format!("Bearer {valid}"));
        }
        let response = app
            .clone()
            .oneshot(req.body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), status, "{method} {path}");
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        if status == 200 {
            let body: Value = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(body["data"]["post_id"], 1);
            assert_eq!(body["data"]["is_bookmarked"], saved);
            assert_eq!(*store.saved.lock().unwrap(), saved);
        }
    }
    assert!(store
        .calls
        .lock()
        .unwrap()
        .iter()
        .all(|(viewer, _, _)| *viewer == 42));
}

#[tokio::test]
async fn unlike_auth_visibility_and_count() {
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
    for (path, auth, status) in [
        ("/api/v2/posts/1/likes", false, 401),
        ("/api/v2/posts/01/likes", true, 400),
        ("/api/v2/posts/2/likes", true, 404),
        ("/api/v2/posts/1/likes?user_id=99", true, 200),
        ("/api/v2/posts/1/likes", true, 200),
    ] {
        let mut req = Request::builder().method("DELETE").uri(path);
        if auth {
            req = req.header("authorization", format!("Bearer {valid}"));
        }
        let response = app
            .clone()
            .oneshot(req.body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), status);
        if status == 200 {
            let body: Value =
                serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes())
                    .unwrap();
            assert_eq!(body["data"]["post_id"], 1);
            assert_eq!(body["data"]["is_liked"], false);
            assert_eq!(body["data"]["likes_count"], 3.0);
        }
    }
    assert_eq!(
        store.calls.lock().unwrap().as_slice(),
        &[(42, 2, false), (42, 1, false), (42, 1, false)]
    );
}

struct BookmarkExecutor {
    visibility: Vec<bool>,
    affected: u64,
    calls: Mutex<Vec<(&'static str, BindMap)>>,
}
impl SessionExecutor for BookmarkExecutor {
    fn preflight(&self, _: &'static str) -> StoreFuture<'_, ()> {
        Box::pin(async { Ok(()) })
    }
    fn query(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
        Box::pin(async move {
            let mut calls = self.calls.lock().unwrap();
            if sql.contains("n_post_stats") {
                calls.push((sql, binds));
                return Ok(vec![DbRow::from([("LIKES_COUNT".into(), DbValue::I64(3))])]);
            }
            let index = calls
                .iter()
                .filter(|(q, _)| q.starts_with("SELECT"))
                .count();
            calls.push((sql, binds));
            Ok(if self.visibility.get(index).copied().unwrap_or(false) {
                vec![DbRow::from([("POST_ID".into(), DbValue::I64(7))])]
            } else {
                vec![]
            })
        })
    }
    fn execute(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, u64> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((sql, binds));
            Ok(self.affected)
        })
    }
}

#[tokio::test]
async fn unlike_repository_checks_visibility_and_reads_count() {
    for (visible, affected, expected, count) in [
        (vec![true], 1, Some(3.0), 3),
        (vec![true, true], 0, Some(3.0), 4),
        (vec![true, false], 0, None, 3),
        (vec![false], 0, None, 1),
    ] {
        let repo = OracleSessions {
            executor: BookmarkExecutor {
                visibility: visible,
                affected,
                calls: Mutex::new(vec![]),
            },
        };
        assert_eq!(repo.remove_post_like(42, 7).await.unwrap(), expected);
        let calls = repo.executor.calls.lock().unwrap();
        assert_eq!(calls.len(), count);
        for (sql, binds) in calls.iter() {
            assert_eq!(binds["post_id"], DbValue::I64(7));
            if !sql.contains("n_post_stats") {
                assert_eq!(binds["user_id"], DbValue::I64(42));
                assert!(sql.contains("fn_can_view_post(:user_id,"));
            }
        }
    }
}
#[tokio::test]
async fn bookmark_repository_checks_visibility_at_write_and_rechecks_zero_rows() {
    for (visible, affected, saved, expected, count) in [
        (vec![true], 1, true, true, 2),
        (vec![true], 1, false, true, 2),
        (vec![true, true], 0, true, true, 3),
        (vec![true, false], 0, true, false, 3),
        (vec![false], 0, true, false, 1),
    ] {
        let repo = OracleSessions {
            executor: BookmarkExecutor {
                visibility: visible,
                affected,
                calls: Mutex::new(vec![]),
            },
        };
        assert_eq!(
            repo.set_post_bookmark(42, 7, saved).await.unwrap(),
            expected
        );
        let calls = repo.executor.calls.lock().unwrap();
        assert_eq!(calls.len(), count);
        for (sql, binds) in calls.iter() {
            assert_eq!(binds["user_id"], DbValue::I64(42));
            assert_eq!(binds["post_id"], DbValue::I64(7));
            assert!(sql.contains("fn_can_view_post(:user_id,"));
            if sql.starts_with("SELECT") {
                assert!(sql.contains("p.is_deleted=0"));
            }
        }
    }
}
