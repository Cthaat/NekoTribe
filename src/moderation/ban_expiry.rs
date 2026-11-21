use crate::{
    auth::session_repository::row_number,
    db::{
        oracle::{BindMap, DbError},
        pool::OraclePool,
        tx::OracleTx,
        value::DbValue,
    },
    direct_history::query,
};
use serde::Deserialize;
use std::{
    collections::HashMap,
    sync::OnceLock,
    time::{Duration, Instant},
};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Contract {
    sql: HashMap<String, String>,
    interval_seconds: u64,
}

fn contract() -> &'static Contract {
    static CONTRACT: OnceLock<Contract> = OnceLock::new();
    CONTRACT.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../../contracts/requirements/moderation-ban-expiry.json"
        ))
        .expect("valid moderation ban-expiry contract")
    })
}

pub(crate) fn restore(connection: &oracle::Connection, user: i64) -> Result<(), DbError> {
    restore_with_lock(connection, user, &contract().sql["lock"])
}

fn restore_with_lock(
    connection: &oracle::Connection,
    user: i64,
    lock: &str,
) -> Result<(), DbError> {
    let tx = OracleTx::new(connection);
    let sql = &contract().sql;
    let key = || BindMap::from([("user_id".into(), DbValue::I64(user))]);
    let result = (|| {
        if !query(connection, lock, key())?.is_empty()
            && tx.execute(&sql["restore"], key())?.rows_affected == 1
            && tx.execute(&sql["expire"], key())?.rows_affected == 0
        {
            return Err(DbError::SchemaNotReady);
        }
        tx.commit()
    })();
    if result.is_err() {
        tx.rollback()?;
    }
    result
}

pub(crate) async fn run_sweep(pool: OraclePool) {
    let period = Duration::from_secs(contract().interval_seconds);
    let mut ticks = tokio::time::interval_at(tokio::time::Instant::now() + period, period);
    ticks.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        ticks.tick().await;
        if pool.run_blocking(sweep).await.is_err() {
            tracing::warn!("moderation ban expiry sweep incomplete");
        }
    }
}

fn sweep(connection: &oracle::Connection) -> Result<(), DbError> {
    connection.set_call_timeout(Some(Duration::from_secs(5)))?;
    let deadline = Instant::now() + Duration::from_secs(25);
    let sql = &contract().sql;
    let users = query(connection, &sql["candidates"], BindMap::new())?;
    let lock = format!("{} SKIP LOCKED", sql["lock"]);
    for row in users {
        if Instant::now() >= deadline {
            break;
        }
        restore_with_lock(connection, row_number(&row, "USER_ID"), &lock)?;
    }
    Ok(())
}
