use std::sync::Arc;

use tokio::sync::Semaphore;

use crate::{
    config::env::OracleConfig,
    db::{
        oracle::{self, BindMap, DbError, ExecuteResult},
        row::{oracle_row_to_db_row, DbRow},
    },
};

#[derive(Clone)]
pub struct OraclePool {
    config: OracleConfig,
    semaphore: Arc<Semaphore>,
}

impl OraclePool {
    pub fn new(config: OracleConfig) -> Self {
        let max = config.pool_max.max(1);
        Self {
            config,
            semaphore: Arc::new(Semaphore::new(max)),
        }
    }

    pub async fn query_rows(
        &self,
        sql: impl Into<String>,
        binds: BindMap,
    ) -> Result<Vec<DbRow>, DbError> {
        let sql = sql.into();
        self.run_blocking(move |connection| {
            let bind_values = oracle::bind_values(binds);
            let bind_refs = oracle::bind_refs(&bind_values);
            let rows = connection.query_named(&sql, &bind_refs)?;
            rows.map(|row| oracle_row_to_db_row(&row?)).collect()
        })
        .await
    }

    pub async fn query_one(
        &self,
        sql: impl Into<String>,
        binds: BindMap,
    ) -> Result<Option<DbRow>, DbError> {
        Ok(self.query_rows(sql, binds).await?.into_iter().next())
    }

    pub async fn execute(
        &self,
        sql: impl Into<String>,
        binds: BindMap,
    ) -> Result<ExecuteResult, DbError> {
        let sql = sql.into();
        self.run_blocking(move |connection| {
            let bind_values = oracle::bind_values(binds);
            let bind_refs = oracle::bind_refs(&bind_values);
            let statement = connection.execute_named(&sql, &bind_refs)?;
            let rows_affected = statement.row_count()?;
            connection.commit()?;
            Ok(ExecuteResult { rows_affected })
        })
        .await
    }

    pub async fn next_id(&self, sequence_name: &str) -> Result<i64, DbError> {
        let sql = format!("SELECT {sequence_name}.NEXTVAL AS ID FROM dual");
        let row = self
            .query_one(sql, BindMap::new())
            .await?
            .ok_or_else(|| DbError::ExpectedNumber("ID".to_string()))?;
        row.get("ID")
            .and_then(|value| value.as_i64())
            .ok_or_else(|| DbError::ExpectedNumber("ID".to_string()))
    }

    pub async fn count(&self, sql: impl Into<String>, binds: BindMap) -> Result<u64, DbError> {
        let row = self
            .query_one(sql, binds)
            .await?
            .ok_or_else(|| DbError::ExpectedNumber("TOTAL".to_string()))?;
        row.get("TOTAL")
            .and_then(|value| value.as_i64())
            .and_then(|value| u64::try_from(value).ok())
            .ok_or_else(|| DbError::ExpectedNumber("TOTAL".to_string()))
    }

    async fn run_blocking<F, T>(&self, operation: F) -> Result<T, DbError>
    where
        F: FnOnce(::oracle::Connection) -> Result<T, DbError> + Send + 'static,
        T: Send + 'static,
    {
        let permit = self
            .semaphore
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| DbError::SemaphoreClosed)?;
        let config = self.config.clone();

        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            let connection = oracle::connect(&config)?;
            operation(connection)
        })
        .await?
    }
}
