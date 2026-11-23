pub mod content_detection;
pub mod delete;
pub mod local_publish;
pub mod multipart;
pub(crate) mod private_bind;
pub mod private_read;
mod rich_metadata;
pub mod storage_key;
pub(crate) mod upload;
pub mod upload_transaction;
pub mod vision;
mod wav_duration;
mod zip_detection;
pub(crate) mod publish;

use crate::auth::storage_urls::StorageUrlPolicy;
use serde_json::Value;

pub(crate) fn normalize_attachment_urls(
    policy: &StorageUrlPolicy,
    item: &mut Value,
) -> Result<(), ()> {
    let url = item["public_url"].as_str().unwrap_or_default();
    let canonical = item["media_id"].as_i64().and_then(private_read::content_url);
    let (public, thumbnail) = if canonical.as_deref() == Some(url) {
        (url.to_owned(), Value::Null)
    } else {
        let thumbnail = match item["thumbnail_url"].as_str() {
            Some(value) if !value.is_empty() => Value::String(policy.normalize_avatar(value)?),
            _ => Value::Null,
        };
        (policy.normalize_avatar(url)?, thumbnail)
    };
    let object = item.as_object_mut().ok_or(())?;
    object.insert("public_url".into(), public.into());
    object.insert("thumbnail_url".into(), thumbnail);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn attachment_normalization_preserves_canonical_private_url() {
        let policy = StorageUrlPolicy::from_lookup(|key| match key {
            "STORAGE_PUBLIC_BASE" => Some("/api/v2/media".into()),
            "STORAGE_CDN_BASE_URL" => Some("https://cdn.example".into()),
            _ => None,
        });
        let mut media = serde_json::json!({
            "media_id": 12,
            "public_url": "/api/v2/media/12/content",
            "thumbnail_url": null,
        });
        normalize_attachment_urls(&policy, &mut media).unwrap();
        assert_eq!(media["public_url"], "/api/v2/media/12/content");
        assert!(media["thumbnail_url"].is_null());
        media["public_url"] = "/storage/posts/photo.png".into();
        normalize_attachment_urls(&policy, &mut media).unwrap();
        assert_eq!(
            media["public_url"],
            "https://cdn.example/api/v2/media/posts/photo.png"
        );
    }
}
