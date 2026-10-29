use nekotribe_backend::{
    auth::{
        session_repository::{OracleSessions, SessionExecutor},
        sessions::{SessionRepository, SessionStoreError, StoreFuture},
        storage_urls::StorageUrlPolicy,
    },
    db::oracle::BindMap,
    media::upload_transaction::{MediaUpload, MediaUploadOutcome},
};
use std::sync::Mutex;

#[derive(Default)]
struct Executor {
    calls: Mutex<Vec<(i64, String)>>,
}

impl SessionExecutor for Executor {
    fn execute(&self, _: &'static str, _: BindMap) -> StoreFuture<'_, u64> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn preflight(&self, _: &'static str) -> StoreFuture<'_, ()> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn create_media_atomic<'a>(
        &'a self,
        input: &'a MediaUpload,
        policy: &'a StorageUrlPolicy,
    ) -> StoreFuture<'a, MediaUploadOutcome<serde_json::Value>> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((
                input.user_id,
                policy.normalize_avatar("/storage/posts/a").unwrap(),
            ));
            Ok(MediaUploadOutcome::Failed {
                cleanup_safe: false,
                schema_unavailable: false,
            })
        })
    }
}

#[tokio::test]
async fn repository_preserves_unknown_commit_and_delegates_input_and_policy() {
    let repository = OracleSessions {
        executor: Executor::default(),
    };
    let input = MediaUpload {
        user_id: 42,
        size: 1,
        key: "posts/a".into(),
        public_url: "/storage/posts/a".into(),
        filename: "a".into(),
        media_type: "image".into(),
        mime_type: "image/png".into(),
        width: None,
        height: None,
        duration: None,
        thumbnail_url: None,
        alt_text: None,
        description: None,
    };
    let policy = StorageUrlPolicy::from_lookup(|key| {
        (key == "STORAGE_PUBLIC_BASE").then(|| "/media".into())
    });
    let outcome = repository
        .create_media_atomic(&input, &policy)
        .await
        .unwrap();
    assert!(!outcome.cleanup_safe());
    assert_eq!(
        *repository.executor.calls.lock().unwrap(),
        [(42, "/media/posts/a".into())]
    );
}
