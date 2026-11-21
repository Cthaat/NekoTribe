use crate::{
    auth::sessions::NativeState,
    httpx::{errors::ApiError, response::V2Response},
    media::{
        content_detection,
        local_publish::FinalizeError,
        multipart::{self, Limits, ParseError},
        private_read, publish,
        rich_metadata, storage_key,
        upload_transaction::{MediaAccess, MediaUpload},
        wav_duration,
    },
    posts::bookmark::interaction_actor,
    storage::{local_http::LocalStorageConfig, media_type_selection::select_media_file_type},
};
use axum::{
    body::Body,
    extract::State,
    http::{header, HeaderValue, Request, StatusCode},
    response::{IntoResponse, Response},
    Extension, Json,
};
use tokio::io::{AsyncReadExt, AsyncSeekExt};

pub(crate) const PRIVATE_UPLOAD_ROUTE: &str = "/api/v2/media/private";

async fn image_dimensions(file: &mut tokio::fs::File) -> Option<(f64, f64)> {
    file.seek(std::io::SeekFrom::Start(0)).await.ok()?;
    let mut prefix = Vec::new();
    let read = (&mut *file).take(4 << 20).read_to_end(&mut prefix).await;
    let reset = file.seek(std::io::SeekFrom::Start(0)).await;
    if read.is_err() || reset.is_err() {
        return None;
    }
    let dimensions = tokio::task::spawn_blocking(move || imagesize::blob_size(&prefix).ok())
        .await
        .ok()??;
    if dimensions.width == 0 || dimensions.height == 0 {
        return None;
    }
    Some((dimensions.width as f64, dimensions.height as f64))
}

pub(crate) async fn upload(
    State(state): State<NativeState>,
    config: Option<Extension<LocalStorageConfig>>,
    request: Request<Body>,
) -> Response {
    upload_response(state, config, request, false).await
}

pub(crate) async fn upload_private(
    State(state): State<NativeState>,
    config: Option<Extension<LocalStorageConfig>>,
    request: Request<Body>,
) -> Response {
    upload_response(state, config, request, true).await
}

async fn upload_response(
    state: NativeState,
    config: Option<Extension<LocalStorageConfig>>,
    request: Request<Body>,
    require_private: bool,
) -> Response {
    let mut response = upload_inner(state, config.map(|v| v.0), request, require_private)
        .await
        .into_response();
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("private, no-store"),
    );
    response
}

async fn upload_inner(
    state: NativeState,
    config: Option<LocalStorageConfig>,
    request: Request<Body>,
    require_private: bool,
) -> Result<Response, ApiError> {
    let (parts, body) = request.into_parts();
    let actor = interaction_actor(&state, &parts.headers).await?;
    let content_type = parts
        .headers
        .get(header::CONTENT_TYPE)
        .and_then(|h| h.to_str().ok())
        .unwrap_or("");
    let boundary = multer::parse_boundary(content_type)
        .map_err(|_| ApiError::bad_request("请使用 multipart/form-data 上传媒体文件"))?;
    let limits = Limits::default();
    let selected_file = if require_private {
        multipart::parse_private(body, &boundary, limits).await
    } else {
        multipart::parse(body, &boundary, limits).await
    };
    let mut media = selected_file.map_err(|error| match error {
        ParseError::NoFile => ApiError::bad_request("上传文件为空"),
        ParseError::Invalid => ApiError::bad_request("媒体上传失败"),
        ParseError::InvalidAccessScope => ApiError::bad_request("媒体访问范围无效"),
        ParseError::Storage => ApiError::server_error("服务器内部错误"),
    })?;
    validate_text_lengths(&media.alt_text, &media.description)?;
    let detected = content_detection::inspect_file(&mut media.file)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    let name = if media.name.is_empty() {
        "upload.bin"
    } else {
        &media.name
    };
    let selected = select_media_file_type(name, &media.mime, detected.as_ref());
    if !selected.supported {
        return Err(ApiError::bad_request(
            "仅支持图片、视频、音频、文档、文本或压缩包文件",
        ));
    }
    let private_scope = media.private_scope;
    if private_scope.is_some() {
        state
            .repository
            .preflight_private_media_upload()
            .await
            .map_err(|_| private_read::unavailable())?;
    }
    let dimensions = if selected.media_type == "image" || selected.media_type == "gif" {
        image_dimensions(&mut media.file).await
    } else {
        None
    };
    let rich = if selected.media_type == "video" || selected.media_type == "audio" {
        let binary = std::env::var_os("FFPROBE_PATH")
            .filter(|v| !v.is_empty())
            .unwrap_or_else(|| "ffprobe".into());
        rich_metadata::probe(
            &mut media.file,
            &binary,
            &selected.mime_type,
            media.temp_path.as_deref(),
        )
        .await
    } else {
        None
    };
    let wav_duration = if selected.mime_type == "audio/wav"
        && rich.as_ref().and_then(|value| value.duration).is_none()
    {
        wav_duration::pcm_duration(&mut media.file).await
    } else {
        None
    };
    let config = config.unwrap_or_else(|| LocalStorageConfig::from_lookup(|_| None));
    if config.unsupported {
        return Err(private_read::unavailable());
    }
    let key = storage_key::new_key(
        actor,
        &selected.media_type,
        &selected.extension,
        chrono::Utc::now(),
    )
    .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    let (key, access) = if let Some(scope) = private_scope {
        let suffix = key
            .strip_prefix("posts/")
            .ok_or_else(|| ApiError::server_error("服务器内部错误"))?;
        (
            format!("private/{}/{suffix}", scope.as_str()),
            MediaAccess::Private(scope),
        )
    } else {
        let url = state
            .storage_urls
            .normalize_avatar(&format!("/storage/{key}"))
            .map_err(|_| ApiError::server_error("服务器内部错误"))?;
        (key, MediaAccess::Public(url))
    };
    let input = MediaUpload {
        user_id: i64::try_from(actor).map_err(|_| ApiError::server_error("服务器内部错误"))?,
        size: i64::try_from(media.size).map_err(|_| ApiError::server_error("服务器内部错误"))?,
        key: key.clone(),
        access,
        filename: name.to_owned(),
        media_type: selected.media_type,
        mime_type: selected.mime_type,
        width: dimensions
            .map(|value| value.0)
            .or_else(|| rich.as_ref().and_then(|value| value.width)),
        height: dimensions
            .map(|value| value.1)
            .or_else(|| rich.as_ref().and_then(|value| value.height)),
        duration: rich.and_then(|value| value.duration).or(wav_duration),
        thumbnail_url: None,
        alt_text: Some(media.alt_text),
        description: Some(media.description),
    };
    let object = publish::publish(config, media.file, media.size, key, &input.mime_type)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    let result = state
        .repository
        .create_media_atomic(&input, &state.storage_urls)
        .await;
    let result = publish::finalize(object, result).await;
    let value = result.map_err(|error| match error {
        FinalizeError::SchemaUnavailable if private_scope.is_some() => private_read::unavailable(),
        FinalizeError::SchemaUnavailable => ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            50301,
            "服务暂不可用，请稍后重试。",
        ),
        FinalizeError::StoreUnavailable => ApiError::server_error("服务器内部错误"),
    })?;
    Ok(Json(V2Response::ok_with_message(value, "media uploaded")).into_response())
}

fn validate_text_lengths(alt_text: &str, description: &str) -> Result<(), ApiError> {
    if alt_text.len() > 500 || description.len() > 1000 {
        return Err(ApiError::bad_request("媒体替代文本或描述过长"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::{engine::general_purpose::STANDARD, Engine};
    use tokio::io::AsyncWriteExt;

    #[test]
    fn validates_metadata_limits_in_utf8_bytes() {
        assert!(validate_text_lengths(&("猫".repeat(166) + "ab"), &("猫".repeat(333) + "a")).is_ok());
        assert!(validate_text_lengths(&"猫".repeat(167), "").is_err());
        assert!(validate_text_lengths("", &"猫".repeat(334)).is_err());
    }

    #[tokio::test]
    async fn reads_common_image_sizes_and_preserves_unknown_as_null() {
        let cases = [
            ("jpeg", include_str!("../../tests/fixtures/media-metadata-jpeg.b64")),
            ("gif", "R0lGODlhBwAFAIAAAExpcaq7zCH5BAUAAAAALAAAAAAHAAUAAAIFjI+puwUAOw=="),
            ("webp", "UklGRjAAAABXRUJQVlA4ICQAAABwAQCdASoHAAUAAUAmJYwCdAFAAAD+8sp8CStWbpYcm1zEAAA="),
            ("avif", "AAAAHGZ0eXBhdmlmAAAAAG1pZjFhdmlmbWlhZgAAANZtZXRhAAAAAAAAACFoZGxyAAAAAAAAAABwaWN0AAAAAAAAAAAAAAAAAAAAAA5waXRtAAAAAAABAAAAImlsb2MAAAAAREAAAQABAAAAAAD6AAEAAAAAAAAAGgAAACNpaW5mAAAAAAABAAAAFWluZmUCAAAAAAEAAGF2MDEAAAAAVmlwcnAAAAA4aXBjbwAAAAxhdjFDgSACAAAAABRpc3BlAAAAAAAAAAcAAAAFAAAAEHBpeGkAAAAAAwgICAAAABZpcG1hAAAAAAAAAAEAAQOBAgMAAAAibWRhdBIACgg4CLRhAQ0GkDIMGAAAAEAF9e7WR/Sb"),
        ];
        for (kind, data) in cases {
            let mut file = tokio::fs::File::from_std(tempfile::tempfile().unwrap());
            let bytes = STANDARD.decode(data).unwrap();
            file.write_all(&bytes).await.unwrap();
            file.flush().await.unwrap();
            assert_eq!(
                image_dimensions(&mut file).await,
                Some((7.0, 5.0)),
                "{kind}: {:?}",
                imagesize::blob_size(&bytes)
            );
            assert_eq!(file.stream_position().await.unwrap(), 0);
        }
        let mut invalid = tokio::fs::File::from_std(tempfile::tempfile().unwrap());
        invalid.write_all(b"not an image").await.unwrap();
        invalid.flush().await.unwrap();
        assert!(image_dimensions(&mut invalid).await.is_none());
    }
}
