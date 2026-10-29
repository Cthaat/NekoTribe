use serde::{Deserialize, Serialize};
use std::path::Path;

// Content detection is a separate component; this only applies its result.
#[derive(Debug, Clone, Deserialize)]
pub struct DetectedType {
    pub ext: String,
    pub mime: String,
}
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SelectedType {
    pub extension: String,
    pub mime_type: String,
    pub media_type: String,
    pub supported: bool,
}

fn normalize_mime(value: &str) -> String {
    crate::auth::login::js_trim(value.split(';').next().unwrap_or("")).to_lowercase()
}
fn fallback(extension: &str) -> &'static str {
    match extension {
        ".7z" => "application/x-7z-compressed",
        ".csv" => "text/csv",
        ".doc" => "application/msword",
        ".docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        ".gz" => "application/gzip",
        ".json" => "application/json",
        ".md" => "text/markdown",
        ".odp" => "application/vnd.oasis.opendocument.presentation",
        ".ods" => "application/vnd.oasis.opendocument.spreadsheet",
        ".odt" => "application/vnd.oasis.opendocument.text",
        ".pdf" => "application/pdf",
        ".ppt" => "application/vnd.ms-powerpoint",
        ".pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        ".rar" => "application/vnd.rar",
        ".rtf" => "application/rtf",
        ".tar" => "application/x-tar",
        ".tsv" => "text/tab-separated-values",
        ".txt" => "text/plain",
        ".xls" => "application/vnd.ms-excel",
        ".xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        ".xml" => "application/xml",
        ".zip" => "application/zip",
        _ => "",
    }
}
fn supported(mime: &str) -> bool {
    matches!(
        mime,
        "image/avif"
            | "image/gif"
            | "image/jpeg"
            | "image/png"
            | "image/webp"
            | "audio/mpeg"
            | "audio/ogg"
            | "audio/wav"
            | "video/mp4"
            | "video/ogg"
            | "video/webm"
            | "application/json"
            | "application/msword"
            | "application/pdf"
            | "application/rtf"
            | "application/vnd.ms-excel"
            | "application/vnd.ms-powerpoint"
            | "application/vnd.oasis.opendocument.presentation"
            | "application/vnd.oasis.opendocument.spreadsheet"
            | "application/vnd.oasis.opendocument.text"
            | "application/vnd.openxmlformats-officedocument.presentationml.presentation"
            | "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            | "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            | "application/xml"
            | "text/csv"
            | "text/markdown"
            | "text/plain"
            | "text/tab-separated-values"
            | "text/xml"
            | "application/gzip"
            | "application/vnd.rar"
            | "application/x-7z-compressed"
            | "application/x-rar-compressed"
            | "application/x-tar"
            | "application/zip"
    )
}
pub fn select_media_file_type(
    name: &str,
    uploaded: &str,
    detected: Option<&DetectedType>,
) -> SelectedType {
    let extension = detected
        .filter(|d| !d.ext.is_empty())
        .map(|d| format!(".{}", d.ext.to_lowercase()))
        .unwrap_or_else(|| {
            Path::new(name)
                .extension()
                .and_then(|e| e.to_str())
                .map(|e| format!(".{}", e.to_lowercase()))
                .unwrap_or_else(|| ".bin".into())
        });
    let uploaded = normalize_mime(uploaded);
    let detected = detected
        .map(|d| normalize_mime(&d.mime))
        .unwrap_or_default();
    let fallback = fallback(&extension);
    let mime = if !detected.is_empty() {
        detected
    } else if uploaded == "application/octet-stream" && !fallback.is_empty() {
        fallback.into()
    } else if !uploaded.is_empty() {
        uploaded
    } else {
        fallback.into()
    };
    let media_type = if mime == "image/gif" {
        "gif"
    } else if matches!(
        mime.as_str(),
        "image/avif" | "image/jpeg" | "image/png" | "image/webp"
    ) {
        "image"
    } else if mime.starts_with("video/") {
        "video"
    } else if mime.starts_with("audio/") {
        "audio"
    } else {
        "file"
    };
    SelectedType {
        extension,
        media_type: media_type.into(),
        supported: supported(&mime),
        mime_type: mime,
    }
}
