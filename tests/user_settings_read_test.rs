use axum::{body::Body, http::Request};
use nekotribe_backend::{
    auth::{
        sessions::{
            build_native_router, CorsPolicy, SessionRepository, SessionStoreError, StoreFuture,
        },
        TokenClaims, TokenCodec,
    },
    users::settings_patch::SettingsPatch,
    users::settings_read::SettingsRead,
};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

struct Store(&'static str);

struct Publisher(Mutex<Vec<serde_json::Value>>);
impl nekotribe_backend::notification_events::NotificationPublisher for Publisher {
    fn publish<'a>(
        &'a self,
        _: u64,
        _: &'a str,
        _: &'a serde_json::Map<String, serde_json::Value>,
    ) -> nekotribe_backend::notification_events::PublishFuture<'a> {
        Box::pin(async { Ok(()) })
    }
    fn publish_presence<'a>(
        &'a self,
        data: &'a serde_json::Map<String, serde_json::Value>,
    ) -> nekotribe_backend::notification_events::PublishFuture<'a> {
        Box::pin(async move {
            self.0
                .lock()
                .unwrap()
                .push(serde_json::Value::Object(data.clone()));
            Ok(())
        })
    }
}

#[tokio::test]
async fn settings_patch_publishes_presence_after_success() {
    use nekotribe_backend::auth::{
        otp::SmtpConfig,
        sessions::{build_native_router_with_realtime_and_publisher, RefreshPolicy},
        storage_urls::StorageUrlPolicy,
    };
    let fixture: serde_json::Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = fixture["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|x| x["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    let codec = TokenCodec::new(
        fixture["keys"]["access"].as_str().unwrap().as_bytes(),
        fixture["keys"]["refresh"].as_str().unwrap().as_bytes(),
    )
    .unwrap();
    let publisher = Arc::new(Publisher(Mutex::new(vec![])));
    let app = build_native_router_with_realtime_and_publisher(
        codec,
        Arc::new(Store("ok")),
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_000),
        RefreshPolicy::default(),
        StorageUrlPolicy::default(),
        Arc::new(SmtpConfig::default()),
        None,
        Some(publisher.clone()),
    );
    let request = Request::patch("/api/v2/users/me/settings")
        .header("Content-Type", "application/json")
        .header("Authorization", format!("Bearer {token}"))
        .body(Body::from(r#"{"show_online_status":false}"#))
        .unwrap();
    assert_eq!(app.oneshot(request).await.unwrap().status().as_u16(), 200);
    let events = publisher.0.lock().unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["user_id"], 42);
    assert_eq!(events[0]["online_status"], "hidden");
    assert_eq!(events[0]["last_seen_at"], serde_json::Value::Null);
}
impl SessionRepository for Store {
    fn patch_user_settings<'a>(
        &'a self,
        user: u64,
        _: &'a SettingsPatch,
    ) -> StoreFuture<'a, SettingsRead> {
        self.get_user_settings(user)
    }
    fn user_presence(&self, user: u64) -> StoreFuture<'_, serde_json::Value> {
        Box::pin(async move {
            if self.0 == "presence-error" {
                Err(SessionStoreError)
            } else {
                Ok(serde_json::json!({"user_id":user,"online_status":"hidden","last_seen_at":null}))
            }
        })
    }
    fn touch<'a>(&'a self, claims: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async move { Ok(u64::from(claims.user_id == 42)) })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn get_user_settings(&self, user: u64) -> StoreFuture<'_, SettingsRead> {
        Box::pin(async move {
            match self.0 {
                "schema" => Ok(SettingsRead::SchemaUnavailable),
                "error" => Err(SessionStoreError),
                "missing-user" => Ok(SettingsRead::UserMissing),
                "missing-settings" => Ok(SettingsRead::SettingsMissing),
                _ => Ok(SettingsRead::Ready(serde_json::json!({
                    "user_id":user,"two_factor_enabled":false,"login_alerts":false,
                    "profile_visibility":"public","show_online_status":false,
                    "allow_dm_from_strangers":false,"push_notification_enabled":false,
                    "email_notification_enabled":false,"ai_sentiment_enabled":false,
                    "ai_sentiment_model_id":null,"ai_sentiment_return_probabilities":true,
                    "ai_sentiment_include_metadata":false,"ai_sentiment_top_k":3,"updated_at":""
                }))),
            }
        })
    }
}

#[tokio::test]
async fn settings_shared_native_http_cases() {
    let fixture: serde_json::Value = serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = fixture["cases"].as_array().unwrap().iter().find(|x| x["id"] == "access-hs256").unwrap()["token"].as_str().unwrap();
    let vectors: serde_json::Value = serde_json::from_str(include_str!("../contracts/scenarios/user-settings-native.json")).unwrap();
    for method in ["GET", "PATCH"] {
        for case in vectors["cases"].as_array().unwrap() {
            let mode = match case["mode"].as_str().unwrap() {
                "schema" => "schema", "error" => "error", "missing-user" => "missing-user", "missing-settings" => "missing-settings", _ => "ok"
            };
            let codec = TokenCodec::new(fixture["keys"]["access"].as_str().unwrap().as_bytes(), fixture["keys"]["refresh"].as_str().unwrap().as_bytes()).unwrap();
            let app = build_native_router(codec, Arc::new(Store(mode)), CorsPolicy::default(), Arc::new(|| 1_700_000_000));
            let mut request = Request::builder().method(method).uri("/api/v2/users/me/settings").header("Content-Type", "application/json");
            match case["credential"].as_str().unwrap() {
                "valid" => request = request.header("Authorization", format!("Bearer {token}")),
                "invalid" => request = request.header("Authorization", "Bearer invalid-token"),
                _ => {}
            }
            let response = app.oneshot(request.body(Body::from("{}")).unwrap()).await.unwrap();
            assert_eq!(response.status().as_u16(), case["status"].as_u64().unwrap() as u16, "{method} {case}");
            assert_eq!(response.headers().get("cache-control").and_then(|v| v.to_str().ok()), Some("private, no-store"), "{method} {case}");
            let bytes = axum::body::to_bytes(response.into_body(), 4096).await.unwrap();
            let body: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
            if let Some(message) = case["message"].as_str() { assert_eq!(body["message"], message); }
            if case["status"] == 200 {
                assert_eq!(body["data"].as_object().unwrap().len(), 14);
                assert_eq!(body["data"]["ai_sentiment_top_k"], 3);
            }
        }
    }
}

#[tokio::test]
async fn settings_patch_validates_and_maps_errors() {
    let fixture: serde_json::Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = fixture["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|x| x["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    for (mode, body, bearer, status) in [
        ("ok", r#"{"login_alerts":true}"#, true, 200),
        ("ok", r#"{"show_online_status":false}"#, true, 200),
        ("ok", r#"{"two_factor_enabled":null}"#, true, 400),
        ("ok", "{}", false, 401),
        ("schema", "{}", true, 503),
        (
            "presence-error",
            r#"{"show_online_status":true}"#,
            true,
            500,
        ),
    ] {
        let codec = TokenCodec::new(
            fixture["keys"]["access"].as_str().unwrap().as_bytes(),
            fixture["keys"]["refresh"].as_str().unwrap().as_bytes(),
        )
        .unwrap();
        let app = build_native_router(
            codec,
            Arc::new(Store(mode)),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
        );
        let mut req =
            Request::patch("/api/v2/users/me/settings").header("Content-Type", "application/json");
        if bearer {
            req = req.header("Authorization", format!("Bearer {token}"));
        }
        let response = app
            .oneshot(req.body(Body::from(body)).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), status, "{mode} {body}");
    }
}

#[tokio::test]
async fn settings_get_requires_auth_and_maps_failures() {
    let fixture: serde_json::Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = fixture["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|x| x["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    for (mode, bearer, status) in [
        ("ok", true, 200),
        ("ok", false, 401),
        ("schema", true, 503),
        ("error", true, 500),
    ] {
        let codec = TokenCodec::new(
            fixture["keys"]["access"].as_str().unwrap().as_bytes(),
            fixture["keys"]["refresh"].as_str().unwrap().as_bytes(),
        )
        .unwrap();
        let app = build_native_router(
            codec,
            Arc::new(Store(mode)),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
        );
        let mut request = Request::get("/api/v2/users/me/settings");
        if bearer {
            request = request.header("Authorization", format!("Bearer {token}"));
        }
        let response = app
            .oneshot(request.body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), status, "{mode}");
        if status == 200 {
            assert_eq!(response.headers()["cache-control"], "private, no-store");
            let body = axum::body::to_bytes(response.into_body(), 4096)
                .await
                .unwrap();
            let value: serde_json::Value = serde_json::from_slice(&body).unwrap();
            assert_eq!(value["data"]["user_id"], 42);
        }
    }
}
