use axum::{body::Body, http::Request};
use http_body_util::BodyExt;
use nekotribe_backend::{
    auth::{
        otp::SmtpConfig,
        session_repository::{OracleSessions, SessionExecutor},
        sessions::{
            build_native_router_with_realtime_and_publisher, CorsPolicy, RefreshPolicy,
            SessionRepository, SessionStoreError, StoreFuture,
        },
        storage_urls::StorageUrlPolicy,
        TokenClaims, TokenCodec,
    },
    db::{oracle::BindMap, row::DbRow, value::DbValue},
};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

struct Store {
    found: bool,
    fail: bool,
    calls: Mutex<Vec<(u64, u64, bool)>>,
}
impl SessionRepository for Store {
    fn list_post_comments<'a>(
        &'a self,
        user: u64,
        id: u64,
        query: &'a nekotribe_backend::posts::comments::CommentListQuery,
    ) -> StoreFuture<'a, Option<(Vec<Value>, u64)>> {
        Box::pin(async move {
            self.calls
                .lock()
                .unwrap()
                .push((user, id, query.sort == "popular"));
            if self.fail {
                return Err(SessionStoreError);
            }
            let author = if id == 3 { 42 } else { 7 };
            Ok(self.found.then(|| (vec![json!({"comment_id":9,"post_id":id,"author_id":author,"is_liked":true,"stats":{"likes_count":3,"replies_count":0}})],1)))
        })
    }
    fn read_post_author<'a>(
        &'a self,
        viewer: Option<u64>,
        id: u64,
    ) -> StoreFuture<'a, Option<Value>> {
        Box::pin(async move {
            Ok((viewer == Some(42) && (id == 7 || id == 42))
                .then(|| json!({"user_id":id,"username":"author","avatar_url":""})))
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
}

#[tokio::test]
async fn post_comment_author_can_delete_own_comment() {
    let (codec, token) = credentials();
    let store = Arc::new(Store {
        found: true,
        fail: false,
        calls: Mutex::new(vec![]),
    });
    let app = build_native_router_with_realtime_and_publisher(
        codec,
        store,
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_000),
        RefreshPolicy::default(),
        StorageUrlPolicy::default(),
        Arc::new(SmtpConfig::default()),
        None,
        None,
    );
    let request = Request::builder()
        .uri("/api/v2/posts/3/comments")
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();
    let response = app.oneshot(request).await.unwrap();
    assert_eq!(response.status().as_u16(), 200);
    let data: Value =
        serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(data["data"][0]["viewer_state"]["can_delete"], true);
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
async fn post_comments_route_requires_auth_and_checks_post_visibility() {
    for (path, authenticated, found, status) in [
        ("/api/v2/posts/1/comments", false, true, 401),
        ("/api/v2/posts/01/comments", true, true, 400),
        ("/api/v2/posts/2/comments", true, false, 404),
        (
            "/api/v2/posts/1/comments?sort=popular&page=2&page_size=3",
            true,
            true,
            200,
        ),
    ] {
        let (codec, token) = credentials();
        let store = Arc::new(Store {
            found,
            fail: false,
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
        let mut req = Request::builder().method("GET").uri(path);
        if authenticated {
            req = req.header("authorization", format!("Bearer {token}"));
        }
        let response = app.oneshot(req.body(Body::empty()).unwrap()).await.unwrap();
        assert_eq!(response.status().as_u16(), status, "{path}");
        assert_eq!(
            response.headers().get("cache-control").unwrap(),
            "private, no-store"
        );
        if status == 200 {
            let body: Value =
                serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes())
                    .unwrap();
            assert_eq!(body["data"][0]["comment_id"], 9);
            assert_eq!(body["data"][0]["author"]["user_id"], 7);
            assert_eq!(body["data"][0]["viewer_state"]["can_delete"], false);
            assert_eq!(body["meta"]["page"], 2.0);
            assert_eq!(*store.calls.lock().unwrap(), vec![(42, 1, true)]);
        }
    }
}

struct CommentsExecutor {
    calls: Mutex<Vec<(&'static str, BindMap)>>,
    hidden: bool,
}
impl SessionExecutor for CommentsExecutor {
    fn preflight(&self, _: &'static str) -> StoreFuture<'_, ()> {
        Box::pin(async { Ok(()) })
    }
    fn execute(&self, _: &'static str, _: BindMap) -> StoreFuture<'_, u64> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn query(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((sql, binds));
            if sql.contains("FROM n_posts p") {
                return Ok(if self.hidden {
                    vec![]
                } else {
                    vec![DbRow::from([("POST_ID".into(), DbValue::I64(1))])]
                });
            }
            if sql.starts_with("SELECT COUNT") {
                return Ok(vec![DbRow::from([("TOTAL".into(), DbValue::I64(4))])]);
            }
            Ok(vec![DbRow::from([
                ("COMMENT_ID".into(), DbValue::I64(9)),
                ("POST_ID".into(), DbValue::I64(1)),
                ("USER_ID".into(), DbValue::I64(7)),
                ("PARENT_COMMENT_ID".into(), DbValue::Null),
                ("ROOT_COMMENT_ID".into(), DbValue::I64(3)),
                ("CONTENT".into(), DbValue::String("text".into())),
                ("LIKES_COUNT".into(), DbValue::I64(2)),
                ("REPLIES_COUNT".into(), DbValue::I64(1)),
                ("IS_LIKED".into(), DbValue::I64(1)),
                (
                    "CREATED_AT".into(),
                    DbValue::String("2026-01-02T03:04:05Z".into()),
                ),
            ])])
        })
    }
}
#[tokio::test]
async fn post_comments_repository_filters_visibility_and_maps_rows() {
    use nekotribe_backend::{
        auth::session_list::session_pagination, posts::comments::CommentListQuery,
    };
    for (sort, order) in [
        ("newest", "c.created_at DESC"),
        ("oldest", "c.created_at ASC"),
        ("popular", "c.likes_count DESC, c.created_at DESC"),
        ("other", "c.created_at DESC"),
    ] {
        let repo = OracleSessions {
            executor: CommentsExecutor {
                calls: Mutex::new(vec![]),
                hidden: false,
            },
        };
        let query = CommentListQuery {
            page: session_pagination("page=2&page_size=3"),
            sort: sort.into(),
            comment_id: None,
        };
        let (items, total) = repo
            .list_post_comments(42, 1, &query)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(total, 4);
        assert_eq!(items[0]["comment_id"], 9);
        assert_eq!(items[0]["root_comment_id"], 3);
        assert_eq!(items[0]["created_at"], "2026-01-02T03:04:05.000Z");
        assert_eq!(items[0]["is_liked"], true);
        let calls = repo.executor.calls.lock().unwrap();
        assert_eq!(calls.len(), 3);
        for (sql, binds) in calls.iter() {
            assert!(sql.contains("fn_can_view_post(:viewer_id,"));
            assert_eq!(binds["viewer_id"], DbValue::I64(42));
            assert_eq!(binds["post_id"], DbValue::I64(1));
        }
        for (sql, _) in &calls[1..] {
            for predicate in [
                "post_author.is_active=1",
                "comment_author.is_active=1",
                "b.user_id=:viewer_id AND b.target_user_id=c.user_id",
                "b.target_user_id=:viewer_id AND b.user_id=c.user_id",
            ] {
                assert!(sql.contains(predicate), "{sql}");
            }
        }
        assert!(calls[2].0.contains(&format!("ORDER BY {order}")));
        assert_eq!(calls[2].1["start_row"], DbValue::F64(4.0));
        assert_eq!(calls[2].1["end_row"], DbValue::F64(6.0));
    }
    let repo = OracleSessions {
        executor: CommentsExecutor {
            calls: Mutex::new(vec![]),
            hidden: true,
        },
    };
    let query = CommentListQuery {
        page: session_pagination(""),
        sort: "newest".into(),
        comment_id: None,
    };
    assert!(repo
        .list_post_comments(42, 2, &query)
        .await
        .unwrap()
        .is_none());
    assert_eq!(repo.executor.calls.lock().unwrap().len(), 1);
}
