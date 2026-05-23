use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum DbValue {
    Null,
    String(String),
    I64(i64),
    F64(f64),
    BoolNumber(bool),
    JsonString(String),
    TimestampString(String),
}

impl DbValue {
    pub fn from_option_string(value: Option<String>) -> Self {
        value.map(Self::String).unwrap_or(Self::Null)
    }

    pub fn as_i64(&self) -> Option<i64> {
        match self {
            Self::I64(value) => Some(*value),
            Self::F64(value) => Some(*value as i64),
            Self::BoolNumber(value) => Some(i64::from(*value)),
            Self::String(value) | Self::JsonString(value) | Self::TimestampString(value) => {
                value.parse::<i64>().ok()
            }
            Self::Null => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Self::String(value) | Self::JsonString(value) | Self::TimestampString(value) => {
                Some(value)
            }
            _ => None,
        }
    }
}
