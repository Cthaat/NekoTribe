use crate::{
    auth::sessions::NativeState,
    httpx::{errors::ApiError, response::V2Response},
    media::{
        content_detection,
        local_publish::{self, FinalizeError},
        multipart::{self, Limits, ParseError},
        storage_key,
        upload_transaction::MediaUpload,
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

pub(crate) async fn upload(
    State(state): State<NativeState>,
    config: Option<Extension<LocalStorageConfig>>,
    request: Request<Body>,
) -> Response {
    let mut response = upload_inner(state, config.map(|v| v.0), request)
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
    let mut media = multipart::parse(body, &boundary, Limits::default())
        .await
        .map_err(|error| match error {
            ParseError::NoFile => ApiError::bad_request("上传文件为空"),
            ParseError::Invalid => ApiError::bad_request("媒体上传失败"),
            ParseError::Storage => ApiError::server_error("服务器内部错误"),
        })?;
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
    let config = config.unwrap_or_else(|| LocalStorageConfig::from_lookup(|_| None));
    if config.unsupported {
        return Err(ApiError::new(
            StatusCode::NOT_IMPLEMENTED,
            50101,
            "媒体存储暂不可用",
        ));
    }
    let key = storage_key::new_key(
        actor,
        &selected.media_type,
        &selected.extension,
        chrono::Utc::now(),
    )
    .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    let public_url = state
        .storage_urls
        .normalize_avatar(&format!("/storage/{key}"))
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    let input = MediaUpload {
        user_id: i64::try_from(actor).map_err(|_| ApiError::server_error("服务器内部错误"))?,
        size: i64::try_from(media.size).map_err(|_| ApiError::server_error("服务器内部错误"))?,
        key: key.clone(),
        public_url,
        filename: name.to_owned(),
        media_type: selected.media_type,
        mime_type: selected.mime_type,
        width: None,
        height: None,
        duration: None,
        thumbnail_url: None,
        alt_text: Some(media.alt_text),
        description: Some(media.description),
    };
    let size = media.size;
    let mut source = media.file.into_std().await;
    let root = config.root;
    let object = tokio::task::spawn_blocking(move || {
        std::fs::create_dir_all(&root)?;
        local_publish::publish(&mut source, size, &root, &key)
    })
    .await
    .map_err(|_| ApiError::server_error("服务器内部错误"))?
    .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    let result = state
        .repository
        .create_media_atomic(&input, &state.storage_urls)
        .await;
    let result = tokio::task::spawn_blocking(move || local_publish::finalize(object, result))
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    let value = result.map_err(|error| match error {
        FinalizeError::SchemaUnavailable => ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            50301,
            "服务暂不可用，请稍后重试。",
        ),
        FinalizeError::StoreUnavailable => ApiError::server_error("服务器内部错误"),
    })?;
    Ok(Json(V2Response::ok_with_message(value, "media uploaded")).into_response())
}
