use axum::{body::Body, http::Request};
use http_body_util::BodyExt;
use nekotribe_backend::auth::{
    session_repository::{OracleSessions, SessionExecutor},
    session_list::{session_pagination, SessionItem, SessionPage},
    sessions::{
        build_native_router, CorsPolicy, SessionRepository, SessionStoreError, StoreFuture,
    },
    TokenClaims, TokenCodec,
};
use nekotribe_backend::db::{oracle::BindMap, row::DbRow, value::DbValue};
use serde_json::{json, Value};
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};
use tower::ServiceExt;

struct EmptyPageExecutor(AtomicUsize);

impl SessionExecutor for EmptyPageExecutor {
    fn execute(&self, _: &'static str, _: BindMap) -> StoreFuture<'_, u64> {
        panic!("session listing cannot write");
    }

    fn preflight(&self, _: &'static str) -> StoreFuture<'_, ()> {
        panic!("session listing should issue only its read query");
    }

    fn query(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
        Box::pin(async move {
            self.0.fetch_add(1, Ordering::SeqCst);
            assert!(sql.contains("WHERE user_id = :user_id AND revoked_at IS NULL"));
            assert!(sql.contains("ORDER BY last_accessed_at DESC, session_id ASC"));
            assert!(sql.contains("LEFT JOIN eligible e ON e.rn BETWEEN :start_row AND :end_row"));
            assert!(sql.ends_with("ORDER BY e.rn"));
            assert_eq!(binds["user_id"], DbValue::I64(42));
            assert_eq!(binds["start_row"], DbValue::F64(10.0));
            assert_eq!(binds["end_row"], DbValue::F64(10.0));
            Ok(vec![DbRow::from([
                ("TOTAL".into(), DbValue::I64(3)),
                ("SESSION_ID".into(), DbValue::Null),
            ])])
        })
    }
}

#[tokio::test]
async fn session_repository_keeps_total_for_an_empty_page() {
    let repository = OracleSessions {
        executor: EmptyPageExecutor(AtomicUsize::new(0)),
    };
    let (sessions, total) = repository
        .list_sessions(42, session_pagination("page=10&page_size=1"))
        .await
        .unwrap();
    assert!(sessions.is_empty());
    assert_eq!(total, 3);
    assert_eq!(repository.executor.0.load(Ordering::SeqCst), 1);
}

#[test]
fn shared_session_pagination() {
    let f: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/auth-session-pagination.json"
    ))
    .unwrap();
    let cases = f["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 16);
    for case in cases {
        let p = session_pagination(case["query"].as_str().unwrap());
        for (name, actual) in [
            ("page", p.page),
            ("page_size", p.page_size),
            ("start", p.start),
            ("end", p.end),
        ] {
            assert_eq!(
                actual,
                case[name].as_f64().unwrap(),
                "{} {name}",
                case["id"]
            );
        }
    }
}

struct Fake {
    calls: AtomicUsize,
    fail: bool,
}
impl SessionRepository for Fake {
    fn touch<'a>(&'a self, _: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(1) })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn list_sessions<'a>(
        &'a self,
        user: u64,
        page: SessionPage,
    ) -> StoreFuture<'a, (Vec<SessionItem>, u64)> {
        Box::pin(async move {
            self.calls.fetch_add(1, Ordering::SeqCst);
            assert_eq!(user, 42);
            assert_eq!(page.start, 2.0);
            if self.fail {
                return Err(SessionStoreError);
            };
            Ok((
                vec![SessionItem {
                    session_id: "fixture-session-42".into(),
                    device_info: "device".into(),
                    ip_address: "127.0.0.1".into(),
                    last_accessed_at: "2026-01-01T00:00:00.000Z".into(),
                    created_at: String::new(),
                    is_current: false,
                }],
                3,
            ))
        })
    }
}
#[tokio::test]
async fn authenticated_list_and_failure() {
    let f: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = f["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    for (auth, bad_cookie, fail, status, calls) in [
        (true, false, false, 200, 1),
        (false, false, false, 401, 0),
        (true, true, false, 401, 0),
        (true, false, true, 500, 1),
    ] {
        let repo = Arc::new(Fake {
            calls: AtomicUsize::new(0),
            fail,
        });
        let codec = TokenCodec::new(
            f["keys"]["access"].as_str().unwrap().as_bytes(),
            f["keys"]["refresh"].as_str().unwrap().as_bytes(),
        )
        .unwrap();
        let app = build_native_router(
            codec,
            repo.clone(),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
        );
        let mut request = Request::builder().uri("/api/v2/auth/sessions?page=2&page_size=1");
        if auth {
            request = request.header("authorization", format!("Bearer {token}"));
        }
        if bad_cookie {
            request = request.header("cookie", "access_token=bad");
        }
        let response = app
            .oneshot(request.body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), status);
        assert_eq!(repo.calls.load(Ordering::SeqCst), calls);
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        let body: Value = serde_json::from_slice(&bytes).unwrap();
        if status == 200 {
            assert_eq!(body["data"][0]["is_current"], true);
            assert_eq!(
                body["meta"],
                json!({"page":2.0,"page_size":1.0,"total":3,"has_next":true})
            );
        }
    }
}
