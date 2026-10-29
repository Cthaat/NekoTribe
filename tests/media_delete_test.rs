use axum::{body::Body, http::Request, Extension};
use nekotribe_backend::{
    auth::{
        session_repository::{OracleSessions, SessionExecutor},
        sessions::{
            build_native_router, CorsPolicy, SessionRepository, SessionStoreError, StoreFuture,
        },
        TokenClaims, TokenCodec,
    },
    db::{oracle::BindMap, row::DbRow, value::DbValue},
    media::delete::MediaDelete,
    storage::local_http::LocalStorageConfig,
};
use std::{
    fs,
    sync::{Arc, Mutex},
};
use tower::ServiceExt;

struct Store {
    result: Result<Option<MediaDelete>, SessionStoreError>,
    calls: Mutex<Vec<(u64, f64)>>,
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
    fn delete_media(&self, user: u64, id: f64) -> StoreFuture<'_, Option<MediaDelete>> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((user, id));
            self.result.clone()
        })
    }
}

#[tokio::test]
async fn native_route_cleans_only_after_confirmed_delete() {
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
    let root = std::env::temp_dir().join(format!("neko-media-delete-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(root.join("owned")).unwrap();
    let file = root.join("owned/a.txt");
    for (result, status, exists) in [
        (
            Ok(Some(MediaDelete {
                key: Some("owned/a.txt".into()),
                public_url: None,
                thumbnail_url: None,
            })),
            200,
            false,
        ),
        (Ok(None), 404, true),
        (Err(SessionStoreError), 500, true),
    ] {
        fs::write(&file, b"safe").unwrap();
        let codec = TokenCodec::new(
            tokens["keys"]["access"].as_str().unwrap().as_bytes(),
            tokens["keys"]["refresh"].as_str().unwrap().as_bytes(),
        )
        .unwrap();
        let store = Arc::new(Store {
            result,
            calls: Mutex::new(vec![]),
        });
        let app = build_native_router(
            codec,
            store.clone(),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
        )
        .layer(Extension(LocalStorageConfig {
            root: root.clone(),
            unsupported: false,
        }));
        let req = Request::delete("/api/v2/media/2e1")
            .header("authorization", format!("Bearer {token}"))
            .body(Body::empty())
            .unwrap();
        let response = app.oneshot(req).await.unwrap();
        assert_eq!(response.status(), status);
        assert_eq!(response.headers()["cache-control"], "private, no-store");
        assert_eq!(*store.calls.lock().unwrap(), vec![(42, 20.0)]);
        assert_eq!(file.exists(), exists);
    }
    fs::remove_dir_all(root).unwrap();
}

struct Executor {
    rows: Vec<DbRow>,
    affected: u64,
    fail: bool,
    calls: Mutex<Vec<(&'static str, BindMap)>>,
}
impl SessionExecutor for Executor {
    fn preflight(&self, _: &'static str) -> StoreFuture<'_, ()> {
        Box::pin(async { Ok(()) })
    }
    fn query(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((sql, binds));
            Ok(self.rows.clone())
        })
    }
    fn execute(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, u64> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((sql, binds));
            if self.fail {
                Err(SessionStoreError)
            } else {
                Ok(self.affected)
            }
        })
    }
}
#[tokio::test]
async fn repository_scopes_owner_and_returns_only_confirmed_row() {
    for (exists, affected, fail) in [
        (false, 0, false),
        (true, 0, false),
        (true, 1, false),
        (true, 2, false),
        (true, 1, true),
    ] {
        let row = DbRow::from([
            ("STORAGE_KEY".into(), DbValue::String("owned/a.txt".into())),
            ("PUBLIC_URL".into(), DbValue::Null),
            ("THUMBNAIL_URL".into(), DbValue::Null),
        ]);
        let repo = OracleSessions {
            executor: Executor {
                rows: if exists { vec![row] } else { vec![] },
                affected,
                fail,
                calls: Mutex::new(vec![]),
            },
        };
        let result = repo.delete_media(42, 20.0).await;
        assert_eq!(result.is_err(), fail || affected > 1);
        if let Ok(value) = result {
            assert_eq!(value.is_some(), exists && affected == 1)
        }
        let calls = repo.executor.calls.lock().unwrap();
        assert!(calls[0].0.contains("owner_user_id=:user_id"));
        assert_eq!(calls[0].1["user_id"], DbValue::I64(42));
        if exists {
            assert!(calls[1].0.contains("owner_user_id=:user_id"));
            assert_eq!(calls[1].1["media_id"], DbValue::F64(20.0));
        }
    }
}

#[tokio::test]
async fn unauthenticated_and_invalid_ids_never_reach_store() {
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
    let store = Arc::new(Store {
        result: Ok(None),
        calls: Mutex::new(vec![]),
    });
    let app = build_native_router(
        codec,
        store.clone(),
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_000),
    );
    for (path, auth, status) in [("20", false, 401), ("invalid", true, 400), ("0", true, 400)] {
        let mut request = Request::delete(format!("/api/v2/media/{path}"));
        if auth {
            request = request.header("authorization", format!("Bearer {token}"));
        }
        let response = app
            .clone()
            .oneshot(request.body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), status);
        assert_eq!(response.headers()["cache-control"], "private, no-store");
    }
    assert!(store.calls.lock().unwrap().is_empty());
}
