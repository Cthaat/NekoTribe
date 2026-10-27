use std::{collections::HashSet, sync::RwLock};

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModelConfigError(pub &'static str);

impl ModelConfigError {
    pub fn code(&self) -> &'static str {
        self.0
    }
}

impl std::fmt::Display for ModelConfigError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}
impl std::error::Error for ModelConfigError {}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SelectionSnapshot {
    pub configuration_revision: u64,
    pub role: String,
    pub profile_id: String,
    pub provider_id: String,
    pub adapter: String,
    pub base_url: String,
    pub model: String,
    pub api_key_env: Option<String>,
    pub capabilities: Vec<String>,
    pub context_window_tokens: u32,
    pub max_output_tokens: u32,
}

const INVALID: ModelConfigError = ModelConfigError("INVALID_CONFIGURATION");
const CAPABILITIES: [&str; 3] = ["tools", "structured-output", "vision"];

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Configuration {
    #[serde(deserialize_with = "integer")]
    schema_version: u64,
    #[serde(deserialize_with = "integer")]
    revision: u64,
    providers: Vec<Provider>,
    models: Vec<Model>,
    bindings: Bindings,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Provider {
    id: String,
    adapter: String,
    base_url: String,
    api_key_env: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Model {
    id: String,
    provider_id: String,
    model: String,
    capabilities: Vec<String>,
    #[serde(deserialize_with = "integer")]
    context_window_tokens: u64,
    #[serde(deserialize_with = "integer")]
    max_output_tokens: u64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Bindings {
    knowledge: String,
    writing: String,
    agent: String,
    moderation: String,
}

impl Bindings {
    fn model_id(&self, role: &str) -> Option<&str> {
        match role {
            "knowledge" => Some(&self.knowledge),
            "writing" => Some(&self.writing),
            "agent" => Some(&self.agent),
            "moderation" => Some(&self.moderation),
            _ => None,
        }
    }
}

fn integer<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<u64, D::Error> {
    let value = Value::deserialize(deserializer)?;
    let number = value
        .as_f64()
        .ok_or_else(|| serde::de::Error::custom("integer required"))?;
    if number < 1.0 || number > 9_007_199_254_740_991.0 || number.fract() != 0.0 {
        return Err(serde::de::Error::custom("invalid integer"));
    }
    Ok(number as u64)
}

fn valid_id(value: &str) -> bool {
    let bytes = value.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 64
        && bytes[0].is_ascii_alphanumeric()
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(byte))
}

fn valid_capabilities(values: &[String]) -> bool {
    let mut seen = HashSet::new();
    values
        .iter()
        .all(|value| CAPABILITIES.contains(&value.as_str()) && seen.insert(value))
}

fn configuration_whitespace(character: char) -> bool {
    character.is_whitespace() || character == '\u{feff}'
}

fn valid_host(host: &str) -> bool {
    if host.starts_with('[') {
        return host
            .strip_prefix('[')
            .and_then(|value| value.strip_suffix(']'))
            .is_some_and(|value| value.parse::<std::net::Ipv6Addr>().is_ok());
    }
    if !host.is_ascii() {
        return false;
    }
    let dns = host.strip_suffix('.').unwrap_or(host);
    if dns.is_empty() || host.len() > 253 {
        return false;
    }
    let last = dns.rsplit('.').next().unwrap_or_default();
    let numeric = last.bytes().all(|byte| byte.is_ascii_digit());
    let hexadecimal = last
        .strip_prefix("0x")
        .or_else(|| last.strip_prefix("0X"))
        .is_some_and(|digits| {
            !digits.is_empty() && digits.bytes().all(|byte| byte.is_ascii_hexdigit())
        });
    if numeric || hexadecimal {
        return host
            .parse::<std::net::Ipv4Addr>()
            .is_ok_and(|address| address.to_string() == host);
    }
    dns.split('.').all(|label| {
        let bytes = label.as_bytes();
        let edge = |byte: u8| byte.is_ascii_alphanumeric() || byte == b'_';
        !bytes.is_empty()
            && bytes.len() <= 63
            && edge(bytes[0])
            && edge(bytes[bytes.len() - 1])
            && bytes.iter().all(|byte| edge(*byte) || *byte == b'-')
    })
}

fn valid_url(raw: &str) -> bool {
    let Some(remainder) = raw
        .strip_prefix("http://")
        .or_else(|| raw.strip_prefix("https://"))
    else {
        return false;
    };
    if raw
        .chars()
        .any(|character| configuration_whitespace(character) || character.is_ascii_control())
        || raw.contains(['?', '#', '\\'])
    {
        return false;
    }
    let authority = remainder.split('/').next().unwrap_or_default();
    if authority.is_empty() || authority.contains('@') {
        return false;
    }
    let (host, port) = if authority.starts_with('[') {
        let Some(end) = authority.find(']') else {
            return false;
        };
        let suffix = &authority[end + 1..];
        if suffix.is_empty() {
            (&authority[..=end], None)
        } else if let Some(port) = suffix.strip_prefix(':') {
            (&authority[..=end], Some(port))
        } else {
            return false;
        }
    } else {
        authority
            .split_once(':')
            .map_or((authority, None), |(host, port)| (host, Some(port)))
    };
    if !valid_host(host) {
        return false;
    }
    if let Some(port) = port {
        if port.is_empty()
            || !port.bytes().all(|byte| byte.is_ascii_digit())
            || port
                .parse::<u16>()
                .ok()
                .filter(|value| *value > 0)
                .is_none()
        {
            return false;
        }
    }
    reqwest::Url::parse(raw).ok().is_some_and(|url| {
        url.host_str().is_some() && url.username().is_empty() && url.password().is_none()
    })
}

impl Configuration {
    fn parse(input: &Value) -> Result<Self, ModelConfigError> {
        let mut config: Self = serde_json::from_value(input.clone()).map_err(|_| INVALID)?;
        if config.schema_version != 1 || config.providers.is_empty() || config.models.is_empty() {
            return Err(INVALID);
        }
        let mut provider_ids = HashSet::new();
        for provider in &mut config.providers {
            if !valid_id(&provider.id)
                || !provider_ids.insert(provider.id.clone())
                || !["ollama", "openai-compatible"].contains(&provider.adapter.as_str())
                || !valid_url(&provider.base_url)
            {
                return Err(INVALID);
            }
            if let Some(reference) = &provider.api_key_env {
                if !reference.is_empty() {
                    let bytes = reference.as_bytes();
                    if !(bytes[0].is_ascii_uppercase() || bytes[0] == b'_')
                        || !bytes.iter().all(|byte| {
                            byte.is_ascii_uppercase() || byte.is_ascii_digit() || *byte == b'_'
                        })
                    {
                        return Err(INVALID);
                    }
                }
            }
            provider.api_key_env = provider
                .api_key_env
                .take()
                .filter(|value| !value.is_empty());
            provider.base_url = provider.base_url.trim_end_matches('/').to_owned();
        }
        let mut model_ids = HashSet::new();
        for model in &mut config.models {
            if !valid_id(&model.id)
                || !model_ids.insert(model.id.clone())
                || !valid_id(&model.provider_id)
                || !provider_ids.contains(&model.provider_id)
                || model.model.is_empty()
                || model.model.trim_matches(configuration_whitespace) != model.model
                || model.model.chars().count() > 256
                || !valid_capabilities(&model.capabilities)
                || model.context_window_tokens > i32::MAX as u64
                || model.max_output_tokens > i32::MAX as u64
                || model.max_output_tokens >= model.context_window_tokens
            {
                return Err(INVALID);
            }
            model.capabilities.sort();
        }
        for role in ["knowledge", "writing", "agent", "moderation"] {
            let id = config.bindings.model_id(role).ok_or(INVALID)?;
            let model = config
                .models
                .iter()
                .find(|model| model.id == id)
                .ok_or(INVALID)?;
            let required = match role {
                "agent" => Some("tools"),
                "moderation" => Some("structured-output"),
                _ => None,
            };
            if required.is_some_and(|capability| {
                !model.capabilities.iter().any(|value| value == capability)
            }) {
                return Err(INVALID);
            }
        }
        Ok(config)
    }
}

/// Offline routing configuration. All selections own their data and survive replacement.
pub struct ModelRouter {
    configuration: RwLock<Configuration>,
}
impl ModelRouter {
    pub fn new(input: &Value) -> Result<Self, ModelConfigError> {
        Ok(Self {
            configuration: RwLock::new(Configuration::parse(input)?),
        })
    }

    pub fn select(
        &self,
        role: &str,
        required: &[&str],
    ) -> Result<SelectionSnapshot, ModelConfigError> {
        let config = self.configuration.read().map_err(|_| INVALID)?;
        let id = config
            .bindings
            .model_id(role)
            .ok_or(ModelConfigError("UNKNOWN_ROLE"))?;
        let mut seen = HashSet::new();
        if !required
            .iter()
            .all(|value| CAPABILITIES.contains(value) && seen.insert(*value))
        {
            return Err(ModelConfigError("UNSUPPORTED_CAPABILITY"));
        }
        let model = config
            .models
            .iter()
            .find(|model| model.id == id)
            .ok_or(INVALID)?;
        if !required.iter().all(|value| {
            model
                .capabilities
                .iter()
                .any(|capability| capability == value)
        }) {
            return Err(ModelConfigError("UNSUPPORTED_CAPABILITY"));
        }
        let provider = config
            .providers
            .iter()
            .find(|provider| provider.id == model.provider_id)
            .ok_or(INVALID)?;
        Ok(SelectionSnapshot {
            configuration_revision: config.revision,
            role: role.to_owned(),
            profile_id: model.id.clone(),
            provider_id: provider.id.clone(),
            adapter: provider.adapter.clone(),
            base_url: provider.base_url.clone(),
            model: model.model.clone(),
            api_key_env: provider.api_key_env.clone(),
            capabilities: model.capabilities.clone(),
            context_window_tokens: model.context_window_tokens as u32,
            max_output_tokens: model.max_output_tokens as u32,
        })
    }

    /// Compare and replace under one write lock; failed updates leave the old state intact.
    pub fn replace(&self, input: &Value, expected_revision: u64) -> Result<(), ModelConfigError> {
        let mut current = self.configuration.write().map_err(|_| INVALID)?;
        if current.revision != expected_revision {
            return Err(ModelConfigError("STALE_CONFIGURATION"));
        }
        let next = Configuration::parse(input)?;
        if next.revision <= current.revision {
            return Err(ModelConfigError("REVISION_REUSED"));
        }
        *current = next;
        Ok(())
    }
}
