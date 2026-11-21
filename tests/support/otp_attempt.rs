use nekotribe_backend::auth::{
    otp_attempt_limit::{AttemptFuture, OtpAttemptLimit, OtpAttemptLimiter},
    otp_send_limit::LimitUnavailable,
};
use std::sync::Arc;

struct Limiter(u16);

impl OtpAttemptLimiter for Limiter {
    fn reserve_attempt<'a>(&'a self, _: &'a str) -> AttemptFuture<'a> {
        Box::pin(async move {
            match self.0 {
                429 => Ok(false),
                503 => Err(LimitUnavailable),
                _ => Ok(true),
            }
        })
    }
}

pub fn fixture(status: u16) -> axum::Extension<OtpAttemptLimit> {
    axum::Extension(OtpAttemptLimit(Arc::new(Limiter(status))))
}
