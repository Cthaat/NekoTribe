#[derive(Debug, PartialEq, Eq)]
pub struct InvalidBody;

/// Parses a bounded UTF-8 request body; an empty body or object uses the old behavior.
pub fn parse(bytes: &[u8]) -> Result<Option<String>, InvalidBody> {
    if bytes.is_empty() {
        return Ok(None);
    }
    if bytes.len() > 4096 {
        return Err(InvalidBody);
    }
    let value: serde_json::Value = serde_json::from_slice(bytes).map_err(|_| InvalidBody)?;
    let body = value.as_object().ok_or(InvalidBody)?;
    if body.is_empty() {
        return Ok(None);
    }
    if body.len() != 1 {
        return Err(InvalidBody);
    }
    let phrase = body
        .get("search_phrase")
        .and_then(|v| v.as_str())
        .ok_or(InvalidBody)?;
    let trimmed = crate::auth::login::js_trim(phrase);
    if trimmed.is_empty()
        || trimmed.len() > 256
        || trimmed.chars().any(|c| c <= '\u{1f}' || c == '\u{7f}')
    {
        return Err(InvalidBody);
    }
    Ok(Some(trimmed.to_owned()))
}
