//! Bounded images from authorized media records and unattached-draft metadata writes.
use crate::{
    auth::{login::js_trim, sessions::NativeState},
    db::{
        oracle::{BindMap, DbError},
        row::DbRow,
        tx::Transaction,
        value::DbValue,
    },
    httpx::{errors::ApiError, response::V2Response},
    storage::local_http::{LocalStorageConfig, read_vision_image},
};
use axum::{
    Json,
    body::{Body, to_bytes},
    extract::{Path, State},
    http::{Request, StatusCode, header},
    response::{IntoResponse, Response},
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::sync::OnceLock;

pub(crate) const MAX_IMAGES: usize = 4;
pub(crate) const MAX_IMAGE_BYTES: usize = 4 * 1024 * 1024;
pub(crate) const MAX_TOTAL_IMAGE_BYTES: usize = 8 * 1024 * 1024;
pub(crate) const MAX_ALT_TEXT_BYTES: usize = 500;
const MAX_ID: i64 = 9_007_199_254_740_991;

#[derive(Deserialize)]
struct Queries {
    owned_image: String,
    lock_owned_image: String,
    image_is_attached: String,
    write_alt_text: String,
    moderation_images: String,
    moderation_image: String,
    moderation_group_images: String,
    moderation_group_image: String,
}

fn queries() -> &'static Queries {
    #[derive(Deserialize)]
    struct Contract {
        sql: Queries,
    }
    static QUERIES: OnceLock<Contract> = OnceLock::new();
    &QUERIES
        .get_or_init(|| {
            serde_json::from_str(include_str!("../../contracts/requirements/ai-vision.json"))
                .expect("valid image vision contract")
        })
        .sql
}

pub(crate) fn valid_id(id: i64) -> bool {
    (1..=MAX_ID).contains(&id)
}

pub(crate) fn alt_text(value: &str) -> Result<Option<&str>, ()> {
    let text = js_trim(value);
    if text.len() > MAX_ALT_TEXT_BYTES || text.chars().any(char::is_control) {
        return Err(());
    }
    Ok((!text.is_empty()).then_some(text))
}

fn mime_type(value: &str) -> Option<&'static str> {
    match value {
        "image/jpeg" => Some("image/jpeg"),
        "image/png" => Some("image/png"),
        "image/webp" => Some("image/webp"),
        _ => None,
    }
}

pub(crate) struct Image {
    mime: &'static str,
    bytes: Vec<u8>,
}

impl Image {
    pub(crate) fn validated(mime: &str, bytes: Vec<u8>) -> Option<Self> {
        let mime = mime_type(mime)?;
        if bytes.len() > MAX_IMAGE_BYTES
            || super::content_detection::detect_prefix(&bytes[..bytes.len().min(1024)])
                .is_none_or(|data| data.mime != mime)
        {
            return None;
        }
        Some(Self { mime, bytes })
    }

    pub(crate) fn mime(&self) -> &'static str {
        self.mime
    }

    pub(crate) fn bytes(&self) -> &[u8] {
        &self.bytes
    }
}

#[derive(Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Asset {
    pub media_id: i64,
    storage_key: String,
    access_scope: String,
    mime_type: String,
    file_size: i64,
}

impl Asset {
    fn from_row(row: &DbRow) -> Option<Self> {
        Some(Self {
            media_id: row.get("MEDIA_ID")?.as_i64().filter(|id| valid_id(*id))?,
            storage_key: row.get("STORAGE_KEY")?.as_str()?.into(),
            access_scope: row.get("ACCESS_SCOPE")?.as_str()?.into(),
            mime_type: row.get("MIME_TYPE")?.as_str()?.into(),
            file_size: row.get("FILE_SIZE")?.as_i64()?,
        })
    }

    pub(crate) fn size(&self) -> Option<usize> {
        mime_type(&self.mime_type)?;
        usize::try_from(self.file_size)
            .ok()
            .filter(|size| (1..=MAX_IMAGE_BYTES).contains(size))
    }

    pub(crate) fn source(&self) -> Option<ImageSource> {
        self.size()?;
        if self.access_scope != "public" || !valid_id(self.media_id) || self.storage_key.is_empty()
        {
            return None;
        }
        let value = format!(
            "{}\n{}\n{}\n{}",
            self.media_id, self.storage_key, self.mime_type, self.file_size
        );
        Some(ImageSource {
            media_id: self.media_id,
            version: hex::encode(Sha256::digest(value.as_bytes())),
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ImageSource {
    pub media_id: i64,
    pub version: String,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum ImageRead {
    Missing,
    Unsupported,
    Unavailable,
}

pub(crate) async fn load_image(
    config: LocalStorageConfig,
    asset: &Asset,
) -> Result<Image, ImageRead> {
    let size = asset.size().ok_or(ImageRead::Unsupported)?;
    let response = read_vision_image(config, &asset.storage_key, &asset.access_scope).await;
    match response.status() {
        StatusCode::OK => {}
        StatusCode::NOT_FOUND => return Err(ImageRead::Missing),
        _ => return Err(ImageRead::Unavailable),
    }
    if response
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|h| h.to_str().ok())
        != Some(asset.mime_type.as_str())
        || response
            .headers()
            .get(header::CONTENT_LENGTH)
            .is_some_and(|h| h.to_str().ok().and_then(|v| v.parse::<usize>().ok()) != Some(size))
    {
        return Err(ImageRead::Missing);
    }
    let body = to_bytes(response.into_body(), size)
        .await
        .map_err(|_| ImageRead::Missing)?;
    if body.len() != size {
        return Err(ImageRead::Missing);
    }
    Image::validated(&asset.mime_type, body.to_vec()).ok_or(ImageRead::Missing)
}

fn asset_binds(viewer: i64, media_id: i64) -> BindMap {
    BindMap::from([
        ("viewer_id".into(), DbValue::I64(viewer)),
        ("media_id".into(), DbValue::I64(media_id)),
    ])
}

pub(crate) fn owned_image(
    tx: &impl Transaction,
    viewer: i64,
    media_id: i64,
) -> Result<Option<Asset>, DbError> {
    let rows = tx.query(&queries().owned_image, asset_binds(viewer, media_id))?;
    Ok(match rows.as_slice() {
        [row] => Some(Asset::from_row(row))
            .flatten()
            .filter(|asset| asset.media_id == media_id),
        _ => None,
    })
}

#[derive(Debug, PartialEq, Eq)]
pub enum AltTextUpdate {
    Missing,
    Attached,
    Updated,
}

pub(crate) fn update_alt_text(
    tx: &impl Transaction,
    viewer: i64,
    media_id: i64,
    alt: Option<String>,
) -> Result<AltTextUpdate, DbError> {
    let result = (|| {
        if tx
            .query(&queries().lock_owned_image, asset_binds(viewer, media_id))?
            .len()
            != 1
        {
            return Ok(AltTextUpdate::Missing);
        }
        if !tx
            .query(
                &queries().image_is_attached,
                BindMap::from([("media_id".into(), DbValue::I64(media_id))]),
            )?
            .is_empty()
        {
            return Ok(AltTextUpdate::Attached);
        }
        let mut binds = asset_binds(viewer, media_id);
        binds.insert(
            "alt_text".into(),
            alt.map_or(DbValue::Null, DbValue::String),
        );
        if tx.execute(&queries().write_alt_text, binds)? != 1 {
            return Err(DbError::ExpectedNumber("updated image row".into()));
        }
        Ok(AltTextUpdate::Updated)
    })();
    match result {
        Ok(AltTextUpdate::Updated) => tx.commit()?,
        _ => tx.rollback()?,
    }
    result
}

pub(crate) fn moderation_images(
    tx: &impl Transaction,
    viewer: i64,
    kind: &str,
    post_id: i64,
) -> Result<Vec<Asset>, DbError> {
    let query = match kind {
        "post" => &queries().moderation_images,
        "group_post" => &queries().moderation_group_images,
        _ => return Ok(Vec::new()),
    };
    Ok(tx
        .query(
            query,
            BindMap::from([
                ("viewer_id".into(), DbValue::I64(viewer)),
                ("post_id".into(), DbValue::I64(post_id)),
            ]),
        )?
        .iter()
        .filter_map(Asset::from_row)
        .filter(|asset| asset.source().is_some())
        .take(MAX_IMAGES)
        .collect())
}

pub(crate) fn current_sources(
    tx: &impl Transaction,
    viewer: i64,
    kind: &str,
    post_id: i64,
    references: &[ImageSource],
    lock: bool,
) -> Result<bool, DbError> {
    if !(1..=MAX_IMAGES).contains(&references.len()) {
        return Ok(false);
    }
    let query = match kind {
        "post" => &queries().moderation_image,
        "group_post" => &queries().moderation_group_image,
        _ => return Ok(false),
    };
    let locked_query;
    let query = if lock {
        locked_query = format!("{query} FOR UPDATE OF p.is_deleted,a.status NOWAIT");
        locked_query.as_str()
    } else {
        query
    };
    for reference in references {
        let mut binds = asset_binds(viewer, reference.media_id);
        binds.insert("post_id".into(), DbValue::I64(post_id));
        let rows = tx.query(query, binds)?;
        let [row] = rows.as_slice() else {
            return Ok(false);
        };
        if Asset::from_row(row)
            .and_then(|asset| asset.source())
            .as_ref()
            != Some(reference)
        {
            return Ok(false);
        }
    }
    Ok(true)
}

pub(crate) async fn patch_alt_text(
    State(state): State<NativeState>,
    Path(id): Path<String>,
    request: Request<Body>,
) -> Response {
    async {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Patch {
            alt_text: String,
        }
        let (parts, body) = request.into_parts();
        let actor = crate::posts::bookmark::interaction_actor(&state, &parts.headers).await?;
        let invalid = || ApiError::bad_request("替代文本参数错误");
        let id = id
            .parse::<i64>()
            .ok()
            .filter(|media_id| valid_id(*media_id) && media_id.to_string() == id)
            .ok_or_else(invalid)?;
        let raw = to_bytes(body, 4096).await.map_err(|_| invalid())?;
        if raw.iter().find(|value| !value.is_ascii_whitespace()) != Some(&b'{') {
            return Err(invalid());
        }
        let input: Patch = serde_json::from_slice(&raw).map_err(|_| invalid())?;
        if input.alt_text.len() > MAX_ALT_TEXT_BYTES {
            return Err(invalid());
        }
        let alt = alt_text(&input.alt_text)
            .map_err(|_| invalid())?
            .map(str::to_owned);
        match state
            .repository
            .update_media_alt_text(actor as i64, id, alt.clone())
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?
        {
            AltTextUpdate::Missing => Err(ApiError::not_found("媒体不存在")),
            AltTextUpdate::Attached => Err(ApiError::conflict("媒体正在使用")),
            AltTextUpdate::Updated => {
                Ok(Json(V2Response::ok(json!({"media_id":id,"alt_text":alt}))).into_response())
            }
        }
    }
    .await
    .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    struct AttachmentStore {
        events: RefCell<Vec<&'static str>>,
        attached: bool,
        available: bool,
    }

    impl Transaction for AttachmentStore {
        fn query(&self, sql: &str, binds: BindMap) -> Result<Vec<DbRow>, DbError> {
            assert_eq!(binds["media_id"], DbValue::I64(7));
            if sql == queries().lock_owned_image {
                self.events.borrow_mut().push("lock");
                assert_eq!(binds["viewer_id"], DbValue::I64(42));
                return Ok(self.available.then(DbRow::new).into_iter().collect());
            }
            if sql == queries().image_is_attached {
                self.events.borrow_mut().push("references");
                return Ok(self.attached.then(DbRow::new).into_iter().collect());
            }
            assert_eq!(sql, queries().moderation_group_image);
            assert_eq!(binds["post_id"], DbValue::I64(11));
            assert_eq!(binds["viewer_id"], DbValue::I64(42));
            self.events.borrow_mut().push("current");
            Ok(self
                .available
                .then(|| {
                    DbRow::from([
                        ("MEDIA_ID".into(), DbValue::I64(7)),
                        (
                            "STORAGE_KEY".into(),
                            DbValue::String("posts/images/42/a.png".into()),
                        ),
                        ("MIME_TYPE".into(), DbValue::String("image/png".into())),
                        ("ACCESS_SCOPE".into(), DbValue::String("public".into())),
                        ("FILE_SIZE".into(), DbValue::I64(100)),
                    ])
                })
                .into_iter()
                .collect())
        }

        fn execute(&self, sql: &str, binds: BindMap) -> Result<u64, DbError> {
            assert_eq!(sql, queries().write_alt_text);
            assert_eq!(binds["alt_text"], DbValue::Null);
            self.events.borrow_mut().push("write");
            Ok(1)
        }

        fn commit(&self) -> Result<(), DbError> {
            self.events.borrow_mut().push("commit");
            Ok(())
        }
        fn rollback(&self) -> Result<(), DbError> {
            self.events.borrow_mut().push("rollback");
            Ok(())
        }
    }

    #[test]
    fn draft_alt_text_update_checks_all_attachments_while_holding_asset_lock() {
        for (available, attached, expected, events) in [
            (
                false,
                false,
                AltTextUpdate::Missing,
                vec!["lock", "rollback"],
            ),
            (
                true,
                true,
                AltTextUpdate::Attached,
                vec!["lock", "references", "rollback"],
            ),
            (
                true,
                false,
                AltTextUpdate::Updated,
                vec!["lock", "references", "write", "commit"],
            ),
        ] {
            let store = AttachmentStore {
                events: RefCell::default(),
                available,
                attached,
            };
            assert_eq!(update_alt_text(&store, 42, 7, None).unwrap(), expected);
            assert_eq!(*store.events.borrow(), events);
        }
    }

    #[test]
    fn group_image_history_checks_exact_attachment_and_metadata_digest() {
        let store = AttachmentStore {
            events: RefCell::default(),
            available: true,
            attached: true,
        };
        let digest = hex::encode(Sha256::digest(b"7\nposts/images/42/a.png\nimage/png\n100"));
        let reference = ImageSource {
            media_id: 7,
            version: digest,
        };
        assert!(
            current_sources(
                &store,
                42,
                "group_post",
                11,
                std::slice::from_ref(&reference),
                false
            )
            .unwrap()
        );
        assert!(
            !current_sources(
                &store,
                42,
                "group_post",
                11,
                &[ImageSource {
                    version: "a".repeat(64),
                    ..reference.clone()
                }],
                false
            )
            .unwrap()
        );
        let removed = AttachmentStore {
            available: false,
            ..store
        };
        assert!(!current_sources(&removed, 42, "group_post", 11, &[reference], false).unwrap());
    }
}
