use tokio::io::{AsyncReadExt, AsyncSeekExt};

// Only chunk headers are read; the uploaded audio payload is never buffered.
pub async fn pcm_duration(file: &mut tokio::fs::File) -> Option<f64> {
    let result = read_duration(file).await;
    file.seek(std::io::SeekFrom::Start(0)).await.ok()?;
    result
}

async fn read_duration(file: &mut tokio::fs::File) -> Option<f64> {
    let length = file.metadata().await.ok()?.len();
    file.seek(std::io::SeekFrom::Start(0)).await.ok()?;
    let mut header = [0u8; 12];
    file.read_exact(&mut header).await.ok()?;
    if &header[..4] != b"RIFF" || &header[8..] != b"WAVE" {
        return None;
    }
    let end = u64::from(u32::from_le_bytes(header[4..8].try_into().ok()?)) + 8;
    if end < 12 || end > length {
        return None;
    }
    let (mut position, mut rate, mut align, mut data) = (12u64, 0u32, 0u16, None);
    for _ in 0..1024 {
        if position + 8 > end {
            break;
        }
        file.seek(std::io::SeekFrom::Start(position)).await.ok()?;
        let mut chunk = [0u8; 8];
        file.read_exact(&mut chunk).await.ok()?;
        let size = u64::from(u32::from_le_bytes(chunk[4..].try_into().ok()?));
        let start = position + 8;
        if size + (size & 1) > end - start {
            return None;
        }
        match &chunk[..4] {
            b"fmt " => {
                if rate != 0 || size < 16 {
                    return None;
                }
                let mut fmt = [0u8; 16];
                file.read_exact(&mut fmt).await.ok()?;
                let kind = u16::from_le_bytes(fmt[0..2].try_into().ok()?);
                let channels = u16::from_le_bytes(fmt[2..4].try_into().ok()?);
                let sample_rate = u32::from_le_bytes(fmt[4..8].try_into().ok()?);
                let bytes = u32::from_le_bytes(fmt[8..12].try_into().ok()?);
                let block = u16::from_le_bytes(fmt[12..14].try_into().ok()?);
                let bits = u16::from_le_bytes(fmt[14..16].try_into().ok()?);
                if !matches!(kind, 1 | 3)
                    || channels == 0
                    || sample_rate == 0
                    || bits == 0
                    || bits % 8 != 0
                    || u64::from(channels) * u64::from(bits / 8) != u64::from(block)
                    || u64::from(sample_rate) * u64::from(block) != u64::from(bytes)
                {
                    return None;
                }
                rate = bytes;
                align = block;
            }
            b"data" => {
                if data.replace(size).is_some() {
                    return None;
                }
            }
            _ => {}
        }
        position = start + size + (size & 1);
    }
    let data = data?;
    if position != end || rate == 0 || data % u64::from(align) != 0 {
        return None;
    }
    Some((data as f64 / f64::from(rate) + 0.5).floor())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncWriteExt;

    fn wav() -> Vec<u8> {
        let mut bytes = Vec::from(&b"RIFF"[..]);
        bytes.extend_from_slice(&16036u32.to_le_bytes());
        bytes.extend_from_slice(b"WAVEfmt ");
        bytes.extend_from_slice(&16u32.to_le_bytes());
        bytes.extend_from_slice(&1u16.to_le_bytes());
        bytes.extend_from_slice(&1u16.to_le_bytes());
        bytes.extend_from_slice(&8000u32.to_le_bytes());
        bytes.extend_from_slice(&16000u32.to_le_bytes());
        bytes.extend_from_slice(&2u16.to_le_bytes());
        bytes.extend_from_slice(&16u16.to_le_bytes());
        bytes.extend_from_slice(b"data");
        bytes.extend_from_slice(&16000u32.to_le_bytes());
        bytes.resize(16044, 0);
        bytes
    }

    #[tokio::test]
    async fn validates_pcm_and_restores_file_position() {
        for case in 0..5 {
            let mut bytes = wav();
            match case {
                1 => bytes[0] = b'x',
                2 => {
                    bytes.pop();
                }
                3 => bytes[28..32].copy_from_slice(&1u32.to_le_bytes()),
                4 => bytes[20..22].copy_from_slice(&6u16.to_le_bytes()),
                _ => {}
            }
            let mut file = tokio::fs::File::from_std(tempfile::tempfile().unwrap());
            file.write_all(&bytes).await.unwrap();
            file.flush().await.unwrap();
            assert_eq!(
                pcm_duration(&mut file).await,
                if case == 0 { Some(1.0) } else { None },
                "case {case}"
            );
            assert_eq!(file.stream_position().await.unwrap(), 0);
        }
    }
}
