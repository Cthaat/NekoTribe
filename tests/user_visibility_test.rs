use axum::{body::Body, http::Request};
use http_body_util::BodyExt;
use nekotribe_backend::{
    auth::{
        session_list::SessionPage,
        sessions::{
            build_native_router, CorsPolicy, SessionRepository, SessionStoreError, StoreFuture,
        },
        TokenClaims, TokenCodec,
    },
    users::{discovery::DiscoveryQuery, follow::FollowOutcome, visibility::Kind},
};
use serde_json::{json, Value};
use std::sync::{
    atomic::{AtomicBool, AtomicUsize, Ordering},
    Arc, Mutex,
};
use tower::ServiceExt;

#[derive(Default)]
struct Store {
    following: AtomicBool,
    notices: AtomicUsize,
    discovery: Mutex<Option<DiscoveryQuery>>,
}

impl SessionRepository for Store {
    fn discover_users(
        &self,
        viewer: u64,
        query: DiscoveryQuery,
    ) -> StoreFuture<'_, (Vec<Value>, i64)> {
        Box::pin(async move {
            assert_eq!(viewer, 42);
            let empty = matches!(&query, DiscoveryQuery::Search { page, .. } if page.start > 8.0);
            *self.discovery.lock().unwrap() = Some(query);
            Ok((
                if empty {
                    vec![]
                } else {
                    vec![json!({"user_id":7,"avatar_url":""})]
                },
                8,
            ))
        })
    }
    fn list_user_follows(
        &self,
        viewer: u64,
        target: u64,
        _: &'static str,
        page: SessionPage,
    ) -> StoreFuture<'_, (Vec<Value>, i64)> {
        Box::pin(async move {
            if viewer != 42 || target != 9 || page.start != 3.0 {
                return Err(SessionStoreError);
            }
            Ok((vec![], 2))
        })
    }
    fn write_user_follow(
        &self,
        _: u64,
        target: u64,
        remove: bool,
    ) -> StoreFuture<'_, FollowOutcome> {
        Box::pin(async move {
            Ok(match target {
                7 => FollowOutcome::Blocked,
                81 if !remove => FollowOutcome::Missing,
                _ => {
                    let already = self.following.swap(!remove, Ordering::SeqCst);
                    FollowOutcome::Applied {
                        count: i64::from(!remove),
                        inserted: !remove && !already,
                    }
                }
            })
        })
    }
    fn prepare_follow_notification(&self, actor: u64, target: u64) -> StoreFuture<'_, Option<u64>> {
        Box::pin(async move {
            assert_eq!((actor, target), (42, 9));
            assert!(self.following.load(Ordering::SeqCst));
            self.notices.fetch_add(1, Ordering::SeqCst);
            Ok(None)
        })
    }
    fn touch<'a>(&'a self, _: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(1) })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn list_user_visibility(
        &self,
        viewer: u64,
        _: Kind,
        page: SessionPage,
    ) -> StoreFuture<'_, (Vec<Value>, i64)> {
        Box::pin(async move {
            if viewer != 42 || page.start != 3.0 || page.end != 4.0 {
                return Err(SessionStoreError);
            }
            Ok((vec![], 2))
        })
    }
    fn write_user_visibility(
        &self,
        viewer: u64,
        target: u64,
        _: Kind,
        remove: bool,
        _: Option<String>,
    ) -> StoreFuture<'_, bool> {
        Box::pin(async move {
            if viewer != 42 {
                return Err(SessionStoreError);
            }
            Ok(remove || target == 9)
        })
    }
}

#[tokio::test]
async fn shared_visibility_routes() {
    run_cases(include_str!("../contracts/scenarios/user-visibility.json")).await;
}

#[tokio::test]
async fn shared_follow_routes() {
    run_cases(include_str!("../contracts/scenarios/user-follow.json")).await;
}

#[tokio::test]
async fn shared_discovery_routes() {
    run_cases(include_str!("../contracts/scenarios/user-discovery.json")).await;
}

async fn run_cases(vectors: &str) {
    let tokens: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let codec = TokenCodec::new(
        tokens["keys"]["access"].as_str().unwrap().as_bytes(),
        tokens["keys"]["refresh"].as_str().unwrap().as_bytes(),
    )
    .unwrap();
    let token = tokens["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    let store = Arc::new(Store::default());
    let app = build_native_router(
        codec,
        store.clone(),
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_000),
    );
    let vectors: Value = serde_json::from_str(vectors).unwrap();
    let discovery = vectors["id"] == "USER-DISCOVERY";
    for case in vectors["cases"].as_array().unwrap() {
        let mut request = Request::builder()
            .method(case["method"].as_str().unwrap_or("GET"))
            .uri(case["path"].as_str().unwrap());
        if case["id"] != "anonymous" && case["id"] != "unauthenticated" {
            request = request.header("authorization", format!("Bearer {token}"));
        }
        let body = if let Some(body) = case.get("body") {
            request = request.header("content-type", "application/json");
            Body::from(body.to_string())
        } else {
            Body::empty()
        };
        let before = store.notices.load(Ordering::SeqCst);
        let response = app
            .clone()
            .oneshot(request.body(body).unwrap())
            .await
            .unwrap();
        assert_eq!(
            response.status().as_u16(),
            case["status"].as_u64().unwrap() as u16,
            "{}",
            case["id"]
        );
        assert_eq!(
            store.notices.load(Ordering::SeqCst) - before,
            usize::from(case["notify"] == true)
        );
        if case["status"] != 200 {
            if discovery {
                assert!(store.discovery.lock().unwrap().take().is_none());
            }
            continue;
        }
        assert_eq!(response.headers()["cache-control"], "private, no-store");
        let payload: Value =
            serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes())
                .unwrap();
        if discovery {
            let meta = case["meta"].as_object().unwrap();
            assert_eq!(payload["meta"].as_object().unwrap().len(), meta.len());
            for (key, expected) in meta {
                let actual = &payload["meta"][key];
                if expected.is_number() {
                    assert_eq!(actual.as_f64(), expected.as_f64(), "{} / {key}", case["id"]);
                } else {
                    assert_eq!(actual, expected, "{} / {key}", case["id"]);
                }
            }
            assert_eq!(
                payload["data"].as_array().unwrap().len(),
                usize::from(case["empty"] != true)
            );
            match store.discovery.lock().unwrap().take().unwrap() {
                DiscoveryQuery::Recommendations { limit } => {
                    assert_eq!(Some(limit), case["meta"]["limit"].as_f64())
                }
                DiscoveryQuery::Search {
                    pattern,
                    sort,
                    verified_only,
                    ..
                } => {
                    assert_eq!(Some(pattern.as_str()), case["pattern"].as_str());
                    assert_eq!(Some(sort), case["sort"].as_str());
                    assert_eq!(Some(verified_only), case["verified"].as_i64());
                }
            }
        } else if case["method"] == "GET" {
            assert_eq!(payload["data"], json!([]));
            assert_eq!(
                payload["meta"],
                json!({"page":2.0,"page_size":2.0,"total":2,"has_next":false})
            );
        } else {
            assert_eq!(payload["data"]["relationship"], case["relationship"]);
            assert_eq!(payload["data"].get("expires_at"), case.get("expires_at"));
            assert_eq!(payload["data"].get("followers_count"), case.get("count"));
        }
    }
}
