#[derive(Debug, PartialEq, Eq)]
pub struct InvalidBody;

#[derive(Debug, Default, PartialEq, Eq)]
pub struct KnowledgeSearchBody {
    pub phrase: Option<String>,
    pub skill_id: Option<&'static str>,
    pub expected_sequence: Option<i64>,
}

pub(super) fn expected_sequence(value: &serde_json::Value) -> Option<i64> {
    value
        .as_f64()
        .filter(|number| (1.0..=9_999_999_999.0).contains(number) && number.fract() == 0.0)
        .map(|number| number as i64)
}

pub(super) fn has_too_many_members(bytes: &[u8], max: usize) -> bool {
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
            if fields > max {
                return true;
            }
        }
    }
    false
}

/// Parses a bounded UTF-8 request body; an empty body or object uses the old behavior.
pub fn parse(bytes: &[u8]) -> Result<KnowledgeSearchBody, InvalidBody> {
    if bytes.is_empty() {
        return Ok(KnowledgeSearchBody::default());
    }
    if bytes.len() > 4096 {
        return Err(InvalidBody);
    }
    let value: serde_json::Value = serde_json::from_slice(bytes).map_err(|_| InvalidBody)?;
    let body = value.as_object().ok_or(InvalidBody)?;
    if body.keys().any(|key| {
        !matches!(
            key.as_str(),
            "search_phrase" | "skill_id" | "expected_sequence"
        )
    }) || has_too_many_members(bytes, body.len())
    {
        return Err(InvalidBody);
    }
    let skill_id = match body.get("skill_id") {
        None => None,
        Some(value) if value.as_str() == Some("knowledge-answer") => Some("knowledge-answer"),
        _ => return Err(InvalidBody),
    };
    let phrase = if let Some(value) = body.get("search_phrase") {
        let trimmed = crate::auth::login::js_trim(value.as_str().ok_or(InvalidBody)?);
        if trimmed.is_empty()
            || trimmed.len() > 256
            || trimmed.chars().any(|c| c <= '\u{1f}' || c == '\u{7f}')
        {
            return Err(InvalidBody);
        }
        Some(trimmed.to_owned())
    } else {
        None
    };
    let sequence = body
        .get("expected_sequence")
        .map(|value| expected_sequence(value).ok_or(InvalidBody))
        .transpose()?;
    Ok(KnowledgeSearchBody {
        phrase,
        skill_id,
        expected_sequence: sequence,
    })
}
