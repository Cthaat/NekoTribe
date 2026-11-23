use axum::{body::Body, http::Request, Router};
use http_body_util::BodyExt;
use nekotribe_backend::{
    auth::{
        session_list::SessionPage,
        session_repository::{OracleSessions, SessionExecutor, TOUCH_SQL},
        sessions::{build_native_router, CorsPolicy, SessionRepository, StoreFuture},
        storage_urls::StorageUrlPolicy,
        TokenCodec,
    },
    db::{oracle::BindMap, row::DbRow, value::DbValue},
    group_content::Outcome,
    posts::list::parse_post_list_query,
};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

struct Executor {
    feedback_ready: bool,
    calls: Mutex<Vec<(&'static str, BindMap)>>,
}

impl SessionExecutor for Executor {
    fn execute(&self, statement: &'static str, binds: BindMap) -> StoreFuture<'_, u64> {
        assert_eq!(statement, TOUCH_SQL);
        assert_eq!(binds["user_id"], DbValue::I64(42));
        Box::pin(async { Ok(1) })
    }

    fn preflight(&self, _: &'static str) -> StoreFuture<'_, ()> {
        Box::pin(async { Ok(()) })
    }

    fn query(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
        self.calls.lock().unwrap().push((sql, binds));
        Box::pin(async move {
            if sql.starts_with("SELECT table_name FROM user_tables") {
                Ok(if self.feedback_ready {
                    vec![DbRow::new()]
                } else {
                    vec![]
                })
            } else if sql.starts_with("SELECT COUNT(*) AS total") {
                Ok(vec![DbRow::from([("TOTAL".into(), DbValue::I64(0))])])
            } else {
                assert!(sql.contains("ROW_NUMBER() OVER (ORDER BY"));
                Ok(Vec::new())
            }
        })
    }

    fn read_group_activity<'a>(
        &'a self,
        viewer: u64,
        page: SessionPage,
        _: &'a StorageUrlPolicy,
    ) -> StoreFuture<'a, Outcome> {
        Box::pin(async move {
            assert_eq!(viewer, 42);
            let data = match page.page as u64 {
                2 => {
                    assert_eq!((page.start, page.end), (2.0, 2.0));
                    json!([{
                        "post_id": 20, "group_id": 4, "group_name": "Rust",
                        "author": {"user_id": 7}, "media_urls": [], "content": "Summary",
                        "markdown": "# Full body", "poll": {"poll_id": 9},
                    }])
                }
                4 => json!([]),
                _ => panic!("unexpected page"),
            };
            Ok(Outcome::Found(data, 3))
        })
    }
}

#[tokio::test]
async fn recommended_home_uses_shared_score_and_legacy_feedback_with_scoped_fallbacks() {
    let spec: Value =
        serde_json::from_str(include_str!("../contracts/requirements/home-feed.json")).unwrap();
    let score = spec["recommendationScore"].as_str().unwrap();
    let recency = spec["recommendationRecency"].as_str().unwrap();
    for (raw, mode, viewer, ready, ranked, personalized, recent) in [
        (
            "timeline=recommended&sort=oldest",
            "all",
            Some(42),
            true,
            true,
            true,
            true,
        ),
        (
            "timeline=recommended",
            "all",
            Some(42),
            false,
            true,
            false,
            true,
        ),
        (
            "timeline=recommended&sort=popular",
            "all",
            None,
            true,
            false,
            false,
            true,
        ),
        (
            "timeline=recommended&q=RUST&sort=oldest",
            "all",
            Some(42),
            true,
            false,
            false,
            false,
        ),
        ("timeline=home", "all", Some(42), true, false, true, false),
        (
            "timeline=following",
            "all",
            Some(42),
            true,
            false,
            false,
            false,
        ),
        (
            "timeline=recommended&sort=popular",
            "trending",
            Some(42),
            true,
            false,
            true,
            false,
        ),
    ] {
        let repository = OracleSessions {
            executor: Executor {
                feedback_ready: ready,
                calls: Mutex::default(),
            },
        };
        let mut query = parse_post_list_query(raw);
        query.mode = mode.into();
        let (items, total) = repository.list_visible_posts(viewer, &query).await.unwrap();
        assert!(items.is_empty());
        assert_eq!(total, 0);
        let calls = repository.executor.calls.lock().unwrap();
        let (count, counts) = &calls[calls.len() - 2];
        let (page, binds) = &calls[calls.len() - 1];
        assert_eq!(page.contains(score), ranked, "{raw} {mode}");
        assert_eq!(page.contains(recency), recent, "{raw} {mode}");
        assert_eq!(count.contains("rf.action = 'not_interested'"), personalized);
        assert_eq!(page.contains("rf.action = 'not_interested'"), personalized);
        assert_eq!(page.contains("rf.action = 'show_less'"), personalized);
        if ranked && personalized {
            assert!(page.find("rf.action = 'show_less'").unwrap() < page.find(score).unwrap());
        }
        assert!(count.contains("fn_can_view_post(:viewer_id,v.post_id)=1"));
        assert!(page.contains("fn_can_view_post(:viewer_id,v.post_id)=1"));
        assert_eq!(
            counts["viewer_id"],
            viewer.map_or(DbValue::Null, |id| DbValue::I64(id as i64))
        );
        assert_eq!(binds["start_row"], DbValue::F64(1.0));
        assert_eq!(binds["end_row"], DbValue::F64(20.0));
        if !query.search.is_empty() {
            assert!(page.contains("LIKE :q"));
            assert_eq!(binds["q"], DbValue::String("%rust%".into()));
        }
    }
}

fn router() -> (Router, String) {
    let fixture: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = fixture["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|case| case["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    let codec = TokenCodec::new(
        fixture["keys"]["access"].as_str().unwrap().as_bytes(),
        fixture["keys"]["refresh"].as_str().unwrap().as_bytes(),
    )
    .unwrap();
    let repo = OracleSessions {
        executor: Executor {
            feedback_ready: true,
            calls: Mutex::default(),
        },
    };
    (
        build_native_router(
            codec,
            Arc::new(repo),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
        ),
        format!("Bearer {token}"),
    )
}

async fn request(router: &Router, path: &str, token: Option<&str>) -> (u16, Value) {
    let mut request = Request::get(path);
    if let Some(token) = token {
        request = request.header("authorization", token);
    }
    let response = router
        .clone()
        .oneshot(request.body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(response.headers()["cache-control"], "private, no-store");
    let status = response.status().as_u16();
    let body =
        serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes()).unwrap();
    (status, body)
}

#[tokio::test]
async fn group_activity_requires_auth_and_keeps_group_post_fields_and_paging() {
    let (router, token) = router();
    let path = "/api/v2/feed/groups?page=2&page_size=1";
    assert_eq!(request(&router, path, None).await.0, 401);
    let (status, body) = request(&router, path, Some(&token)).await;
    assert_eq!(status, 200);
    assert_eq!(body["data"][0]["group_name"], "Rust");
    assert_eq!(body["data"][0]["markdown"], "# Full body");
    assert_eq!(body["data"][0]["poll"]["poll_id"], 9);
    assert_eq!(
        body["meta"],
        json!({"page":2.0,"page_size":1.0,"total":3,"has_next":true})
    );
    let (_, empty) = request(
        &router,
        "/api/v2/feed/groups?page=4&page_size=1",
        Some(&token),
    )
    .await;
    assert_eq!(empty["data"], json!([]));
    assert_eq!(empty["meta"]["has_next"], false);
    assert_eq!(
        request(&router, "/api/v2/posts?timeline=recommended", None)
            .await
            .0,
        200
    );
}
