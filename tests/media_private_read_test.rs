use axum::{
    body::{to_bytes, Body},
    http::{header, Method, Request},
    Extension,
};
use nekotribe_backend::{
    auth::{
        sessions::{build_native_router, CorsPolicy, SessionRepository, StoreFuture},
        TokenClaims, TokenCodec,
    },
    media::private_read::Lookup,
    storage::local_http::{self, LocalStorageConfig},
};
use std::{fs, sync::Arc};
use tower::ServiceExt;

const PRIVATE_KEY: &str = "private/chat/42/photo.png";

struct Store;

impl SessionRepository for Store {
    fn touch<'a>(&'a self, claims: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async move { Ok(u64::from(claims.user_id == 42)) })
    }

    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }

    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }

    fn lookup_private_media(&self, viewer_id: i64, media_id: i64) -> StoreFuture<'_, Lookup> {
        assert_eq!(viewer_id, 42);
        Box::pin(async move {
            Ok(match media_id {
                1 => Lookup::Permitted {
                    storage_key: PRIVATE_KEY.into(),
                    access_scope: "chat".into(),
                },
                2 => Lookup::Missing,
                3 => Lookup::SchemaUnavailable,
                4 => Lookup::Permitted {
                    storage_key: PRIVATE_KEY.into(),
                    access_scope: "post".into(),
                },
                5 => Lookup::Permitted {
                    storage_key: "private/chat/42/absent.png".into(),
                    access_scope: "chat".into(),
                },
                _ => panic!("unexpected media ID in lookup"),
            })
        })
    }
}

#[tokio::test]
async fn private_download_applies_authorization_before_local_streaming() {
    let tokens: serde_json::Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = tokens["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    let codec = TokenCodec::new(
        tokens["keys"]["access"].as_str().unwrap().as_bytes(),
        tokens["keys"]["refresh"].as_str().unwrap().as_bytes(),
    )
    .unwrap();
    let root = tempfile::tempdir().unwrap();
    let file = root.path().join(PRIVATE_KEY);
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    fs::write(file, b"0123456789").unwrap();
    let config = LocalStorageConfig {
        root: root.path().into(),
        unsupported: false,
        s3: None,
    };
    let app = build_native_router(
        codec,
        Arc::new(Store),
        CorsPolicy {
            origins: vec!["https://client.example".into()],
            localhost: false,
        },
        Arc::new(|| 1_700_000_000),
    )
    .layer(Extension(config.clone()))
    .merge(local_http::router(config));
    for (method, id, range, authenticated, status, content_range, expected_body) in [
        (Method::GET, "1", "", false, 401, "", None),
        (Method::HEAD, "1", "", false, 401, "", Some("")),
        (Method::GET, "01", "", true, 400, "", None),
        (Method::GET, "9007199254740992", "", true, 400, "", None),
        (Method::GET, "2", "bytes=1-2", true, 404, "", None),
        (Method::GET, "3", "", true, 503, "", None),
        (Method::GET, "4", "", true, 404, "", None),
        (Method::GET, "5", "", true, 404, "", None),
        (Method::GET, "1", "", true, 200, "", Some("0123456789")),
        (Method::HEAD, "1", "invalid", true, 200, "", Some("")),
        (
            Method::GET,
            "1",
            "bytes=-3",
            true,
            206,
            "bytes 7-9/10",
            Some("789"),
        ),
        (
            Method::GET,
            "1",
            "bytes=1-2,4-5",
            true,
            416,
            "bytes */10",
            None,
        ),
    ] {
        let mut request = Request::builder()
            .method(method)
            .uri(format!("/api/v2/media/{id}/content"))
            .header(header::ORIGIN, "https://client.example");
        if authenticated {
            request = request.header(header::AUTHORIZATION, format!("Bearer {token}"));
        }
        if !range.is_empty() {
            request = request.header(header::RANGE, range);
        }
        let response = app
            .clone()
            .oneshot(request.body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), status, "{id} {range}");
        let headers = response.headers();
        assert_eq!(headers[header::CACHE_CONTROL], "private, no-store");
        assert_eq!(headers["x-content-type-options"], "nosniff");
        assert!(!headers.contains_key(header::LOCATION));
        assert_eq!(
            headers
                .get(header::CONTENT_RANGE)
                .and_then(|v| v.to_str().ok())
                .unwrap_or(""),
            content_range
        );
        if response.status().is_success() {
            assert_eq!(headers[header::CONTENT_TYPE], "application/octet-stream");
            assert_eq!(headers[header::CONTENT_DISPOSITION], "attachment");
            assert_eq!(
                headers[header::CONTENT_LENGTH],
                if status == 206 { "3" } else { "10" }
            );
            assert_eq!(
                headers[header::ACCESS_CONTROL_ALLOW_ORIGIN],
                "https://client.example"
            );
            let exposed = headers[header::ACCESS_CONTROL_EXPOSE_HEADERS]
                .to_str()
                .unwrap();
            for name in ["content-range", "accept-ranges", "content-disposition"] {
                assert!(exposed.split(',').any(|value| value == name));
            }
        }
        let body = to_bytes(response.into_body(), 1024).await.unwrap();
        if status == 416 {
            let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
            assert_eq!(json["code"], 41601);
            assert_eq!(json["message"], "请求范围无效");
        }
        match expected_body {
            Some(expected) => assert_eq!(body.as_ref(), expected.as_bytes()),
            None => assert!(!String::from_utf8_lossy(&body).contains("private/")),
        }
    }
    for (uri, expected_status) in [("/api/v2/media/1/content", 204), ("/api/v2/media/1", 403)] {
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::OPTIONS)
                    .uri(uri)
                    .header(header::ORIGIN, "https://client.example")
                    .header(header::ACCESS_CONTROL_REQUEST_METHOD, "HEAD")
                    .header(
                        header::ACCESS_CONTROL_REQUEST_HEADERS,
                        "authorization,range",
                    )
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), expected_status);
        if expected_status == 204 {
            assert_eq!(
                response.headers()[header::CACHE_CONTROL],
                "private, no-store"
            );
            assert_eq!(
                response.headers()[header::ACCESS_CONTROL_ALLOW_METHODS],
                "GET,HEAD,OPTIONS"
            );
            assert_eq!(
                response.headers()[header::ACCESS_CONTROL_ALLOW_HEADERS],
                "authorization,range"
            );
        }
    }
    let response = app
        .oneshot(
            Request::get(format!("/storage/{PRIVATE_KEY}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), 404);
}
