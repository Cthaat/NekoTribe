use axum::{body::Body, http::Request, Extension};
use nekotribe_backend::{
    auth::{
        sessions::{
            build_native_router, CorsPolicy, SessionRepository, SessionStoreError, StoreFuture,
        },
        storage_urls::StorageUrlPolicy,
        TokenClaims, TokenCodec,
    },
    media::upload_transaction::{MediaUpload, MediaUploadOutcome},
    storage::local_http::LocalStorageConfig,
};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

struct Store {
    mode: &'static str,
    keys: Mutex<Vec<String>>,
}
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
    fn create_media_atomic<'a>(
        &'a self,
        input: &'a MediaUpload,
        _: &'a StorageUrlPolicy,
    ) -> StoreFuture<'a, MediaUploadOutcome<serde_json::Value>> {
        Box::pin(async move {
            self.keys.lock().unwrap().push(input.key.clone());
            match self.mode {
                "success" => Ok(MediaUploadOutcome::Created(
                    serde_json::json!({"media_id": 12, "mime_type": input.mime_type, "file_size": input.size, "width": input.width, "height": input.height, "duration": input.duration}),
                )),
                "rollback" => Ok(MediaUploadOutcome::Failed {
                    cleanup_safe: true,
                    schema_unavailable: false,
                }),
                "schema" => Ok(MediaUploadOutcome::Failed {
                    cleanup_safe: true,
                    schema_unavailable: true,
                }),
                "unknown" => Ok(MediaUploadOutcome::Failed {
                    cleanup_safe: false,
                    schema_unavailable: false,
                }),
                _ => Err(SessionStoreError),
            }
        })
    }
}

#[tokio::test]
#[ignore = "requires FFPROBE_PATH set to a working ffprobe"]
async fn real_wav_upload_reports_duration() {
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
    let store = Arc::new(Store {
        mode: "success",
        keys: Mutex::new(vec![]),
    });
    let app = build_native_router(
        codec,
        store,
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_000),
    )
    .layer(Extension(LocalStorageConfig {
        root: root.path().into(),
        unsupported: false,
    }));
    let mut wav = Vec::from(&b"RIFF"[..]);
    wav.extend_from_slice(&16036u32.to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&8000u32.to_le_bytes());
    wav.extend_from_slice(&16000u32.to_le_bytes());
    wav.extend_from_slice(&2u16.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&16000u32.to_le_bytes());
    wav.resize(wav.len() + 16000, 0);
    let mut body = b"--x\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n".to_vec();
    body.extend_from_slice(&wav);
    body.extend_from_slice(b"\r\n--x--\r\n");
    let req = Request::post("/api/v2/media")
        .header("Authorization", format!("Bearer {token}"))
        .header("Content-Type", "multipart/form-data; boundary=x")
        .body(Body::from(body))
        .unwrap();
    let response = app.oneshot(req).await.unwrap();
    assert_eq!(response.status().as_u16(), 200);
    let bytes = axum::body::to_bytes(response.into_body(), 4096)
        .await
        .unwrap();
    let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(json["data"]["duration"], 1.0);
}

#[tokio::test]
async fn uploaded_image_records_dimensions() {
    use base64::{engine::general_purpose::STANDARD, Engine};
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
    let store = Arc::new(Store {
        mode: "success",
        keys: Mutex::new(vec![]),
    });
    let app = build_native_router(
        codec,
        store,
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_000),
    )
    .layer(Extension(LocalStorageConfig {
        root: root.path().into(),
        unsupported: false,
    }));
    let mut body = b"--x\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.png\"\r\nContent-Type: image/png\r\n\r\n".to_vec();
    body.extend(STANDARD.decode("iVBORw0KGgoAAAANSUhEUgAAAAcAAAAFCAIAAAAG+GGPAAAACXBIWXMAAAPoAAAD6AG1e1JrAAAAEUlEQVR4nGNYtfsMJmKgkSgAdy1MtEKm+7sAAAAASUVORK5CYII=").unwrap());
    body.extend_from_slice(b"\r\n--x--\r\n");
    let req = Request::post("/api/v2/media")
        .header("Authorization", format!("Bearer {token}"))
        .header("Content-Type", "multipart/form-data; boundary=x")
        .body(Body::from(body))
        .unwrap();
    let response = app.oneshot(req).await.unwrap();
    assert_eq!(response.status().as_u16(), 200);
    let bytes = axum::body::to_bytes(response.into_body(), 4096)
        .await
        .unwrap();
    let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(json["data"]["width"], 7.0);
    assert_eq!(json["data"]["height"], 5.0);
}

#[tokio::test]
async fn upload_authentication_and_transaction_lifecycle() {
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
    for (mode, status, retained) in [
        ("success", 200, true),
        ("rollback", 500, false),
        ("schema", 503, false),
        ("unknown", 500, true),
        ("error", 500, true),
    ] {
        let codec = TokenCodec::new(
            tokens["keys"]["access"].as_str().unwrap().as_bytes(),
            tokens["keys"]["refresh"].as_str().unwrap().as_bytes(),
        )
        .unwrap();
        let root = tempfile::tempdir().unwrap();
        let store = Arc::new(Store {
            mode,
            keys: Mutex::new(vec![]),
        });
        let app = build_native_router(
            codec,
            store.clone(),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
        )
        .layer(Extension(LocalStorageConfig {
            root: root.path().into(),
            unsupported: false,
        }));
        let request = Request::post("/api/v2/media").header("Authorization", format!("Bearer {token}")).header("Content-Type", "multipart/form-data; boundary=x").body(Body::from("--x\r\nContent-Disposition: form-data; name=\"file\"; filename=\"note.txt\"\r\nContent-Type: text/plain\r\n\r\nhello\r\n--x--\r\n")).unwrap();
        let response = app.clone().oneshot(request).await.unwrap();
        assert_eq!(response.status().as_u16(), status, "{mode}");
        assert_eq!(response.headers()["cache-control"], "private, no-store");
        let keys = store.keys.lock().unwrap();
        assert_eq!(keys.len(), 1, "{mode}");
        assert_eq!(root.path().join(&keys[0]).exists(), retained, "{mode}");
        let unauthorized = app
            .oneshot(
                Request::post("/api/v2/media")
                    .header("Content-Type", "application/json")
                    .body(Body::from("bad"))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(unauthorized.status().as_u16(), 401);
    }
}

#[tokio::test]
async fn upload_rejects_bad_input_before_writing_and_reports_unsupported_storage() {
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
    for (content_type, body, unsupported, status) in [
        ("application/json", b"{}".as_slice(), false, 400),
        ("multipart/form-data; boundary=x", b"--x--\r\n".as_slice(), false, 400),
        ("multipart/form-data; boundary=x", b"--x\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\nContent-Type: text/plain\r\n\r\nMZ\x90\x00\x03\x00\x00\x00\r\n--x--\r\n".as_slice(), false, 400),
        ("multipart/form-data; boundary=x", b"--x\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\nContent-Type: text/plain\r\n\r\nhello\r\n--x--\r\n".as_slice(), true, 501),
    ] {
        let codec = TokenCodec::new(tokens["keys"]["access"].as_str().unwrap().as_bytes(), tokens["keys"]["refresh"].as_str().unwrap().as_bytes()).unwrap();
        let root = tempfile::tempdir().unwrap();
        let store = Arc::new(Store { mode: "success", keys: Mutex::new(vec![]) });
        let app = build_native_router(codec, store.clone(), CorsPolicy::default(), Arc::new(|| 1_700_000_000)).layer(Extension(LocalStorageConfig { root: root.path().into(), unsupported }));
        let req = Request::post("/api/v2/media").header("Authorization", format!("Bearer {token}")).header("Content-Type", content_type).body(Body::from(body.to_vec())).unwrap();
        let response = app.oneshot(req).await.unwrap();
        assert_eq!(response.status().as_u16(), status);
        assert!(store.keys.lock().unwrap().is_empty());
        assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 0);
    }
}
