use axum::{body::Body, http::Request};
use nekotribe_backend::{
    ai::conversation_store::{AiOperation, ModerationPolicy},
    auth::{
        sessions::{build_native_router, CorsPolicy, SessionRepository, StoreFuture},
        TokenClaims, TokenCodec,
    },
};
use std::sync::Arc;
use tower::ServiceExt;

struct Store(Option<nekotribe_backend::ai::conversation_store::Error>);
impl SessionRepository for Store {
    fn touch<'a>(&'a self, claims: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async move { Ok(u64::from(claims.user_id == 42)) })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn ai_conversation(
        &self,
        user: u64,
        operation: AiOperation,
        _: ModerationPolicy,
    ) -> StoreFuture<'_, Result<serde_json::Value, nekotribe_backend::ai::conversation_store::Error>>
    {
        let failure = self.0.clone();
        Box::pin(async move {
            assert_eq!(user, 42);
            let _ = operation;
            Ok(match failure {
                Some(error) => Err(error),
                None => Ok(serde_json::json!({"ok":true})),
            })
        })
    }
}
#[tokio::test]
async fn ai_routes_require_auth_validate_input_and_disable_caching() {
    let f: serde_json::Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = f["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|x| x["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    let codec = TokenCodec::new(
        f["keys"]["access"].as_str().unwrap().as_bytes(),
        f["keys"]["refresh"].as_str().unwrap().as_bytes(),
    )
    .unwrap();
    let app = build_native_router(
        codec,
        Arc::new(Store(None)),
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_000),
    );
    let id = "f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb";
    for (method, path, body, bearer, status) in [
        (
            "POST",
            "/api/v2/ai/conversations".to_string(),
            r#"{"purpose":"knowledge"}"#,
            true,
            200,
        ),
        (
            "GET",
            format!("/api/v2/ai/conversations/{id}"),
            "",
            true,
            200,
        ),
        (
            "POST",
            format!("/api/v2/ai/conversations/{id}/messages"),
            r#"{"content":"hello"}"#,
            true,
            200,
        ),
        (
            "GET",
            format!("/api/v2/ai/conversations/{id}/messages?after_sequence=2&limit=10"),
            "",
            true,
            200,
        ),
        (
            "POST",
            format!("/api/v2/ai/conversations/{id}/messages"),
            r#"{"content":"x","role":"assistant"}"#,
            true,
            400,
        ),
        (
            "GET",
            format!("/api/v2/ai/conversations/{id}/messages?limit=51"),
            "",
            true,
            400,
        ),
        (
            "GET",
            format!("/api/v2/ai/conversations/{id}/messages?limit=1&limit=2"),
            "",
            true,
            400,
        ),
        (
            "GET",
            format!("/api/v2/ai/conversations/{id}/messages?limit=1e1"),
            "",
            true,
            400,
        ),
        (
            "POST",
            "/api/v2/ai/conversations".to_string(),
            r#"{"purpose":"knowledge","api_key":"secret"}"#,
            true,
            400,
        ),
        (
            "GET",
            format!("/api/v2/ai/conversations/{id}"),
            "",
            false,
            401,
        ),
    ] {
        let mut req = Request::builder()
            .method(method)
            .uri(path)
            .header("content-type", "application/json");
        if bearer {
            req = req.header("authorization", format!("Bearer {token}"));
        }
        let response = app
            .clone()
            .oneshot(req.body(Body::from(body)).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), status);
        assert_eq!(
            response.headers().get("cache-control").unwrap(),
            "private, no-store"
        );
    }
}

#[tokio::test]
async fn ai_store_errors_are_mapped_to_safe_http_responses() {
    use nekotribe_backend::ai::conversation_store::Error;
    let f: serde_json::Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = f["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|x| x["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    for (failure, status) in [
        (Error::NotFound, 404),
        (Error::Forbidden, 403),
        (Error::Conflict, 409),
        (Error::SchemaUnavailable, 503),
        (Error::Store, 500),
    ] {
        let codec = TokenCodec::new(
            f["keys"]["access"].as_str().unwrap().as_bytes(),
            f["keys"]["refresh"].as_str().unwrap().as_bytes(),
        )
        .unwrap();
        let app = build_native_router(
            codec,
            Arc::new(Store(Some(failure))),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
        );
        let req = Request::get("/api/v2/ai/conversations/f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb")
            .header("authorization", format!("Bearer {token}"))
            .body(Body::empty())
            .unwrap();
        let response = app.oneshot(req).await.unwrap();
        assert_eq!(response.status().as_u16(), status);
        assert_eq!(
            response.headers().get("cache-control").unwrap(),
            "private, no-store"
        );
    }
}

#[test]
fn moderation_settings_are_loaded_from_server_configuration() {
    use nekotribe_backend::ai::conversation_http::ModerationSettings;
    let settings = ModerationSettings::from_lookup(&|key| match key {
        "MODERATION_ALLOW_ALL" => Some("false".into()),
        "MODERATION_ADMIN_ACCOUNTS" => Some("staff@example.test".into()),
        _ => None,
    });
    assert_eq!(settings.allow_all, "false");
    assert_eq!(settings.accounts, "staff@example.test");
}
