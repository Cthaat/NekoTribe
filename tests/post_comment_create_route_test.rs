use axum::{body::Body, http::Request};
use http_body_util::BodyExt;
use nekotribe_backend::{
    auth::{
        otp::SmtpConfig,
        sessions::{
            build_native_router_with_realtime_and_publisher, CorsPolicy, RefreshPolicy,
            SessionRepository, SessionStoreError, StoreFuture,
        },
        storage_urls::StorageUrlPolicy,
        TokenClaims, TokenCodec,
    },
    notification_events::{EventError, NotificationPublisher, PublishFuture},
    posts::comment_create::{
        CommentCreation, CommentNoticeContext, CommentNoticeInput, CommentParentNotice,
        StoredCommentNotification,
    },
};
use serde_json::{json, Map, Value};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

struct Store {
    mode: &'static str,
    post_author: u64,
    parent_author: u64,
    push: bool,
    calls: Mutex<Vec<String>>,
    notices: Mutex<Vec<CommentNoticeInput>>,
}
impl SessionRepository for Store {
    fn touch<'a>(&'a self, c: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async move { Ok(u64::from(c.user_id == 42)) })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn create_post_comment<'a>(
        &'a self,
        user: u64,
        post: u64,
        content: &'a str,
        parent: Option<u64>,
    ) -> StoreFuture<'a, CommentCreation> {
        Box::pin(async move {
            self.calls
                .lock()
                .unwrap()
                .push(format!("create:{user}:{post}:{content}"));
            match self.mode {
                "hidden" => Ok(CommentCreation::PostUnavailable),
                "parent" => Ok(CommentCreation::ParentUnavailable),
                "write-error" => Err(SessionStoreError),
                _ => Ok(CommentCreation::Created(
                    json!({"comment_id":100,"post_id":post,"author_id":user,"parent_comment_id":parent,"root_comment_id":if parent.is_some(){30}else{100},"content":content,"stats":{"likes_count":0,"replies_count":0},"is_liked":false,"created_at":"","updated_at":""}),
                )),
            }
        })
    }
    fn comment_notice_context<'a>(
        &'a self,
        _: u64,
        _: u64,
        _: u64,
    ) -> StoreFuture<'a, CommentNoticeContext> {
        Box::pin(async move {
            if self.mode == "notice-error" {
                return Err(SessionStoreError);
            };
            Ok(CommentNoticeContext {
                actor_name: "viewer".into(),
                post_author: Some(self.post_author),
                comment_excerpt: if self.mode == "surrogate" {
                    "\"\\ud83d...\"".into()
                } else {
                    "\"comment\"".into()
                },
                post_excerpt: "\"post\"".into(),
            })
        })
    }
    fn comment_parent_notice<'a>(
        &'a self,
        _: u64,
        _: Option<u64>,
    ) -> StoreFuture<'a, CommentParentNotice> {
        Box::pin(async move {
            Ok(CommentParentNotice {
                author: Some(self.parent_author),
                excerpt: "\"parent\"".into(),
            })
        })
    }
    fn store_comment_notification<'a>(
        &'a self,
        input: &'a CommentNoticeInput,
    ) -> StoreFuture<'a, Option<StoredCommentNotification>> {
        Box::pin(async move {
            if self.mode == "store-error" {
                return Err(SessionStoreError);
            }
            if input.recipient == input.actor {
                return Ok(None);
            }
            let mut notices = self.notices.lock().unwrap();
            notices.push(input.clone());
            if self.mode == "second-error" && notices.len() == 2 {
                notices.pop();
                return Err(SessionStoreError);
            }
            Ok(Some(StoredCommentNotification {
                recipient: input.recipient,
                id: 500 + notices.len() as u64,
                push_enabled: self.push,
            }))
        })
    }
    fn read_notification<'a>(&'a self, _: u64, id: u64) -> StoreFuture<'a, Option<Value>> {
        Box::pin(async move { Ok(Some(json!({"notification_id":id,"type":"comment"}))) })
    }
    fn read_post_author<'a>(
        &'a self,
        viewer: Option<u64>,
        id: u64,
    ) -> StoreFuture<'a, Option<Value>> {
        Box::pin(async move {
            Ok((viewer == Some(42) && id == 42)
                .then(|| json!({"user_id":42,"username":"viewer","avatar_url":""})))
        })
    }
}

#[tokio::test]
async fn comment_redis_failure_keeps_comment_and_metadata_preserves_utf16_escape() {
    let (codec, token) = credentials();
    let store = Arc::new(Store {
        mode: "surrogate",
        post_author: 7,
        parent_author: 8,
        push: true,
        calls: Mutex::new(vec![]),
        notices: Mutex::new(vec![]),
    });
    let publisher = Arc::new(Publisher {
        calls: Mutex::new(vec![]),
        fail: true,
    });
    let app = build_native_router_with_realtime_and_publisher(
        codec,
        store.clone(),
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_000),
        RefreshPolicy::default(),
        StorageUrlPolicy::default(),
        Arc::new(SmtpConfig::default()),
        None,
        Some(publisher.clone()),
    );
    let request = Request::builder()
        .method("POST")
        .uri("/api/v2/posts/1/comments")
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(r#"{"content":"hi"}"#))
        .unwrap();
    let response = app.oneshot(request).await.unwrap();
    assert_eq!(response.status().as_u16(), 200);
    assert_eq!(publisher.calls.lock().unwrap().len(), 1);
    let notices = store.notices.lock().unwrap();
    assert_eq!(notices.len(), 1);
    assert!(notices[0]
        .metadata_json
        .contains(r#""comment_excerpt":"\ud83d...""#));
}
#[derive(Default)]
struct Publisher {
    calls: Mutex<Vec<(u64, String)>>,
    fail: bool,
}
impl NotificationPublisher for Publisher {
    fn publish<'a>(
        &'a self,
        user: u64,
        kind: &'a str,
        _: &'a Map<String, Value>,
    ) -> PublishFuture<'a> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((user, kind.into()));
            if self.fail {
                Err(EventError)
            } else {
                Ok(())
            }
        })
    }
}
fn credentials() -> (TokenCodec, String) {
    let t: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = t["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap()
        .to_owned();
    (
        TokenCodec::new(
            t["keys"]["access"].as_str().unwrap().as_bytes(),
            t["keys"]["refresh"].as_str().unwrap().as_bytes(),
        )
        .unwrap(),
        token,
    )
}
#[tokio::test]
async fn comment_creation_auth_notifications_and_failure_boundaries() {
    for (body, auth, mode, post_author, parent_author, push, status, created, notices, events) in [
        (r#"{"content":"hi"}"#, false, "", 7, 8, true, 401, 0, 0, 0),
        (
            r#"{"content":"hi","parent_comment_id":"40"}"#,
            true,
            "",
            7,
            8,
            true,
            200,
            1,
            2,
            2,
        ),
        (
            r#"{"content":"hi","parent_comment_id":1.5}"#,
            true,
            "",
            7,
            8,
            true,
            400,
            0,
            0,
            0,
        ),
        (
            r#"{"content":"hi","parent_comment_id":9007199254740992}"#,
            true,
            "",
            7,
            8,
            true,
            400,
            0,
            0,
            0,
        ),
        (
            r#"{"content":"hi","parent_comment_id":"01"}"#,
            true,
            "",
            7,
            8,
            true,
            400,
            0,
            0,
            0,
        ),
        (
            r#"{"content":"hi","parent_comment_id":{}}"#,
            true,
            "",
            7,
            8,
            true,
            400,
            0,
            0,
            0,
        ),
        (r#"{"content":" "}"#, true, "", 7, 8, true, 400, 0, 0, 0),
        (
            r#"{"content":"hi"}"#,
            true,
            "hidden",
            7,
            8,
            true,
            404,
            1,
            0,
            0,
        ),
        (
            r#"{"content":"hi","parent_comment_id":40}"#,
            true,
            "parent",
            7,
            8,
            true,
            404,
            1,
            0,
            0,
        ),
        (
            r#"{"content":" hello "}"#,
            true,
            "",
            7,
            8,
            true,
            200,
            1,
            1,
            1,
        ),
        (
            r#"{"content":"hi","parent_comment_id":40}"#,
            true,
            "",
            7,
            8,
            true,
            200,
            1,
            2,
            2,
        ),
        (
            r#"{"content":"hi","parent_comment_id":40}"#,
            true,
            "",
            7,
            7,
            true,
            200,
            1,
            1,
            1,
        ),
        (
            r#"{"content":"hi","parent_comment_id":40}"#,
            true,
            "",
            42,
            42,
            true,
            200,
            1,
            0,
            0,
        ),
        (r#"{"content":"hi"}"#, true, "", 7, 8, false, 200, 1, 1, 0),
        (
            r#"{"content":"hi"}"#,
            true,
            "notice-error",
            7,
            8,
            true,
            500,
            1,
            0,
            0,
        ),
        (
            r#"{"content":"hi","parent_comment_id":40}"#,
            true,
            "second-error",
            7,
            8,
            true,
            500,
            1,
            1,
            1,
        ),
    ] {
        let (codec, token) = credentials();
        let store = Arc::new(Store {
            mode,
            post_author,
            parent_author,
            push,
            calls: Mutex::new(vec![]),
            notices: Mutex::new(vec![]),
        });
        let publisher = Arc::new(Publisher::default());
        let app = build_native_router_with_realtime_and_publisher(
            codec,
            store.clone(),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
            RefreshPolicy::default(),
            StorageUrlPolicy::default(),
            Arc::new(SmtpConfig::default()),
            None,
            Some(publisher.clone()),
        );
        let mut request = Request::builder()
            .method("POST")
            .uri("/api/v2/posts/1/comments?user_id=99")
            .header("content-type", "application/json");
        if auth {
            request = request.header("authorization", format!("Bearer {token}"));
        }
        let response = app
            .oneshot(request.body(Body::from(body)).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), status, "{body} {mode}");
        assert_eq!(
            response.headers().get("cache-control").unwrap(),
            "private, no-store"
        );
        let output: Value =
            serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes())
                .unwrap();
        assert_eq!(store.calls.lock().unwrap().len(), created);
        assert_eq!(store.notices.lock().unwrap().len(), notices);
        assert_eq!(publisher.calls.lock().unwrap().len(), events);
        if status == 200 {
            assert_eq!(output["message"], "comment created");
            assert_eq!(output["data"]["author"]["user_id"], 42);
            assert_eq!(output["data"]["viewer_state"]["can_delete"], true);
        }
        for (index, notice) in store.notices.lock().unwrap().iter().enumerate() {
            let meta: Value = serde_json::from_str(&notice.metadata_json).unwrap();
            assert_eq!(meta["post_id"], 1);
            assert_eq!(meta["comment_id"], 100);
            assert_eq!(
                meta["event"],
                if index == 0 {
                    "comment_created"
                } else {
                    "comment_reply"
                }
            );
        }
    }
}
