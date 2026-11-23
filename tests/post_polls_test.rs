use axum::{body::Body, http::Request};
use http_body_util::BodyExt;
use nekotribe_backend::{
    auth::{
        sessions::{build_native_router, CorsPolicy, SessionRepository, StoreFuture},
        TokenClaims, TokenCodec,
    },
    posts::polls::{Operation, Outcome, Poll, PollOption, Target},
};
use serde_json::Value;
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

    fn post_poll(
        &self,
        viewer: Option<u64>,
        target: Target,
        operation: Operation,
    ) -> StoreFuture<'_, Outcome> {
        Box::pin(async move {
            match target {
                Target::Regular(7) => return Ok(Outcome::MissingPost),
                Target::Regular(8) => return Ok(Outcome::Unavailable),
                Target::Regular(9) => return Ok(Outcome::MissingPoll),
                Target::Regular(10) => assert!(viewer.is_none() || viewer == Some(42)),
                Target::Group {
                    group_id: 3,
                    post_id: 10,
                } => assert_eq!(viewer, Some(42)),
                Target::Group {
                    group_id: 4,
                    post_id: 10,
                } => return Ok(Outcome::Forbidden),
                other => panic!("unexpected target {other:?}"),
            }
            let my_option_ids = match operation {
                Operation::Read => Vec::new(),
                Operation::Vote(choices) => {
                    assert_eq!(viewer, Some(42));
                    if choices == [2] {
                        return Ok(Outcome::Duplicate);
                    }
                    assert_eq!(choices, [1]);
                    choices
                }
            };
            let votes_count = my_option_ids.len() as i64;
            Ok(Outcome::Found(Poll {
                poll_id: 1,
                multiple: matches!(target, Target::Group { .. }),
                closes_at: "2030-01-02T03:04:05.000Z".into(),
                closed: false,
                total_ballots: votes_count,
                my_option_ids,
                options: vec![
                    PollOption {
                        option_id: 1,
                        text: "a".into(),
                        votes_count,
                        percent: (votes_count * 100) as f64,
                    },
                    PollOption {
                        option_id: 2,
                        text: "b".into(),
                        votes_count: 0,
                        percent: 0.0,
                    },
                ],
            }))
        })
    }
}

fn setup() -> (axum::Router, String) {
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
    let router = build_native_router(
        codec,
        Arc::new(Repository),
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_000),
    );
    (router, format!("Bearer {token}"))
}

async fn request(
    router: &axum::Router,
    path: &str,
    token: Option<&str>,
    ballot: Option<&str>,
) -> (u16, Value) {
    let mut builder = Request::builder()
        .method(if ballot.is_some() { "POST" } else { "GET" })
        .uri(path);
    if let Some(token) = token {
        builder = builder.header("authorization", token);
    }
    let request = builder
        .header("content-type", "application/json")
        .body(Body::from(ballot.unwrap_or_default().to_owned()))
        .unwrap();
    let response = router.clone().oneshot(request).await.unwrap();
    assert_eq!(response.headers()["cache-control"], "private, no-store");
    let status = response.status().as_u16();
    let body =
        serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes()).unwrap();
    (status, body)
}

#[tokio::test]
async fn native_poll_routes_use_original_auth_and_return_authoritative_vote_receipts() {
    let (router, token) = setup();
    for (path, auth, multiple) in [
        ("/api/v2/posts/10/poll", None, false),
        ("/api/v2/groups/3/posts/10/poll", Some(token.as_str()), true),
    ] {
        let (status, body) = request(&router, path, auth, None).await;
        assert_eq!(status, 200);
        assert_eq!(body["data"]["my_option_ids"].as_array().unwrap().len(), 0);
        assert_eq!(body["data"]["multiple"], multiple);

        let vote_path = format!("{path}/vote");
        let (status, body) = request(
            &router,
            &vote_path,
            Some(&token),
            Some(r#"{"option_ids":[1.0]}"#),
        )
        .await;
        assert_eq!(status, 200);
        assert_eq!(body["data"]["my_option_ids"], serde_json::json!([1]));
        assert_eq!(body["message"], "vote recorded");
        assert_eq!(
            request(
                &router,
                &vote_path,
                Some(&token),
                Some(r#"{"option_ids":[2]}"#)
            )
            .await
            .0,
            409
        );
        assert_eq!(
            request(&router, &vote_path, None, Some(r#"{"option_ids":[1]}"#))
                .await
                .0,
            401
        );
    }
    assert_eq!(
        request(&router, "/api/v2/groups/3/posts/10/poll", None, None)
            .await
            .0,
        401
    );
}

#[tokio::test]
async fn native_polls_return_scope_readiness_and_validation_errors() {
    let (router, token) = setup();
    for (id, expected) in [(7, 404), (8, 503), (9, 404)] {
        assert_eq!(
            request(&router, &format!("/api/v2/posts/{id}/poll"), None, None)
                .await
                .0,
            expected
        );
    }
    let vote = r#"{"option_ids":[1]}"#;
    assert_eq!(
        request(
            &router,
            "/api/v2/groups/4/posts/10/poll/vote",
            Some(&token),
            Some(vote)
        )
        .await
        .0,
        403
    );
    assert_eq!(
        request(&router, "/api/v2/posts/01/poll", None, None)
            .await
            .0,
        400
    );
    for ballot in [
        r#"{"option_ids":[1,1]}"#,
        r#"{"option_ids":["1"]}"#,
        r#"{"option_ids":[7]}"#,
        r#"{"option_ids":[1],"extra":true}"#,
    ] {
        assert_eq!(
            request(
                &router,
                "/api/v2/posts/10/poll/vote",
                Some(&token),
                Some(ballot)
            )
            .await
            .0,
            400
        );
    }
}
