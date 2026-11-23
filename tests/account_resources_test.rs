use axum::{
    body::{to_bytes, Body},
    http::Request,
};
use nekotribe_backend::{
    auth::{
        sessions::{build_native_router, CorsPolicy, SessionRepository, StoreFuture},
        TokenClaims, TokenCodec,
    },
    db::{row::DbRow, value::DbValue},
    users::account_resources::ResourceQuery,
};
use serde_json::Value;
use std::sync::Arc;
use tower::ServiceExt;

struct Store;

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
    fn account_resources(&self, actor: u64, query: ResourceQuery) -> StoreFuture<'_, Vec<DbRow>> {
        assert_eq!(actor, 42);
        let date = || DbValue::String("2026-11-21T00:00:00.000Z".into());
        let row = match query {
            ResourceQuery::Usage => DbRow::from([
                ("BYTES".into(), DbValue::I64(768)),
                ("FILES".into(), DbValue::I64(2)),
                ("CONVERSATIONS".into(), DbValue::I64(2)),
            ]),
            ResourceQuery::Posts => DbRow::from([
                ("POST_ID".into(), DbValue::I64(1)),
                ("CONTENT".into(), DbValue::String("first\nsecond".into())),
                ("CREATED_AT".into(), date()),
            ]),
            ResourceQuery::Bookmarks => DbRow::from([
                ("POST_ID".into(), DbValue::I64(4)),
                ("CREATED_AT".into(), date()),
            ]),
        };
        Box::pin(async move { Ok(vec![row]) })
    }
}

#[tokio::test]
async fn personal_resource_routes() {
    let tokens: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = tokens["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    let codec = TokenCodec::new(
        tokens["keys"]["access"].as_str().unwrap().as_bytes(),
        tokens["keys"]["refresh"].as_str().unwrap().as_bytes(),
    )
    .unwrap();
    let app = build_native_router(
        codec,
        Arc::new(Store),
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_000),
    );
    let request = |path: &str, auth: bool| {
        let mut builder = Request::builder().uri(format!("/api/v2/users/me/{path}"));
        if auth {
            builder = builder.header("Authorization", format!("Bearer {token}"));
        }
        app.clone().oneshot(builder.body(Body::empty()).unwrap())
    };
    let usage = request("usage?user_id=77", true).await.unwrap();
    assert_eq!(usage.status(), 200);
    assert_eq!(usage.headers()["cache-control"], "private, no-store");
    let data: Value =
        serde_json::from_slice(&to_bytes(usage.into_body(), 4096).await.unwrap()).unwrap();
    assert_eq!(data["data"]["media"]["bytes"], 768);
    assert_eq!(data["data"]["ai_history"]["conversations"], 2);

    let json = request("export?format=json", true).await.unwrap();
    assert_eq!(json.status(), 200);
    assert!(json.headers()["content-disposition"]
        .to_str()
        .unwrap()
        .contains(".json"));
    let data: Value =
        serde_json::from_slice(&to_bytes(json.into_body(), 4096).await.unwrap()).unwrap();
    assert_eq!(data["bookmarks"][0]["post_id"], 4);
    let markdown = request("export?format=markdown", true).await.unwrap();
    assert_eq!(markdown.status(), 200);
    assert!(
        String::from_utf8_lossy(&to_bytes(markdown.into_body(), 4096).await.unwrap())
            .contains("    first\n    second")
    );

    assert_eq!(request("export", false).await.unwrap().status(), 401);
    assert_eq!(
        request("export?format=csv", true).await.unwrap().status(),
        400
    );
}
