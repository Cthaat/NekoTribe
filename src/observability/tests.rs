use super::*;
use crate::{app::routes::build_router, cache::redis::RedisPool, config::env::AppConfig};
use axum::{body::Body, http::Request};
use http_body_util::BodyExt;
use tower::ServiceExt;
use uuid::Uuid;

fn build(token: Option<&str>) -> Router {
    let config = AppConfig::native_from_lookup(|key| match key {
        "METRICS_TOKEN" => token.map(str::to_owned),
        "ACCESS_SECRET"
        | "REFRESH_SECRET"
        | "ORACLE_SERVICE_NAME"
        | "ORACLE_USER"
        | "ORACLE_PASSWORD" => Some("isolated-fixture".into()),
        "ORACLE_HOST" => Some("no-oracle.example.test".into()),
        "CORS_ALLOWED_ORIGINS" => Some("https://browser.example.test".into()),
        _ => None,
    })
    .unwrap();
    build_router(config)
}

#[test]
fn metric_families_are_bounded_and_histograms_are_cumulative() {
    let m = Metrics::default();
    let unknown = Method::from_bytes(b"UNBOUNDED_INPUT").unwrap();
    m.http(&Method::GET, StatusCode::OK, Duration::from_millis(3));
    m.http(&Method::GET, StatusCode::OK, Duration::from_millis(21));
    m.http(&unknown, StatusCode::NOT_FOUND, Duration::from_secs(12));
    for cache in [CacheResult::Hit, CacheResult::Miss, CacheResult::Degraded] {
        m.cache(cache);
    }
    m.ai(
        "image_description",
        AiResult::Success,
        false,
        Duration::from_millis(3),
    );
    m.ai(
        "image_description",
        AiResult::Failure,
        true,
        Duration::from_millis(80),
    );
    m.ai(
        "image_description",
        AiResult::Cancelled,
        false,
        Duration::from_secs(15),
    );
    m.ai(
        "untrusted-operation",
        AiResult::Success,
        false,
        Duration::from_secs(12),
    );
    let oracle = m.oracle_connection();
    let socket1 = m.socket();
    let socket2 = m.socket();
    let room1 = m.room(4000);
    let room2 = m.room(4000);
    let room3 = m.room(4001);
    let output = m.render();
    for (name, metric) in &contract().metric_families {
        assert!(output.contains(&format!("# TYPE {name} {}", metric.kind)));
    }
    for suffix in [
        "http_requests_total{method=\"OTHER\",status=\"404\"} 1",
        "http_request_duration_seconds_bucket{method=\"GET\",status=\"200\",le=\"0.005\"} 1",
        "http_request_duration_seconds_bucket{method=\"GET\",status=\"200\",le=\"0.025\"} 2",
        "http_request_duration_seconds_bucket{method=\"GET\",status=\"200\",le=\"+Inf\"} 2",
        "http_request_duration_seconds_count{method=\"GET\",status=\"200\"} 2",
        "oracle_pool_connections{state=\"open\"} 1",
        "oracle_pool_connections{state=\"in_use\"} 1",
        "redis_operations_total{result=\"hit\"} 1",
        "redis_operations_total{result=\"miss\"} 1",
        "redis_operations_total{result=\"degraded\"} 1",
        "ai_requests_total{operation=\"image_description\",result=\"success\"} 1",
        "ai_requests_total{operation=\"image_description\",result=\"failure\"} 1",
        "ai_requests_total{operation=\"image_description\",result=\"cancelled\"} 1",
        "ai_quota_rejections_total{operation=\"image_description\"} 1",
        "websocket_connections 2",
        "websocket_channels 2",
    ] {
        let expected = format!("nekotribe_{suffix}\n");
        assert!(output.contains(&expected), "missing {expected}");
    }
    let sum: f64 = output
        .lines()
        .find_map(|line| {
            line.strip_prefix(
                "nekotribe_http_request_duration_seconds_sum{method=\"GET\",status=\"200\"} ",
            )
        })
        .unwrap()
        .parse()
        .unwrap();
    assert!((sum - 0.024).abs() < 0.000_001);
    for denied in ["UNBOUNDED_INPUT", "untrusted-operation", "4001"] {
        assert!(!output.contains(denied));
    }
    drop(room1);
    assert!(m.render().contains("nekotribe_websocket_channels 2"));
    drop((oracle, room2, room3));
    let output = m.render();
    assert!(output.contains("nekotribe_oracle_pool_connections{state=\"open\"} 0"));
    assert!(output.contains("nekotribe_websocket_connections 2"));
    assert!(output.contains("nekotribe_websocket_channels 0"));
    drop((socket1, socket2));
    assert!(m.render().contains("nekotribe_websocket_connections 0"));
}

async fn call(
    app: &Router,
    method: Method,
    uri: &str,
    headers: &[(&'static str, &'static str)],
) -> Response {
    let mut request = Request::builder().method(method).uri(uri);
    for (key, value) in headers {
        request = request.header(*key, *value);
    }
    app.clone()
        .oneshot(request.body(Body::empty()).unwrap())
        .await
        .unwrap()
}

async fn text(response: Response) -> String {
    String::from_utf8(
        response
            .into_body()
            .collect()
            .await
            .unwrap()
            .to_bytes()
            .to_vec(),
    )
    .unwrap()
}

#[tokio::test]
async fn native_router_scrape_authorization_and_exclusion() {
    let app = build(None);
    let response = call(&app, Method::GET, "/metrics", &[]).await;
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
    assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
    let app = build(Some("test-scrape-secret"));
    for headers in [
        vec![],
        vec![("authorization", "Bearer incorrect")],
        vec![
            ("authorization", "Bearer test-scrape-secret"),
            ("authorization", "Bearer test-scrape-secret"),
        ],
    ] {
        let response = call(&app, Method::GET, "/metrics", &headers).await;
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
        assert!(text(response).await.is_empty());
    }
    let auth = [("authorization", "Bearer test-scrape-secret")];
    let response = call(&app, Method::GET, "/metrics", &auth).await;
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response.headers()[header::CONTENT_TYPE],
        contract().content_type
    );
    assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
    assert!(response.headers().contains_key("x-request-id"));
    let initial = text(response).await;
    assert!(!initial.contains("test-scrape-secret"));
    let http = |output: &str| {
        output
            .lines()
            .filter(|line| line.contains("nekotribe_http_"))
            .map(str::to_owned)
            .collect::<Vec<_>>()
    };
    let second = text(call(&app, Method::GET, "/metrics", &auth).await).await;
    // Other tests may run native requests concurrently, but scrapes never add a GET/200 series.
    assert!(!http(&initial)
        .iter()
        .any(|line| line.contains("method=\"GET\",status=\"200\"")));
    assert!(!http(&second)
        .iter()
        .any(|line| line.contains("method=\"GET\",status=\"200\"")));
}

#[tokio::test]
async fn native_router_correlates_preflight_errors_and_well_formed_headers() {
    let app = build(Some("test-scrape-secret"));
    let callback = call(
        &app,
        Method::GET,
        "/api/v2/auth/oauth/github/callback?state=not-a-valid-state&code=raw-field",
        &[
            ("x-request-id", "trace:Client-4.5"),
            ("origin", "https://browser.example.test"),
        ],
    )
    .await;
    assert_eq!(callback.status(), StatusCode::BAD_REQUEST);
    assert_eq!(callback.headers()["x-request-id"], "trace:Client-4.5");
    assert_eq!(callback.headers()["referrer-policy"], "no-referrer");
    let exposed = callback.headers()["access-control-expose-headers"]
        .to_str()
        .unwrap();
    for header in [
        "x-request-id",
        "Retry-After",
        "RateLimit-Limit",
        "RateLimit-Remaining",
        "RateLimit-Reset",
    ] {
        assert!(exposed.split(',').any(|h| h.eq_ignore_ascii_case(header)));
    }
    let preflight = call(
        &app,
        Method::OPTIONS,
        "/api/v2/posts",
        &[
            ("origin", "https://browser.example.test"),
            ("access-control-request-method", "GET"),
            ("access-control-request-headers", "x-request-id"),
            ("x-request-id", "before:main"),
        ],
    )
    .await;
    assert_eq!(preflight.status(), StatusCode::NO_CONTENT);
    assert_eq!(preflight.headers()["x-request-id"], "before:main");
    let (duplicate, invalid) = tokio::join!(
        call(
            &app,
            Method::GET,
            "/observability-missing",
            &[("x-request-id", "one"), ("x-request-id", "two")]
        ),
        call(
            &app,
            Method::GET,
            "/observability-missing",
            &[("x-request-id", "first second")]
        ),
    );
    let duplicated =
        Uuid::parse_str(duplicate.headers()["x-request-id"].to_str().unwrap()).unwrap();
    let invalid = Uuid::parse_str(invalid.headers()["x-request-id"].to_str().unwrap()).unwrap();
    assert_eq!(duplicated.get_version_num(), 4);
    assert_eq!(invalid.get_version_num(), 4);
    assert_ne!(duplicated, invalid);
    let rendered = text(
        call(
            &app,
            Method::GET,
            "/metrics",
            &[("authorization", "Bearer test-scrape-secret")],
        )
        .await,
    )
    .await;
    for value in [
        "trace:Client",
        "before:main",
        "observability-missing",
        "raw-field",
    ] {
        assert!(!rendered.contains(value));
    }
    assert!(rendered.contains("nekotribe_http_requests_total{method=\"GET\",status=\"400\"}"));
    assert!(rendered.contains("nekotribe_http_requests_total{method=\"OPTIONS\",status=\"204\"}"));
}

#[tokio::test]
async fn failed_redis_cache_read_reports_degraded_without_connecting() {
    let read = |output: &str| -> u64 {
        output
            .lines()
            .find_map(|line| {
                line.strip_prefix("nekotribe_redis_operations_total{result=\"degraded\"} ")
            })
            .unwrap()
            .parse()
            .unwrap()
    };
    let before = read(&metrics().render());
    assert!(RedisPool::degraded("isolated Redis fixture")
        .get("sensitive-cache-key")
        .await
        .is_err());
    let after = metrics().render();
    assert!(read(&after) > before);
    assert!(!after.contains("sensitive-cache-key"));
}
