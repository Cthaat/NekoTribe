//! Uncached shared Skill configuration; caller must authenticate before use.
use crate::{
    ai::skill_selection::Registry,
    db::{
        oracle::{self as db_oracle, bind_refs, bind_values, BindMap, DbError},
        row::{oracle_row_to_db_row, DbRow},
        tx::OracleTx,
        value::DbValue,
    },
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::OnceLock;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WriteContract {
    max_generation: i64,
    queries: WriteQueries,
}

#[derive(Deserialize)]
struct WriteQueries {
    insert: String,
    update: String,
}

fn write_contract() -> &'static WriteContract {
    static CONTRACT: OnceLock<WriteContract> = OnceLock::new();
    CONTRACT.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../../contracts/requirements/ai-skill-config-write.json"
        ))
        .expect("valid skill publication contract")
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    Unavailable,
}
pub struct Config {
    pub generation: i64,
    pub registry: Registry,
}
pub trait Reader {
    fn load(&self) -> Result<Vec<DbRow>, Error>;
}

pub fn load(reader: &impl Reader, actor: i64) -> Result<Config, Error> {
    if !(1..=9_007_199_254_740_991).contains(&actor) {
        return Err(Error::Unavailable);
    }
    decode_config(&reader.load()?)?.ok_or(Error::Unavailable)
}

fn decode_config(rows: &[DbRow]) -> Result<Option<Config>, Error> {
    if rows.is_empty() {
        return Ok(None);
    }
    if rows.len() != 1 {
        return Err(Error::Unavailable);
    }
    let row = &rows[0];
    let generation = row
        .get("GENERATION")
        .and_then(DbValue::as_str)
        .and_then(|v| v.parse::<i64>().ok())
        .filter(|v| (1..=write_contract().max_generation).contains(v))
        .ok_or(Error::Unavailable)?;
    let raw = row
        .get("ENABLED_IDS")
        .and_then(DbValue::as_str)
        .filter(|v| v.len() <= 512)
        .ok_or(Error::Unavailable)?;
    let enabled: Vec<String> = serde_json::from_str(raw).map_err(|_| Error::Unavailable)?;
    let registry = Registry::new(&enabled).map_err(|_| Error::Unavailable)?;
    Ok(Some(Config {
        generation,
        registry,
    }))
}
pub(crate) struct OracleReader<'a>(pub(crate) &'a oracle::Connection);
impl Reader for OracleReader<'_> {
    fn load(&self) -> Result<Vec<DbRow>, Error> {
        read_oracle(self.0, false)
    }
}
struct LockedOracleReader<'a>(&'a oracle::Connection);
impl Reader for LockedOracleReader<'_> {
    fn load(&self) -> Result<Vec<DbRow>, Error> {
        read_oracle(self.0, true)
    }
}
fn skill_config_query(lock: bool) -> &'static str {
    if lock {
        "SELECT generation,enabled_ids FROM n_ai_skill_config WHERE singleton_id=:singleton_id FOR UPDATE NOWAIT"
    } else {
        "SELECT generation,enabled_ids FROM n_ai_skill_config WHERE singleton_id=:singleton_id"
    }
}
fn verify_schema(connection: &::oracle::Connection) -> Result<(), Error> {
    let snapshot = crate::auth::readiness::collect_ai_skill_snapshot(connection)
        .map_err(|_| Error::Unavailable)?;
    crate::auth::readiness::validate_feature_snapshot(&snapshot, "ai-skills")
        .map_err(|_| Error::Unavailable)
}

fn read_oracle(connection: &::oracle::Connection, lock: bool) -> Result<Vec<DbRow>, Error> {
    verify_schema(connection)?;
    let binds = bind_values(BindMap::from([("singleton_id".into(), DbValue::I64(1))]));
    let mut rows = connection
        .query_named(skill_config_query(lock), &bind_refs(&binds))
        .map_err(|_| Error::Unavailable)?;
    let mut output = Vec::new();
    for _ in 0..2 {
        let Some(row) = rows.next().transpose().map_err(|_| Error::Unavailable)? else {
            break;
        };
        output.push(oracle_row_to_db_row(&row).map_err(|_| Error::Unavailable)?)
    }
    Ok(output)
}
/// `actor` comes from authenticated backend identity, not client input.
pub fn load_from_oracle(connection: &oracle::Connection, actor: i64) -> Result<Config, Error> {
    load(&OracleReader(connection), actor)
}
/// Caller owns the transaction and must finish promptly; never hold the lock during inference.
pub fn lock_from_oracle(connection: &oracle::Connection, actor: i64) -> Result<Config, Error> {
    load(&LockedOracleReader(connection), actor)
}

enum Maintenance {
    Plan(Vec<String>),
    Status,
    Publish { expected: i64, enabled: Vec<String> },
}

fn parse_command(args: &[String]) -> Result<Maintenance, &'static str> {
    let (mut mode, mut expected, mut enabled) = (None, None, None);
    let mut args = args.iter().map(String::as_str);
    while let Some(arg) = args.next() {
        match arg {
            "--plan" | "--status" | "--publish" if mode.is_none() => mode = Some(arg),
            "--expected" if expected.is_none() => {
                let value = args.next().ok_or("INVALID_ARGUMENTS")?;
                let parsed = value.parse::<i64>().map_err(|_| "INVALID_ARGUMENTS")?;
                if parsed < 0
                    || parsed >= write_contract().max_generation
                    || parsed.to_string() != value
                {
                    return Err("INVALID_ARGUMENTS");
                }
                expected = Some(parsed);
            }
            "--enabled-json" if enabled.is_none() => {
                let value = args
                    .next()
                    .filter(|value| value.len() <= 512)
                    .ok_or("INVALID_ARGUMENTS")?;
                let mut ids: Vec<String> =
                    serde_json::from_str(value).map_err(|_| "INVALID_ARGUMENTS")?;
                Registry::new(&ids).map_err(|_| "SKILL_CONFIG_INVALID_INPUT")?;
                ids.sort_unstable();
                enabled = Some(ids);
            }
            _ => return Err("INVALID_ARGUMENTS"),
        }
    }
    match (mode.unwrap_or("--plan"), expected, enabled) {
        ("--plan", None, enabled) => Ok(Maintenance::Plan(enabled.unwrap_or_default())),
        ("--status", None, None) => Ok(Maintenance::Status),
        ("--publish", Some(expected), Some(enabled)) => {
            Ok(Maintenance::Publish { expected, enabled })
        }
        _ => Err("INVALID_ARGUMENTS"),
    }
}

fn maintenance_config(
    env: impl Fn(&str) -> Option<String>,
) -> Result<crate::config::env::OracleConfig, &'static str> {
    const INVALID: &str = "SKILL_CONFIG_CONFIGURATION_INVALID";
    let shared = |key: &str| crate::config::env::shared_native_value(&env, key);
    let required = |name| {
        shared(name)
            .filter(|value| !value.trim().is_empty())
            .ok_or(INVALID)
    };
    let host = required("ORACLE_HOST")?;
    let service_name = required("ORACLE_SERVICE_NAME")?;
    if [&host, &service_name]
        .iter()
        .any(|value| value.contains(['(', ')', '/', '=', ' ', '\t', '\r', '\n']))
    {
        return Err(INVALID);
    }
    let port = shared("ORACLE_PORT")
        .filter(|value| !value.is_empty())
        .map_or(Ok(1521), |value| value.parse::<u16>())
        .map_err(|_| INVALID)?;
    if port == 0 {
        return Err(INVALID);
    }
    Ok(crate::config::env::OracleConfig {
        host,
        port,
        service_name,
        user: required("ORACLE_USER")?,
        password: required("ORACLE_PASSWORD")?,
        pool_min: 0,
        pool_max: 1,
    })
}

fn apply_publication(
    tx: &impl crate::db::tx::Transaction,
    expected: i64,
    enabled: &[String],
) -> Result<Value, &'static str> {
    let encoded = serde_json::to_string(enabled).map_err(|_| "SKILL_CONFIG_WRITE_FAILED")?;
    let mut binds = BindMap::from([("enabled_ids".into(), DbValue::String(encoded))]);
    let queries = &write_contract().queries;
    let query = if expected == 0 {
        &queries.insert
    } else {
        binds.insert("expected_generation".into(), DbValue::I64(expected));
        &queries.update
    };
    match tx.execute(query, binds) {
        Ok(1) => tx.commit().map_err(|_| "SKILL_CONFIG_COMMIT_UNCERTAIN")?,
        Ok(0) => {
            tx.rollback().map_err(|_| "SKILL_CONFIG_WRITE_FAILED")?;
            return Err("SKILL_CONFIG_CONFLICT");
        }
        Err(DbError::Oracle(error))
            if expected == 0 && error.db_error().is_some_and(|e| e.code() == 1) =>
        {
            tx.rollback().map_err(|_| "SKILL_CONFIG_WRITE_FAILED")?;
            return Err("SKILL_CONFIG_CONFLICT");
        }
        _ => {
            let _ = tx.rollback();
            return Err("SKILL_CONFIG_WRITE_FAILED");
        }
    }
    Ok(json!({"generation":expected + 1,"enabled":enabled}))
}

/// Trusted operator command. The offline plan checks input before reading any credentials.
pub fn maintain_skills(
    args: &[String],
    env: impl Fn(&str) -> Option<String>,
) -> Result<Value, &'static str> {
    let mode = parse_command(args)?;
    if let Maintenance::Plan(enabled) = mode {
        return Ok(json!({"mode":"plan","enabled":enabled,"connected":false}));
    }
    let connection = db_oracle::connect(&maintenance_config(env)?)
        .map_err(|_| "SKILL_CONFIG_OPERATION_FAILED")?;
    let result = (|| match mode {
        Maintenance::Status => {
            let rows =
                read_oracle(&connection, false).map_err(|_| "SKILL_CONFIG_OPERATION_FAILED")?;
            let config = decode_config(&rows).map_err(|_| "SKILL_CONFIG_OPERATION_FAILED")?;
            Ok(match config {
                Some(config) => {
                    json!({"mode":"status","generation":config.generation,"enabled":config.registry.enabled_ids()})
                }
                None => json!({"mode":"status","initialized":false}),
            })
        }
        Maintenance::Publish { expected, enabled } => {
            verify_schema(&connection).map_err(|_| "SKILL_CONFIG_WRITE_FAILED")?;
            apply_publication(&OracleTx::new(&connection), expected, &enabled)
        }
        Maintenance::Plan(_) => unreachable!(),
    })();
    connection
        .close()
        .map_err(|_| "SKILL_CONFIG_CONNECTION_CLOSE_FAILED")?;
    result
}

#[cfg(test)]
mod tests {
    #[test]
    fn lock_is_nonblocking_and_regular_reads_do_not_lock() {
        assert!(super::skill_config_query(true).ends_with(" FOR UPDATE NOWAIT"));
        assert!(!super::skill_config_query(false).contains("FOR UPDATE"));
    }

    #[test]
    fn maintenance_plan_is_offline_and_validates_its_input() {
        let args = |values: &[&str]| {
            values
                .iter()
                .map(|value| (*value).to_owned())
                .collect::<Vec<_>>()
        };
        let offline = |_: &str| -> Option<String> { panic!("plan read Oracle configuration") };
        let plan = super::maintain_skills(
            &args(&["--enabled-json", r#"["writing-draft","knowledge-answer"]"#]),
            offline,
        )
        .unwrap();
        assert_eq!(
            plan,
            serde_json::json!({"mode":"plan","enabled":["knowledge-answer","writing-draft"],"connected":false})
        );
        assert!(super::maintain_skills(
            &args(&["--publish", "--expected", "01", "--enabled-json", "[]"]),
            offline
        )
        .is_err());
        assert!(
            super::maintain_skills(&args(&["--status", "--enabled-json", "[]"]), offline).is_err()
        );
    }
}
