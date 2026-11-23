use super::contract;
use crate::{
    auth::sessions::NativeState,
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    Json,
    extract::State,
    http::{HeaderMap, HeaderValue, StatusCode, header::CACHE_CONTROL},
    response::{IntoResponse, Response},
};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use chrono::{DateTime, SecondsFormat};
use hmac::{Hmac, Mac};
use serde_json::{Value, json};
use sha1::Sha1;
use std::sync::OnceLock;

pub(super) struct Config {
    stun: Vec<String>,
    turn: Vec<String>,
    secret: Option<String>,
}

impl Config {
    pub(super) fn from_lookup(lookup: impl Fn(&str) -> Option<String>) -> Result<Self, ()> {
        let env = &contract().environment;
        let stun = parse_urls(lookup(&env.stun_urls), false)?;
        let turn = parse_urls(lookup(&env.turn_urls), true)?;
        let secret = if turn.is_empty() {
            None
        } else {
            Some(
                lookup(&env.turn_shared_secret)
                    .filter(|key| !key.trim().is_empty())
                    .ok_or(())?,
            )
        };
        Ok(Self { stun, turn, secret })
    }

    fn response(&self, user: u64, now: u64) -> Result<Value, ()> {
        let mut servers = Vec::new();
        if !self.stun.is_empty() {
            servers.push(json!({"urls":self.stun}));
        }
        let mut expires_at = None;
        if let Some(secret) = &self.secret {
            let expiration = now.checked_add(contract().turn_ttl_seconds).ok_or(())?;
            let timestamp =
                DateTime::from_timestamp(i64::try_from(expiration).map_err(|_| ())?, 0).ok_or(())?;
            let username = format!("{expiration}:{user}");
            let mut mac = Hmac::<Sha1>::new_from_slice(secret.as_bytes()).map_err(|_| ())?;
            mac.update(username.as_bytes());
            let credential = STANDARD.encode(mac.finalize().into_bytes());
            servers.push(json!({"urls":self.turn,"username":username,"credential":credential}));
            expires_at = Some(timestamp.to_rfc3339_opts(SecondsFormat::Secs, true));
        }
        Ok(json!({"ice_servers":servers,"expires_at":expires_at}))
    }
}

fn parse_urls(input: Option<String>, turn: bool) -> Result<Vec<String>, ()> {
    static HOSTNAME: OnceLock<regex::Regex> = OnceLock::new();
    let hostname = HOSTNAME.get_or_init(|| {
        regex::Regex::new(r"^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.?$")
            .expect("valid ASCII ICE hostname pattern")
    });
    let mut urls = Vec::new();
    for url in input
        .as_deref()
        .unwrap_or_default()
        .split(',')
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        let (scheme, rest) = url.split_once(':').ok_or(())?;
        if !(if turn {
            matches!(scheme, "turn" | "turns")
        } else {
            matches!(scheme, "stun" | "stuns")
        }) {
            return Err(());
        }
        let authority = if let Some((host, query)) = rest.split_once('?') {
            if !turn || !matches!(query, "transport=udp" | "transport=tcp") {
                return Err(());
            }
            host
        } else {
            rest
        };
        if authority.is_empty()
            || authority.ends_with(':')
            || authority.chars().any(|c| {
                c.is_whitespace()
                    || c.is_control()
                    || matches!(c, '/' | '\\' | '#' | '@' | '%' | '?')
            })
        {
            return Err(());
        }
        let parsed = reqwest::Url::parse(&format!("http://{authority}")).map_err(|_| ())?;
        let valid_host = if authority.starts_with('[') {
            parsed.host_str().is_some_and(|host| host.starts_with('['))
        } else {
            hostname.is_match(authority.split(':').next().unwrap_or_default())
        };
        if !valid_host || parsed.port() == Some(0) {
            return Err(());
        }
        if !urls.iter().any(|entry| entry == url) {
            urls.push(url.to_owned());
        }
        if urls.len() > 8 {
            return Err(());
        }
    }
    Ok(urls)
}

pub(crate) async fn get(State(state): State<NativeState>, headers: HeaderMap) -> Response {
    let result = async {
        let user = crate::posts::bookmark::interaction_actor(&state, &headers).await?;
        let unavailable =
            || ApiError::new(StatusCode::SERVICE_UNAVAILABLE, 50301, "通话配置暂不可用");
        let ice = state
            .calls
            .ice
            .as_ref()
            .as_ref()
            .map_err(|_| unavailable())?;
        let payload = ice
            .response(user, (state.clock)())
            .map_err(|_| unavailable())?;
        Ok::<_, ApiError>(Json(V2Response::ok(payload)))
    }
    .await;
    let mut response = result.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ice_configuration_checks_scheme_authority_and_transport() {
        assert_eq!(
            parse_urls(
                Some(" stun:a.example, stun:a.example , stuns:[2001:db8::1]:3478".into()),
                false
            )
            .unwrap(),
            ["stun:a.example", "stuns:[2001:db8::1]:3478"]
        );
        for url in [
            "turn:a.example",
            "stun:a.example/path",
            "stun:user@host",
            "stun:x#y",
            "stun:host:99999",
            "stun:host:",
            "stuns:[2001:db8::1]:",
            "stun:猫.example",
            "stun:ice_server.example",
            "stun:ice%2eexample",
            "stun:host?transport=tcp",
        ] {
            assert!(parse_urls(Some(url.into()), false).is_err());
        }
        assert!(parse_urls(Some("turns:relay.example:5349?transport=tcp".into()), true).is_ok());
        assert!(parse_urls(Some("turn:relay.example:?transport=udp".into()), true).is_err());
    }

    #[test]
    fn turn_credential_uses_coturn_vector_without_the_server_secret() {
        let config = Config::from_lookup(|key| match key {
            "WEBRTC_STUN_URLS" => Some("stun:stun.example".into()),
            "WEBRTC_TURN_URLS" => Some("turn:relay.example?transport=udp".into()),
            "WEBRTC_TURN_SHARED_SECRET" => Some("fixture".into()),
            _ => None,
        })
        .unwrap();
        let response = config.response(42, 50).unwrap();
        assert_eq!(response["expires_at"], "1970-01-01T04:05:50Z");
        assert_eq!(
            response["ice_servers"][1],
            json!({
                "urls":["turn:relay.example?transport=udp"],"username":"14750:42","credential":"h7TVctYJAAhNujIfA0lO6lj/jXE="
            })
        );
        assert!(!response.to_string().contains("fixture"));
        assert_eq!(
            Config::from_lookup(|_| None)
                .unwrap()
                .response(42, 50)
                .unwrap(),
            json!({"ice_servers":[],"expires_at":null})
        );
        assert!(
            Config::from_lookup(
                |key| (key == "WEBRTC_TURN_URLS").then(|| "turn:relay.example".into())
            )
            .is_err()
        );
    }
}
