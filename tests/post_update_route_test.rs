use axum::{body::Body, http::Request};
use http_body_util::BodyExt;
use nekotribe_backend::{
    auth::{
        sessions::{
            build_native_router, CorsPolicy, SessionRepository, SessionStoreError, StoreFuture,
        },
        TokenClaims, TokenCodec,
    },
    posts::{update_request::PostUpdateInput, update_transaction::PostUpdate},
};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;
struct Store {
    mode: &'static str,
    calls: Mutex<Vec<&'static str>>,
}
impl Store {
    fn step(&self, step: &'static str) -> Result<(), SessionStoreError> {
        self.calls.lock().unwrap().push(step);
        if self.mode == step {
            Err(SessionStoreError)
        } else {
            Ok(())
        }
    }
}
impl SessionRepository for Store {
    fn touch<'a>(&'a self, _: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async {
            self.step("touch")?;
            Ok(u64::from(self.mode != "revoked"))
        })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn update_post_atomic<'a>(
        &'a self,
        actor: u64,
        id: u64,
        _: &'a PostUpdateInput,
    ) -> StoreFuture<'a, PostUpdate> {
        Box::pin(async move {
            assert_eq!((actor, id), (42, 20));
            self.step("update")?;
            Ok(match self.mode {
                "missing" => PostUpdate::Missing,
                "other" => PostUpdate::NotOwner,
                "media" => PostUpdate::MediaUnavailable,
                "empty" => PostUpdate::ContentEmpty,
                _ => PostUpdate::Updated,
            })
        })
    }
    fn read_visible_post<'a>(
        &'a self,
        actor: Option<u64>,
        id: u64,
    ) -> StoreFuture<'a, Option<Value>> {
        Box::pin(async move {
            assert_eq!((actor, id), (Some(42), 20));
            self.step("post")?;
            Ok((self.mode!="post-missing").then(||json!({"post_id":20,"author":{"user_id":42},"content":"new","stats":{"views_count":0},"viewer_state":{}})))
        })
    }
    fn read_post_author<'a>(&'a self, _: Option<u64>, _: u64) -> StoreFuture<'a, Option<Value>> {
        Box::pin(async {
            self.step("author")?;
            Ok((self.mode != "author-missing")
                .then(|| json!({"user_id":42,"username":"viewer","avatar_url":""})))
        })
    }
    fn media_readiness(&self) -> StoreFuture<'_, ()> {
        Box::pin(async { self.step("media-ready") })
    }
    fn read_post_media<'a>(&'a self, _: u64) -> StoreFuture<'a, Vec<Value>> {
        Box::pin(async { Ok(vec![]) })
    }
    fn read_post_tags<'a>(&'a self, _: u64) -> StoreFuture<'a, Vec<String>> {
        Box::pin(async { Ok(vec![]) })
    }
    fn read_post_mentions<'a>(&'a self, _: Option<u64>, _: u64) -> StoreFuture<'a, Vec<Value>> {
        Box::pin(async { Ok(vec![]) })
    }
    fn increment_post_views<'a>(&'a self, _: u64) -> StoreFuture<'a, ()> {
        Box::pin(async { panic!("editing must not increment views") })
    }
}
#[tokio::test]
async fn patch_and_put_auth_errors_and_response_boundaries() {
    let tokens: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = tokens["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    for method in ["PATCH", "PUT"] {
        for (mode, body, path, auth, status, message) in [
            ("", "[]", "20", false, 401, "请先登录"),
            ("revoked", "{}", "20", true, 401, "Token无效或已过期"),
            ("", "{}", "01", true, 400, "id 参数错误"),
            ("", "[]", "20", true, 400, "请求体必须是 JSON 对象"),
            (
                "",
                r#"{"visibility":null}"#,
                "20",
                true,
                400,
                "visibility 参数错误",
            ),
            ("missing", "{}", "20", true, 404, "帖子不存在"),
            ("other", "{}", "20", true, 422, "只能修改自己的帖子"),
            ("media", "{}", "20", true, 400, "附件不存在或无权使用"),
            ("empty", "{}", "20", true, 400, "content 不能为空"),
            ("update", "{}", "20", true, 500, "服务器内部错误"),
            ("post", "{}", "20", true, 500, "服务器内部错误"),
            ("post-missing", "{}", "20", true, 404, "帖子不存在"),
            ("author-missing", "{}", "20", true, 404, "用户不存在"),
            (
                "media-ready",
                "{}",
                "20",
                true,
                503,
                "服务暂不可用，请稍后重试。",
            ),
            ("", r#"{"content":"new"}"#, "20", true, 200, "post updated"),
        ] {
            let codec = TokenCodec::new(
                tokens["keys"]["access"].as_str().unwrap().as_bytes(),
                tokens["keys"]["refresh"].as_str().unwrap().as_bytes(),
            )
            .unwrap();
            let store = Arc::new(Store {
                mode,
                calls: Mutex::new(vec![]),
            });
            let app = build_native_router(
                codec,
                store.clone(),
                CorsPolicy::default(),
                Arc::new(|| 1_700_000_000),
            );
            let mut req = Request::builder()
                .method(method)
                .uri(format!("/api/v2/posts/{path}"))
                .header("content-type", "application/json");
            if auth {
                req = req.header("authorization", format!("Bearer {token}"))
            };
            let response = app
                .oneshot(req.body(Body::from(body)).unwrap())
                .await
                .unwrap();
            assert_eq!(response.status().as_u16(), status, "{mode}");
            assert_eq!(response.headers()["cache-control"], "private, no-store");
            let out: Value =
                serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes())
                    .unwrap();
            assert_eq!(out["message"], message, "{mode}");
            let calls = store.calls.lock().unwrap();
            if status == 200 {
                assert_eq!(
                    calls.as_slice(),
                    ["touch", "update", "post", "author", "media-ready"]
                )
            } else if mode == "update" {
                assert_eq!(calls.as_slice(), ["touch", "update"])
            };
        }
    }
}
