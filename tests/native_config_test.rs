use nekotribe_backend::config::env::{AppConfig, BackendMode};
use std::collections::BTreeMap;
fn env() -> BTreeMap<String, String> {
    [
        ("ACCESS_SECRET", "access-private"),
        ("REFRESH_SECRET", "refresh-private"),
        ("ORACLE_HOST", "db.example"),
        ("ORACLE_PORT", "1521"),
        ("ORACLE_SERVICE_NAME", "APP"),
        ("ORACLE_USER", "private-user"),
        ("ORACLE_PASSWORD", "private-password"),
        ("ORACLE_POOL_MIN", "2"),
        ("ORACLE_POOL_MAX", "10"),
    ]
    .into_iter()
    .map(|(k, v)| (k.into(), v.into()))
    .collect()
}
#[test]
fn native_config_validates_and_redacts() {
    let e = env();
    let c = AppConfig::native_from_lookup(|k| e.get(k).cloned()).unwrap();
    assert_eq!(c.backend_mode, BackendMode::Native);
    assert_eq!(c.server.host, "127.0.0.1");
    assert_eq!(c.server.port, 30003);
    assert!(c.native.as_ref().unwrap().keys.codec().is_ok());
    let debug = format!("{c:?}");
    for secret in [
        "access-private",
        "refresh-private",
        "private-user",
        "private-password",
        "db.example",
    ] {
        assert!(!debug.contains(secret), "debug leaked {secret}")
    }
}

#[test]
fn native_config_accepts_shared_nuxt_variables() {
    let mut e: BTreeMap<String, String> = env()
        .into_iter()
        .map(|(key, value)| (format!("NUXT_{key}"), value))
        .collect();
    e.insert("ORACLE_HOST".into(), "different.example".into());
    e.insert("ORACLE_PASSWORD".into(), "legacy-password".into());
    e.insert("NUXT_ORACLE_PORT".into(), "1522".into());
    e.insert("NUXT_COOKIE_SECURE".into(), "true".into());
    let config = AppConfig::native_from_lookup(|key| e.get(key).cloned()).unwrap();
    assert_eq!(config.oracle.host, "db.example");
    assert_eq!(config.oracle.port, 1522);
    assert!(config.native.unwrap().refresh_policy.cookie_secure);
    e.insert("NUXT_ORACLE_PASSWORD".into(), String::new());
    assert!(AppConfig::native_from_lookup(|key| e.get(key).cloned()).is_err());
}

#[test]
fn native_redis_uses_shared_configuration_and_redacts_credentials() {
    let mut e = env();
    e.insert(
        "REDIS_URL".into(),
        "redis://:old-secret@redis.example:6380/3".into(),
    );
    e.insert("REDIS_HOST".into(), "redis.internal".into());
    e.insert("REDIS_PORT".into(), "6381".into());
    e.insert("REDIS_DB".into(), "4".into());
    e.insert("REDIS_PASSWORD".into(), "new@secret:%2F/%25".into());
    let config = AppConfig::native_from_lookup(|k| e.get(k).cloned()).unwrap();
    let url = reqwest::Url::parse(&config.redis.connection_url()).unwrap();
    assert_eq!(url.host_str(), Some("redis.internal"));
    assert_eq!(url.port(), Some(6381));
    assert_eq!(url.path(), "/4");
    assert!(!format!("{config:?}").contains("secret"));
    assert!(url.password().is_some());
    let client = redis::Client::open(config.redis.connection_url()).unwrap();
    assert_eq!(
        client.get_connection_info().redis_settings().password(),
        Some("new@secret:%2F/%25")
    );
    e.insert("REDIS_URL".into(), "rediss://redis.example:6380/3".into());
    let tls = AppConfig::native_from_lookup(|k| e.get(k).cloned()).unwrap();
    assert!(tls.redis.connection_url().starts_with("rediss://"));
    assert!(redis::Client::open(tls.redis.connection_url()).is_ok());
    e.insert("NUXT_REDIS_PORT".into(), String::new());
    e.insert("NUXT_REDIS_DB".into(), String::new());
    let shared = AppConfig::native_from_lookup(|k| e.get(k).cloned()).unwrap();
    assert_eq!(shared.redis.port, 6380);
    assert_eq!(shared.redis.db, 3);
    e.remove("NUXT_REDIS_PORT");
    e.insert("REDIS_PORT".into(), "bad-secret".into());
    let error = AppConfig::native_from_lookup(|k| e.get(k).cloned()).unwrap_err();
    assert!(!error.to_string().contains("secret"));
}

#[test]
fn native_redis_uses_docker_overrides_only_when_enabled() {
    let mut e = env();
    e.insert("REDIS_HOST".into(), "local.example".into());
    e.insert("DOCKER_REDIS_HOST".into(), "container.example".into());
    let local = AppConfig::native_from_lookup(|k| e.get(k).cloned()).unwrap();
    assert_eq!(local.redis.host, "local.example");
    e.insert("NEKOTRIBE_DOCKER".into(), "true".into());
    let container = AppConfig::native_from_lookup(|k| e.get(k).cloned()).unwrap();
    assert_eq!(container.redis.host, "container.example");
}

#[test]
fn smtp_prefers_nuxt_variables_and_redacts_credentials() {
    use nekotribe_backend::auth::otp::SmtpConfig;
    let both = BTreeMap::from([
        ("SMTP_HOST", "ignored.test"),
        ("NUXT_SMTP_HOST", "selected.test"),
        ("SMTP_PASS", "synthetic-mail-password"),
    ]);
    let expected = BTreeMap::from([
        ("SMTP_HOST", "selected.test"),
        ("SMTP_PASS", "synthetic-mail-password"),
    ]);
    let actual = SmtpConfig::from_lookup(&|key| both.get(key).map(|v| v.to_string()));
    assert_eq!(
        actual,
        SmtpConfig::from_lookup(&|key| expected.get(key).map(|v| v.to_string()))
    );
    assert!(!format!("{actual:?}").contains("synthetic-mail-password"));
}

#[test]
fn native_config_loads_storage_url_settings_without_logging_credentials() {
    let mut e = env();
    e.insert("STORAGE_PUBLIC_BASE".into(), "/media".into());
    e.insert(
        "STORAGE_CDN_BASE_URL".into(),
        "https://user:private-url-secret@cdn.example".into(),
    );
    let config = AppConfig::native_from_lookup(|key| e.get(key).cloned()).unwrap();
    assert!(!format!("{config:?}").contains("private-url-secret"));
    assert!(config
        .native
        .unwrap()
        .storage_urls
        .normalize_avatar("/uploads/a.png")
        .is_err());
}
#[test]
fn native_config_rejects_missing_or_invalid_values() {
    for (key, value) in [
        ("ACCESS_SECRET", ""),
        ("REFRESH_SECRET", ""),
        ("RUST_BACKEND_PORT", "0"),
        ("PORT", "65536"),
        ("ORACLE_PORT", "0"),
        ("ORACLE_HOST", ""),
        ("ORACLE_SERVICE_NAME", ""),
        ("ORACLE_USER", ""),
        ("ORACLE_PASSWORD", ""),
        ("ORACLE_POOL_MIN", "invalid"),
        ("ORACLE_POOL_MIN", "11"),
        ("ORACLE_POOL_MAX", "0"),
    ] {
        let mut e = env();
        e.insert(key.into(), value.into());
        assert!(
            AppConfig::native_from_lookup(|k| e.get(k).cloned()).is_err(),
            "accepted {key}={value}"
        )
    }
    assert_eq!(BackendMode::parse(None).unwrap(), BackendMode::Native);
    assert_eq!(
        BackendMode::parse(Some("compat")).unwrap(),
        BackendMode::Compat
    );
    assert_eq!(
        BackendMode::parse(Some("native")).unwrap(),
        BackendMode::Native
    );
    assert!(BackendMode::parse(Some("typo")).is_err())
}
#[test]
fn cors_config_preserves_explicit_empty_and_serialized_origin_rules() {
    use nekotribe_backend::auth::sessions::CorsPolicy;
    let mut e = env();
    e.insert("NUXT_CORS_ALLOW_LOCALHOST_ORIGINS".into(), String::new());
    e.insert("CORS_ALLOW_LOCALHOST_ORIGINS".into(), "true".into());
    e.insert("NODE_ENV".into(), "development".into());
    e.insert(
        "CORS_ALLOWED_ORIGINS".into(),
        "https://app.example?,http://localhost:,https://app.example,https://app.example".into(),
    );
    let p = CorsPolicy::from_lookup(|k| e.get(k).cloned());
    assert!(!p.localhost);
    assert_eq!(p.origins, vec!["https://app.example"])
}

#[test]
fn native_refresh_lifetimes_and_cookie_secure_are_validated() {
    let mut e = env();
    let defaults = AppConfig::native_from_lookup(|k| e.get(k).cloned()).unwrap();
    let policy = defaults.native.unwrap().refresh_policy;
    assert_eq!(
        (
            policy.access_seconds,
            policy.refresh_seconds,
            policy.cookie_secure
        ),
        (900, 2_592_000, false)
    );
    e.insert("ACCESS_EXPIRES_IN".into(), " +0100 ".into());
    e.insert("REFRESH_EXPIRES_IN".into(), "200".into());
    e.insert("COOKIE_SECURE".into(), "true".into());
    let policy = AppConfig::native_from_lookup(|k| e.get(k).cloned())
        .unwrap()
        .native
        .unwrap()
        .refresh_policy;
    assert_eq!(
        (
            policy.access_seconds,
            policy.refresh_seconds,
            policy.cookie_secure
        ),
        (100, 200, true)
    );
    e.insert("COOKIE_SECURE".into(), "TRUE".into());
    assert!(
        !AppConfig::native_from_lookup(|k| e.get(k).cloned())
            .unwrap()
            .native
            .unwrap()
            .refresh_policy
            .cookie_secure
    );
    e.insert("NUXT_ACCESS_EXPIRES_IN".into(), "".into());
    assert!(AppConfig::native_from_lookup(|k| e.get(k).cloned()).is_err());
    e.remove("NUXT_ACCESS_EXPIRES_IN");
    for value in [
        "",
        "1e3",
        "\u{00a0}200",
        "100",
        "99",
        "0",
        "-1",
        "2147483648",
        "1000000000000",
        "18446744073709551615",
    ] {
        e.insert("REFRESH_EXPIRES_IN".into(), value.into());
        assert!(
            AppConfig::native_from_lookup(|k| e.get(k).cloned()).is_err(),
            "accepted {value}"
        );
    }
}
