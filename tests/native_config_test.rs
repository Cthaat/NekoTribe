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
    assert_eq!(BackendMode::parse(None).unwrap(), BackendMode::Compat);
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
    e.insert("ACCESS_EXPIRES_IN".into(), "100".into());
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
    for value in [
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
