//! Prefix signature detection, before container-specific inspection.
//! An unrecognized prefix does not prove a file is safe.
use crate::storage::media_type_selection::DetectedType;
use tokio::io::{AsyncReadExt, AsyncSeekExt};

/// Classify a request-owned file, withholding ZIP results until inspected.
pub async fn inspect_file(file: &mut tokio::fs::File) -> std::io::Result<Option<DetectedType>> {
    use std::io::{Error, ErrorKind, SeekFrom};
    let size = file.metadata().await?.len();
    if size == 0 || size > 500 << 20 {
        return Err(Error::new(ErrorKind::InvalidData, "invalid media size"));
    }
    file.seek(SeekFrom::Start(0)).await?;
    let mut prefix = Vec::with_capacity(4096);
    (&mut *file).take(4096).read_to_end(&mut prefix).await?;
    file.seek(SeekFrom::Start(0)).await?;
    if prefix.starts_with(b"PK\x03\x04")
        || prefix.starts_with(b"PK\x05\x06")
        || prefix.starts_with(b"PK\x07\x08")
    {
        let cloned = file.try_clone().await?.into_std().await;
        let result = tokio::task::spawn_blocking(move || super::zip_detection::inspect(cloned))
            .await
            .map_err(|_| Error::other("ZIP inspection failed"))?;
        file.seek(SeekFrom::Start(0)).await?;
        return result.map(Some);
    }
    if prefix.starts_with(b"\x89PNG\r\n\x1a\n") {
        return inspect_png(file, size).await.map(Some);
    }
    Ok(detect_prefix(&prefix))
}

/// Inspect PNG chunk headers without loading the image; restore the file offset.
pub async fn inspect_png(file: &mut tokio::fs::File, size: u64) -> std::io::Result<DetectedType> {
    let result = inspect_png_inner(file, size).await;
    file.seek(std::io::SeekFrom::Start(0)).await?;
    result
}

async fn inspect_png_inner(file: &mut tokio::fs::File, size: u64) -> std::io::Result<DetectedType> {
    use std::io::{Error, ErrorKind, SeekFrom};
    let invalid = || Error::new(ErrorKind::InvalidData, "invalid PNG chunks");
    if size != file.metadata().await?.len() || size < 8 || size > 500 << 20 {
        return Err(invalid());
    }
    file.seek(SeekFrom::Start(0)).await?;
    let mut signature = [0; 8];
    file.read_exact(&mut signature).await?;
    if &signature != b"\x89PNG\r\n\x1a\n" {
        return Err(invalid());
    }
    let mut offset = 8u64;
    for _ in 0..10_000 {
        if offset.checked_add(8).is_none_or(|end| end > size) {
            return Err(invalid());
        }
        file.seek(SeekFrom::Start(offset)).await?;
        let mut header = [0u8; 8];
        file.read_exact(&mut header).await?;
        let length = u32::from_be_bytes(header[..4].try_into().map_err(|_| invalid())?) as u64;
        if length > 0x7fff_ffff {
            return Err(invalid());
        }
        let next = offset
            .checked_add(12)
            .and_then(|n| n.checked_add(length))
            .filter(|n| *n <= size)
            .ok_or_else(invalid)?;
        match &header[4..] {
            b"acTL" => {
                return Ok(DetectedType {
                    ext: "apng".into(),
                    mime: "image/apng".into(),
                })
            }
            b"IDAT" => {
                return Ok(DetectedType {
                    ext: "png".into(),
                    mime: "image/png".into(),
                })
            }
            _ => offset = next,
        }
    }
    Err(invalid())
}

pub async fn inspect_prefix(file: &mut tokio::fs::File) -> std::io::Result<Option<DetectedType>> {
    file.seek(std::io::SeekFrom::Start(0)).await?;
    let mut prefix = Vec::with_capacity(4096);
    (&mut *file).take(4096).read_to_end(&mut prefix).await?;
    file.seek(std::io::SeekFrom::Start(0)).await?;
    Ok(detect_prefix(&prefix))
}

pub fn detect_prefix(data: &[u8]) -> Option<DetectedType> {
    if data.starts_with(b"MZ") {
        return Some(DetectedType {
            ext: "exe".into(),
            mime: "application/x-msdownload".into(),
        });
    }
    if data.starts_with(b"\x7fELF") {
        return Some(DetectedType {
            ext: "elf".into(),
            mime: "application/x-elf".into(),
        });
    }
    infer::get(data).map(|kind| DetectedType {
        ext: kind.extension().into(),
        mime: match kind.mime_type() {
            "audio/x-wav" => "audio/wav",
            mime => mime,
        }
        .into(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn detects_png_chunks_after_prefix_and_restores_file_position() {
        use base64::{engine::general_purpose::STANDARD, Engine};
        use tokio::io::AsyncWriteExt;
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../contracts/scenarios/media-container-samples.json"
        ))
        .unwrap();
        for case in fixture["cases"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|v| matches!(v["id"].as_str(), Some("large-png" | "large-apng")))
        {
            let data = STANDARD.decode(case["base64"].as_str().unwrap()).unwrap();
            let mut file = tokio::fs::File::from_std(tempfile::tempfile().unwrap());
            file.write_all(&data).await.unwrap();
            file.flush().await.unwrap();
            let detected = inspect_file(&mut file).await.unwrap().unwrap();
            assert_eq!(detected.ext, case["expected"]["ext"].as_str().unwrap());
            assert_eq!(detected.mime, case["expected"]["mime"].as_str().unwrap());
            assert_eq!(file.stream_position().await.unwrap(), 0);
        }
    }

    #[tokio::test]
    async fn rejects_truncated_and_excessive_png_chunks() {
        use tokio::io::AsyncWriteExt;
        let mut file = tokio::fs::File::from_std(tempfile::tempfile().unwrap());
        let data = b"\x89PNG\r\n\x1a\n\x7f\xff\xff\xfftEXt";
        file.write_all(data).await.unwrap();
        file.flush().await.unwrap();
        assert!(inspect_png(&mut file, data.len() as u64).await.is_err());
    }

    #[tokio::test]
    async fn detects_shared_zip_containers() {
        use base64::{engine::general_purpose::STANDARD, Engine};
        use tokio::io::AsyncWriteExt;
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../contracts/scenarios/media-container-samples.json"
        ))
        .unwrap();
        for case in fixture["cases"].as_array().unwrap().iter().filter(|v| {
            matches!(
                v["id"].as_str(),
                Some("large-zip" | "large-docx" | "large-odt" | "large-jar")
            )
        }) {
            let mut file = tokio::fs::File::from_std(tempfile::tempfile().unwrap());
            file.write_all(&STANDARD.decode(case["base64"].as_str().unwrap()).unwrap())
                .await
                .unwrap();
            file.flush().await.unwrap();
            let result = inspect_file(&mut file).await.unwrap().unwrap();
            assert_eq!(
                result.ext,
                case["expected"]["ext"].as_str().unwrap(),
                "{}",
                case["id"]
            );
            assert_eq!(
                result.mime,
                case["expected"]["mime"].as_str().unwrap(),
                "{}",
                case["id"]
            );
            assert_eq!(file.stream_position().await.unwrap(), 0);
        }
    }

    #[tokio::test]
    async fn rejects_zip_with_mismatched_local_header() {
        use base64::{engine::general_purpose::STANDARD, Engine};
        use tokio::io::AsyncWriteExt;
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../contracts/scenarios/media-container-samples.json"
        ))
        .unwrap();
        let case = fixture["cases"]
            .as_array()
            .unwrap()
            .iter()
            .find(|v| v["id"] == "large-docx")
            .unwrap();
        let mut data = STANDARD.decode(case["base64"].as_str().unwrap()).unwrap();
        data[30] ^= 1;
        let mut file = tokio::fs::File::from_std(tempfile::tempfile().unwrap());
        file.write_all(&data).await.unwrap();
        file.flush().await.unwrap();
        assert!(inspect_file(&mut file).await.is_err());
    }

    #[tokio::test]
    async fn inspects_streamed_upload_without_consuming_its_file() {
        use axum::body::Body;
        use tokio::io::AsyncReadExt;
        let mut body = b"--x\r\nContent-Disposition: form-data; name=\"file\"; filename=\"fake.txt\"\r\nContent-Type: text/plain\r\n\r\n".to_vec();
        let png =
            hex::decode("89504e470d0a1a0a0000000d4948445200000001000000010806000000").unwrap();
        body.extend_from_slice(&png);
        body.extend_from_slice(b"\r\n--x--\r\n");
        let mut upload = crate::media::multipart::parse(Body::from(body), "x", Default::default())
            .await
            .unwrap();
        let detected = inspect_prefix(&mut upload.file).await.unwrap().unwrap();
        assert_eq!(detected.mime, "image/png");
        let mut remaining = Vec::new();
        upload.file.read_to_end(&mut remaining).await.unwrap();
        assert_eq!(remaining, png);
    }

    #[test]
    fn shared_simple_signature_vectors() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../contracts/scenarios/media-content-signatures.json"
        ))
        .unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            let id = case["id"].as_str().unwrap();
            if matches!(id, "apng" | "zip" | "docx") {
                continue;
            }
            let actual = detect_prefix(&hex::decode(case["hex"].as_str().unwrap()).unwrap());
            let expected = &case["expected"];
            if expected.is_null() {
                assert!(actual.is_none(), "{id}");
                continue;
            }
            let actual = actual.unwrap_or_else(|| panic!("{id}"));
            assert_eq!(actual.ext, expected["ext"].as_str().unwrap(), "{id}");
            assert_eq!(actual.mime, expected["mime"].as_str().unwrap(), "{id}");
        }
    }

    #[test]
    fn detects_common_real_content_and_rejects_unsupported_executable() {
        let png =
            hex::decode("89504e470d0a1a0a0000000d4948445200000001000000010806000000").unwrap();
        let png_type = detect_prefix(&png).unwrap();
        assert_eq!(
            (png_type.ext.as_str(), png_type.mime.as_str()),
            ("png", "image/png")
        );
        let exe = hex::decode("4d5a90000300000004000000ffff0000").unwrap();
        let exe_type = detect_prefix(&exe).unwrap();
        assert_eq!(
            (exe_type.ext.as_str(), exe_type.mime.as_str()),
            ("exe", "application/x-msdownload")
        );
        let selected = crate::storage::media_type_selection::select_media_file_type(
            "safe.txt",
            "text/plain",
            Some(&exe_type),
        );
        assert!(!selected.supported);
        assert!(detect_prefix(b"plain text").is_none());
    }
}
