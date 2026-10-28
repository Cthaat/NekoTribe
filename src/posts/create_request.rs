use crate::{
    auth::{login::js_trim, sessions::percent_decode},
    httpx::errors::ApiError,
};
use serde_json::value::RawValue;
use std::collections::BTreeMap;

const MAX_SAFE_ID: u64 = 9_007_199_254_740_991;
type RequestObject = BTreeMap<String, Box<RawValue>>;

#[derive(Debug, Clone)]
pub struct PostCreateInput {
    pub content: String,
    pub visibility: String,
    pub location: String,
    pub media_ids: Vec<f64>,
    pub tag_names: Vec<String>,
    pub mention_user_ids: Vec<f64>,
    pub reply_to_post_id: Option<u64>,
    pub repost_of_post_id: Option<u64>,
    pub quoted_post_id: Option<u64>,
}

impl Default for PostCreateInput {
    fn default() -> Self {
        Self {
            content: String::new(),
            visibility: "public".into(),
            location: String::new(),
            media_ids: Vec::new(),
            tag_names: Vec::new(),
            mention_user_ids: Vec::new(),
            reply_to_post_id: None,
            repost_of_post_id: None,
            quoted_post_id: None,
        }
    }
}

impl PostCreateInput {
    pub fn post_type(&self) -> &'static str {
        if self.reply_to_post_id.is_some() {
            "reply"
        } else if self.repost_of_post_id.is_some() {
            "repost"
        } else if self.quoted_post_id.is_some() {
            "quote"
        } else {
            "post"
        }
    }
}

/// The caller passes an original URI segment, before percent decoding.
pub fn parse_repost_id(raw: &str) -> Result<u64, ApiError> {
    let decoded = percent_decode(raw).ok_or_else(invalid_id)?;
    canonical_id(&decoded)
}

pub fn parse_create_body(
    bytes: &[u8],
    content_type: &str,
    repost: Option<u64>,
) -> Result<PostCreateInput, ApiError> {
    let body = request_object(bytes, content_type)?;
    let mut input = PostCreateInput {
        content: scalar(body.get("content").map(Box::as_ref)).unwrap_or_default(),
        visibility: scalar(body.get("visibility").map(Box::as_ref))
            .unwrap_or_else(|| "public".into()),
        ..PostCreateInput::default()
    };
    if !matches!(
        input.visibility.as_str(),
        "public" | "followers" | "mentioned" | "private"
    ) {
        return Err(ApiError::bad_request("visibility 参数错误"));
    }
    if let Some(id) = repost {
        input.repost_of_post_id = Some(id);
        return Ok(input);
    }
    input.media_ids = number_array(field(&body, "media_ids", "mediaIds"));
    input.tag_names = array(field(&body, "tag_names", "tagNames"))
        .iter()
        .filter_map(|value| scalar(Some(value)))
        .map(|value| js_trim(&value).to_owned())
        .filter(|value| !value.is_empty())
        .collect();
    input.mention_user_ids = number_array(field(&body, "mention_user_ids", "mentionUserIds"));
    input.reply_to_post_id = reference(field(&body, "reply_to_post_id", "replyToPostId"))?;
    input.repost_of_post_id = reference(field(&body, "repost_of_post_id", "repostOfPostId"))?;
    input.quoted_post_id = reference(field(&body, "quoted_post_id", "quotedPostId"))?;
    input.location = scalar(body.get("location").map(Box::as_ref)).unwrap_or_default();
    let reference_count = [
        input.reply_to_post_id,
        input.repost_of_post_id,
        input.quoted_post_id,
    ]
    .into_iter()
    .flatten()
    .count();
    if reference_count > 1 {
        return Err(ApiError::bad_request("引用字段只能传一个"));
    }
    if input.repost_of_post_id.is_none()
        && js_trim(&input.content).is_empty()
        && input.media_ids.is_empty()
    {
        return Err(ApiError::bad_request("content 不能为空"));
    }
    Ok(input)
}

pub(super) fn request_object(bytes: &[u8], content_type: &str) -> Result<RequestObject, ApiError> {
    let bad = || ApiError::bad_request("请求体必须是 JSON 对象");
    if bytes.len() > 1024 * 1024 {
        return Err(bad());
    }
    let content_type = content_type
        .split(';')
        .next()
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase();
    if content_type.starts_with("text/") {
        return Err(bad());
    }
    if content_type == "application/x-www-form-urlencoded" {
        let mut headers = http::HeaderMap::new();
        headers.insert(
            http::header::CONTENT_TYPE,
            http::HeaderValue::from_static("application/x-www-form-urlencoded"),
        );
        let form = crate::auth::login::request_body(&headers, bytes)?;
        let json = serde_json::to_vec(&form).map_err(|_| bad())?;
        return serde_json::from_slice(&json).map_err(|_| bad());
    }
    // RawValue preserves valid JSON number tokens such as 1e400, which JS
    // converts to Infinity. from_slice still checks syntax and trailing data.
    serde_json::from_slice(bytes).map_err(|_| bad())
}

pub(super) fn field<'a>(
    body: &'a RequestObject,
    primary: &str,
    fallback: &str,
) -> Option<&'a RawValue> {
    body.get(primary)
        .or_else(|| body.get(fallback))
        .map(Box::as_ref)
}

pub(super) fn scalar(value: Option<&RawValue>) -> Option<String> {
    let raw = value?.get();
    match raw.as_bytes().first()? {
        b'"' => serde_json::from_str(raw).ok(),
        b't' | b'f' => Some(raw.to_owned()),
        b'-' | b'0'..=b'9' => {
            let number = raw.parse::<f64>().ok()?;
            Some(if number == 0.0 {
                "0".into()
            } else if number == f64::INFINITY {
                "Infinity".into()
            } else if number == f64::NEG_INFINITY {
                "-Infinity".into()
            } else {
                ryu_js::Buffer::new().format(number).to_owned()
            })
        }
        _ => None,
    }
}

pub(super) fn array(value: Option<&RawValue>) -> Vec<Box<RawValue>> {
    value
        .and_then(|value| serde_json::from_str(value.get()).ok())
        .unwrap_or_default()
}

pub(super) fn number_array(value: Option<&RawValue>) -> Vec<f64> {
    array(value)
        .iter()
        .filter_map(|value| {
            let raw = value.get();
            let number = if raw.starts_with('"') {
                let text: String = serde_json::from_str(raw).ok()?;
                if text.is_empty() {
                    return None;
                }
                string_number(js_trim(&text))?
            } else {
                raw.parse::<f64>().ok()?
            };
            number.is_finite().then_some(number)
        })
        .collect()
}

fn string_number(text: &str) -> Option<f64> {
    if text.is_empty() {
        return Some(0.0);
    }
    let bits = if text.starts_with("0x") || text.starts_with("0X") {
        Some(4)
    } else if text.starts_with("0o") || text.starts_with("0O") {
        Some(3)
    } else if text.starts_with("0b") || text.starts_with("0B") {
        Some(1)
    } else {
        None
    };
    match bits {
        Some(bits) => radix_number(&text[2..], bits),
        None => text.parse().ok(),
    }
}

// All JS nondecimal string radices are powers of two. Keep 53 significant
// bits plus guard/sticky bits so arbitrarily long IDs round once, to nearest
// even, instead of accumulating floating-point rounding per digit.
fn radix_number(digits: &str, bits_per_digit: u32) -> Option<f64> {
    if digits.is_empty() {
        return None;
    }
    let mut significand = 0_u64;
    let mut bit_count = 0_i32;
    let mut guard = false;
    let mut sticky = false;
    for digit in digits.chars() {
        let digit = digit.to_digit(1 << bits_per_digit)?;
        for shift in (0..bits_per_digit).rev() {
            let bit = (digit >> shift) & 1;
            if bit_count == 0 && bit == 0 {
                continue;
            }
            bit_count += 1;
            match bit_count {
                1..=53 => significand = (significand << 1) | u64::from(bit),
                54 => guard = bit != 0,
                _ => sticky |= bit != 0,
            }
        }
    }
    if guard && (sticky || significand & 1 != 0) {
        significand += 1;
    }
    Some(significand as f64 * 2_f64.powi((bit_count - 53).max(0)))
}

fn reference(value: Option<&RawValue>) -> Result<Option<u64>, ApiError> {
    let Some(value) = value else {
        return Ok(None);
    };
    let raw = value.get();
    if raw == "null" {
        return Ok(None);
    }
    if raw.starts_with('"') {
        let text: String = serde_json::from_str(raw).map_err(|_| invalid_id())?;
        return if text.is_empty() {
            Ok(None)
        } else {
            canonical_id(&text).map(Some)
        };
    }
    let number = raw.parse::<f64>().map_err(|_| invalid_id())?;
    if number.is_finite() && number >= 1.0 && number <= MAX_SAFE_ID as f64 && number.fract() == 0.0
    {
        Ok(Some(number as u64))
    } else {
        Err(invalid_id())
    }
}

fn canonical_id(text: &str) -> Result<u64, ApiError> {
    if text.is_empty() || text.starts_with('0') || !text.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(invalid_id());
    }
    text.parse::<u64>()
        .ok()
        .filter(|id| *id > 0 && *id <= MAX_SAFE_ID)
        .ok_or_else(invalid_id)
}

fn invalid_id() -> ApiError {
    ApiError::bad_request("id 参数错误")
}
