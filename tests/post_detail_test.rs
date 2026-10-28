use axum::{body::Body, http::Request};
use http_body_util::BodyExt;
use nekotribe_backend::auth::{
    sessions::{
        build_native_router, CorsPolicy, SessionRepository, SessionStoreError, StoreFuture,
    },
    TokenClaims, TokenCodec,
};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;
struct Store {
    post: Value,
    events: Mutex<Vec<String>>,
    viewer: Mutex<Option<u64>>,
    fault: String,
    missing: bool,
    revoked: bool,
    touch_fail: bool,
}
impl Store {
    fn step(&self, name: &str) -> Result<(), SessionStoreError> {
        self.events.lock().unwrap().push(name.into());
        if self.fault == name {
            Err(SessionStoreError)
        } else {
            Ok(())
        }
    }
}
impl SessionRepository for Store {
    fn touch<'a>(&'a self, c: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async move {
            if self.touch_fail {
                return Err(SessionStoreError);
            };
            Ok(u64::from(!self.revoked && c.user_id == 42))
        })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn read_visible_post<'a>(
        &'a self,
        viewer: Option<u64>,
        id: u64,
    ) -> StoreFuture<'a, Option<Value>> {
        Box::pin(async move {
            *self.viewer.lock().unwrap() = viewer;
            self.step("post")?;
            if id != 1 {
                return Err(SessionStoreError);
            };
            Ok((!self.missing).then(|| self.post.clone()))
        })
    }
    fn read_post_author<'a>(&'a self, _: Option<u64>, id: u64) -> StoreFuture<'a, Option<Value>> {
        Box::pin(async move {
            self.step("author")?;
            if id != 7 {
                return Err(SessionStoreError);
            };
            Ok((self.fault != "author-missing").then(|| self.post["author"].clone()))
        })
    }
    fn media_readiness<'a>(&'a self) -> StoreFuture<'a, ()> {
        Box::pin(async { self.step("media-ready") })
    }
    fn read_post_media<'a>(&'a self, _: u64) -> StoreFuture<'a, Vec<Value>> {
        Box::pin(async {
            self.step("media")?;
            Ok(self.post["media"].as_array().unwrap().clone())
        })
    }
    fn read_post_tags<'a>(&'a self, _: u64) -> StoreFuture<'a, Vec<String>> {
        Box::pin(async {
            self.step("tags")?;
            Ok(self.post["tags"]
                .as_array()
                .unwrap()
                .iter()
                .map(|x| x.as_str().unwrap().into())
                .collect())
        })
    }
    fn read_post_mentions<'a>(&'a self, _: Option<u64>, _: u64) -> StoreFuture<'a, Vec<Value>> {
        Box::pin(async {
            self.step("mentions")?;
            Ok(self.post["mentions"].as_array().unwrap().clone())
        })
    }
    fn increment_post_views<'a>(&'a self, _: u64) -> StoreFuture<'a, ()> {
        Box::pin(async { self.step("views") })
    }
}
#[tokio::test]
async fn shared_post_detail_vectors() {
    let data: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/post-detail-vectors.json"
    ))
    .unwrap();
    let tokens: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = |id: &str| {
        tokens["cases"]
            .as_array()
            .unwrap()
            .iter()
            .find(|x| x["id"] == id)
            .unwrap()["token"]
            .as_str()
            .unwrap()
    };
    let cases = data["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 22);
    for tc in cases {
        let flag = |k: &str| tc[k].as_bool().unwrap_or(false);
        let s = Arc::new(Store {
            post: data["post"].clone(),
            events: Mutex::new(Vec::new()),
            viewer: Mutex::new(None),
            fault: tc["fault"].as_str().unwrap_or("").into(),
            missing: flag("missing"),
            revoked: flag("revoked"),
            touch_fail: flag("touch_fail"),
        });
        let codec = TokenCodec::new(
            tokens["keys"]["access"].as_str().unwrap().as_bytes(),
            tokens["keys"]["refresh"].as_str().unwrap().as_bytes(),
        )
        .unwrap();
        let app = build_native_router(
            codec,
            s.clone(),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
        );
        let mut req = Request::builder().uri(format!(
            "/api/v2/posts/{}?viewer_id=99",
            tc["target"].as_str().unwrap()
        ));
        req = match tc["auth"].as_str().unwrap() {
            "valid" => req.header("authorization", format!("Bearer {}", token("access-hs256"))),
            "cookie" => req.header("cookie", format!("access_token={}", token("access-hs256"))),
            "bad-cookie" => req
                .header("cookie", "access_token=bad")
                .header("authorization", format!("Bearer {}", token("access-hs256"))),
            "expired" => req.header("authorization", format!("Bearer {}", token("expired"))),
            _ => req,
        };
        let response = app.oneshot(req.body(Body::empty()).unwrap()).await.unwrap();
        assert_eq!(
            response.status().as_u16(),
            tc["status"].as_u64().unwrap() as u16,
            "{}",
            tc["id"]
        );
        assert_eq!(
            json!(*s.events.lock().unwrap()),
            tc["events"],
            "{}",
            tc["id"]
        );
        if tc["status"] == 200 {
            assert_eq!(response.headers()["cache-control"], "private, no-store")
        };
        let text = String::from_utf8(
            response
                .into_body()
                .collect()
                .await
                .unwrap()
                .to_bytes()
                .to_vec(),
        )
        .unwrap();
        assert!(!text.contains("private-database-error"));
        if tc["status"] == 200 {
            let v: Value = serde_json::from_str(&text).unwrap();
            assert_eq!(v["data"], data["post"])
        }
        if !tc["events"].as_array().unwrap().is_empty() {
            assert_eq!(
                *s.viewer.lock().unwrap(),
                if tc["auth"] == "none" { None } else { Some(42) }
            )
        }
    }
}
