//! Internal authority check. Callers must authenticate before use and recheck at delivery.
use crate::{
    ai::public_terms_source,
    db::{
        oracle::{bind_refs, bind_values, BindMap},
        row::{oracle_row_to_db_row, DbRow},
        value::DbValue,
    },
};
use serde_json::Value;
use sha2::{Digest, Sha256};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    InvalidViewer,
    Unavailable,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Authority {
    pub digest: String,
    pub generation: i64,
}
pub trait Reader {
    fn load(&self) -> Result<Vec<DbRow>, Error>;
}

pub fn catalog_digest(raw: &Value) -> Result<String, Error> {
    let catalog = public_terms_source::parse(raw).map_err(|_| Error::Unavailable)?;
    let mut hash = Sha256::new();
    hash.update(b"neko-ai-terms-catalog-v1\0");
    for row in catalog {
        for field in [row.id.to_string(), row.version] {
            hash.update(format!("{}:", field.len()).as_bytes());
            hash.update(field.as_bytes());
        }
    }
    Ok(hex::encode(hash.finalize()))
}

/// `viewer` must come from the selected backend's verified authentication, not user input.
pub fn read(reader: &impl Reader, viewer: i64, raw: &Value) -> Result<Authority, Error> {
    if !(1..=9_007_199_254_740_991).contains(&viewer) {
        return Err(Error::InvalidViewer);
    }
    let digest = catalog_digest(raw)?;
    let rows = reader.load().map_err(|_| Error::Unavailable)?;
    if rows.len() != 1 {
        return Err(Error::Unavailable);
    }
    let row = &rows[0];
    let actual = row
        .get("CATALOG_DIGEST")
        .and_then(DbValue::as_str)
        .ok_or(Error::Unavailable)?;
    // Oracle is read as text; avoid lossy float-to-integer conversions.
    let number = |key: &str| {
        row.get(key)
            .and_then(DbValue::as_str)
            .and_then(|v| v.parse::<i64>().ok())
            .ok_or(Error::Unavailable)
    };
    let generation = number("GENERATION")?;
    if actual != digest
        || number("ENABLED")? != 1
        || !(1..=999_999_999_999_999).contains(&generation)
    {
        return Err(Error::Unavailable);
    }
    Ok(Authority { digest, generation })
}

pub(crate) struct OracleReader<'a>(pub(crate) &'a oracle::Connection, pub(crate) bool);
fn authority_query(lock: bool) -> &'static str {
    if lock {
        "SELECT catalog_digest,generation,enabled FROM n_ai_terms_active WHERE singleton_id=:singleton_id FOR UPDATE WAIT 5"
    } else {
        "SELECT catalog_digest,generation,enabled FROM n_ai_terms_active WHERE singleton_id=:singleton_id"
    }
}
impl Reader for OracleReader<'_> {
    fn load(&self) -> Result<Vec<DbRow>, Error> {
        let binds = bind_values(BindMap::from([("singleton_id".into(), DbValue::I64(1))]));
        let mut rows = self
            .0
            .query_named(authority_query(self.1), &bind_refs(&binds))
            .map_err(|_| Error::Unavailable)?;
        let mut output = Vec::new();
        for _ in 0..2 {
            let Some(row) = rows.next().transpose().map_err(|_| Error::Unavailable)? else {
                break;
            };
            output.push(oracle_row_to_db_row(&row).map_err(|_| Error::Unavailable)?);
        }
        Ok(output)
    }
}
/// Read the current durable marker. This function does not authenticate the caller.
pub fn read_from_oracle(
    connection: &oracle::Connection,
    viewer: i64,
    raw: &Value,
) -> Result<Authority, Error> {
    read(&OracleReader(connection, false), viewer, raw)
}
/// Only call within a write transaction; commit or rollback must release the lock.
pub fn read_from_oracle_locked(
    connection: &oracle::Connection,
    viewer: i64,
    raw: &Value,
) -> Result<Authority, Error> {
    read(&OracleReader(connection, true), viewer, raw)
}

#[cfg(test)]
mod lock_tests {
    use super::*;
    #[test]
    fn ordinary_authority_queries_remain_unlocked_and_write_checks_wait_bounded() {
        assert!(!authority_query(false).contains("FOR UPDATE"));
        assert!(authority_query(true).ends_with("FOR UPDATE WAIT 5"));
    }
}
