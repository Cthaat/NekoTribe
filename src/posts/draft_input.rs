use super::{create_request::PostCreateInput, draft_store::contract, markdown, polls};
use crate::{auth::login::js_trim, group_post_write::PostInput, httpx::errors::ApiError};
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;

const MAX_ID: u64 = 9_007_199_254_740_991;

#[derive(Clone, Serialize, Deserialize)]
#[serde(try_from = "f64")]
struct JsonId(u64);

impl TryFrom<f64> for JsonId {
    type Error = &'static str;

    fn try_from(number: f64) -> Result<Self, Self::Error> {
        if !(1.0..=MAX_ID as f64).contains(&number) || number.fract() != 0.0 {
            return Err("invalid id");
        }
        Ok(Self(number as u64))
    }
}

fn present<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    T::deserialize(deserializer).map(Some)
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Regular {
    group_id: (),
    content: String,
    #[serde(
        default,
        deserialize_with = "present",
        skip_serializing_if = "Option::is_none"
    )]
    visibility: Option<String>,
    #[serde(
        default,
        deserialize_with = "present",
        skip_serializing_if = "Option::is_none"
    )]
    media_ids: Option<Vec<JsonId>>,
    #[serde(
        default,
        deserialize_with = "present",
        skip_serializing_if = "Option::is_none"
    )]
    tag_names: Option<Vec<String>>,
    #[serde(
        default,
        deserialize_with = "present",
        skip_serializing_if = "Option::is_none"
    )]
    mention_user_ids: Option<Vec<JsonId>>,
    #[serde(
        default,
        deserialize_with = "present",
        skip_serializing_if = "Option::is_none"
    )]
    location: Option<String>,
    #[serde(
        default,
        deserialize_with = "present",
        skip_serializing_if = "Option::is_none"
    )]
    poll: Option<Value>,
    #[serde(
        default,
        deserialize_with = "present",
        skip_serializing_if = "Option::is_none"
    )]
    markdown: Option<String>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Group {
    group_id: JsonId,
    content: String,
    #[serde(
        default,
        deserialize_with = "present",
        skip_serializing_if = "Option::is_none"
    )]
    media_urls: Option<Vec<String>>,
    #[serde(
        default,
        deserialize_with = "present",
        skip_serializing_if = "Option::is_none"
    )]
    is_announcement: Option<bool>,
    #[serde(
        default,
        deserialize_with = "present",
        skip_serializing_if = "Option::is_none"
    )]
    poll: Option<Value>,
    #[serde(
        default,
        deserialize_with = "present",
        skip_serializing_if = "Option::is_none"
    )]
    markdown: Option<String>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(untagged)]
pub enum DraftPayload {
    Regular(Regular),
    Group(Group),
}

pub(super) enum Post {
    Regular(PostCreateInput),
    Group { group: u64, input: PostInput },
}

impl Post {
    pub(super) fn poll(&self) -> Option<&polls::Draft> {
        match self {
            Self::Regular(input) => input.poll.as_ref(),
            Self::Group { input, .. } => input.poll.as_ref(),
        }
    }

    pub(super) fn has_markdown(&self) -> bool {
        match self {
            Self::Regular(input) => input.markdown.is_some(),
            Self::Group { input, .. } => input.markdown.is_some(),
        }
    }
}

fn invalid_payload() -> ApiError {
    ApiError::bad_request("草稿内容参数错误")
}

pub(super) fn parse_payload(raw: &[u8]) -> Result<DraftPayload, ApiError> {
    if raw.len() > contract().max_payload_bytes {
        return Err(invalid_payload());
    }
    let mut payload: DraftPayload = serde_json::from_slice(raw).map_err(|_| invalid_payload())?;
    payload.validate()?;
    if serde_json::to_vec(&payload)
        .map_err(|_| invalid_payload())?
        .len()
        > contract().max_payload_bytes
    {
        return Err(invalid_payload());
    }
    Ok(payload)
}

fn validate_items<T>(values: Option<&Vec<T>>, max: usize, test: impl Fn(&T) -> bool) -> bool {
    values.is_none_or(|values| values.len() <= max && values.iter().all(test))
}

fn poll(value: Option<&Value>) -> Result<Option<polls::Draft>, ApiError> {
    value
        .map(|value| polls::parse_draft(&value.to_string()))
        .transpose()
}

impl DraftPayload {
    pub(super) fn group_id(&self) -> Option<u64> {
        match self {
            Self::Regular(_) => None,
            Self::Group(group) => Some(group.group_id.0),
        }
    }

    fn validate(&mut self) -> Result<(), ApiError> {
        let (poll_value, markdown_body) = match self {
            Self::Regular(input) => {
                if input.content.len() > 4000
                    || !input.visibility.as_deref().is_none_or(|value| {
                        matches!(value, "public" | "followers" | "mentioned" | "private")
                    })
                    || !validate_items(input.media_ids.as_ref(), 4, |_| true)
                    || !validate_items(input.tag_names.as_ref(), 20, |tag| tag.len() <= 100)
                    || !validate_items(input.mention_user_ids.as_ref(), 50, |_| true)
                    || !input
                        .location
                        .as_ref()
                        .is_none_or(|location| location.len() <= 100)
                {
                    return Err(invalid_payload());
                }
                (&mut input.poll, input.markdown.as_deref())
            }
            Self::Group(input) => {
                if input.content.len() > 4000
                    || !validate_items(input.media_urls.as_ref(), 4, |url| {
                        url.len() <= 2000 && !url.contains(',')
                    })
                    || input
                        .media_urls
                        .as_ref()
                        .is_some_and(|urls| urls.join(",").len() > 2000)
                {
                    return Err(invalid_payload());
                }
                (&mut input.poll, input.markdown.as_deref())
            }
        };
        if let Some(body) = markdown_body {
            markdown::validate(body)?;
        }
        if let Some(draft) = poll(poll_value.as_ref())? {
            *poll_value = Some(serde_json::to_value(draft).map_err(|_| invalid_payload())?);
        }
        Ok(())
    }

    pub(super) fn post(self) -> Result<Post, ApiError> {
        let ids = |values: Option<Vec<JsonId>>| {
            values
                .unwrap_or_default()
                .into_iter()
                .map(|value| value.0 as f64)
                .collect()
        };
        match self {
            Self::Regular(input) => {
                if js_trim(&input.content).is_empty()
                    && input.media_ids.as_ref().is_none_or(Vec::is_empty)
                {
                    return Err(ApiError::bad_request("content 不能为空"));
                }
                Ok(Post::Regular(PostCreateInput {
                    content: input.content,
                    visibility: input.visibility.unwrap_or_else(|| "public".into()),
                    media_ids: ids(input.media_ids),
                    tag_names: input.tag_names.unwrap_or_default(),
                    mention_user_ids: ids(input.mention_user_ids),
                    location: input.location.unwrap_or_default(),
                    poll: poll(input.poll.as_ref())?,
                    markdown: input.markdown,
                    ..PostCreateInput::default()
                }))
            }
            Self::Group(input) => {
                let content = js_trim(&input.content);
                if content.is_empty() || content.len() > 4000 {
                    return Err(ApiError::bad_request("content 参数错误"));
                }
                let urls = input.media_urls.unwrap_or_default();
                let media = urls
                    .iter()
                    .map(|url| js_trim(url))
                    .filter(|url| !url.is_empty())
                    .collect::<Vec<_>>()
                    .join(",");
                if media.len() > 2000 {
                    return Err(ApiError::bad_request("media_urls 参数错误"));
                }
                Ok(Post::Group {
                    group: input.group_id.0,
                    input: PostInput {
                        content: content.into(),
                        media,
                        announcement: input.is_announcement.unwrap_or(false),
                        poll: poll(input.poll.as_ref())?,
                        markdown: input.markdown,
                    },
                })
            }
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub struct ListQuery {
    pub(super) before_id: Option<u64>,
    pub(super) group_scope: Option<u64>,
    pub(super) limit: usize,
}

pub(super) fn parse_query(raw: &str) -> Result<ListQuery, ApiError> {
    let url = reqwest::Url::parse(&format!("http://localhost/?{raw}")).expect("fixed URL");
    let mut query = ListQuery {
        before_id: None,
        group_scope: None,
        limit: contract().default_list_limit,
    };
    let mut limit_seen = false;
    for (key, value) in url.query_pairs() {
        match key.as_ref() {
            "before_id" if query.before_id.is_none() => {
                query.before_id = Some(parse_id(&value, "before_id")?)
            }
            "group_id" if query.group_scope.is_none() => {
                query.group_scope = Some(if value == "0" {
                    0
                } else {
                    parse_id(&value, "group_id")?
                });
            }
            "limit" if !limit_seen => {
                let limit = parse_id(&value, "limit")?;
                if limit > contract().max_list_limit as u64 {
                    return Err(ApiError::bad_request("limit 参数错误"));
                }
                query.limit = limit as usize;
                limit_seen = true;
            }
            "before_id" | "group_id" | "limit" => {
                return Err(ApiError::bad_request(format!("{key} 参数错误")))
            }
            _ => {}
        }
    }
    Ok(query)
}

pub(super) fn parse_id(raw: &str, key: &str) -> Result<u64, ApiError> {
    crate::group_content::parse_content_id(raw, key)
}

pub(super) fn parse_schedule(raw: &[u8]) -> Result<String, ApiError> {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Schedule {
        scheduled_at: String,
    }

    let invalid = || ApiError::bad_request("scheduled_at 参数错误");
    let schedule: Schedule = serde_json::from_slice(raw).map_err(|_| invalid())?;
    polls::utc_milliseconds(&schedule.scheduled_at).ok_or_else(invalid)
}
