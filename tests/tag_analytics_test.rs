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
    result: Value,
    missing: bool,
    fail: bool,
    revoked: bool,
    call: Mutex<Option<(u64, String)>>,
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
    fn read_tag_analytics<'a>(
        &'a self,
        viewer: u64,
        name: &'a str,
    ) -> StoreFuture<'a, Option<Value>> {
        Box::pin(async move {
            *self.call.lock().unwrap() = Some((viewer, name.to_owned()));
            if self.fail {
                return Err(SessionStoreError);
            };
            Ok((!self.missing).then(|| self.result.clone()))
        })
    }
}
#[tokio::test]
async fn shared_analytics_vectors() {
    let data: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/tag-analytics.json")).unwrap();
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
        let result = if tc["zero"] == true {
            json!({"name":"C# cats","total_posts":0,"total_authors":0,"total_views":0,"total_likes":0,"engagement_score":0})
        } else {
            data["result"].clone()
        };
        let s = Arc::new(Store {
            result: result.clone(),
            missing: tc["missing"] == true,
            fail: tc["failure"] == true,
            revoked: auth == "revoked",
            call: Mutex::new(None),
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
        let mut req = Request::builder().uri(tc["path"].as_str().unwrap());
        req = match auth {
            "valid" | "revoked" => req.header("authorization", format!("Bearer {valid}")),
            "cookie" => req.header("cookie", format!("access_token={valid}")),
            "bad" => req.header("authorization", "Bearer bad"),
            "bad-cookie" => req
                .header("cookie", "access_token=bad")
                .header("authorization", format!("Bearer {valid}")),
            _ => req,
        };
        let response = app.oneshot(req.body(Body::empty()).unwrap()).await.unwrap();
        assert_eq!(
            response.status().as_u16(),
            tc["status"].as_u64().unwrap() as u16,
            "{}",
            tc["id"]
        );
        assert_eq!(response.headers()["cache-control"], "private, no-store");
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
        assert!(!text.contains("private-tag-analytics-error"));
        if let Some(name) = tc["name"].as_str() {
            assert_eq!(*s.call.lock().unwrap(), Some((42, name.into())));
        } else {
            assert!(s.call.lock().unwrap().is_none());
        }
        if tc["status"] == 200 {
            let body: Value = serde_json::from_str(&text).unwrap();
            assert_eq!(body["data"], result);
        }
    }
}
