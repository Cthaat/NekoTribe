use nekotribe_backend::{
    cache::redis::RedisPool,
    config::env::AppConfig,
    db::{oracle::BindMap, pool::OraclePool},
};

fn load_env() {
    let _ = dotenvy::from_path("../.env");
    let _ = dotenvy::dotenv();
}

#[tokio::test]
#[ignore = "requires Oracle Client plus a running NekoTribe Oracle database"]
async fn oracle_select_one_from_dual() {
    load_env();

    let config = AppConfig::from_env().expect("app config from env");
    let pool = OraclePool::new(config.oracle);
    let row = pool
        .query_one("SELECT 1 AS TOTAL FROM dual", BindMap::new())
        .await
        .expect("oracle query")
        .expect("one row");

    assert_eq!(row.get("TOTAL").and_then(|value| value.as_i64()), Some(1));
}

#[tokio::test]
#[ignore = "requires a running Redis service"]
async fn redis_ping_returns_pong() {
    load_env();

    let config = AppConfig::from_env().expect("app config from env");
    let redis = RedisPool::connect(&config.redis).await;
    assert!(
        redis.is_available(),
        "redis unavailable: {:?}",
        redis.unavailable_reason()
    );
    assert_eq!(redis.ping().await.expect("redis ping"), "PONG");
}
