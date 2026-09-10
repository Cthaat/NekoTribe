pub const RATE_LIMIT_PREFIX: &str = "rate_limit";
pub const API_CACHE_SCHEMA_VERSION: &str = "1";
pub const API_CACHE_PREFIX: &str = "nt:api-cache";
pub const API_CACHE_HIT_PREFIX: &str = "nt:api-cache-hits";
pub const API_CACHE_TAG_PREFIX: &str = "nt:api-cache-tag";
pub const API_CACHE_TAG_TTL_SECONDS: usize = 7 * 24 * 60 * 60;
pub const ORACLE_QUERY_CACHE_SCHEMA_VERSION: &str = "2";
pub const ORACLE_QUERY_CACHE_PREFIX: &str = "nt:oracle-query-cache";
pub const ORACLE_QUERY_CACHE_HIT_PREFIX: &str = "nt:oracle-query-cache-hits";
pub const ORACLE_QUERY_CACHE_TAG_PREFIX: &str = "nt:oracle-query-cache-tag";
pub const ORACLE_QUERY_CACHE_TAG_TTL_SECONDS: usize = 7 * 24 * 60 * 60;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RedisChannels {
    pub broadcast: &'static str,
    pub user_prefix: &'static str,
    pub room_prefix: &'static str,
    pub chat_channel_prefix: &'static str,
    pub presence: &'static str,
    pub system: &'static str,
}

pub const REDIS_CHANNELS: RedisChannels = RedisChannels {
    broadcast: "ws:broadcast",
    user_prefix: "ws:user:",
    room_prefix: "ws:room:",
    chat_channel_prefix: "ws:chat:channel:",
    presence: "ws:presence",
    system: "ws:system",
};

pub fn normalize_key_part(input: &str) -> String {
    let mut normalized = String::with_capacity(input.len());
    let mut previous_colon = false;

    for ch in input.to_ascii_lowercase().chars() {
        if ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-') {
            normalized.push(ch);
            previous_colon = false;
        } else if ch == ':' {
            if !previous_colon {
                normalized.push(':');
            }
            previous_colon = true;
        } else if !previous_colon {
            normalized.push(':');
            previous_colon = true;
        }
    }

    let trimmed = normalized.trim_matches(':').to_string();
    if trimmed.is_empty() {
        "generic".to_string()
    } else {
        trimmed
    }
}

pub fn sha256_hex(input: &str) -> String {
    use sha2::{Digest, Sha256};

    hex::encode(Sha256::digest(input.as_bytes()))
}
