use crate::{
    auth::sessions::NativeState,
    db::{oracle::BindMap, tx::OracleTx, value::DbValue},
    httpx::{errors::ApiError, response::V2Response},
    media::{
        publish,
        multipart::{self, Limits, ParseError},
        upload_transaction::MediaUploadOutcome,
    },
    posts::bookmark::interaction_actor,
    storage::local_http::LocalStorageConfig,
};
use axum::{
    body::Body,
    extract::State,
    http::{header, HeaderValue, Request, StatusCode},
    response::{IntoResponse, Response},
    Extension, Json,
};
use chrono::{Datelike, Utc};
use serde::Deserialize;
use serde_json::json;
use std::{collections::HashMap, sync::OnceLock};
use tokio::io::AsyncReadExt;

#[derive(Deserialize)]
struct Format {
    hex: String,
    mime: String,
    extension: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Contract {
    max_file_bytes: u64,
    max_field_bytes: u64,
    max_files: usize,
    max_fields: usize,
    formats: Vec<Format>,
    sql: HashMap<String, String>,
}

fn contract() -> &'static Contract {
    static CONTRACT: OnceLock<Contract> = OnceLock::new();
    CONTRACT.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../../contracts/requirements/user-avatar.json"
        ))
        .expect("valid avatar contract")
    })
}

pub struct AvatarUpload {
    pub user_id: i64,
    pub size: i64,
    pub name: String,
    pub key: String,
    pub url: String,
    pub mime: String,
}

pub(crate) fn replace(
    connection: &oracle::Connection,
    input: AvatarUpload,
) -> MediaUploadOutcome<i64> {
    let sql = &contract().sql;
    let tx = OracleTx::new(connection);
    let prepare = || -> Result<i64, ()> {
        let locked = connection
            .query_row_as_named::<i64>(&sql["lock"], &[("user_id", &input.user_id)])
            .map_err(|_| ())?;
        if locked != input.user_id {
            return Err(());
        }
        let id = connection
            .query_row_as::<i64>(&sql["next"], &[])
            .map_err(|_| ())?;
        if !(1..=9_007_199_254_740_991).contains(&id) {
            return Err(());
        }
        let reference = BindMap::from([
            ("user_id".into(), DbValue::I64(input.user_id)),
            ("media_id".into(), DbValue::I64(id)),
            ("public_url".into(), DbValue::String(input.url)),
        ]);
        let mut media = reference.clone();
        media.extend([
            ("file_name".into(), DbValue::String(input.name)),
            ("storage_key".into(), DbValue::String(input.key)),
            ("file_size".into(), DbValue::I64(input.size)),
            ("mime_type".into(), DbValue::String(input.mime)),
        ]);
        if tx
            .execute(&sql["insert"], media)
            .map_err(|_| ())?
            .rows_affected
            != 1
            || tx
                .execute(&sql["update"], reference)
                .map_err(|_| ())?
                .rows_affected
                != 1
        {
            return Err(());
        }
        Ok(id)
    };
    match prepare() {
        Ok(id) if tx.commit().is_ok() => MediaUploadOutcome::Created(id),
        Ok(_) => MediaUploadOutcome::Failed {
            cleanup_safe: false,
            schema_unavailable: false,
        },
        Err(()) => MediaUploadOutcome::Failed {
            cleanup_safe: tx.rollback().is_ok(),
            schema_unavailable: false,
        },
    }
}

pub(crate) async fn upload(
    State(state): State<NativeState>,
    config: Option<Extension<LocalStorageConfig>>,
    request: Request<Body>,
) -> Response {
    let mut response = upload_inner(state, config.map(|value| value.0), request)
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
    let server_error = || ApiError::server_error("服务器内部错误");
    let content_type = parts
        .headers
        .get(header::CONTENT_TYPE)
        .and_then(|header| header.to_str().ok())
        .unwrap_or("");
    if !content_type
        .split(';')
        .next()
        .unwrap_or_default()
        .trim_end()
        .eq_ignore_ascii_case("multipart/form-data")
    {
        return Err(ApiError::bad_request("请使用 multipart/form-data 上传头像"));
    }
    let config = config.unwrap_or_else(|| LocalStorageConfig::from_lookup(|_| None));
    if config.unsupported {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            50301,
            "媒体存储暂不可用",
        ));
    }
    let boundary =
        multer::parse_boundary(content_type).map_err(|_| ApiError::bad_request("头像上传失败"))?;
    let contract = contract();
    let mut media = multipart::parse_with_alias(
        body,
        &boundary,
        Limits {
            file_bytes: contract.max_file_bytes,
            total_file_bytes: contract.max_file_bytes,
            field_bytes: contract.max_field_bytes,
            files: contract.max_files,
            fields: contract.max_fields,
        },
        "avatar",
    )
    .await
    .map_err(|error| match error {
        ParseError::NoFile => ApiError::bad_request("上传文件为空"),
        ParseError::Invalid | ParseError::InvalidAccessScope => ApiError::bad_request("头像上传失败"),
        ParseError::Storage => server_error(),
    })?;
    let mut prefix = Vec::with_capacity(8);
    (&mut media.file)
        .take(8)
        .read_to_end(&mut prefix)
        .await
        .map_err(|_| server_error())?;
    let signature = hex::encode(prefix);
    let format = contract
        .formats
        .iter()
        .find(|format| signature.starts_with(&format.hex))
        .ok_or_else(|| ApiError::bad_request("头像仅支持 jpg、png、gif 图片"))?;

    let name = if media.name.is_empty()
        || media.name.len() > 255
        || media.name.contains(['/', '\\'])
        || media.name.chars().any(|ch| ch < ' ' || ch == '\u{7f}')
    {
        format!("avatar{}", format.extension)
    } else {
        media.name
    };
    let now = Utc::now();
    let key = format!(
        "avatars/{actor}/{:04}/{:02}/{}{}",
        now.year(),
        now.month(),
        uuid::Uuid::new_v4(),
        format.extension
    );
    let url = state
        .storage_urls
        .normalize_avatar(&format!("/storage/{key}"))
        .map_err(|_| server_error())?;
    let input = AvatarUpload {
        user_id: i64::try_from(actor).map_err(|_| server_error())?,
        size: media.size as i64,
        name,
        key: key.clone(),
        url: url.clone(),
        mime: format.mime.clone(),
    };
    let object = publish::publish(config,media.file,media.size,key,&input.mime)
        .await.map_err(|_| server_error())?;
    let result = state.repository.replace_user_avatar(input).await;
    let id = publish::finalize(object,result).await
        .map_err(|_| server_error())?;
    Ok(Json(V2Response::ok(
        json!({ "avatar_url": url, "avatar_media_id": id }),
    ))
    .into_response())
}
