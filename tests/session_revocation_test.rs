use nekotribe_backend::auth::{
    sessions::{
        build_native_router, CorsPolicy, SessionRepository, SessionStoreError, StoreFuture,
    },
    TokenClaims, TokenCodec,
};
use serde::Deserialize;
use serde_json::Value;
use std::sync::{Arc, Mutex};

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Session {
    session_id: String,
    user_id: u64,
    access_jti: String,
    access_expires_at: u64,
    revoked_at: Option<u64>,
    last_accessed_at: u64,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Scenario {
    id: String,
    sessions: Vec<Session>,
    fault: Option<String>,
    requests: Vec<FixtureRequest>,
    expected_touches: usize,
    expected_revokes: usize,
    expected_revoked_session_ids: Vec<String>,
    expected_touched_session_ids: Vec<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FixtureRequest {
    method: String,
    path: String,
    headers: std::collections::BTreeMap<String, String>,
    #[serde(default)]
    cookie_fields: Vec<String>,
    expected_status: u16,
    expected_envelope: Option<Value>,
    expected_cleared_cookies: Vec<String>,
}
#[derive(Deserialize)]
struct Fixture {
    now: u64,
    keys: Keys,
    cases: Vec<Scenario>,
}
#[derive(Deserialize)]
struct Keys {
    access: String,
    refresh: String,
}
struct Memory {
    rows: Vec<Session>,
    now: u64,
    fault: Option<String>,
    touches: usize,
    revokes: usize,
}
struct Repository(Mutex<Memory>);
impl SessionRepository for Repository {
    fn touch<'a>(&'a self, c: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async move {
            let mut s = self.0.lock().unwrap();
            s.touches += 1;
            if s.fault.as_deref() == Some("touch") {
                return Err(SessionStoreError);
            };
            let now = s.now;
            for r in &mut s.rows {
                if r.user_id == c.user_id
                    && r.session_id == c.session_id
                    && r.access_jti == c.jti
                    && r.revoked_at.is_none()
                    && r.access_expires_at > now
                {
                    r.last_accessed_at = now;
                    return Ok(1);
                }
            }
            Ok(0)
        })
    }
    fn revoke<'a>(&'a self, u: u64, id: &'a str) -> StoreFuture<'a, u64> {
        self.revoke_rows(u, id, false)
    }
    fn revoke_others<'a>(&'a self, u: u64, id: &'a str) -> StoreFuture<'a, u64> {
        self.revoke_rows(u, id, true)
    }
}
impl Repository {
    fn revoke_rows<'a>(&'a self, u: u64, id: &'a str, others: bool) -> StoreFuture<'a, u64> {
        Box::pin(async move {
            let mut s = self.0.lock().unwrap();
            s.revokes += 1;
            if s.fault.as_deref() == Some("revoke") {
                return Err(SessionStoreError);
            };
            let now = s.now;
            let mut n = 0;
            for r in &mut s.rows {
                if r.user_id == u
                    && r.revoked_at.is_none()
                    && if others {
                        r.session_id != id
                    } else {
                        r.session_id == id
                    }
                {
                    r.revoked_at = Some(now);
                    n += 1
                }
            }
            Ok(n)
        })
    }
}
fn fixture() -> Fixture {
    serde_json::from_str(include_str!(
        "../contracts/scenarios/auth-session-revocation.json"
    ))
    .unwrap()
}
async fn serve(
    router: axum::Router,
) -> (
    String,
    tokio::sync::oneshot::Sender<()>,
    tokio::task::JoinHandle<()>,
) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let (tx, rx) = tokio::sync::oneshot::channel();
    let task = tokio::spawn(async move {
        axum::serve(listener, router)
            .with_graceful_shutdown(async {
                let _ = rx.await;
            })
            .await
            .unwrap()
    });
    (base, tx, task)
}
#[tokio::test]
async fn shared_http_jwt_session_scenarios() {
    let f = fixture();
    let now = f.now;
    for s in f.cases {
        let repo = Arc::new(Repository(Mutex::new(Memory {
            rows: s.sessions,
            now,
            fault: s.fault,
            touches: 0,
            revokes: 0,
        })));
        let codec = TokenCodec::new(f.keys.access.as_bytes(), f.keys.refresh.as_bytes()).unwrap();
        let router = build_native_router(
            codec,
            repo.clone(),
            CorsPolicy::default(),
            Arc::new(move || now),
        );
        let (base, stop, task) = serve(router).await;
        let client = reqwest::Client::new();
        for r in s.requests {
            let mut req = client.request(r.method.parse().unwrap(), format!("{base}{}", r.path));
            for (k, v) in r.headers {
                req = req.header(k, v)
            }
            for value in r.cookie_fields {
                req = req.header("Cookie", value)
            }
            let response = req.send().await.unwrap();
            assert_eq!(
                response.status().as_u16(),
                r.expected_status,
                "{} {}",
                s.id,
                r.path
            );
            let mut cleared = Vec::new();
            for c in response.headers().get_all("set-cookie") {
                let c = c.to_str().unwrap();
                assert!(
                    c.contains("Max-Age=0") && c.contains("Path=/"),
                    "{} {c}",
                    s.id
                );
                cleared.push(c.split('=').next().unwrap().to_owned())
            }
            cleared.sort();
            let mut expected = r.expected_cleared_cookies;
            expected.sort();
            assert_eq!(cleared, expected, "{}", s.id);
            let body: Value = response.json().await.unwrap();
            if let Some(expected) = r.expected_envelope {
                assert_eq!(body, expected, "{}", s.id)
            } else {
                assert_eq!(body["code"], 50001);
                assert!(!body.to_string().contains("private"))
            }
        }
        let state = repo.0.lock().unwrap();
        assert_eq!(
            (state.touches, state.revokes),
            (s.expected_touches, s.expected_revokes),
            "{}",
            s.id
        );
        let mut revoked: Vec<_> = state
            .rows
            .iter()
            .filter(|r| r.revoked_at.is_some())
            .map(|r| r.session_id.clone())
            .collect();
        let mut touched: Vec<_> = state
            .rows
            .iter()
            .filter(|r| r.last_accessed_at == now)
            .map(|r| r.session_id.clone())
            .collect();
        revoked.sort();
        touched.sort();
        assert_eq!(revoked, s.expected_revoked_session_ids, "{}", s.id);
        assert_eq!(touched, s.expected_touched_session_ids, "{}", s.id);
        drop(state);
        let _ = stop.send(());
        task.await.unwrap();
    }
}
#[tokio::test]
async fn native_cors_precedes_auth_and_unknown_routes_do_not_proxy() {
    let f = fixture();
    let repo = Arc::new(Repository(Mutex::new(Memory {
        rows: vec![],
        now: f.now,
        fault: None,
        touches: 0,
        revokes: 0,
    })));
    let cors = CorsPolicy {
        origins: vec!["https://app.example".into()],
        localhost: false,
    };
    let router = build_native_router(
        TokenCodec::new(f.keys.access.as_bytes(), f.keys.refresh.as_bytes()).unwrap(),
        repo.clone(),
        cors,
        Arc::new(|| 1700000000),
    );
    let (base, stop, task) = serve(router).await;
    let client = reqwest::Client::new();
    for (origin, method, headers, status) in [
        (
            "https://app.example",
            "DELETE",
            "Authorization,x-device-info,x-request-id",
            204,
        ),
        ("https://evil.example", "DELETE", "", 403),
        ("https://app.example", "TRACE", "", 403),
        ("https://app.example", "DELETE", "x-no", 403),
        ("", "", "", 204),
    ] {
        let r = client
            .request(
                reqwest::Method::OPTIONS,
                format!("{base}/api/v2/auth/sessions/peer"),
            )
            .header("Origin", origin)
            .header("Access-Control-Request-Method", method)
            .header("Access-Control-Request-Headers", headers)
            .send()
            .await
            .unwrap();
        assert_eq!(r.status().as_u16(), status);
        assert!(r.headers()["vary"].to_str().unwrap().contains("Origin"))
    }
    for path in [
        "/storage/file",
        "/uploads/file",
        "/_ws",
        "/api/v2/auth/login",
        "/api/v2/auth/sessions/peer",
    ] {
        let r = client.get(format!("{base}{path}")).send().await.unwrap();
        assert!(r.status().is_client_error())
    }
    let r = client
        .get(format!("{base}/api/health"))
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 200);
    assert_eq!(repo.0.lock().unwrap().touches, 0);
    let _ = stop.send(());
    task.await.unwrap()
}

#[tokio::test]
async fn refresh_without_credentials_is_unauthorized() {
    use axum::{body::Body, http::Request};
    use tower::ServiceExt;
    let f = fixture();
    let repo = Arc::new(Repository(Mutex::new(Memory {
        rows: vec![],
        now: f.now,
        fault: None,
        touches: 0,
        revokes: 0,
    })));
    let router = build_native_router(
        TokenCodec::new(f.keys.access.as_bytes(), f.keys.refresh.as_bytes()).unwrap(),
        repo,
        CorsPolicy::default(),
        Arc::new(move || f.now),
    );
    let response = router
        .oneshot(
            Request::builder()
                .method("PATCH")
                .uri("/api/v2/auth/tokens/current")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), 401);
}

#[tokio::test]
async fn native_actual_cors_ignores_preflight_only_headers() {
    let f = fixture();
    let repo = Arc::new(Repository(Mutex::new(Memory {
        rows: vec![],
        now: f.now,
        fault: None,
        touches: 0,
        revokes: 0,
    })));
    let router = build_native_router(
        TokenCodec::new(f.keys.access.as_bytes(), f.keys.refresh.as_bytes()).unwrap(),
        repo,
        CorsPolicy {
            origins: vec!["https://app.example".into()],
            localhost: false,
        },
        Arc::new(|| 1700000000),
    );
    let (base, stop, task) = serve(router).await;
    let r = reqwest::Client::new()
        .delete(format!("{base}/api/v2/auth/sessions/peer"))
        .header("Origin", "https://app.example")
        .header("Access-Control-Request-Method", "TRACE")
        .header("Access-Control-Request-Headers", "x-disallowed")
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 401);
    assert_eq!(
        r.headers()
            .get("access-control-allow-origin")
            .and_then(|h| h.to_str().ok()),
        Some("https://app.example")
    );
    let _ = stop.send(());
    task.await.unwrap()
}

#[tokio::test]
async fn native_mode_router_has_zero_calls_to_counted_nuxt() {
    use nekotribe_backend::{app::routes::build_router, config::env::AppConfig};
    use std::sync::atomic::{AtomicUsize, Ordering};
    let count = Arc::new(AtomicUsize::new(0));
    let counter = count.clone();
    let upstream = axum::Router::new().fallback(move || {
        let counter = counter.clone();
        async move {
            counter.fetch_add(1, Ordering::SeqCst);
            "unexpected"
        }
    });
    let (upstream_url, upstream_stop, upstream_task) = serve(upstream).await;
    let f = fixture();
    let config = AppConfig::native_from_lookup(|k| match k {
        "ACCESS_SECRET" => Some(f.keys.access.clone()),
        "REFRESH_SECRET" => Some(f.keys.refresh.clone()),
        "ORACLE_HOST" => Some("not-used.invalid".into()),
        "ORACLE_SERVICE_NAME" => Some("unused".into()),
        "ORACLE_USER" => Some("unused".into()),
        "ORACLE_PASSWORD" => Some("unused".into()),
        _ => None,
    })
    .unwrap();
    let mut config = config;
    config.legacy_backend.base_url = upstream_url;
    let (base, stop, task) = serve(build_router(config)).await;
    let client = reqwest::Client::new();
    for path in [
        "/api/v2/auth/login",
        "/api/v2/auth/sessions",
        "/storage/file",
        "/uploads/file",
        "/_ws",
    ] {
        assert_eq!(
            client
                .get(format!("{base}{path}"))
                .send()
                .await
                .unwrap()
                .status(),
            404
        )
    }
    assert_eq!(
        client
            .delete(format!("{base}/api/v2/auth/sessions/peer"))
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    assert_eq!(count.load(Ordering::SeqCst), 0);
    let _ = stop.send(());
    task.await.unwrap();
    let _ = upstream_stop.send(());
    upstream_task.await.unwrap()
}

#[tokio::test]
async fn native_cookie_quotes_and_first_duplicate_match_nuxt() {
    let f = fixture();
    let token = f.cases[0].requests[0]
        .headers
        .get("authorization")
        .unwrap()
        .strip_prefix("Bearer ")
        .unwrap()
        .to_owned();
    let mut actual = Vec::new();
    let mut expected = Vec::new();
    for (cookie, header, status, touches) in [
        (format!("access_token=\"{token}\""), None, 200, 1),
        (format!("access_token=; access_token={token}"), None, 401, 0),
        (
            "access_token=; access_token=invalid".into(),
            Some(token.clone()),
            200,
            1,
        ),
    ] {
        let repo = Arc::new(Repository(Mutex::new(Memory {
            rows: f.cases[0].sessions.clone(),
            now: f.now,
            fault: None,
            touches: 0,
            revokes: 0,
        })));
        let router = build_native_router(
            TokenCodec::new(f.keys.access.as_bytes(), f.keys.refresh.as_bytes()).unwrap(),
            repo.clone(),
            CorsPolicy::default(),
            Arc::new(|| 1700000000),
        );
        let (base, stop, task) = serve(router).await;
        let mut request = reqwest::Client::new()
            .delete(format!("{base}/api/v2/auth/sessions/peer"))
            .header("Cookie", &cookie);
        if let Some(header) = header {
            request = request.header("Authorization", header)
        };
        let response = request.send().await.unwrap();
        let actual_status = response.status().as_u16();
        let message = if actual_status == 401 {
            let body: Value = response.json().await.unwrap();
            Some(body["message"].as_str().unwrap().to_owned())
        } else {
            None
        };
        actual.push((actual_status, repo.0.lock().unwrap().touches, message));
        expected.push((
            status,
            touches,
            if status == 401 {
                Some("请先登录".to_owned())
            } else {
                None
            },
        ));
        let _ = stop.send(());
        task.await.unwrap();
    }
    assert_eq!(
        actual, expected,
        "quoted and duplicate Cookie compatibility"
    );
}

#[tokio::test]
async fn repeated_cookie_fields_preserve_first_name_priority() {
    let f = fixture();
    let token = f.cases[0].requests[0]
        .headers
        .get("authorization")
        .unwrap()
        .strip_prefix("Bearer ")
        .unwrap()
        .to_owned();
    let mut actual = Vec::new();
    let mut expected = Vec::new();
    for (fields, header, status, touches) in [
        (
            vec!["harmless=1".to_owned(), format!("access_token={token}")],
            Some("Bearer invalid".to_owned()),
            200,
            1,
        ),
        (
            vec![
                "harmless=1".to_owned(),
                "access_token=".to_owned(),
                format!("access_token={token}"),
            ],
            None,
            401,
            0,
        ),
        (
            vec![
                "access_token=".to_owned(),
                "access_token=invalid".to_owned(),
            ],
            Some(token.clone()),
            200,
            1,
        ),
        (
            vec![
                "harmless=1".to_owned(),
                "access_token=invalid".to_owned(),
                format!("access_token={token}"),
            ],
            Some(token),
            401,
            0,
        ),
    ] {
        let repo = Arc::new(Repository(Mutex::new(Memory {
            rows: f.cases[0].sessions.clone(),
            now: f.now,
            fault: None,
            touches: 0,
            revokes: 0,
        })));
        let router = build_native_router(
            TokenCodec::new(f.keys.access.as_bytes(), f.keys.refresh.as_bytes()).unwrap(),
            repo.clone(),
            CorsPolicy::default(),
            Arc::new(|| 1700000000),
        );
        let (base, stop, task) = serve(router).await;
        let client = reqwest::Client::new();
        let mut builder = client.delete(format!("{base}/api/v2/auth/sessions/peer"));
        for field in &fields {
            builder = builder.header("Cookie", field)
        }
        if let Some(header) = header {
            builder = builder.header("Authorization", header)
        };
        let request = builder.build().unwrap();
        assert_eq!(
            request.headers().get_all("cookie").iter().count(),
            fields.len(),
            "request must retain repeated fields"
        );
        let response = client.execute(request).await.unwrap();
        actual.push((response.status().as_u16(), repo.0.lock().unwrap().touches));
        expected.push((status, touches));
        let _ = stop.send(());
        task.await.unwrap();
    }
    assert_eq!(actual, expected, "repeated Cookie HTTP field priority");
}
