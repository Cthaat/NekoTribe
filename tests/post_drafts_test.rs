use axum::{body::Body, http::Request, Router};
use http_body_util::BodyExt;
use nekotribe_backend::{
    auth::{
        sessions::{build_native_router, CorsPolicy, SessionRepository, StoreFuture},
        storage_urls::StorageUrlPolicy,
        TokenClaims, TokenCodec,
    },
    httpx::errors::ApiError,
    posts::draft_store::{Operation, Outcome},
};
use serde_json::{json, Value};
use std::sync::Arc;
use tower::ServiceExt;

struct Repository;

impl SessionRepository for Repository {
    fn touch<'a>(&'a self, claims: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async move { Ok(u64::from(claims.user_id == 42)) })
    }

    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }

    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }

    fn post_draft<'a>(
        &'a self,
        owner: u64,
        operation: Operation,
        _: &'a StorageUrlPolicy,
    ) -> StoreFuture<'a, Outcome> {
        Box::pin(async move {
            assert_eq!(owner, 42);
            let payload = json!({"group_id":null,"content":"draft"});
            let item = |status: &str, payload: Value| {
                json!({"draft_id":3,"status":status,"payload":payload,
                "scheduled_at":null,"published_post_id":(status == "published").then_some(77),
                "last_error":null,"updated_at":"2030-01-01T00:00:00.000Z"})
            };
            let result = match operation {
                Operation::List(_) => {
                    json!({"items":[item("draft", payload)],"next_before_id":null})
                }
                Operation::Create(draft) | Operation::Edit(3, draft) => {
                    item("draft", serde_json::to_value(draft).unwrap())
                }
                Operation::Remove(3) => Value::Null,
                Operation::Schedule(3, time) => {
                    assert_eq!(time, "2030-01-02T00:00:00.000Z");
                    let mut result = item("scheduled", payload);
                    result["scheduled_at"] = time.into();
                    result
                }
                Operation::Unschedule(3) => item("draft", payload),
                Operation::Publish(3) => item("published", payload),
                Operation::Publish(5) => {
                    return Ok(Outcome::Rejected(ApiError::not_found("草稿不存在")))
                }
                Operation::Edit(9, _) => {
                    return Ok(Outcome::Rejected(ApiError::conflict("草稿已发布")))
                }
                Operation::Remove(8) => {
                    return Ok(Outcome::Rejected(ApiError::new(
                        axum::http::StatusCode::SERVICE_UNAVAILABLE,
                        50301,
                        "服务暂不可用，请稍后重试。",
                    )))
                }
                _ => panic!("unexpected draft operation"),
            };
            Ok(Outcome::Saved(result, None))
        })
    }
}

fn setup() -> (Router, String) {
    let fixture: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = fixture["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|case| case["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    let codec = TokenCodec::new(
        fixture["keys"]["access"].as_str().unwrap().as_bytes(),
        fixture["keys"]["refresh"].as_str().unwrap().as_bytes(),
    )
    .unwrap();
    (
        build_native_router(
            codec,
            Arc::new(Repository),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
        ),
        format!("Bearer {token}"),
    )
}

async fn request(
    router: &Router,
    action: &str,
    suffix: &str,
    token: Option<&str>,
    body: &str,
) -> (u16, Value) {
    let mut request = Request::builder()
        .method(action)
        .uri(format!("/api/v2/users/me/drafts{suffix}"));
    if let Some(token) = token {
        request = request.header("authorization", token);
    }
    let response = router
        .clone()
        .oneshot(
            request
                .header("content-type", "application/json")
                .body(Body::from(body.to_owned()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.headers()["cache-control"], "private, no-store");
    let code = response.status().as_u16();
    let data =
        serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes()).unwrap();
    (code, data)
}

#[tokio::test]
async fn native_draft_routes_require_owner_auth_and_return_private_receipts() {
    let (router, token) = setup();
    let payload = r##"{"group_id":null,"content":"","markdown":" # Draft\n\n- item "}"##;
    for (action, suffix, body, message) in [
        ("GET", "?group_id=0&limit=20", "", "success"),
        ("POST", "", payload, "draft saved"),
        ("PUT", "/3", payload, "draft saved"),
        (
            "PUT",
            "/3/schedule",
            r#"{"scheduled_at":"2030-01-02T08:00:00+08:00"}"#,
            "draft scheduled",
        ),
        ("DELETE", "/3/schedule", "", "draft unscheduled"),
        ("POST", "/3/publish", "", "draft published"),
        ("DELETE", "/3", "", "draft deleted"),
    ] {
        assert_eq!(request(&router, action, suffix, None, body).await.0, 401);
        let (status, reply) = request(&router, action, suffix, Some(&token), body).await;
        assert_eq!(status, 200, "{action} {suffix}");
        assert_eq!(reply["message"], message);
        assert!(reply["data"].get("owner_id").is_none());
        if message == "draft saved" {
            assert_eq!(reply["data"]["payload"]["markdown"], " # Draft\n\n- item ");
        }
    }
    let (_, prior) = request(&router, "POST", "/3/publish", Some(&token), "").await;
    assert_eq!(prior["data"]["published_post_id"], 77);

    for (action, suffix, body, expected) in [
        ("POST", "/5/publish", "", 404),
        ("PUT", "/9", payload, 409),
        ("DELETE", "/8", "", 503),
        ("PUT", "/3/schedule", "{}", 400),
        ("GET", "?limit=51", "", 400),
        ("POST", "", r#"{"content":"x"}"#, 400),
    ] {
        assert_eq!(
            request(&router, action, suffix, Some(&token), body).await.0,
            expected
        );
    }
}
