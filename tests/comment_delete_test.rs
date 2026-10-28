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
    posts::comment_delete::CommentDelete,
};
use serde_json::Value;
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

struct Store;
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
    fn delete_post_comment<'a>(&'a self, user: u64, id: u64) -> StoreFuture<'a, CommentDelete> {
        Box::pin(async move {
            assert_eq!(user, 42);
            match id {
                1 => Ok(CommentDelete::Deleted),
                2 => Ok(CommentDelete::Missing),
                3 => Ok(CommentDelete::NotOwner),
                _ => Err(SessionStoreError),
            }
        })
    }
}
#[tokio::test]
async fn delete_route_auth_and_responses() {
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
    let app = build_native_router(
        codec,
        Arc::new(Store),
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_000),
    );
    for (id, authenticated, status) in [
        ("1", false, 401),
        ("01", true, 400),
        ("2", true, 404),
        ("3", true, 422),
        ("500", true, 500),
        ("1", true, 200),
    ] {
        let mut req = Request::builder()
            .method("DELETE")
            .uri(format!("/api/v2/comments/{id}"));
        if authenticated {
            req = req.header("authorization", format!("Bearer {token}"));
        }
        let response = app
            .clone()
            .oneshot(req.body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), status);
        assert_eq!(response.headers()["cache-control"], "private, no-store");
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        let data: Value = serde_json::from_slice(&bytes).unwrap();
        if status == 200 {
            assert_eq!(data["message"], "comment deleted");
            assert!(data["data"].is_null());
        }
    }
}
struct Executor {
    owner: Option<i64>,
    affected: u64,
    calls: Mutex<Vec<(&'static str, BindMap)>>,
}
impl SessionExecutor for Executor {
    fn preflight(&self, _: &'static str) -> StoreFuture<'_, ()> {
        Box::pin(async { Ok(()) })
    }
    fn query(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((sql, binds));
            Ok(self
                .owner
                .map(|x| DbRow::from([("USER_ID".into(), DbValue::I64(x))]))
                .into_iter()
                .collect())
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
async fn delete_repository_checks_owner_visibility_and_races() {
    for (owner, affected, expected, writes) in [
        (None, 0, CommentDelete::Missing, 0),
        (Some(7), 0, CommentDelete::NotOwner, 0),
        (Some(42), 0, CommentDelete::Missing, 1),
        (Some(42), 1, CommentDelete::Deleted, 1),
    ] {
        let repo = OracleSessions {
            executor: Executor {
                owner,
                affected,
                calls: Mutex::new(vec![]),
            },
        };
        assert_eq!(repo.delete_post_comment(42, 20).await.unwrap(), expected);
        let calls = repo.executor.calls.lock().unwrap();
        assert_eq!(calls.len(), writes + 1);
        let (sql, binds) = &calls[0];
        for s in [
            "c.is_deleted=0",
            "p.is_deleted=0",
            "fn_can_view_post(:viewer_id,c.post_id)=1",
        ] {
            assert!(sql.contains(s), "{sql}")
        }
        assert_eq!(binds["viewer_id"], DbValue::I64(42));
        if writes > 0 {
            let (sql, binds) = &calls[1];
            for s in [
                "c.user_id=:user_id",
                "c.is_deleted=0",
                "p.is_deleted=0",
                "fn_can_view_post(:user_id,c.post_id)=1",
            ] {
                assert!(sql.contains(s), "{sql}")
            }
            assert_eq!(binds["user_id"], DbValue::I64(42));
            assert_eq!(binds["comment_id"], DbValue::I64(20));
        }
    }
}
