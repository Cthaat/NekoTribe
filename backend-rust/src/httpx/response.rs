use serde::Serialize;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct V2Response<T>
where
    T: Serialize,
{
    pub code: i32,
    pub message: String,
    pub data: T,
    pub meta: Option<V2Meta>,
}

pub type V2NullResponse = V2Response<Option<()>>;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct V2Meta {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub page: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub page_size: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub total: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub has_next: Option<bool>,
}

impl<T> V2Response<T>
where
    T: Serialize,
{
    pub fn ok(data: T) -> Self {
        Self::ok_with_message(data, "success")
    }

    pub fn ok_with_message(data: T, message: impl Into<String>) -> Self {
        Self {
            code: 200,
            message: message.into(),
            data,
            meta: None,
        }
    }

    pub fn with_meta(mut self, meta: V2Meta) -> Self {
        self.meta = Some(meta);
        self
    }
}

impl V2Response<Option<()>> {
    pub fn null(message: impl Into<String>) -> Self {
        Self {
            code: 200,
            message: message.into(),
            data: None,
            meta: None,
        }
    }
}

impl V2Meta {
    pub fn page(page: u32, page_size: u32, total: u64) -> Self {
        Self {
            page: Some(page),
            page_size: Some(page_size),
            total: Some(total),
            has_next: Some(u64::from(page) * u64::from(page_size) < total),
        }
    }
}
