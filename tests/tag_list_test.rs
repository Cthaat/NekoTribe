use axum::{body::Body, http::Request};
use http_body_util::BodyExt;
use nekotribe_backend::{
    auth::{
        sessions::{
            build_native_router, CorsPolicy, SessionRepository, SessionStoreError, StoreFuture,
        },
        TokenClaims, TokenCodec,
    },
    tags::TagListQuery,
};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

struct Store {
    query: Mutex<Option<TagListQuery>>,
    items: Vec<Value>,
    revoked: bool,
    fail: bool,
}
impl SessionRepository for Store {
    fn touch<'a>(&'a self, c: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async move { Ok(u64::from(!self.revoked && c.user_id == 42)) })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn list_tags<'a>(&'a self, q: &'a TagListQuery) -> StoreFuture<'a, (Vec<Value>, u64)> {
        Box::pin(async move {
            *self.query.lock().unwrap() = Some(q.clone());
            if self.fail {
                return Err(SessionStoreError);
            };
            Ok((self.items.clone(), 3))
        })
    }
}
#[tokio::test]
async fn shared_tag_list_vectors() {
    let data: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/tag-list.json")).unwrap();
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
    for tc in data["cases"].as_array().unwrap() {
        let auth = tc["auth"].as_str().unwrap();
        let store = Arc::new(Store {
            query: Mutex::new(None),
            items: data["items"].as_array().unwrap().clone(),
            revoked: auth == "revoked",
            fail: tc["failure"] == true,
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
        let mut req = Request::builder().uri(tc["path"].as_str().unwrap());
        req = match auth {
            "valid" | "revoked" => req.header("authorization", format!("Bearer {valid}")),
            "cookie" => req.header("cookie", format!("access_token={valid}")),
            "bad-cookie" => req
                .header("cookie", "access_token=bad")
                .header("authorization", format!("Bearer {valid}")),
            "bad" => req.header("authorization", "Bearer bad"),
            _ => req,
        };
        let response = app.oneshot(req.body(Body::empty()).unwrap()).await.unwrap();
        assert_eq!(
            response.status().as_u16(),
            tc["status"].as_u64().unwrap() as u16,
            "{}",
            tc["id"]
        );
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        let text = String::from_utf8(bytes.to_vec()).unwrap();
        assert!(!text.contains("private-tag-database-error"));
        if tc["status"] == 200 {
            let body: Value = serde_json::from_str(&text).unwrap();
            let guard = store.query.lock().unwrap();
            let q = guard.as_ref().unwrap();
            assert_eq!(q.q.as_deref(), tc["q"].as_str());
            assert_eq!(q.trending, tc["trending"].as_bool().unwrap());
            assert_eq!(q.page.page, tc["page"].as_f64().unwrap());
            assert_eq!(q.page.page_size, tc["size"].as_f64().unwrap());
            assert_eq!(body["data"], data["items"]);
            assert_eq!(
                body["meta"],
                json!({"page":q.page.page,"page_size":q.page.page_size,"total":3,"has_next":q.page.end<3.0})
            );
        }
    }
}
