use crate::{
    auth::otp_send_limit::{LimitUnavailable, RedisOtpSendLimiter},
    httpx::errors::ApiError,
};
use axum::{extract::Extension, http::StatusCode};
use sha2::{Digest, Sha256};
use std::{future::Future, pin::Pin, sync::Arc, time::Duration};

pub type AttemptFuture<'a> =
    Pin<Box<dyn Future<Output = Result<bool, LimitUnavailable>> + Send + 'a>>;

pub trait OtpAttemptLimiter: Send + Sync {
    fn reserve_attempt<'a>(&'a self, verification_id: &'a str) -> AttemptFuture<'a>;
}

#[derive(Clone)]
pub struct OtpAttemptLimit(pub Arc<dyn OtpAttemptLimiter>);

const OTP_ATTEMPT_LIMIT_LUA: &str = "local ttl = redis.call('PTTL', KEYS[1])
if ttl == -2 then
  redis.call('SET', KEYS[1], '1', 'EX', 3600)
  return 1
end
local count = tonumber(redis.call('GET', KEYS[1]))
if ttl < 0 or not count or count < 1 or count > 5 or count ~= math.floor(count) then
  return redis.error_reply('invalid OTP attempt limit state')
end
if count == 5 then return 0 end
redis.call('INCR', KEYS[1])
return 1";

fn otp_attempt_key(verification_id: &str) -> String {
    let digest = Sha256::digest(verification_id.as_bytes());
    format!("neko:auth:otp-attempt:v1:{}", hex::encode(digest))
}

impl OtpAttemptLimiter for RedisOtpSendLimiter {
    fn reserve_attempt<'a>(&'a self, verification_id: &'a str) -> AttemptFuture<'a> {
        Box::pin(async move {
            let reserved = tokio::time::timeout(Duration::from_secs(2), async {
                let mut connection = self.0.get_multiplexed_async_connection().await?;
                redis::cmd("EVAL")
                    .arg(OTP_ATTEMPT_LIMIT_LUA)
                    .arg(1)
                    .arg(otp_attempt_key(verification_id))
                    .query_async::<i64>(&mut connection)
                    .await
            })
            .await
            .map_err(|_| LimitUnavailable)?
            .map_err(|_| LimitUnavailable)?;
            match reserved {
                0 => Ok(false),
                1 => Ok(true),
                _ => Err(LimitUnavailable),
            }
        })
    }
}

pub(crate) async fn require_otp_attempt(
    limiter: Option<Extension<OtpAttemptLimit>>,
    verification_id: &str,
) -> Result<(), ApiError> {
    let unavailable = || {
        ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            50301,
            "服务暂不可用，请稍后重试。",
        )
    };
    let Extension(limiter) = limiter.ok_or_else(unavailable)?;
    if !limiter
        .0
        .reserve_attempt(verification_id)
        .await
        .map_err(|_| unavailable())?
    {
        return Err(ApiError::new(
            StatusCode::TOO_MANY_REQUESTS,
            42901,
            "验证码尝试次数已用完，请重新获取验证码",
        ));
    }
    Ok(())
}
