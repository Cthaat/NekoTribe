use crate::db::oracle::{BindMap, DbError, ExecuteResult};

pub struct OracleTx<'a> {
    connection: &'a oracle::Connection,
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
}
