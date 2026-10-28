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
    posts::like::{PostLikeOutcome, StoredLikeNotification},
};
use serde_json::Value;
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

struct Store {
    calls: Mutex<Vec<(u64, u64, bool)>>,
    notices: Mutex<u64>,
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
    fn set_comment_like<'a>(
        &'a self,
        user: u64,
        id: u64,
        liked: bool,
    ) -> StoreFuture<'a, Option<PostLikeOutcome>> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((user, id, liked));
            match id {
                2 => Ok(None),
                500 => Err(SessionStoreError),
                _ => Ok(Some(PostLikeOutcome {
                    count: 3.0,
                    inserted: liked,
                })),
            }
        })
    }
    fn prepare_comment_like_notification<'a>(
        &'a self,
        _: u64,
        _: u64,
    ) -> StoreFuture<'a, Option<StoredLikeNotification>> {
        Box::pin(async move {
            *self.notices.lock().unwrap() += 1;
            Ok(None)
        })
    }
}
#[tokio::test]
async fn comment_like_route_auth_visibility_and_notifications() {
    let tokens: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = tokens["cases"]
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
    let store = Arc::new(Store {
        calls: Mutex::new(vec![]),
        notices: Mutex::new(0),
    });
    let app = build_native_router(
        codec,
        store.clone(),
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_000),
    );
    for (method, id, auth, status) in [
        ("POST", "1", false, 401),
        ("POST", "01", true, 400),
        ("POST", "2", true, 404),
        ("DELETE", "2", true, 404),
        ("POST", "500", true, 500),
        ("POST", "1", true, 200),
        ("DELETE", "1", true, 200),
    ] {
        let mut req = Request::builder()
            .method(method)
            .uri(format!("/api/v2/comments/{id}/likes"));
        if auth {
            req = req.header("authorization", format!("Bearer {token}"));
        }
        let res = app
            .clone()
            .oneshot(req.body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(res.status().as_u16(), status);
        assert_eq!(res.headers()["cache-control"], "private, no-store");
        let data: Value =
            serde_json::from_slice(&res.into_body().collect().await.unwrap().to_bytes()).unwrap();
        if status == 200 {
            assert_eq!(data["data"]["comment_id"], 1);
            assert_eq!(data["data"]["is_liked"], method == "POST");
            assert_eq!(data["data"]["likes_count"], 3.0)
        }
    }
    assert_eq!(*store.notices.lock().unwrap(), 1);
    assert!(store.calls.lock().unwrap().iter().all(|x| x.0 == 42));
}
struct Executor {
    hidden: bool,
    race: bool,
    missing_count: bool,
    affected: u64,
    calls: Mutex<Vec<(&'static str, BindMap)>>,
}
impl SessionExecutor for Executor {
    fn preflight(&self, _: &'static str) -> StoreFuture<'_, ()> {
        Box::pin(async { Ok(()) })
    }
    fn query(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
        Box::pin(async move {
            let mut c = self.calls.lock().unwrap();
            c.push((sql, binds));
            let n = c.iter().filter(|(q, _)| q.starts_with("SELECT")).count();
            if self.hidden
                || (self.race && n > 1)
                || (self.missing_count && sql.contains("likes_count"))
            {
                Ok(vec![])
            } else if sql.contains("likes_count") {
                Ok(vec![DbRow::from([("LIKES_COUNT".into(), DbValue::I64(3))])])
            } else {
                Ok(vec![DbRow::from([("COMMENT_ID".into(), DbValue::I64(20))])])
            }
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
async fn comment_like_repository_checks_visibility_and_binds() {
    for (hidden, race, missing_count, affected, liked, visible, inserted) in [
        (true, false, false, 0, true, false, false),
        (false, true, false, 0, true, false, false),
        (false, false, true, 1, true, false, false),
        (false, false, false, 1, true, true, true),
        (false, false, false, 0, true, true, false),
        (false, false, false, 1, false, true, false),
        (false, false, false, 0, false, true, false),
    ] {
        let repo = OracleSessions {
            executor: Executor {
                hidden,
                race,
                missing_count,
                affected,
                calls: Mutex::new(vec![]),
            },
        };
        let result = repo.set_comment_like(42, 20, liked).await.unwrap();
        assert_eq!(result.is_some(), visible);
        if let Some(r) = result {
            assert_eq!(r.count, 3.0);
            assert_eq!(r.inserted, inserted)
        }
        for (sql, binds) in repo.executor.calls.lock().unwrap().iter() {
            if sql.starts_with("INSERT") || sql.starts_with("DELETE") {
                for part in [
                    "c.is_deleted=0",
                    "p.is_deleted=0",
                    "fn_can_view_post(:user_id,c.post_id)=1",
                ] {
                    assert!(sql.contains(part), "{sql}")
                }
                assert_eq!(binds["user_id"], DbValue::I64(42));
                assert_eq!(binds["comment_id"], DbValue::I64(20));
            }
        }
    }
}
