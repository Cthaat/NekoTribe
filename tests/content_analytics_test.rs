use axum::{body::Body, http::Request};
use http_body_util::BodyExt;
use nekotribe_backend::{
    auth::{
        session_repository::{OracleSessions, SessionExecutor, TOUCH_SQL},
        sessions::{build_native_router, CorsPolicy, StoreFuture},
        TokenCodec,
    },
    db::{oracle::BindMap, row::DbRow, value::DbValue},
};
use serde_json::Value;
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};
use tower::ServiceExt;

struct Executor(Arc<AtomicUsize>);

fn row(fields: &[(&str, DbValue)]) -> DbRow {
    fields
        .iter()
        .map(|(key, value)| (key.to_string(), value.clone()))
        .collect()
}

impl SessionExecutor for Executor {
    fn execute(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, u64> {
        assert_eq!(sql, TOUCH_SQL);
        assert_eq!(binds["user_id"], DbValue::I64(42));
        Box::pin(async { Ok(1) })
    }

    fn preflight(&self, _: &'static str) -> StoreFuture<'_, ()> {
        Box::pin(async { Ok(()) })
    }

    fn query(&self, statement: &'static str, binds: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
        self.0.fetch_add(1, Ordering::Relaxed);
        assert_eq!(binds["viewer_id"], DbValue::I64(42));
        let DbValue::I64(id) = binds["target_id"] else {
            panic!("missing target")
        };
        let spec: Value = serde_json::from_str(include_str!(
            "../contracts/requirements/content-analytics.json"
        ))
        .unwrap();
        let n = DbValue::I64;
        let f = DbValue::F64;
        let rows = if spec["post"] == statement {
            match id {
                1 | 7 => vec![row(&[
                    ("POST_ID", n(id)),
                    ("IS_OWNER", n(1)),
                    ("STATS_POST_ID", n(id)),
                    ("VIEWS_COUNT", n(if id == 1 { 3 } else { 0 })),
                    ("LIKES_COUNT", n(if id == 1 { 2 } else { 8 })),
                    ("COMMENTS_COUNT", n(2)),
                    ("REPLIES_COUNT", n(1)),
                    ("RETWEETS_COUNT", n(3)),
                    ("ENGAGEMENT_SCORE", f(4.25)),
                    ("LIKE_RATE", f(if id == 1 { 0.6667 } else { 0.0 })),
                ])],
                13 => vec![row(&[("IS_OWNER", n(1)), ("STATS_POST_ID", DbValue::Null)])],
                8 => vec![row(&[("IS_OWNER", n(0))])],
                _ => Vec::new(),
            }
        } else if spec["summary"] == statement {
            let (posts, week, received, average, outgoing, score) = match id {
                42 => (3, 2, 10, 5.0, 1, 4.25),
                8 => (1, 1, 5, 5.0, 0, 3.5),
                12 => (0, 0, 0, 0.0, 0, 0.0),
                _ => return Box::pin(async { Ok(Vec::new()) }),
            };
            vec![row(&[
                ("USER_ID", n(id)),
                ("TOTAL_POSTS", n(posts)),
                ("POSTS_THIS_WEEK", n(week)),
                ("POSTS_THIS_MONTH", n(posts)),
                ("TOTAL_LIKES_RECEIVED", n(received)),
                ("AVG_LIKES_PER_POST", f(average)),
                ("TOTAL_LIKES_GIVEN", n(outgoing)),
                ("TOTAL_COMMENTS_MADE", n(outgoing)),
                ("ENGAGEMENT_SCORE", f(score)),
            ])]
        } else {
            assert_eq!(spec["daily"], statement);
            assert_eq!(id, 42);
            let DbValue::I64(days) = binds["days"] else {
                panic!("missing days")
            };
            vec![
                row(&[
                    ("DAY", DbValue::String("2026-11-17".into())),
                    ("ENGAGEMENT_SCORE", n(3))
                ]);
                days as usize
            ]
        };
        Box::pin(async move { Ok(rows) })
    }
}

#[tokio::test]
async fn shared_content_analytics_scenarios_use_native_repository() {
    let tokens: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let access = tokens["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|case| case["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    let codec = TokenCodec::new(
        tokens["keys"]["access"].as_str().unwrap().as_bytes(),
        tokens["keys"]["refresh"].as_str().unwrap().as_bytes(),
    )
    .unwrap();
    let reads = Arc::new(AtomicUsize::new(0));
    let app = build_native_router(
        codec,
        Arc::new(OracleSessions {
            executor: Executor(reads.clone()),
        }),
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_000),
    );
    let spec: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/content-analytics.json"
    ))
    .unwrap();
    for scenario in spec["cases"].as_array().unwrap() {
        let path = scenario["path"].as_str().unwrap().replacen(
            "/users/1/analytics",
            "/users/42/analytics",
            1,
        );
        let mut request = Request::builder().method("GET").uri(path);
        let anonymous = scenario["anonymous"] == true;
        if !anonymous {
            request = request.header("authorization", format!("Bearer {access}"));
        }
        let before = reads.load(Ordering::Relaxed);
        let response = app
            .clone()
            .oneshot(request.body(Body::empty()).unwrap())
            .await
            .unwrap();
        let status = scenario["status"].as_u64().unwrap() as u16;
        assert_eq!(response.status().as_u16(), status, "{}", scenario["id"]);
        assert_eq!(response.headers()["cache-control"], "private, no-store");
        assert_eq!(
            reads.load(Ordering::Relaxed) - before,
            usize::from(!anonymous && status != 400 && scenario["skipQuery"] != true)
        );
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        let body: Value = serde_json::from_slice(&bytes).unwrap();
        if status != 200 {
            assert_eq!(body["code"], u32::from(status) * 100 + 1);
        } else if let Some(length) = scenario["length"].as_u64() {
            assert_eq!(body["data"].as_array().unwrap().len() as u64, length);
        } else if let Some(expected) = scenario["data"].as_object() {
            let data = body["data"].as_object().unwrap();
            assert_eq!(data.len(), expected.len());
            for (key, value) in expected {
                let want = if key == "user_id" && value.as_i64() == Some(1) {
                    Some(42.0)
                } else {
                    value.as_f64()
                };
                assert_eq!(data[key].as_f64(), want, "{key}, {}", scenario["id"]);
            }
        }
        assert!(body["meta"].is_null());
    }
}
