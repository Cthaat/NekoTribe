use axum::{body::Body, http::Request};
use nekotribe_backend::{
    auth::{
        sessions::{
            build_native_router, CorsPolicy, SessionRepository, SessionStoreError, StoreFuture,
        },
        TokenClaims, TokenCodec,
    },
    users::settings_read::SettingsRead,
};
use std::sync::Arc;
use tower::ServiceExt;

struct Store(&'static str);
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
    fn get_user_settings(&self, user: u64) -> StoreFuture<'_, SettingsRead> {
        Box::pin(async move {
            match self.0 {
                "schema" => Ok(SettingsRead::SchemaUnavailable),
                "error" => Err(SessionStoreError),
                _ => Ok(SettingsRead::Ready(serde_json::json!({"user_id":user}))),
            }
        })
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
