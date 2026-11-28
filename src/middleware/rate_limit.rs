use axum::{
    body::Body,
    extract::MatchedPath,
    http::{Method, Request, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
    Json,
};
use redis::aio::ConnectionManager;
use std::{sync::Arc, time::Duration};
use tokio::sync::OnceCell;

use crate::httpx::errors::ApiError;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Tier {
    Auth,
    Ai,
    Transfer,
    Write,
    Read,
}

impl Tier {
    fn defaults(self) -> (&'static str, u32, u32) {
        match self {
            Self::Auth => ("auth", 10, 60),
            Self::Ai => ("ai", 10, 60),
            Self::Transfer => ("transfer", 10, 60),
            Self::Write => ("write", 40, 10),
            Self::Read => ("read", 100, 10),
        }
    }

    fn classify(method: &Method, template: &str) -> Option<Self> {
        let path = template.strip_prefix("/api/v2/")?;
        if method == Method::OPTIONS
            || path == "integrations/sentiment-flow"
            || path.starts_with("integrations/sentiment-flow/")
        {
            return None;
        }
        let sessions = path == "auth/sessions" || path.starts_with("auth/sessions/");
        let auth_exception = (sessions && matches!(*method, Method::GET | Method::DELETE))
            || (path == "auth/tokens/current" && method == Method::DELETE);
        Some(match (method.as_str(), path) {
            (_, p) if p.starts_with("auth/") && !auth_exception => Self::Auth,
            ("PATCH", "users/me/email")
            | ("DELETE", "users/me/two-factor")
            | ("POST", "users/me/two-factor/setup" | "users/me/two-factor/confirm") => Self::Auth,
            (
                "POST",
                "ai/media/describe"
                | "users/me/ai-provider/test"
                | "ai/conversations/{id}/generate"
                | "ai/conversations/{id}/knowledge-generate"
                | "ai/conversations/{id}/group-generate"
                | "ai/conversations/{id}/moderation-generate",
            ) => Self::Ai,
            ("GET", "users/me/export")
            | ("POST", "media" | "media/private")
            | ("PUT", "users/me/avatar") => Self::Transfer,
            ("GET" | "HEAD", _) => Self::Read,
            _ => Self::Write,
        })
    }
}

#[cfg(test)]
#[path = "admission_tests.rs"]
mod tests;

const WINDOW: &str = r#"
local ttl = redis.call('PTTL', KEYS[1])
if ttl == -2 then
  redis.call('SET', KEYS[1], 1, 'PX', ARGV[2])
  return {1, tonumber(ARGV[1]) - 1, tonumber(ARGV[2])}
end
if ttl < 0 then return redis.error_reply('invalid window expiry') end
local used = tonumber(redis.call('GET', KEYS[1]))
local limit = tonumber(ARGV[1])
if used >= limit then return {0, 0, ttl} end
redis.call('INCR', KEYS[1])
return {1, limit - used - 1, ttl}
"#;

#[derive(Clone)]
pub(crate) struct Admission {
    client: redis::Client,
    manager: Arc<OnceCell<ConnectionManager>>,
    budgets: [(u32, u32); 5],
}

impl Admission {
    pub(crate) fn new(
        client: redis::Client,
    ) -> Result<Self, crate::auth::sessions::SessionStoreError> {
        let mut budgets = [(0, 0); 5];
        use Tier::{Ai, Auth, Read, Transfer, Write};
        for tier in [Auth, Ai, Transfer, Write, Read] {
            let (name, limit, seconds) = tier.defaults();
            let setting = |suffix, default| {
                let key = format!("V2_RATE_LIMIT_{}_{suffix}", name.to_ascii_uppercase());
                match std::env::var(key) {
                    Ok(s) => s
                        .parse::<u32>()
                        .ok()
                        .filter(|n| *n > 0)
                        .ok_or(crate::auth::sessions::SessionStoreError),
                    Err(std::env::VarError::NotPresent) => Ok(default),
                    Err(_) => Err(crate::auth::sessions::SessionStoreError),
                }
            };
            budgets[tier as usize] = (
                setting("LIMIT", limit)?,
                setting("WINDOW_SECONDS", seconds)?,
            );
        }
        Ok(Self {
            client,
            manager: Arc::default(),
            budgets,
        })
    }
    async fn reserve(&self, tier: Tier, ip: &str) -> Option<(bool, u32, u64)> {
        let (limit, seconds) = self.budgets[tier as usize];
        let key = format!("neko:v2:admission:1:{}:{ip}", tier.defaults().0);
        tokio::time::timeout(Duration::from_secs(2), async {
            let mut manager = self
                .manager
                .get_or_try_init(|| self.client.get_connection_manager())
                .await?
                .clone();
            redis::cmd("EVAL")
                .arg(WINDOW)
                .arg(1)
                .arg(key)
                .arg(limit)
                .arg(u64::from(seconds) * 1000)
                .query_async::<(bool, u32, u64)>(&mut manager)
                .await
        })
        .await
        .ok()?
        .ok()
    }
}

pub(crate) async fn admit(request: Request<Body>, next: Next) -> Response {
    let tier = request
        .extensions()
        .get::<MatchedPath>()
        .and_then(|p| Tier::classify(request.method(), p.as_str()));
    let Some((tier, store)) = tier.zip(request.extensions().get::<Admission>()) else {
        return next.run(request).await;
    };
    let limit = store.budgets[tier as usize].0;
    let ip = crate::auth::login::client_ip(request.headers(), request.extensions());
    let Some((admitted, remaining, ttl)) = store.reserve(tier, &ip).await else {
        return next.run(request).await;
    };
    let mut response = if admitted {
        next.run(request).await
    } else {
        rejection(request.method(), request.uri().path())
    };
    budget_headers(&mut response, admitted, limit, remaining, ttl);
    response
}

fn budget_headers(response: &mut Response, admitted: bool, limit: u32, remaining: u32, ttl: u64) {
    let delay = ttl.div_ceil(1000).max(1);
    let headers = response.headers_mut();
    headers.insert("ratelimit-limit", limit.into());
    headers.insert("ratelimit-remaining", remaining.into());
    headers.insert("ratelimit-reset", delay.into());
    if !admitted {
        headers.insert("retry-after", delay.into());
    }
}

fn rejection(method: &Method, path: &str) -> Response {
    let status = StatusCode::TOO_MANY_REQUESTS;
    let message = "请求过于频繁，请稍后再试";
    if method == Method::HEAD {
        return status.into_response();
    }
    let body = serde_json::json!({
        "error": true,
        "url": path,
        "statusCode": status.as_u16(),
        "statusMessage": "Too Many Requests",
        "message": message,
        "data": ApiError::new(status, 42901, message).body()
    });
    (status, Json(body)).into_response()
}
