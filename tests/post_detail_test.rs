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
    list_query: Mutex<Option<nekotribe_backend::posts::list::PostListQuery>>,
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
    fn list_visible_posts<'a>(
        &'a self,
        viewer: Option<u64>,
        query: &'a nekotribe_backend::posts::list::PostListQuery,
    ) -> StoreFuture<'a, (Vec<Value>, u64)> {
        Box::pin(async move {
            *self.viewer.lock().unwrap() = viewer;
            *self.list_query.lock().unwrap() = Some(query.clone());
            self.step("list")?;
            Ok((
                if self.missing {
                    vec![]
                } else {
                    vec![self.post.clone()]
                },
                3,
            ))
        })
    }
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
            list_query: Mutex::new(None),
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

#[tokio::test]
async fn post_list_route_auth_search_and_failures() {
    let data: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/post-detail-vectors.json"
    ))
    .unwrap();
    let tokens: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let valid = tokens["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|x| x["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    for (query, token, fault, empty, status, events) in [
        (
            "?page=2&page_size=1&q=%20%23%23Cat_%25%20&sort=popular&viewer_id=99",
            "",
            "",
            false,
            200,
            vec!["list", "author", "media-ready", "media", "tags", "mentions"],
        ),
        ("?timeline=following", "", "", false, 401, vec![]),
        ("?timeline=mentions", "", "", false, 401, vec![]),
        (
            "?timeline=following",
            valid,
            "",
            false,
            200,
            vec!["list", "author", "media-ready", "media", "tags", "mentions"],
        ),
        ("", "bad", "", false, 401, vec![]),
        ("", "", "", true, 200, vec!["list"]),
        ("", "", "list", false, 500, vec!["list"]),
        (
            "",
            "",
            "media-ready",
            false,
            503,
            vec!["list", "author", "media-ready"],
        ),
    ] {
        let store = Arc::new(Store {
            post: data["post"].clone(),
            events: Mutex::new(vec![]),
            viewer: Mutex::new(None),
            list_query: Mutex::new(None),
            fault: fault.into(),
            missing: empty,
            revoked: false,
            touch_fail: false,
        });
        let codec = TokenCodec::new(
            tokens["keys"]["access"].as_str().unwrap().as_bytes(),
            tokens["keys"]["refresh"].as_str().unwrap().as_bytes(),
        )
        .unwrap();
        let app = build_native_router(
            codec,
            store.clone(),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
        );
        let mut builder = Request::builder().uri(format!("/api/v2/posts{query}"));
        if !token.is_empty() {
            builder = builder.header("authorization", format!("Bearer {token}"));
        }
        let response = app
            .oneshot(builder.body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), status, "{query}");
        assert_eq!(*store.events.lock().unwrap(), events, "{query}");
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        let text = String::from_utf8(bytes.to_vec()).unwrap();
        assert!(!text.contains("private-database-error"));
        let body: Value = serde_json::from_str(&text).unwrap();
        if (query == "?timeline=following" || query == "?timeline=mentions") && token.is_empty() {
            assert_eq!(body["message"], "未认证或 token 无效");
        }
        if query.contains("sort=popular") {
            let guard = store.list_query.lock().unwrap();
            let parsed = guard.as_ref().unwrap();
            assert_eq!(parsed.search, "##cat_%");
            assert_eq!(parsed.tag_search, "cat_%");
            assert_eq!(parsed.sort, "popular");
            assert_eq!(*store.viewer.lock().unwrap(), None);
            assert_eq!(body["data"], json!([data["post"].clone()]));
            assert_eq!(
                body["meta"],
                json!({"page":2.0,"page_size":1.0,"total":3,"has_next":true})
            );
        }
        if query == "?timeline=following" && token == valid {
            assert_eq!(*store.viewer.lock().unwrap(), Some(42));
        }
    }
}

#[test]
fn post_list_search_lowercases_unicode_like_the_nuxt_baseline() {
    let query = nekotribe_backend::posts::list::parse_post_list_query("q=%C4%B0%20%CE%9F%CE%A3");
    assert_eq!(query.search, "i\u{307} ος");
}

#[tokio::test]
async fn post_list_modes_require_auth_and_trending_forces_sort() {
    let data: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/post-detail-vectors.json"
    ))
    .unwrap();
    let tokens: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let valid = tokens["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|x| x["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    for (path, mode, anonymous_status) in [
        ("/api/v2/posts/trending?sort=oldest", "trending", 200),
        ("/api/v2/users/me/posts?viewer_id=99", "me", 401),
        ("/api/v2/users/me/bookmarks?viewer_id=99", "bookmarks", 401),
        (
            "/api/v2/users/me/likes?sort=oldest&viewer_id=99",
            "likes",
            401,
        ),
    ] {
        for authenticated in [false, true] {
            let store = Arc::new(Store {
                post: data["post"].clone(),
                events: Mutex::new(vec![]),
                viewer: Mutex::new(None),
                list_query: Mutex::new(None),
                fault: "".into(),
                missing: true,
                revoked: false,
                touch_fail: false,
            });
            let codec = TokenCodec::new(
                tokens["keys"]["access"].as_str().unwrap().as_bytes(),
                tokens["keys"]["refresh"].as_str().unwrap().as_bytes(),
            )
            .unwrap();
            let app = build_native_router(
                codec,
                store.clone(),
                CorsPolicy::default(),
                Arc::new(|| 1_700_000_000),
            );
            let mut req = Request::builder().uri(path);
            if authenticated {
                req = req.header("authorization", format!("Bearer {valid}"));
            }
            let response = app.oneshot(req.body(Body::empty()).unwrap()).await.unwrap();
            assert_eq!(
                response.status().as_u16(),
                if authenticated { 200 } else { anonymous_status },
                "{path}"
            );
            if authenticated || anonymous_status == 200 {
                let guard = store.list_query.lock().unwrap();
                let query = guard.as_ref().unwrap();
                assert_eq!(query.mode, mode);
                if mode == "trending" {
                    assert_eq!(query.sort, "popular");
                }
                if mode != "trending" {
                    assert_eq!(*store.viewer.lock().unwrap(), Some(42));
                }
            }
        }
    }
}
