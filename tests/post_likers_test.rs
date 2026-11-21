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
use serde_json::{json, Value};
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};
use tower::ServiceExt;

struct Executor(Arc<AtomicUsize>);

impl SessionExecutor for Executor {
    fn execute(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, u64> {
        assert_eq!(sql, TOUCH_SQL);
        assert_eq!(binds["user_id"], DbValue::I64(42));
        Box::pin(async { Ok(1) })
    }

    fn preflight(&self, _: &'static str) -> StoreFuture<'_, ()> {
        Box::pin(async { Ok(()) })
    }

    fn query(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
        self.0.fetch_add(1, Ordering::Relaxed);
        let shared: Value =
            serde_json::from_str(include_str!("../contracts/requirements/post-likers.json"))
                .unwrap();
        assert_eq!(Some(sql), shared["list"].as_str());
        assert_eq!(binds["viewer_id"], DbValue::I64(42));
        assert_eq!(binds.len(), 4);
        let row = |user, total| {
            DbRow::from([
                ("USER_ID".into(), DbValue::I64(user)),
                ("USERNAME".into(), DbValue::String("liker".into())),
                ("RELATION".into(), DbValue::String("none".into())),
                ("TOTAL".into(), DbValue::I64(total)),
            ])
        };
        let rows = match (&binds["post_id"], &binds["start_row"], &binds["end_row"]) {
            (DbValue::I64(1), DbValue::F64(1.0), DbValue::F64(2.0)) => vec![row(8, 3), row(7, 3)],
            (DbValue::I64(1), DbValue::F64(3.0), DbValue::F64(4.0)) => vec![row(9, 3)],
            (DbValue::I64(1), DbValue::F64(5.0), DbValue::F64(6.0)) => vec![row(0, 3)],
            (DbValue::I64(4), DbValue::F64(1.0), DbValue::F64(20.0)) => vec![row(0, 0)],
            (DbValue::I64(2 | 6 | 999), _, _) => vec![],
            _ => panic!("unexpected page binds: {binds:?}"),
        };
        Box::pin(async move { Ok(rows) })
    }
}

#[tokio::test]
async fn shared_post_likers_scenarios_use_native_repository() {
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
    let spec: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/post-likers.json")).unwrap();
    for scenario in spec["cases"].as_array().unwrap() {
        let mut request = Request::builder()
            .method(scenario["method"].as_str().unwrap())
            .uri(scenario["path"].as_str().unwrap());
        if scenario["anonymous"] != true {
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
            usize::from(status == 200 || status == 404)
        );
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        let body: Value = serde_json::from_slice(&bytes).unwrap();
        if status == 200 {
            let ids: Vec<_> = body["data"]
                .as_array()
                .unwrap()
                .iter()
                .map(|user| user["user_id"].clone())
                .collect();
            assert_eq!(json!(ids), scenario["ids"]);
            for key in ["page", "page_size", "total"] {
                assert_eq!(body["meta"][key].as_f64(), scenario["meta"][key].as_f64());
            }
            assert_eq!(body["meta"]["has_next"], scenario["meta"]["has_next"]);
        } else {
            assert_eq!(body["code"], (u32::from(status) * 100 + 1));
        }
    }
}
