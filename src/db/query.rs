use crate::db::{oracle::BindMap, pool::OraclePool, row::DbRow, DbError};

pub async fn query_rows(
    pool: &OraclePool,
    sql: impl Into<String>,
    binds: BindMap,
) -> Result<Vec<DbRow>, DbError> {
    pool.query_rows(sql, binds).await
}

pub async fn query_one(
    pool: &OraclePool,
    sql: impl Into<String>,
    binds: BindMap,
) -> Result<Option<DbRow>, DbError> {
    pool.query_one(sql, binds).await
}
