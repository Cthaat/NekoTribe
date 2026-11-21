use crate::config::env::RedisConfig;
use sha2::{Digest, Sha256};
use std::{future::Future, pin::Pin, sync::Arc, time::Duration};

#[derive(Debug, Clone, Copy)]
pub struct LimitUnavailable;

pub type ReserveFuture<'a> =
    Pin<Box<dyn Future<Output = Result<u64, LimitUnavailable>> + Send + 'a>>;

pub trait OtpSendLimiter: Send + Sync {
    fn reserve<'a>(&'a self, account: &'a str) -> ReserveFuture<'a>;
}

#[derive(Clone)]
pub struct OtpSendLimit(pub Arc<dyn OtpSendLimiter>);

pub struct RedisOtpSendLimiter(pub(super) redis::Client);

impl RedisOtpSendLimiter {
    pub fn new(config: &RedisConfig) -> Result<Self, LimitUnavailable> {
        redis::Client::open(config.connection_url())
            .map(Self)
            .map_err(|_| LimitUnavailable)
    }
}

const OTP_SEND_LIMIT_LUA: &str = "local cooldown = redis.call('PTTL', KEYS[1])
local window = redis.call('PTTL', KEYS[2])
local count = tonumber(redis.call('GET', KEYS[2]) or '0')
if cooldown == -1 or window == -1 or not count or count < 0 or count > 5 or count ~= math.floor(count) then
  return redis.error_reply('invalid OTP rate limit state')
end
local retry = cooldown
if count >= 5 then
  retry = math.max(retry, window)
end
if retry >= 0 then
  return math.max(1, math.ceil(retry / 1000))
end
if window == -2 then
  redis.call('SET', KEYS[2], '1', 'EX', 3600)
else
  redis.call('INCR', KEYS[2])
end
redis.call('SET', KEYS[1], '1', 'EX', 60)
return 0";

pub fn otp_send_keys(account: &str) -> [String; 2] {
    let hashed = Sha256::digest(account.to_ascii_lowercase().as_bytes());
    let prefix = format!("neko:auth:otp-send:v1:{{{}}}", hex::encode(hashed));
    [format!("{prefix}:cooldown"), format!("{prefix}:window")]
}

impl OtpSendLimiter for RedisOtpSendLimiter {
    fn reserve<'a>(&'a self, account: &'a str) -> ReserveFuture<'a> {
        Box::pin(async move {
            let [cooldown, window] = otp_send_keys(account);
            let retry = tokio::time::timeout(Duration::from_secs(2), async {
                let mut connection = self.0.get_multiplexed_async_connection().await?;
                redis::cmd("EVAL")
                    .arg(OTP_SEND_LIMIT_LUA)
                    .arg(2)
                    .arg(cooldown)
                    .arg(window)
                    .query_async::<i64>(&mut connection)
                    .await
            })
            .await
            .map_err(|_| LimitUnavailable)?
            .map_err(|_| LimitUnavailable)?;
            if !(0..=3600).contains(&retry) {
                return Err(LimitUnavailable);
            }
            Ok(retry as u64)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::otp_send_keys;

    #[test]
    fn otp_send_quota_key_matches_other_backends() {
        let prefix = "neko:auth:otp-send:v1:{2ecd29ed8b5e3975d29c00aa4d3a2553bfc46f2391fc39355c23719f8c5314a9}";
        assert_eq!(
            otp_send_keys("Example@Example.Test"),
            [format!("{prefix}:cooldown"), format!("{prefix}:window")]
        );
    }
}
