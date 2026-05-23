use nekotribe_backend::{
    cache::{
        api_cache::{
            build_api_cache_key, is_cacheable_request, should_invalidate_after_success,
            tags_for_path, ttl_policy_for_path, ApiCacheIdentity,
        },
        oracle_query_cache::{
            build_oracle_query_cache_key, is_cache_neutral_mutation_sql, is_cacheable_select_sql,
            is_mutating_sql, table_refs, tags_for_sql, OracleQueryCacheIdentity,
        },
        tags::{
            API_CACHE_HIT_PREFIX, API_CACHE_PREFIX, API_CACHE_SCHEMA_VERSION, API_CACHE_TAG_PREFIX,
            ORACLE_QUERY_CACHE_PREFIX, ORACLE_QUERY_CACHE_SCHEMA_VERSION, RATE_LIMIT_PREFIX,
            REDIS_CHANNELS,
        },
    },
    config::env::{AppConfig, OracleConfig, RedisConfig},
    db::{nullable::NullableExt, value::DbValue},
    middleware::rate_limit::RateLimitInfo,
};
use serde_json::json;
use std::collections::BTreeMap;

#[test]
fn app_config_maps_existing_oracle_and_redis_environment_names() {
    let oracle = OracleConfig {
        host: "localhost".to_string(),
        port: 5501,
        service_name: "ORCLPDB1".to_string(),
        user: "neko_app".to_string(),
        password: "NekoApp2026#".to_string(),
        pool_min: 2,
        pool_max: 10,
    };
    assert_eq!(oracle.connect_string(), "localhost:5501/ORCLPDB1");

    let redis = RedisConfig {
        url: None,
        host: "localhost".to_string(),
        port: 6379,
        db: 0,
        password: Some("NekoRedis2026Local".to_string()),
    };
    assert_eq!(
        redis.connection_url(),
        "redis://:NekoRedis2026Local@localhost:6379/0"
    );

    let redis_with_url_and_password = RedisConfig {
        url: Some("redis://localhost:6379".to_string()),
        host: "ignored".to_string(),
        port: 1,
        db: 0,
        password: Some("NekoRedis2026Local".to_string()),
    };
    assert_eq!(
        redis_with_url_and_password.connection_url(),
        "redis://:NekoRedis2026Local@localhost:6379/0"
    );

    let config = AppConfig::for_test();
    assert_eq!(config.oracle.pool_min, 2);
    assert_eq!(config.oracle.pool_max, 10);
    assert_eq!(config.redis.connection_url(), "redis://127.0.0.1:6379/0");
}

#[test]
fn redis_prefixes_and_channels_match_existing_contract() {
    assert_eq!(RATE_LIMIT_PREFIX, "rate_limit");
    assert_eq!(API_CACHE_PREFIX, "nt:api-cache");
    assert_eq!(API_CACHE_HIT_PREFIX, "nt:api-cache-hits");
    assert_eq!(API_CACHE_TAG_PREFIX, "nt:api-cache-tag");
    assert_eq!(API_CACHE_SCHEMA_VERSION, "1");
    assert_eq!(ORACLE_QUERY_CACHE_PREFIX, "nt:oracle-query-cache");
    assert_eq!(ORACLE_QUERY_CACHE_SCHEMA_VERSION, "2");
    assert_eq!(REDIS_CHANNELS.broadcast, "ws:broadcast");
    assert_eq!(REDIS_CHANNELS.chat_channel_prefix, "ws:chat:channel:");
}

#[test]
fn rate_limit_info_uses_existing_window_and_ttl() {
    let mut info = RateLimitInfo::default();
    for _ in 0..100 {
        assert!(!info.record(1_000));
    }
    assert!(info.record(1_000), "101st request in window is limited");
    assert!(!info.record(12_001), "new 10 second window resets counter");
    assert_eq!(RateLimitInfo::ttl_seconds(), 120);
}

#[test]
fn api_cache_only_caches_successful_safe_gets_and_keeps_viewer_scope() {
    assert!(is_cacheable_request("GET", "/api/v2/posts"));
    assert!(!is_cacheable_request("POST", "/api/v2/posts"));
    assert!(!is_cacheable_request("GET", "/api/v2/auth/otp"));
    assert!(!is_cacheable_request("GET", "/api/v1/users/me"));

    let tags = tags_for_path("/api/v2/posts/100001/comments", Some(42));
    assert!(tags.contains(&"posts".to_string()));
    assert!(tags.contains(&"comments".to_string()));
    assert!(tags.contains(&"viewer:42".to_string()));

    let policy = ttl_policy_for_path("/api/v2/posts/trending");
    assert_eq!(policy.ttl_seconds, 300);

    let mut tag_versions = BTreeMap::new();
    tag_versions.insert("posts".to_string(), "2".to_string());
    let key = build_api_cache_key(ApiCacheIdentity {
        namespace: "v2",
        method: "GET",
        path: "/api/v2/posts",
        query: "page=1&page_size=20",
        user_id: Some(42),
        tag_versions: &tag_versions,
    });
    assert!(key.key.starts_with("nt:api-cache:v2:posts:"));
    assert!(key.hit_key.starts_with("nt:api-cache-hits:v2:"));

    assert!(should_invalidate_after_success("POST", "/api/v2/posts"));
    assert!(!should_invalidate_after_success(
        "PATCH",
        "/api/v2/auth/tokens/current"
    ));
}

#[test]
fn oracle_query_cache_safely_filters_sql_and_keys_include_viewer() {
    assert!(is_cacheable_select_sql(
        "/* comment */ SELECT id, name FROM n_users WHERE id = :id"
    ));
    assert!(is_cacheable_select_sql(
        "WITH recent AS (SELECT id FROM n_posts) SELECT * FROM recent"
    ));
    assert!(!is_cacheable_select_sql(
        "SELECT seq_post_id.NEXTVAL AS id FROM dual"
    ));
    assert!(!is_cacheable_select_sql(
        "SELECT password_hash FROM n_users WHERE id = :id"
    ));
    assert!(!is_cacheable_select_sql(
        "SELECT * FROM n_posts WHERE id = :id FOR UPDATE"
    ));

    assert!(is_mutating_sql(
        "MERGE INTO n_posts p USING dual ON (1 = 1)"
    ));
    assert!(is_cache_neutral_mutation_sql(
        "UPDATE n_auth_sessions SET last_accessed_at = SYSTIMESTAMP WHERE id = :id"
    ));

    assert_eq!(
        table_refs("SELECT * FROM neko_app.n_posts p JOIN n_users u ON u.id = p.user_id"),
        vec!["n_posts".to_string(), "n_users".to_string()]
    );

    let tags = tags_for_sql(
        "SELECT * FROM n_notifications WHERE user_id = :viewer",
        Some(42),
    );
    assert!(tags.contains(&"notifications".to_string()));
    assert!(tags.contains(&"viewer:42".to_string()));

    let mut binds = BTreeMap::new();
    binds.insert("id".to_string(), json!(100001));
    let mut tag_versions = BTreeMap::new();
    tag_versions.insert("table:n_users".to_string(), "7".to_string());
    let first = build_oracle_query_cache_key(OracleQueryCacheIdentity {
        sql: "select * from n_users where id = :id",
        binds: &binds,
        options: &json!({ "max_rows": 20 }),
        viewer_id: Some(42),
        tag_versions: &tag_versions,
    });
    let second = build_oracle_query_cache_key(OracleQueryCacheIdentity {
        sql: "select * from n_users where id = :id",
        binds: &binds,
        options: &json!({ "max_rows": 20 }),
        viewer_id: Some(43),
        tag_versions: &tag_versions,
    });
    assert_ne!(first.cache_id, second.cache_id);
    assert!(first
        .key
        .starts_with("nt:oracle-query-cache:oracle:n_users:"));
}

#[test]
fn db_value_helpers_keep_null_and_bool_number_semantics() {
    assert_eq!(DbValue::Null.as_i64(), None);
    assert_eq!(DbValue::String("42".to_string()).as_i64(), Some(42));
    assert_eq!(DbValue::BoolNumber(true).as_i64(), Some(1));
    assert_eq!(
        Some("value".to_string()).null_if_empty(),
        Some("value".to_string())
    );
    assert_eq!(Some("".to_string()).null_if_empty(), None);
}
