use axum::{body::Body, http::Request};
use http_body_util::BodyExt;
use nekotribe_backend::auth::{
    sessions::{
        build_native_router, CorsPolicy, SessionRepository, SessionStoreError, StoreFuture,
    },
    TokenClaims, TokenCodec,
};
use nekotribe_backend::posts::{create_request::PostCreateInput, create_transaction::PostCreation};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

struct UnusedStore;
impl SessionRepository for UnusedStore {
    fn touch<'a>(&'a self, _: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async { panic!("unauthenticated request touched storage") })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
}

struct Store {
    mode: &'static str,
    calls: Mutex<Vec<&'static str>>,
    input: Mutex<Option<PostCreateInput>>,
}
impl Store {
    fn new(mode: &'static str) -> Self {
        Self {
            mode,
            calls: Mutex::new(vec![]),
            input: Mutex::new(None),
        }
    }
    fn step(&self, name: &'static str) -> Result<(), SessionStoreError> {
        self.calls.lock().unwrap().push(name);
        if self.mode == name {
            Err(SessionStoreError)
        } else {
            Ok(())
        }
    }
}
impl SessionRepository for Store {
    fn touch<'a>(&'a self, claims: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async move {
            self.step("touch")?;
            Ok(u64::from(claims.user_id == 42 && self.mode != "revoked"))
        })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn create_post_atomic<'a>(
        &'a self,
        actor: u64,
        input: &'a PostCreateInput,
    ) -> StoreFuture<'a, PostCreation> {
        Box::pin(async move {
            assert_eq!(actor, 42);
            *self.input.lock().unwrap() = Some(input.clone());
            self.step("write")?;
            Ok(match self.mode {
                "hidden" => PostCreation::ReferenceUnavailable,
                "bad-media" => PostCreation::MediaUnavailable,
                "empty-content" => PostCreation::ContentEmpty,
                _ => PostCreation::Created(100),
            })
        })
    }
    fn post_create_actor_name(&self, actor: u64) -> StoreFuture<'_, String> {
        Box::pin(async move {
            assert_eq!(actor, 42);
            self.step("notice")?;
            Ok("viewer".into())
        })
    }
    fn post_create_source_author(&self, _: u64) -> StoreFuture<'_, Option<u64>> {
        Box::pin(async { Ok(None) })
    }
    fn post_create_excerpt(&self, _: u64) -> StoreFuture<'_, String> {
        Box::pin(async { Ok("\"posted\"".into()) })
    }
    fn resolve_post_mention_recipient(&self, _: f64) -> StoreFuture<'_, Option<u64>> {
        Box::pin(async { Ok(None) })
    }
    fn read_visible_post<'a>(
        &'a self,
        viewer: Option<u64>,
        id: u64,
    ) -> StoreFuture<'a, Option<Value>> {
        Box::pin(async move {
            assert_eq!((viewer, id), (Some(42), 100));
            self.step("post")?;
            Ok((self.mode!="post-missing").then(||json!({"post_id":100,"author":{"user_id":42},"content":"posted","viewer_state":{"can_delete":true,"is_liked":false,"is_bookmarked":false},"stats":{"views_count":0}})))
        })
    }
    fn read_post_author<'a>(
        &'a self,
        viewer: Option<u64>,
        id: u64,
    ) -> StoreFuture<'a, Option<Value>> {
        Box::pin(async move {
            assert_eq!((viewer, id), (Some(42), 42));
            self.step("author")?;
            Ok((self.mode != "author-missing")
                .then(|| json!({"user_id":42,"username":"viewer","avatar_url":""})))
        })
    }
    fn media_readiness(&self) -> StoreFuture<'_, ()> {
        Box::pin(async { self.step("media-ready") })
    }
    fn read_post_media<'a>(&'a self, _: u64) -> StoreFuture<'a, Vec<Value>> {
        Box::pin(async {
            self.step("media")?;
            Ok(vec![])
        })
    }
    fn read_post_tags<'a>(&'a self, _: u64) -> StoreFuture<'a, Vec<String>> {
        Box::pin(async {
            self.step("tags")?;
            Ok(vec![])
        })
    }
    fn read_post_mentions<'a>(&'a self, _: Option<u64>, _: u64) -> StoreFuture<'a, Vec<Value>> {
        Box::pin(async {
            self.step("mentions")?;
            Ok(vec![])
        })
    }
    fn increment_post_views<'a>(&'a self, _: u64) -> StoreFuture<'a, ()> {
        Box::pin(async { panic!("post creation must not increment views") })
    }
}

fn credentials() -> (TokenCodec, String) {
    let f: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = f["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap()
        .to_owned();
    let codec = TokenCodec::new(
        f["keys"]["access"].as_str().unwrap().as_bytes(),
        f["keys"]["refresh"].as_str().unwrap().as_bytes(),
    )
    .unwrap();
    (codec, token)
}

async fn invoke(store: Arc<Store>, path: &str, body: &str, auth: &str) -> (u16, Value) {
    let (codec, token) = credentials();
    let router = build_native_router(
        codec,
        store,
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_000),
    );
    let mut request = Request::post(path).header("content-type", "application/json");
    if auth != "none" {
        request = request.header(
            "authorization",
            format!(
                "Bearer {}",
                if auth == "valid" {
                    token
                } else {
                    "bad-token".into()
                }
            ),
        );
    }
    let response = router
        .oneshot(request.body(Body::from(body.to_owned())).unwrap())
        .await
        .unwrap();
    assert_eq!(response.headers()["cache-control"], "private, no-store");
    let status = response.status().as_u16();
    let body =
        serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes()).unwrap();
    (status, body)
}

#[tokio::test]
async fn post_creation_preserves_failure_and_response_boundaries() {
    for (mode, body, auth, status, message, expected) in [
        (
            "",
            r#"{"content":"hi"}"#,
            "bad",
            401,
            "Token无效或已过期",
            vec![],
        ),
        (
            "revoked",
            r#"{"content":"hi"}"#,
            "valid",
            401,
            "Token无效或已过期",
            vec!["touch"],
        ),
        (
            "touch",
            r#"{"content":"hi"}"#,
            "valid",
            401,
            "Token无效或已过期",
            vec!["touch"],
        ),
        (
            "",
            "[]",
            "valid",
            400,
            "请求体必须是 JSON 对象",
            vec!["touch"],
        ),
        (
            "",
            r#"{"content":"hi","visibility":""}"#,
            "valid",
            400,
            "visibility 参数错误",
            vec!["touch"],
        ),
        (
            "hidden",
            r#"{"content":"hi","reply_to_post_id":1}"#,
            "valid",
            404,
            "帖子不存在",
            vec!["touch", "write"],
        ),
        (
            "bad-media",
            r#"{"media_ids":[9]}"#,
            "valid",
            400,
            "媒体不存在或不可用",
            vec!["touch", "write"],
        ),
        (
            "write",
            r#"{"content":"hi"}"#,
            "valid",
            500,
            "服务器内部错误",
            vec!["touch", "write"],
        ),
        (
            "notice",
            r#"{"content":"hi"}"#,
            "valid",
            500,
            "服务器内部错误",
            vec!["touch", "write", "notice"],
        ),
        (
            "post",
            r#"{"content":"hi"}"#,
            "valid",
            500,
            "服务器内部错误",
            vec!["touch", "write", "notice", "post"],
        ),
        (
            "post-missing",
            r#"{"content":"hi"}"#,
            "valid",
            404,
            "帖子不存在",
            vec!["touch", "write", "notice", "post"],
        ),
        (
            "author-missing",
            r#"{"content":"hi"}"#,
            "valid",
            404,
            "用户不存在",
            vec!["touch", "write", "notice", "post", "author"],
        ),
        (
            "media-ready",
            r#"{"content":"hi"}"#,
            "valid",
            503,
            "服务暂不可用，请稍后重试。",
            vec!["touch", "write", "notice", "post", "author", "media-ready"],
        ),
        (
            "",
            r#"{"content":" hi ","author_id":99}"#,
            "valid",
            200,
            "post created",
            vec![
                "touch",
                "write",
                "notice",
                "post",
                "author",
                "media-ready",
                "media",
                "tags",
                "mentions",
            ],
        ),
    ] {
        let store = Arc::new(Store::new(mode));
        let (actual, out) = invoke(store.clone(), "/api/v2/posts?author_id=99", body, auth).await;
        assert_eq!(actual, status, "mode={mode} out={out}");
        assert_eq!(out["message"], message);
        assert_eq!(*store.calls.lock().unwrap(), expected, "{mode}");
        if status == 200 {
            assert_eq!(out["data"]["author"]["user_id"], 42);
            assert_eq!(out["data"]["media"], json!([]));
            assert_eq!(out["data"]["tags"], json!([]));
            assert_eq!(out["data"]["mentions"], json!([]));
            assert_eq!(out["data"]["stats"]["views_count"], 0);
            assert_eq!(
                store.input.lock().unwrap().as_ref().unwrap().content,
                " hi "
            );
        }
    }
}

#[tokio::test]
async fn shared_post_request_vectors_through_native_routes() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/post-create-request-vectors.json"
    ))
    .unwrap();
    for vector in fixture["cases"].as_array().unwrap() {
        let path = if vector["route"] == "retweet" {
            format!(
                "/api/v2/posts/{}/retweets",
                vector["path_id"].as_str().unwrap()
            )
        } else {
            "/api/v2/posts".into()
        };
        let store = Arc::new(Store::new(""));
        let (status, out) =
            invoke(store.clone(), &path, &vector["body"].to_string(), "valid").await;
        let expected = &vector["expected"];
        assert_eq!(
            u64::from(status),
            expected["status"].as_u64().unwrap(),
            "{}: {out}",
            vector["id"]
        );
        assert_eq!(out["code"], expected["code"]);
        assert_eq!(out["message"], expected["message"]);
        let captured = store.input.lock().unwrap();
        if status != 200 {
            assert!(captured.is_none());
            continue;
        }
        let input = captured.as_ref().unwrap();
        let expected = &expected["input"];
        assert_eq!(input.content, expected["content"].as_str().unwrap());
        assert_eq!(input.visibility, expected["visibility"].as_str().unwrap());
        assert_eq!(input.location, expected["location"].as_str().unwrap());
        assert_eq!(
            input.post_type(),
            vector["expected"]["post_type"].as_str().unwrap()
        );
        for (values, key) in [
            (&input.media_ids, "media_ids"),
            (&input.mention_user_ids, "mention_user_ids"),
        ] {
            assert_eq!(
                values,
                &expected[key]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|n| n.as_f64().unwrap())
                    .collect::<Vec<_>>(),
                "{} {key}",
                vector["id"]
            );
        }
        assert_eq!(
            input.tag_names,
            expected["tag_names"]
                .as_array()
                .unwrap()
                .iter()
                .map(|s| s.as_str().unwrap().to_owned())
                .collect::<Vec<_>>()
        );
        assert_eq!(
            input.reply_to_post_id,
            expected["reply_to_post_id"].as_u64()
        );
        assert_eq!(
            input.repost_of_post_id,
            expected["repost_of_post_id"].as_u64()
        );
        assert_eq!(input.quoted_post_id, expected["quoted_post_id"].as_u64());
    }
}

#[tokio::test]
async fn create_routes_require_authentication_before_body_validation() {
    let fixture: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    for path in ["/api/v2/posts", "/api/v2/posts/1/retweets"] {
        let codec = TokenCodec::new(
            fixture["keys"]["access"].as_str().unwrap().as_bytes(),
            fixture["keys"]["refresh"].as_str().unwrap().as_bytes(),
        )
        .unwrap();
        let router = build_native_router(
            codec,
            Arc::new(UnusedStore),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
        );
        let response = router
            .oneshot(
                Request::post(path)
                    .header("content-type", "application/json")
                    .body(Body::from("invalid-json"))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), 401, "{path}");
        assert_eq!(response.headers()["cache-control"], "private, no-store");
        let body: Value =
            serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes())
                .unwrap();
        assert_eq!(body["message"], "请先登录");
    }
}
