use crate::db::{
    oracle::{bind_refs, bind_values, BindMap, DbError, ExecuteResult},
    row::{oracle_row_to_db_row, DbRow},
    value::DbValue,
};
use oracle::sql_type::Clob;
use std::io::Write;

/// All queries and writes use one connection without auto-committing.
pub trait Transaction {
    fn query(&self, sql: &str, binds: BindMap) -> Result<Vec<DbRow>, DbError>;
    fn execute(&self, sql: &str, binds: BindMap) -> Result<u64, DbError>;
    fn execute_clob(
        &self,
        sql: &str,
        mut binds: BindMap,
        name: &str,
        body: &str,
    ) -> Result<u64, DbError> {
        binds.insert(name.into(), DbValue::String(body.to_owned()));
        self.execute(sql, binds)
    }
    fn commit(&self) -> Result<(), DbError>;
    fn rollback(&self) -> Result<(), DbError>;
}

pub struct OracleTx<'a> {
    connection: &'a oracle::Connection,
}

impl Transaction for OracleTx<'_> {
    fn query(&self, sql: &str, binds: BindMap) -> Result<Vec<DbRow>, DbError> {
        let values = bind_values(binds);
        let refs = bind_refs(&values);
        self.connection
            .query_named(sql, &refs)?
            .map(|row| oracle_row_to_db_row(&row?))
            .collect()
    }

    fn execute(&self, sql: &str, binds: BindMap) -> Result<u64, DbError> {
        Ok(OracleTx::execute(self, sql, binds)?.rows_affected)
    }

    fn execute_clob(
        &self,
        sql: &str,
        binds: BindMap,
        name: &str,
        body: &str,
    ) -> Result<u64, DbError> {
        let mut clob = Clob::new(self.connection)?;
        clob.write_all(body.as_bytes())
            .map_err(|_| DbError::SchemaNotReady)?;
        let values = bind_values(binds);
        let mut refs = bind_refs(&values);
        refs.push((name, &clob));
        Ok(self.connection.execute_named(sql, &refs)?.row_count()?)
    }

    fn commit(&self) -> Result<(), DbError> {
        OracleTx::commit(self)
    }

    fn rollback(&self) -> Result<(), DbError> {
        OracleTx::rollback(self)
    }
}

impl<'a> OracleTx<'a> {
    pub fn new(connection: &'a oracle::Connection) -> Self {
        Self { connection }
    }

    pub fn execute(&self, sql: &str, binds: BindMap) -> Result<ExecuteResult, DbError> {
        let bind_values = crate::db::oracle::bind_values(binds);
        let bind_refs = crate::db::oracle::bind_refs(&bind_values);
        let statement = self.connection.execute_named(sql, &bind_refs)?;
        Ok(ExecuteResult {
            rows_affected: statement.row_count()?,
        })
    }

    pub fn commit(&self) -> Result<(), DbError> {
        self.connection.commit()?;
        Ok(())
    }

    pub fn rollback(&self) -> Result<(), DbError> {
        self.connection.rollback()?;
        Ok(())
    }
}
