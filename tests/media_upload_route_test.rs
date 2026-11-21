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
    users::avatar::AvatarUpload,
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
    fn preflight_private_media_upload(&self) -> StoreFuture<'_, ()> {
        Box::pin(async move {
            if self.mode == "old-schema" {
                Err(SessionStoreError)
            } else {
                Ok(())
            }
        })
    }
    fn create_media_atomic<'a>(
        &'a self,
        input: &'a MediaUpload,
        _: &'a StorageUrlPolicy,
    ) -> StoreFuture<'a, MediaUploadOutcome<serde_json::Value>> {
        Box::pin(async move {
            self.keys.lock().unwrap().push(input.key.clone());
            match self.mode {
                "success" | "old-schema" => Ok(MediaUploadOutcome::Created(
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

    fn replace_user_avatar(&self, input: AvatarUpload) -> StoreFuture<'_, MediaUploadOutcome<i64>> {
        Box::pin(async move {
            assert_eq!(input.user_id, 42);
            let expected = if input.key.ends_with(".png") {
                "image/png"
            } else {
                "image/gif"
            };
            assert_eq!(input.mime, expected);
            self.keys.lock().unwrap().push(input.key);
            Ok(match self.mode {
                "success" => MediaUploadOutcome::Created(12),
                "rollback" | "commit" => MediaUploadOutcome::Failed {
                    cleanup_safe: self.mode == "rollback",
                    schema_unavailable: false,
                },
                _ => return Err(SessionStoreError),
            })
        })
    }
}

#[tokio::test]
async fn shared_user_avatar_routes() {
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
    let cases: serde_json::Value =
        serde_json::from_str(include_str!("../contracts/scenarios/user-avatar.json")).unwrap();
    for vector in cases["cases"].as_array().unwrap() {
        let codec = TokenCodec::new(
            tokens["keys"]["access"].as_str().unwrap().as_bytes(),
            tokens["keys"]["refresh"].as_str().unwrap().as_bytes(),
        )
        .unwrap();
        let root = tempfile::tempdir().unwrap();
        let old = root.path().join("old-avatar.png");
        std::fs::write(&old, b"old").unwrap();
        let mode = match vector["fault"].as_str() {
            Some("rollback") => "rollback",
            Some("commit") => "commit",
            _ => "success",
        };
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
            unsupported: vector["fault"] == "storage-config",
            s3: None,
        }));
        let mut body = Vec::new();
        for part in vector["parts"].as_array().unwrap() {
            let field = part["field"].as_str().unwrap();
            let filename = part["name"]
                .as_str()
                .map(|name| format!("; filename=\"{name}\""))
                .unwrap_or_default();
            body.extend_from_slice(
                format!("--x\r\nContent-Disposition: form-data; name=\"{field}\"{filename}\r\n")
                    .as_bytes(),
            );
            let content_type = part["contentType"].as_str().unwrap_or("image/png");
            if !content_type.is_empty() {
                body.extend_from_slice(format!("Content-Type: {content_type}\r\n").as_bytes());
            }
            body.extend_from_slice(b"\r\n");
            let mut data = hex::decode(part["hex"].as_str().unwrap()).unwrap();
            if let Some(size) = part["size"].as_u64() {
                data.resize(size as usize, 0);
            }
            body.extend(data);
            body.extend_from_slice(b"\r\n");
        }
        body.extend_from_slice(b"--x--\r\n");
        let mut req = Request::put("/api/v2/users/me/avatar?user_id=99")
            .header("Content-Type", "multipart/form-data; boundary=x");
        if vector["status"] != 401 {
            req = req.header("Authorization", format!("Bearer {token}"));
        }
        let response = app
            .oneshot(req.body(Body::from(body)).unwrap())
            .await
            .unwrap();
        assert_eq!(
            response.status().as_u16() as u64,
            vector["status"].as_u64().unwrap(),
            "{}",
            vector["id"]
        );
        assert_eq!(response.headers()["Cache-Control"], "private, no-store");
        let keys = store.keys.lock().unwrap();
        if vector["fault"] == "storage-config" {
            let bytes = axum::body::to_bytes(response.into_body(), 4096)
                .await
                .unwrap();
            let payload: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(payload["code"], 50301);
            assert_eq!(payload["message"], "媒体存储暂不可用");
            assert!(keys.is_empty());
            assert!(old.is_file());
            assert!(!root.path().join("temp").exists());
            continue;
        }
        match vector["extension"].as_str() {
            Some(extension) => {
                assert_eq!(keys.len(), 1);
                assert!(keys[0].starts_with("avatars/42/") && keys[0].ends_with(extension));
                assert_eq!(root.path().join(&keys[0]).is_file(), mode != "rollback");
                if vector["status"] == 200 {
                    let bytes = axum::body::to_bytes(response.into_body(), 4096)
                        .await
                        .unwrap();
                    let payload: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
                    assert_eq!(payload["data"]["avatar_media_id"], 12);
                    assert_eq!(
                        payload["data"]["avatar_url"],
                        format!("/storage/{}", keys[0])
                    );
                }
            }
            None => assert!(keys.is_empty()),
        }
        assert!(old.is_file());
    }
}

#[tokio::test]
async fn wav_upload_reports_duration() {
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
        s3: None,
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
        s3: None,
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
    let legacy_cases = [
        ("success", &[][..], 200, Some("posts/files/42/"), true),
        ("old-schema", &["public"][..], 200, Some("posts/files/42/"), true),
        ("success", &["chat", "public"][..], 200, Some("private/chat/files/42/"), true),
        ("rollback", &["post"][..], 500, Some("private/post/files/42/"), false),
        ("old-schema", &["chat"][..], 503, None, false),
        ("success", &["", "chat"][..], 400, None, false),
        ("success", &[" chat"][..], 400, None, false),
        ("rollback", &[][..], 500, Some("posts/files/42/"), false),
        ("schema", &[][..], 503, Some("posts/files/42/"), false),
        ("unknown", &[][..], 500, Some("posts/files/42/"), true),
        ("error", &[][..], 500, Some("posts/files/42/"), true),
    ];
    let private_cases = [
        ("success", &["chat", "public"][..], 200, Some("private/chat/files/42/"), true),
        ("success", &["post"][..], 200, Some("private/post/files/42/"), true),
        ("success", &[][..], 400, None, false),
        ("success", &["public", "chat"][..], 400, None, false),
        ("success", &[""][..], 400, None, false),
        ("old-schema", &["chat"][..], 503, None, false),
    ];
    let cases = legacy_cases.into_iter().map(|case| ("/api/v2/media", case))
        .chain(private_cases.into_iter().map(|case| ("/api/v2/media/private", case)));
    for (path, (mode, fields, status, expected_prefix, retained)) in cases {
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
            s3: None,
        }));
        let mut body = String::new();
        for scope in fields {
            body.push_str(&format!("--x\r\nContent-Disposition: form-data; name=\"access_scope\"\r\n\r\n{scope}\r\n"));
        }
        body.push_str("--x\r\nContent-Disposition: form-data; name=\"file\"; filename=\"note.txt\"\r\nContent-Type: text/plain\r\n\r\nhello\r\n--x--\r\n");
        let request = Request::post(path)
            .header("Authorization", format!("Bearer {token}"))
            .header("Content-Type", "multipart/form-data; boundary=x")
            .body(Body::from(body))
            .unwrap();
        let response = app.clone().oneshot(request).await.unwrap();
        assert_eq!(response.status().as_u16(), status, "{path} {mode} {fields:?}");
        assert_eq!(response.headers()["cache-control"], "private, no-store");
        let keys = store.keys.lock().unwrap();
        if let Some(prefix) = expected_prefix {
            assert_eq!(keys.len(), 1, "{mode}");
            assert!(keys[0].starts_with(prefix), "{mode}");
            assert_eq!(root.path().join(&keys[0]).exists(), retained, "{mode}");
        } else {
            assert!(keys.is_empty(), "{mode}");
            assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 0);
            let bytes = axum::body::to_bytes(response.into_body(), 4096).await.unwrap();
            let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
            if status == 503 {
                assert_eq!(json["code"], 50301);
                assert_eq!(json["message"], "媒体存储暂不可用");
            } else {
                assert_eq!(json["code"], 40001);
                assert_eq!(json["message"], "媒体访问范围无效");
            }
        }
        let unauthorized = app
            .oneshot(
                Request::post(path)
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
        ("multipart/form-data; boundary=x", b"--x\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\nContent-Type: text/plain\r\n\r\nhello\r\n--x--\r\n".as_slice(), true, 503),
    ] {
        let codec = TokenCodec::new(tokens["keys"]["access"].as_str().unwrap().as_bytes(), tokens["keys"]["refresh"].as_str().unwrap().as_bytes()).unwrap();
        let root = tempfile::tempdir().unwrap();
        let store = Arc::new(Store { mode: "success", keys: Mutex::new(vec![]) });
        let app = build_native_router(codec, store.clone(), CorsPolicy::default(), Arc::new(|| 1_700_000_000)).layer(Extension(LocalStorageConfig { root: root.path().into(), unsupported, s3: None }));
        let req = Request::post("/api/v2/media").header("Authorization", format!("Bearer {token}")).header("Content-Type", content_type).body(Body::from(body.to_vec())).unwrap();
        let response = app.oneshot(req).await.unwrap();
        assert_eq!(response.status().as_u16(), status);
        assert!(store.keys.lock().unwrap().is_empty());
        assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 0);
    }
}
