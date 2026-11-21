use serde_json::Value;
use tokio::io::{AsyncReadExt, AsyncSeekExt};

#[derive(Debug, PartialEq)]
pub struct Metadata {
    pub width: Option<f64>,
    pub height: Option<f64>,
    pub duration: Option<f64>,
}

fn parse_probe(data: &[u8]) -> Option<Metadata> {
    let value: Value = serde_json::from_slice(data).ok()?;
    let streams = value.get("streams").and_then(Value::as_array);
    let stream = |kind: &str| {
        streams.and_then(|values| {
            values
                .iter()
                .find(|v| v.get("codec_type").and_then(Value::as_str) == Some(kind))
        })
    };
    let video = stream("video");
    let audio = stream("audio");
    let duration = value
        .get("format")
        .and_then(|v| v.get("duration"))
        .and_then(Value::as_str)
        .filter(|v| !v.is_empty())
        .or_else(|| {
            video
                .and_then(|v| v.get("duration"))
                .and_then(Value::as_str)
                .filter(|v| !v.is_empty())
        })
        .or_else(|| {
            audio
                .and_then(|v| v.get("duration"))
                .and_then(Value::as_str)
                .filter(|v| !v.is_empty())
        })
        .and_then(|v| v.parse::<f64>().ok())
        .filter(|v| *v >= 0.0)
        .map(f64::round)
        .filter(|v| *v <= 9_007_199_254_740_991.0);
    Some(Metadata {
        width: video
            .and_then(|v| v.get("width"))
            .and_then(Value::as_f64)
            .filter(|v| *v > 0.0 && *v <= 9_007_199_254_740_991.0 && v.fract() == 0.0),
        height: video
            .and_then(|v| v.get("height"))
            .and_then(Value::as_f64)
            .filter(|v| *v > 0.0 && *v <= 9_007_199_254_740_991.0 && v.fract() == 0.0),
        duration,
    })
}

/// Uses the staged upload. Missing tools yield no metadata.
pub async fn probe(
    file: &mut tokio::fs::File,
    binary: &std::ffi::OsStr,
    mime: &str,
    _staged_path: Option<&std::path::Path>,
) -> Option<Metadata> {
    use std::{ffi::OsStr, process::Stdio, sync::OnceLock, time::Duration};
    static LIMIT: OnceLock<tokio::sync::Semaphore> = OnceLock::new();
    let format = match mime {
        "audio/wav" => "wav",
        "audio/mpeg" => "mp3",
        "audio/ogg" | "video/ogg" => "ogg",
        "video/mp4" => "mov",
        "video/webm" => "matroska",
        _ => return None,
    };
    #[cfg(target_os = "linux")]
    let (input_path, protocols) = (OsStr::new("/proc/self/fd/0"), "file,pipe");
    #[cfg(windows)]
    let absolute_path = _staged_path.map(std::path::absolute).transpose().ok()?;
    #[cfg(windows)]
    let (input_path, protocols) = absolute_path
        .as_deref()
        .map(|path| (path.as_os_str(), "file"))
        .unwrap_or((OsStr::new("pipe:0"), "pipe"));
    #[cfg(not(any(target_os = "linux", windows)))]
    let (input_path, protocols) = (OsStr::new("pipe:0"), "pipe");
    let deadline = tokio::time::Instant::now() + Duration::from_secs(8);
    let permit = tokio::time::timeout_at(
        deadline,
        LIMIT
            .get_or_init(|| tokio::sync::Semaphore::new(4))
            .acquire(),
    )
    .await
    .ok()?
    .ok()?;
    file.seek(std::io::SeekFrom::Start(0)).await.ok()?;
    let input = if protocols == "file" {
        Stdio::null()
    } else {
        Stdio::from(file.try_clone().await.ok()?.into_std().await)
    };
    let mut command = tokio::process::Command::new(binary);
    if format == "mov" {
        command.args(["-enable_drefs", "0", "-use_absolute_path", "0"]);
    }
    let mut child = command
        .args([
            "-v",
            "quiet",
            "-protocol_whitelist",
            protocols,
            "-f",
            format,
            "-print_format",
            "json",
            "-show_format",
            "-show_streams",
            "-i",
        ])
        .arg(input_path)
        .stdin(input)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .ok()?;
    let mut output = child.stdout.take()?;
    let result = tokio::time::timeout_at(deadline, async {
        let mut bytes = Vec::new();
        (&mut output)
            .take(65537)
            .read_to_end(&mut bytes)
            .await
            .ok()?;
        if bytes.len() > 65536 {
            return None;
        }
        if !child.wait().await.ok()?.success() {
            return None;
        }
        parse_probe(&bytes)
    })
    .await;
    if !matches!(result, Ok(Some(_))) {
        let _ = child.kill().await;
        let _ = child.wait().await;
    }
    let reset = file.seek(std::io::SeekFrom::Start(0)).await;
    drop(permit);
    reset.ok()?;
    result.ok().flatten()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn missing_probe_is_nonfatal_and_keeps_file_readable() {
        use tokio::io::AsyncWriteExt;
        let mut file = tokio::fs::File::from_std(tempfile::tempfile().unwrap());
        file.write_all(b"example").await.unwrap();
        file.flush().await.unwrap();
        assert!(probe(
            &mut file,
            std::ffi::OsStr::new("nekotribe-nonexistent-ffprobe"),
            "audio/wav",
            None
        )
        .await
        .is_none());
        assert_eq!(file.stream_position().await.unwrap(), 0);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn oversized_probe_output_is_discarded() {
        use std::os::unix::fs::PermissionsExt;
        use tokio::io::AsyncWriteExt;
        let dir = tempfile::tempdir().unwrap();
        let binary = dir.path().join("fake-probe");
        std::fs::write(&binary, b"#!/bin/sh\nhead -c 100000 /dev/zero\n").unwrap();
        std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o700)).unwrap();
        let mut file = tokio::fs::File::from_std(tempfile::tempfile().unwrap());
        file.write_all(b"media").await.unwrap();
        file.flush().await.unwrap();
        assert!(probe(&mut file, binary.as_os_str(), "audio/wav", None)
            .await
            .is_none());
        assert_eq!(file.stream_position().await.unwrap(), 0);
    }

    #[tokio::test]
    #[ignore = "requires a locally installed ffprobe"]
    async fn probes_real_wav_from_staging() {
        use tokio::io::AsyncWriteExt;
        let binary = std::env::var_os("NEKO_TEST_FFPROBE").expect("NEKO_TEST_FFPROBE");
        let mut wav = Vec::from(&b"RIFF"[..]);
        wav.extend_from_slice(&(16036u32).to_le_bytes());
        wav.extend_from_slice(b"WAVEfmt ");
        wav.extend_from_slice(&(16u32).to_le_bytes());
        wav.extend_from_slice(&(1u16).to_le_bytes());
        wav.extend_from_slice(&(1u16).to_le_bytes());
        wav.extend_from_slice(&(8000u32).to_le_bytes());
        wav.extend_from_slice(&(16000u32).to_le_bytes());
        wav.extend_from_slice(&(2u16).to_le_bytes());
        wav.extend_from_slice(&(16u16).to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&(16000u32).to_le_bytes());
        wav.resize(wav.len() + 16000, 0);
        let (staged_file, path) = tempfile::NamedTempFile::new().unwrap().into_parts();
        let mut file = tokio::fs::File::from_std(staged_file);
        file.write_all(&wav).await.unwrap();
        file.flush().await.unwrap();
        let result = probe(&mut file, &binary, "audio/wav", Some(&path))
            .await
            .unwrap();
        assert_eq!(result.duration, Some(1.0));
        assert_eq!(file.stream_position().await.unwrap(), 0);
    }

    #[test]
    fn maps_video_dimensions_and_format_duration_before_stream_duration() {
        let data = br#"{"streams":[{"codec_type":"audio","duration":"5.2"},{"codec_type":"video","width":640,"height":360,"duration":"9.2"}],"format":{"duration":"12.5"}}"#;
        assert_eq!(
            parse_probe(data),
            Some(Metadata {
                width: Some(640.0),
                height: Some(360.0),
                duration: Some(13.0)
            })
        );
        let invalid = br#"{"streams":[{"codec_type":"video","width":0,"height":2.7}],"format":{"duration":"-0.4"}}"#;
        assert_eq!(
            parse_probe(invalid),
            Some(Metadata {
                width: None,
                height: None,
                duration: None
            })
        );
    }

    #[test]
    fn uses_first_stream_and_leaves_missing_or_invalid_values_empty() {
        let audio = br#"{"streams":[{"codec_type":"audio","duration":"3.4"}],"format":{}}"#;
        assert_eq!(
            parse_probe(audio),
            Some(Metadata {
                width: None,
                height: None,
                duration: Some(3.0)
            })
        );
        let unavailable =
            br#"{"streams":[{"codec_type":"audio","duration":"3.4"}],"format":{"duration":"N/A"}}"#;
        assert_eq!(
            parse_probe(unavailable),
            Some(Metadata {
                width: None,
                height: None,
                duration: None
            })
        );
        assert!(parse_probe(b"not json").is_none());
    }
}
