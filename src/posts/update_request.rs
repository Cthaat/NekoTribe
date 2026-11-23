use crate::httpx::errors::ApiError;
use serde::Serialize;
#[derive(Debug, Clone, Default, Serialize)]
pub struct PostUpdateInput {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub visibility: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub location: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub media_ids: Option<Vec<f64>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tag_names: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mention_user_ids: Option<Vec<f64>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub markdown: Option<Option<String>>,
}
pub fn parse_update_body(bytes: &[u8], content_type: &str) -> Result<PostUpdateInput, ApiError> {
    use crate::{
        auth::login::js_trim,
        posts::create_request::{array, field, number_array, request_object, scalar},
    };
    let body = request_object(bytes, content_type)?;
    let text = |name: &str| {
        body.get(name)
            .map(|value| scalar(Some(value.as_ref())).unwrap_or_default())
    };
    let mut input = PostUpdateInput {
        content: text("content"),
        visibility: text("visibility"),
        ..Default::default()
    };
    if input
        .visibility
        .as_ref()
        .is_some_and(|v| !matches!(v.as_str(), "public" | "followers" | "mentioned" | "private"))
    {
        return Err(ApiError::bad_request("visibility 参数错误"));
    }
    if let Some(value) = text("language") {
        let mut language = js_trim(&value).to_lowercase();
        if language.is_empty() {
            language = "zh".into()
        }
        let (prefix, suffix) = language
            .split_once('-')
            .map_or((language.as_str(), None), |(a, b)| (a, Some(b)));
        if prefix.len() != 2
            || !prefix.bytes().all(|c| c.is_ascii_lowercase())
            || suffix.is_some_and(|s| {
                !(2..=7).contains(&s.len())
                    || !s
                        .bytes()
                        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
            })
        {
            return Err(ApiError::bad_request("language 参数错误"));
        }
        input.language = Some(language);
    }
    input.location = text("location");
    if let Some(value) = field(&body, "media_ids", "mediaIds") {
        input.media_ids = Some(number_array(Some(value)))
    }
    if let Some(value) = field(&body, "tag_names", "tagNames") {
        input.tag_names = Some(
            array(Some(value))
                .iter()
                .filter_map(|v| scalar(Some(v)))
                .map(|v| js_trim(&v).to_owned())
                .filter(|v| !v.is_empty())
                .collect(),
        )
    }
    if let Some(value) = field(&body, "mention_user_ids", "mentionUserIds") {
        input.mention_user_ids = Some(number_array(Some(value)))
    }
    if let Some(raw) = body.get("markdown") {
        input.markdown = Some(if raw.get() == "null" {
            None
        } else {
            Some(super::markdown::parse_raw(raw.get())?)
        });
    }
    Ok(input)
}
