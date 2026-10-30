#[derive(Debug, PartialEq, Eq)]
pub struct InvalidBody;

fn has_multiple_members(bytes: &[u8]) -> bool {
    let (mut depth, mut fields) = (0_i32, 0);
    let (mut in_string, mut escaped) = (false, false);
    for &c in bytes {
        if in_string {
            if escaped {
                escaped = false;
            } else if c == b'\\' {
                escaped = true;
            } else if c == b'"' {
                in_string = false;
            }
        } else if c == b'"' {
            in_string = true;
        } else if c == b'{' || c == b'[' {
            depth += 1;
        } else if c == b'}' || c == b']' {
            depth -= 1;
        } else if c == b':' && depth == 1 {
            fields += 1;
            if fields > 1 {
                return true;
            }
        }
    }
    false
}

/// Parses a bounded UTF-8 request body; an empty body or object uses the old behavior.
pub fn parse(bytes: &[u8]) -> Result<Option<String>, InvalidBody> {
    if bytes.is_empty() {
        return Ok(None);
    }
    if bytes.len() > 4096 {
        return Err(InvalidBody);
    }
    let value: serde_json::Value = serde_json::from_slice(bytes).map_err(|_| InvalidBody)?;
    if has_multiple_members(bytes) {
        return Err(InvalidBody);
    }
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
