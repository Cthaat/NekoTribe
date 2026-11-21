use crate::{
    auth::sessions::SessionStoreError,
    storage::{local_http::LocalStorageConfig, s3::S3Storage},
};
use std::io;

use super::{
    local_publish::{self, FinalizeError, PublishedMedia},
    upload_transaction::MediaUploadOutcome,
};

pub(crate) enum PublishedObject {
    Local(PublishedMedia),
    S3(S3Storage, String),
}

pub(crate) async fn publish(
    config: LocalStorageConfig,
    file: tokio::fs::File,
    size: u64,
    key: String,
    mime: &str,
) -> io::Result<PublishedObject> {
    if let Some(s3) = config.s3 {
        s3.put(file, size, &key, mime).await?;
        return Ok(PublishedObject::S3(s3, key));
    }
    let mut source = file.into_std().await;
    tokio::task::spawn_blocking(move || {
        std::fs::create_dir_all(&config.root)?;
        local_publish::publish(&mut source, size, &config.root, &key).map(PublishedObject::Local)
    })
    .await
    .map_err(io::Error::other)?
}

pub(crate) async fn finalize<T: Send + 'static>(
    object: PublishedObject,
    result: Result<MediaUploadOutcome<T>, SessionStoreError>,
) -> Result<T, FinalizeError> {
    match object {
        PublishedObject::Local(local) => {
            tokio::task::spawn_blocking(move || local_publish::finalize(local, result))
                .await
                .map_err(|_| FinalizeError::StoreUnavailable)?
        }
        PublishedObject::S3(storage, key) => match result {
            Ok(MediaUploadOutcome::Created(value)) => Ok(value),
            Ok(MediaUploadOutcome::Failed {
                cleanup_safe,
                schema_unavailable,
            }) => {
                if cleanup_safe {
                    let _ = tokio::spawn(async move {
                        if storage.delete(&key).await.is_err() {
                            tracing::warn!("media upload rollback cleanup unavailable");
                        }
                    })
                    .await;
                }
                Err(if schema_unavailable {
                    FinalizeError::SchemaUnavailable
                } else {
                    FinalizeError::StoreUnavailable
                })
            }
            Err(_) => Err(FinalizeError::StoreUnavailable),
        },
    }
}
