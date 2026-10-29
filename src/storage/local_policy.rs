use serde::Serialize;
#[derive(Debug, PartialEq, Eq)]
pub enum StoragePolicyError {
    InvalidKey,
    InvalidRange,
}
#[derive(Debug, PartialEq, Eq, Serialize)]
pub struct ByteRange {
    pub start: u64,
    pub end: u64,
}
pub fn normalize_local_key(key: &str) -> Result<String, StoragePolicyError> {
    let normalized = key.replace('\\', "/");
    for part in normalized.split('/') {
        if part.is_empty()
            || part == "."
            || part == ".."
            || part.ends_with('.')
            || part.ends_with(' ')
            || part
                .chars()
                .any(|c| c < ' ' || c == '\u{7f}' || "<>:\"|?*".contains(c))
        {
            return Err(StoragePolicyError::InvalidKey);
        }
        let base = part
            .split('.')
            .next()
            .unwrap_or_default()
            .trim_end_matches(' ')
            .to_ascii_uppercase();
        let device = matches!(
            base.as_str(),
            "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$"
        ) || base
            .strip_prefix("COM")
            .or_else(|| base.strip_prefix("LPT"))
            .is_some_and(|n| {
                matches!(
                    n,
                    "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "¹" | "²" | "³"
                )
            });
        if device {
            return Err(StoragePolicyError::InvalidKey);
        }
    }
    Ok(normalized)
}
pub fn parse_local_byte_range(
    header: &str,
    size: u64,
) -> Result<Option<ByteRange>, StoragePolicyError> {
    let header = crate::auth::login::js_trim(header).to_ascii_lowercase();
    if header.is_empty() {
        return Ok(None);
    }
    let value = header
        .strip_prefix("bytes=")
        .ok_or(StoragePolicyError::InvalidRange)?;
    let (raw_start, raw_end) = value
        .split_once('-')
        .ok_or(StoragePolicyError::InvalidRange)?;
    if size == 0
        || !raw_start
            .bytes()
            .chain(raw_end.bytes())
            .all(|b| b.is_ascii_digit())
    {
        return Err(StoragePolicyError::InvalidRange);
    }
    let (start, end) = if raw_start.is_empty() {
        if raw_end.is_empty() {
            return Err(StoragePolicyError::InvalidRange);
        }
        let suffix = raw_end.parse::<u64>().unwrap_or(u64::MAX).min(size);
        if suffix == 0 {
            return Err(StoragePolicyError::InvalidRange);
        };
        (size - suffix, size - 1)
    } else {
        let start = raw_start
            .parse::<u64>()
            .map_err(|_| StoragePolicyError::InvalidRange)?;
        if start >= size {
            return Err(StoragePolicyError::InvalidRange);
        }
        let end = if raw_end.is_empty() {
            size - 1
        } else {
            raw_end.parse::<u64>().unwrap_or(u64::MAX).min(size - 1)
        };
        (start, end)
    };
    if end < start {
        return Err(StoragePolicyError::InvalidRange);
    }
    Ok(Some(ByteRange { start, end }))
}
