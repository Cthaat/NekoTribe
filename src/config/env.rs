use std::{env, error::Error, fmt};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AppConfig {
    pub server: ServerConfig,
    pub auth: AuthConfig,
    pub oracle: OracleConfig,
    pub redis: RedisConfig,
    pub legacy_backend: LegacyBackendConfig,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ServerConfig {
    pub host: String,
    pub port: u16,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AuthConfig {
    pub cookie_secure: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OracleConfig {
    pub host: String,
    pub port: u16,
    pub service_name: String,
    pub user: String,
    pub password: String,
    pub pool_min: usize,
    pub pool_max: usize,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RedisConfig {
    pub url: Option<String>,
    pub host: String,
    pub port: u16,
    pub db: u8,
    pub password: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LegacyBackendConfig {
    pub base_url: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigError {
    message: String,
}

impl ConfigError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl fmt::Display for ConfigError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for ConfigError {}

impl AppConfig {
    pub fn from_env() -> Result<Self, ConfigError> {
        let host = env::var("HOST").unwrap_or_else(|_| "0.0.0.0".to_string());
        let port = env_var("RUST_BACKEND_PORT")
            .or_else(|| env_var("PORT"))
            .map(|raw| parse_port(&raw))
            .transpose()?
            .unwrap_or(8080);

        let docker_mode = docker_mode_enabled();
        let oracle_host = pick_env_value(
            docker_mode,
            env_var("DOCKER_ORACLE_HOST").as_deref(),
            env_var("ORACLE_HOST").as_deref(),
            "localhost",
        );
        let oracle_port = parse_port(&pick_env_value(
            docker_mode,
            env_var("DOCKER_ORACLE_PORT").as_deref(),
            env_var("ORACLE_PORT").as_deref(),
            "1521",
        ))?;
        let oracle_pool_min = env_var("ORACLE_POOL_MIN")
            .and_then(|raw| raw.parse::<usize>().ok())
            .unwrap_or(2);
        let oracle_pool_max = env_var("ORACLE_POOL_MAX")
            .and_then(|raw| raw.parse::<usize>().ok())
            .unwrap_or(10)
            .max(oracle_pool_min);

        let redis_url = pick_env_value_optional(
            docker_mode,
            env_var("DOCKER_REDIS_URL").as_deref(),
            env_var("REDIS_URL").as_deref(),
        );
        let redis_host = pick_env_value(
            docker_mode,
            env_var("DOCKER_REDIS_HOST").as_deref(),
            env_var("REDIS_HOST").as_deref(),
            "127.0.0.1",
        );
        let redis_port = parse_port(&pick_env_value(
            docker_mode,
            env_var("DOCKER_REDIS_PORT").as_deref(),
            env_var("REDIS_PORT").as_deref(),
            "6379",
        ))?;
        let redis_db = env_var("REDIS_DB")
            .and_then(|raw| raw.parse::<u8>().ok())
            .unwrap_or(0);

        Ok(Self {
            server: ServerConfig { host, port },
            auth: AuthConfig {
                cookie_secure: parse_bool(env_var("COOKIE_SECURE").as_deref()),
            },
            oracle: OracleConfig {
                host: oracle_host,
                port: oracle_port,
                service_name: env_var("ORACLE_SERVICE_NAME")
                    .unwrap_or_else(|| "ORCLPDB1".to_string()),
                user: env_var("ORACLE_USER").unwrap_or_else(|| "neko_app".to_string()),
                password: env_var("ORACLE_PASSWORD").unwrap_or_default(),
                pool_min: oracle_pool_min,
                pool_max: oracle_pool_max,
            },
            redis: RedisConfig {
                url: redis_url,
                host: redis_host,
                port: redis_port,
                db: redis_db,
                password: env_var("REDIS_PASSWORD"),
            },
            legacy_backend: LegacyBackendConfig {
                base_url: pick_env_value(
                    docker_mode,
                    env_var("DOCKER_LEGACY_BACKEND_BASE_URL").as_deref(),
                    env_var("LEGACY_BACKEND_BASE_URL").as_deref(),
                    if docker_mode {
                        "http://app:3000"
                    } else {
                        "http://127.0.0.1:30001"
                    },
                ),
            },
        })
    }

    pub fn for_test() -> Self {
        Self {
            server: ServerConfig {
                host: "127.0.0.1".to_string(),
                port: 8080,
            },
            auth: AuthConfig {
                cookie_secure: false,
            },
            oracle: OracleConfig {
                host: "localhost".to_string(),
                port: 5501,
                service_name: "ORCLPDB1".to_string(),
                user: "neko_app".to_string(),
                password: "NekoApp2026#".to_string(),
                pool_min: 2,
                pool_max: 10,
            },
            redis: RedisConfig {
                url: None,
                host: "127.0.0.1".to_string(),
                port: 6379,
                db: 0,
                password: None,
            },
            legacy_backend: LegacyBackendConfig {
                base_url: "http://127.0.0.1:30001".to_string(),
            },
        }
    }
}

impl ServerConfig {
    pub fn bind_addr(&self) -> String {
        format!("{}:{}", self.host, self.port)
    }
}

impl OracleConfig {
    pub fn connect_string(&self) -> String {
        format!("{}:{}/{}", self.host, self.port, self.service_name)
    }
}

impl RedisConfig {
    pub fn connection_url(&self) -> String {
        if let Some(url) = &self.url {
            return normalize_redis_url(url, self.password.as_deref(), self.db);
        }

        match &self.password {
            Some(password) if !password.is_empty() => {
                format!(
                    "redis://:{password}@{}:{}/{}",
                    self.host, self.port, self.db
                )
            }
            _ => format!("redis://{}:{}/{}", self.host, self.port, self.db),
        }
    }
}

fn normalize_redis_url(input: &str, password: Option<&str>, db: u8) -> String {
    let mut url = if input.contains("://") {
        input.to_string()
    } else {
        format!("redis://{input}")
    };

    if let Some(password) = password.filter(|value| !value.is_empty()) {
        let scheme = "redis://";
        if let Some(rest) = url.strip_prefix(scheme) {
            let authority = rest.split('/').next().unwrap_or_default();
            if !authority.contains('@') {
                url = format!("{scheme}:{password}@{rest}");
            }
        }
    }

    if let Some(rest) = url.strip_prefix("redis://") {
        if !rest.contains('/') {
            url.push('/');
            url.push_str(&db.to_string());
        }
    }

    url
}

fn env_var(key: &str) -> Option<String> {
    env::var(key).ok().filter(|value| !value.trim().is_empty())
}

fn docker_mode_enabled() -> bool {
    parse_bool(env_var("RUST_BACKEND_DOCKER").as_deref())
        || parse_bool(env_var("NEKOTRIBE_DOCKER").as_deref())
        || parse_bool(env_var("RUNNING_IN_DOCKER").as_deref())
        || std::path::Path::new("/.dockerenv").exists()
}

fn pick_env_value(
    docker_mode: bool,
    docker_value: Option<&str>,
    local_value: Option<&str>,
    fallback: &str,
) -> String {
    pick_env_value_optional(docker_mode, docker_value, local_value)
        .unwrap_or_else(|| fallback.to_string())
}

fn pick_env_value_optional(
    docker_mode: bool,
    docker_value: Option<&str>,
    local_value: Option<&str>,
) -> Option<String> {
    let first = if docker_mode {
        docker_value
    } else {
        local_value
    };
    let second = if docker_mode {
        local_value
    } else {
        docker_value
    };

    first
        .filter(|value| !value.trim().is_empty())
        .or_else(|| second.filter(|value| !value.trim().is_empty()))
        .map(ToString::to_string)
}

fn parse_port(raw: &str) -> Result<u16, ConfigError> {
    raw.parse::<u16>()
        .map_err(|_| ConfigError::new(format!("invalid port value: {raw}")))
}

fn parse_bool(raw: Option<&str>) -> bool {
    matches!(
        raw.map(str::trim).map(str::to_ascii_lowercase).as_deref(),
        Some("true" | "1" | "yes" | "on")
    )
}

#[cfg(test)]
mod tests {
    use super::{pick_env_value, ServerConfig};

    #[test]
    fn server_config_formats_bind_address() {
        let config = ServerConfig {
            host: "127.0.0.1".to_string(),
            port: 8080,
        };

        assert_eq!(config.bind_addr(), "127.0.0.1:8080");
    }

    #[test]
    fn host_mode_prefers_local_values_even_when_docker_values_are_loaded_from_env_file() {
        assert_eq!(
            pick_env_value(false, Some("oracle19c"), Some("localhost"), "fallback"),
            "localhost"
        );
        assert_eq!(
            pick_env_value(
                false,
                Some("redis://redis:6379"),
                Some("redis://localhost:6379"),
                ""
            ),
            "redis://localhost:6379"
        );
    }

    #[test]
    fn docker_mode_prefers_docker_values() {
        assert_eq!(
            pick_env_value(true, Some("oracle19c"), Some("localhost"), "fallback"),
            "oracle19c"
        );
    }
}
