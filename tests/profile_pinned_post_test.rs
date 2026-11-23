use axum::{body::Body, http::Request, Router};
use http_body_util::BodyExt;
use nekotribe_backend::{
    auth::{
        sessions::{build_native_router, CorsPolicy, SessionRepository, StoreFuture},
        TokenClaims, TokenCodec,
    },
    users::profile_pin::{Operation, Outcome},
};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

#[derive(Default)]
struct Repository {
    pinned: Mutex<Option<u64>>,
}

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

    fn profile_pin(&self, actor: u64, operation: Operation) -> StoreFuture<'_, Outcome> {
        Box::pin(async move {
            assert_eq!(actor, 42);
            let mut pinned = self.pinned.lock().unwrap();
            Ok(match operation {
                Operation::Read(42) => Outcome::Read(*pinned),
                Operation::Read(6) => Outcome::Read(Some(88)),
                Operation::Read(7) => Outcome::Read(None),
                Operation::Read(8) => Outcome::Unavailable,
                Operation::Set(id @ (101 | 102)) => {
                    *pinned = Some(id);
                    Outcome::Set(id)
                }
                Operation::Set(1020) => Outcome::Ineligible,
                Operation::Clear => {
                    *pinned = None;
                    Outcome::Cleared
                }
                _ => panic!("unexpected action {operation:?}"),
            })
        })
    }

    fn read_visible_post(&self, viewer: Option<u64>, post: u64) -> StoreFuture<'_, Option<Value>> {
        Box::pin(async move {
            assert_eq!(viewer, Some(42));
            Ok(match post {
                101 | 102 => {
                    Some(json!({"post_id": post,"author":{"user_id":42},"content":"original"}))
                }
                88 => None,
                _ => panic!("unexpected post {post}"),
            })
        })
    }

    fn read_post_author(&self, viewer: Option<u64>, author: u64) -> StoreFuture<'_, Option<Value>> {
        Box::pin(async move {
            assert_eq!((viewer, author), (Some(42), 42));
            Ok(Some(
                json!({"user_id":42,"username":"viewer","avatar_url":""}),
            ))
        })
    }

    fn media_readiness(&self) -> StoreFuture<'_, ()> {
        Box::pin(async { Ok(()) })
    }
    fn read_post_media(&self, _: u64) -> StoreFuture<'_, Vec<Value>> {
        Box::pin(async { Ok(vec![]) })
    }

    fn read_attached_post_markdown(
        &self,
        ids: Vec<u64>,
    ) -> StoreFuture<'_, nekotribe_backend::posts::markdown::History> {
        Box::pin(async move {
            assert_eq!(ids.len(), 1);
            assert!(matches!(ids[0], 101 | 102));
            Ok(nekotribe_backend::posts::markdown::History::Ready(vec![
                Some("  # Pinned\n\n- item  ".into()),
            ]))
        })
    }
    fn read_post_tags(&self, _: u64) -> StoreFuture<'_, Vec<String>> {
        Box::pin(async { Ok(vec!["tag".into()]) })
    }
    fn read_post_mentions(&self, _: Option<u64>, _: u64) -> StoreFuture<'_, Vec<Value>> {
        Box::pin(async { Ok(vec![]) })
    }

    fn increment_post_views(&self, _: u64) -> StoreFuture<'_, ()> {
        Box::pin(async { panic!("pinned-post reads must not increment views") })
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
            Arc::new(Repository::default()),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
        ),
        format!("Bearer {token}"),
    )
}

async fn request(
    app: &Router,
    method: &str,
    profile: &str,
    token: Option<&str>,
    body: &str,
) -> (u16, Value) {
    let mut request = Request::builder()
        .method(method)
        .uri(format!("/api/v2/users/{profile}/pinned-post"));
    if let Some(token) = token {
        request = request.header("authorization", token);
    }
    let response = app
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
async fn profile_pin_native_routes_authenticate_replace_clear_and_hydrate_visible_posts() {
    let (router, token) = setup();
    let auth = Some(token.as_str());
    for (method, profile, body) in [
        ("GET", "42", ""),
        ("PUT", "me", r#"{"post_id":101}"#),
        ("DELETE", "me", ""),
    ] {
        assert_eq!(request(&router, method, profile, None, body).await.0, 401);
    }
    for (body, id) in [(r#"{"post_id":101}"#, 101), (r#"{"post_id":102.0}"#, 102)] {
        let (status, response) = request(&router, "PUT", "me", auth, body).await;
        assert_eq!(status, 200);
        assert_eq!(response["data"], json!({"post_id":id}));
        let (status, response) = request(&router, "GET", "42", auth, "").await;
        assert_eq!(status, 200);
        assert_eq!(response["data"]["post"]["post_id"], id);
        assert_eq!(response["data"]["post"]["author"]["username"], "viewer");
        assert_eq!(response["data"]["post"]["tags"], json!(["tag"]));
        assert_eq!(
            response["data"]["post"]["markdown"],
            "  # Pinned\n\n- item  "
        );
    }
    for _ in 0..2 {
        let (status, response) = request(&router, "DELETE", "me", auth, "").await;
        assert_eq!(status, 200);
        assert!(response["data"].is_null());
    }
    for profile in ["42", "6", "7"] {
        let (status, response) = request(&router, "GET", profile, auth, "").await;
        assert_eq!(status, 200);
        assert_eq!(response["data"], json!({"post":null}));
    }
    assert_eq!(request(&router, "GET", "8", auth, "").await.0, 503);
    assert_eq!(request(&router, "GET", "01", auth, "").await.0, 400);
    assert_eq!(
        request(&router, "PUT", "me", auth, r#"{"post_id":1020}"#)
            .await
            .0,
        404
    );
    for invalid in [
        r#"{"post_id":0}"#,
        r#"{"post_id":"10"}"#,
        r#"{"post_id":1.2}"#,
        r#"{"post_id":1,"x":0}"#,
    ] {
        assert_eq!(request(&router, "PUT", "me", auth, invalid).await.0, 400);
    }
}
