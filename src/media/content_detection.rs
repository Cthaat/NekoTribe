//! Prefix signature detection, before container-specific inspection.
//! An unrecognized prefix does not prove a file is safe.
use crate::storage::media_type_selection::DetectedType;
use tokio::io::{AsyncReadExt, AsyncSeekExt};

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
