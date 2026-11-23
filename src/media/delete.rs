use crate::{
    auth::sessions::NativeState,
    db::{
        oracle::{BindMap, DbError},
        tx::Transaction,
        value::DbValue,
    },
    httpx::{errors::ApiError, response::V2Response},
    storage::{
        local_http::{link, LocalStorageConfig},
        local_policy::normalize_local_key,
    },
};
use axum::{
    extract::{OriginalUri, State},
    http::{header, HeaderMap, HeaderValue},
    response::{IntoResponse, Response},
    Extension, Json,
};
use serde::Deserialize;
use std::{fs, io, path::Path, sync::OnceLock};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ReferenceContract {
    check_references: String,
    pub(crate) key_pattern: String,
    pub(crate) alias_pattern: String,
    pub(crate) lookup_group_images: String,
    pub(crate) lock_group_image: String,
}

pub(crate) fn reference_contract() -> &'static ReferenceContract {
    static CONTRACT: OnceLock<ReferenceContract> = OnceLock::new();
    &CONTRACT.get_or_init(|| {
        serde_json::from_str(include_str!("../../contracts/requirements/media-delete-references.json"))
            .expect("valid media delete reference contract")
    })
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MediaDelete {
    pub key: Option<String>,
    pub public_url: Option<String>,
    pub thumbnail_url: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MediaDeleteOutcome {
    Missing,
    InUse,
    Deleted(MediaDelete),
}

pub(crate) async fn remove(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
    config: Option<Extension<LocalStorageConfig>>,
) -> Response {
    let result = async {
        let user = crate::posts::bookmark::interaction_actor(&state, &headers).await?;
        let raw = uri.path().strip_prefix("/api/v2/media/").unwrap_or("");
        let decoded = crate::auth::sessions::percent_decode(raw)
            .ok_or_else(|| ApiError::bad_request("id 参数错误"))?;
        let id = crate::posts::create_request::string_number(crate::auth::login::js_trim(&decoded))
            .filter(|v| v.is_finite() && *v > 0.0)
            .ok_or_else(|| ApiError::bad_request("id 参数错误"))?;
        let record = match state
            .repository
            .delete_media(user, id)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?
        {
            MediaDeleteOutcome::Missing => return Err(ApiError::not_found("媒体不存在")),
            MediaDeleteOutcome::InUse => return Err(ApiError::conflict("媒体正在使用")),
            MediaDeleteOutcome::Deleted(record) => record,
        };
        let config = config
            .map(|x| x.0)
            .unwrap_or_else(|| LocalStorageConfig::from_lookup(|_| None));
        let policy = state.storage_urls.clone();
        remove_references(config,policy,record).await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?;
        Ok(Json(V2Response::null("media deleted")).into_response())
    }
    .await;
    let mut response = result.into_response();
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("private, no-store"),
    );
    response
}

async fn remove_references(config: LocalStorageConfig, policy: crate::auth::storage_urls::StorageUrlPolicy, record: MediaDelete) -> Result<(), ()> {
    if let Some(s3) = config.s3 {
        return tokio::spawn(async move {
            for (key, public_url) in [
                (record.key.as_deref(), record.public_url.as_deref()),
                (None, record.thumbnail_url.as_deref()),
            ] {
                if let Some(key) = resolve_reference(&policy, key, public_url)? {
                    s3.delete(&key).await.map_err(|_| ())?;
                }
            }
            Ok(())
        }).await.map_err(|_| ())?;
    }
    tokio::task::spawn_blocking(move || {
        remove_reference(&config,&policy,record.key.as_deref(),record.public_url.as_deref())?;
        remove_reference(&config,&policy,None,record.thumbnail_url.as_deref())
    }).await.map_err(|_|())?
}

pub fn run<T: Transaction>(
    tx: &T,
    user: u64,
    id: f64,
) -> Result<MediaDeleteOutcome, DbError> {
    let user = i64::try_from(user).map_err(|_| DbError::ExpectedNumber("user_id".into()))?;
    match remove_row(tx, user, id) {
        Ok(MediaDeleteOutcome::Deleted(record)) => {
            if let Err(error) = tx.commit() {
                let _ = tx.rollback();
                return Err(error);
            }
            Ok(MediaDeleteOutcome::Deleted(record))
        }
        result => {
            tx.rollback()?;
            result
        }
    }
}

fn remove_row<T: Transaction>(tx: &T, user: i64, id: f64) -> Result<MediaDeleteOutcome, DbError> {
    let bindings = || {
        BindMap::from([
            ("media_id".into(), DbValue::F64(id)),
            ("user_id".into(), DbValue::I64(user)),
        ])
    };
    let rows = tx.query("SELECT storage_key, public_url, thumbnail_url FROM n_media_assets WHERE media_id=:media_id AND owner_user_id=:user_id FOR UPDATE", bindings())?;
    let Some(row) = rows.first() else {
        return Ok(MediaDeleteOutcome::Missing);
    };
    let references = tx.query(
        &reference_contract().check_references,
        BindMap::from([("media_id".into(), DbValue::F64(id))]),
    )?;
    if !references.is_empty() || crate::direct_extras::linked_asset(tx, DbValue::F64(id))? {
        return Ok(MediaDeleteOutcome::InUse);
    }
    let value = |key: &str| -> Result<Option<String>, DbError> {
        match row.get(key) {
            Some(DbValue::Null) => Ok(None),
            Some(DbValue::String(s)) => Ok((!s.is_empty()).then(|| s.clone())),
            _ => Err(DbError::SchemaNotReady),
        }
    };
    let record = MediaDelete {
        key: value("STORAGE_KEY")?,
        public_url: value("PUBLIC_URL")?,
        thumbnail_url: value("THUMBNAIL_URL")?,
    };
    match tx
        .execute(
            "DELETE FROM n_media_assets WHERE media_id=:media_id AND owner_user_id=:user_id",
            bindings(),
        )?
    {
        0 => Ok(MediaDeleteOutcome::Missing),
        1 => Ok(MediaDeleteOutcome::Deleted(record)),
        _ => Err(DbError::SchemaNotReady),
    }
}

fn remove_reference(
    config: &LocalStorageConfig,
    policy: &crate::auth::storage_urls::StorageUrlPolicy,
    key: Option<&str>,
    reference: Option<&str>,
) -> Result<(), ()> {
    let Some(key) = resolve_reference(policy,key,reference)? else { return Ok(()) };
    if config.unsupported
        || key
            .split('/')
            .next()
            .is_some_and(|s| s.eq_ignore_ascii_case("temp"))
    {
        return Err(());
    }
    let mut current = config.root.clone();
    let parts: Vec<_> = key.split('/').collect();
    for (i, part) in parts.iter().enumerate() {
        current.push(part);
        let meta = match fs::symlink_metadata(&current) {
            Ok(m) => m,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(()),
            Err(_) => return Err(()),
        };
        if link(&meta)
            || (i + 1 < parts.len() && !meta.is_dir())
            || (i + 1 == parts.len() && !meta.is_file())
        {
            return Err(());
        }
    }
    match fs::remove_file(Path::new(&current)) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(_) => Err(()),
    }
}

fn resolve_reference(policy: &crate::auth::storage_urls::StorageUrlPolicy, key: Option<&str>, reference: Option<&str>) -> Result<Option<String>, ()> {
    let explicit = key.filter(|value| !value.is_empty());
    let selected = match explicit {
        Some(key) => Some(normalize_local_key(key).map_err(|_| ())?),
        None => policy.managed_key(reference.unwrap_or(""))?,
    };
    let Some(key) = selected else { return Ok(None) };
    let prefix = key.split('/').next().unwrap_or_default();
    if prefix.eq_ignore_ascii_case("private") {
        if explicit.is_none() {
            return Ok(None);
        }
        if !crate::storage::local_policy::is_private_storage_key(&key) {
            return Err(());
        }
    }
    Ok(Some(key))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn local_deletion_rejects_temp_traversal_and_external_reference() {
        let root = std::env::temp_dir().join(format!("neko-media-path-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(root.join("owned")).unwrap();
        let file = root.join("owned/a.txt");
        fs::write(&file, b"safe").unwrap();
        let config = LocalStorageConfig {
            root: root.clone(),
            unsupported: false,
            s3: None,
        };
        let policy = crate::auth::storage_urls::StorageUrlPolicy::from_lookup(|key| match key {
            "STORAGE_PUBLIC_BASE" => Some("/media".into()),
            "BASE_URL" => Some("https://example.test".into()),
            _ => None,
        });
        assert!(remove_reference(
            &config,
            &policy,
            None,
            Some("https://other.test/media/owned/a.txt")
        )
        .is_ok());
        assert!(file.exists());
        assert!(remove_reference(&config, &policy, Some("../escape"), None).is_err());
        assert!(remove_reference(&config, &policy, Some("TEMP/other"), None).is_err());
        assert!(remove_reference(
            &config,
            &policy,
            None,
            Some("https://example.test/media/owned/a.txt")
        )
        .is_ok());
        assert!(!file.exists());
        assert!(remove_reference(
            &LocalStorageConfig {
                root: root.clone(),
                unsupported: true,
                s3: None,
            },
            &policy,
            Some("owned/a.txt"),
            None
        )
        .is_err());
        fs::remove_dir_all(root).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn local_deletion_rejects_linked_directory() {
        let root = std::env::temp_dir().join(format!("neko-media-link-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(root.join("outside")).unwrap();
        fs::write(root.join("outside/a.txt"), b"safe").unwrap();
        std::os::unix::fs::symlink(root.join("outside"), root.join("link")).unwrap();
        let config = LocalStorageConfig {
            root: root.clone(),
            unsupported: false,
            s3: None,
        };
        assert!(remove_reference(&config, &Default::default(), Some("link/a.txt"), None).is_err());
        assert!(root.join("outside/a.txt").exists());
        fs::remove_dir_all(root).unwrap();
    }
}
