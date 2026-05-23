use serde::{Deserialize, Serialize};

pub const RATE_LIMIT_WINDOW_MS: u64 = 10_000;
pub const RATE_LIMIT_MAX_REQUESTS: u32 = 100;
pub const RATE_LIMIT_TTL_SECONDS: u64 = 120;
pub const RATE_LIMIT_MESSAGE: &str = "请求过于频繁，请稍后再试";

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct RateLimitInfo {
    pub count: u32,
    pub last: u64,
}

impl RateLimitInfo {
    pub fn record(&mut self, now_ms: u64) -> bool {
        if now_ms.saturating_sub(self.last) > RATE_LIMIT_WINDOW_MS {
            self.count = 1;
            self.last = now_ms;
            return false;
        }

        self.count = self.count.saturating_add(1);
        self.count > RATE_LIMIT_MAX_REQUESTS
    }

    pub fn ttl_seconds() -> u64 {
        RATE_LIMIT_TTL_SECONDS
    }
}

pub fn parse_rate_limit_info(input: Option<&str>, now_ms: u64) -> RateLimitInfo {
    input
        .and_then(|value| serde_json::from_str::<RateLimitInfo>(value).ok())
        .unwrap_or(RateLimitInfo {
            count: 0,
            last: now_ms,
        })
}
