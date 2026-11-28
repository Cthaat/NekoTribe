use super::*;
use crate::auth::login::resolve_ip;
use axum::{
    extract::ConnectInfo,
    http::{Extensions, HeaderMap},
};
use axum::{routing::get, Extension, Router};
use http_body_util::BodyExt;
use serde_json::Value;
use std::net::SocketAddr;
use tower::ServiceExt;

fn cases() -> Vec<Value> {
    let source = include_str!("../../contracts/scenarios/b0-1-rate-limit.json");
    let vectors: Value = serde_json::from_str(source).unwrap();
    vectors["cases"].as_array().unwrap().clone()
}

fn request(case: &Value) -> (&str, &str) {
    case["input"]["request"]
        .as_str()
        .unwrap()
        .split_once(' ')
        .unwrap()
}

#[test]
fn shared_route_budgets_and_exclusions() {
    for case in cases() {
        let Some(expected) = case["expect"]["tier"].as_str() else {
            continue;
        };
        let (method, uri) = request(&case);
        let path = uri.split('?').next().unwrap().replace("/c1/", "/{id}/");
        let tier = Tier::classify(&method.parse().unwrap(), &path).unwrap();
        let (name, limit, seconds) = tier.defaults();
        assert_eq!(name, expected);
        assert_eq!(case["expect"]["limit"], limit);
        assert_eq!(case["expect"]["windowSeconds"], seconds);
    }
    for path in [
        "/api/ready",
        "/metrics",
        "/_ws",
        "/api/v2/integrations/sentiment-flow/{*path}",
    ] {
        assert_eq!(Tier::classify(&Method::POST, path), None);
    }
    assert_eq!(Tier::classify(&Method::OPTIONS, "/api/v2/media"), None);
    assert_eq!(
        Tier::classify(&Method::GET, "/api/v2/users/me/two-factor"),
        Some(Tier::Read)
    );
}

#[test]
fn socket_and_trusted_proxy_use_canonical_addresses() {
    let mut headers = HeaderMap::new();
    let mut ext = Extensions::new();
    ext.insert(ConnectInfo(
        "[::ffff:192.0.2.8]:1234".parse::<SocketAddr>().unwrap(),
    ));
    headers.insert(
        "x-forwarded-for",
        "2001:0DB8::1, 192.0.2.1".parse().unwrap(),
    );
    assert_eq!(resolve_ip(&headers, &ext, false), "192.0.2.8");
    assert_eq!(resolve_ip(&headers, &ext, true), "2001:db8::1");
    headers.insert("x-forwarded-for", "arbitrary".parse().unwrap());
    assert_eq!(resolve_ip(&headers, &ext, true), "192.0.2.8");
    assert_eq!(resolve_ip(&headers, &Extensions::new(), true), "unknown");
}

#[tokio::test]
async fn rejection_matches_wire_vectors() {
    for case in cases()
        .into_iter()
        .filter(|c| matches!(c["id"].as_str(), Some("tier-rejection" | "head-rejection")))
    {
        let (method, path) = request(&case);
        let mut res = rejection(&method.parse().unwrap(), path);
        let ttl = case["input"]["ttlMs"].as_u64().unwrap();
        budget_headers(&mut res, false, 100, 0, ttl);
        assert_eq!(res.status(), 429);
        for (name, value) in case["expect"]["headers"].as_object().unwrap() {
            assert_eq!(res.headers()[name].to_str().unwrap(), value.to_string());
        }
        let body = res.into_body().collect().await.unwrap().to_bytes();
        if method == "HEAD" {
            assert!(body.is_empty());
            continue;
        }
        let outer: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(outer["url"], path);
        assert_eq!(outer["statusCode"], 429);
        assert_eq!(outer["error"], true);
        let data = &outer["data"];
        assert_eq!(data["code"], 42901);
        assert!(!data["message"].as_str().unwrap().is_empty());
        assert_eq!(data.as_object().unwrap().len(), 4);
        assert_eq!(data.get("data"), Some(&Value::Null));
        assert_eq!(data.get("meta"), Some(&Value::Null));
    }
}

#[cfg(unix)]
#[tokio::test]
#[ignore = "requires a dedicated, empty Redis instance at B01_TEST_REDIS_SOCKET"]
async fn redis_window_routes_and_concurrency() {
    let socket = std::env::var("B01_TEST_REDIS_SOCKET").expect("dedicated empty Redis Unix socket");
    let client = redis::Client::open(format!("unix://{socket}")).unwrap();
    let store = Admission::new(client.clone()).unwrap();
    let mut jobs = tokio::task::JoinSet::new();
    let race = cases()
        .into_iter()
        .find(|case| case["id"] == "shared-race")
        .unwrap();
    let backends = race["input"]["parallelPerBackend"].as_object().unwrap();
    for count in backends.values() {
        let instance = Admission::new(client.clone()).unwrap();
        for _ in 0..count.as_u64().unwrap() {
            let instance = instance.clone();
            jobs.spawn(async move { instance.reserve(Tier::Auth, "192.0.2.8").await.unwrap().0 });
        }
    }
    let mut accepted = 0;
    while let Some(job) = jobs.join_next().await {
        accepted += u32::from(job.unwrap());
    }
    assert_eq!(race["expect"]["admitted"], accepted);
    let mut conn = client.get_multiplexed_async_connection().await.unwrap();
    let key = "neko:v2:admission:1:read:unknown";
    use redis::AsyncCommands;
    let _: () = conn.pset_ex(key, 99, 4000).await.unwrap();
    let app = Router::new()
        .route("/api/v2/posts", get(|| async { "side effect" }))
        .route_layer(axum::middleware::from_fn(admit))
        .layer(Extension(store));
    let call = |method| {
        let request = Request::builder()
            .method(method)
            .uri("/api/v2/posts?q=unused");
        app.clone().oneshot(request.body(Body::empty()).unwrap())
    };
    let last = call("GET").await.unwrap();
    assert_eq!(last.status(), 200);
    assert_eq!(last.headers()["ratelimit-remaining"], "0");
    for method in ["GET", "HEAD"] {
        let denied = call(method).await.unwrap();
        assert_eq!(denied.status(), 429);
        let reset = &denied.headers()["ratelimit-reset"];
        let seconds: u64 = reset.to_str().unwrap().parse().unwrap();
        assert!((1..=4).contains(&seconds));
        assert_eq!(&denied.headers()["retry-after"], reset);
    }
    let used: u32 = redis::cmd("GET")
        .arg(key)
        .query_async(&mut conn)
        .await
        .unwrap();
    assert_eq!(used, 100);
    let _: bool = conn.pexpire(key, 5).await.unwrap();
    tokio::time::sleep(Duration::from_millis(30)).await;
    let fresh = call("GET").await.unwrap();
    assert_eq!(fresh.headers()["ratelimit-remaining"], "99");
}
