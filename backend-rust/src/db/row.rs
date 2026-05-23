use std::collections::BTreeMap;

use crate::db::{oracle::DbError, value::DbValue};

pub type DbRow = BTreeMap<String, DbValue>;

pub fn row_value<'a>(row: &'a DbRow, key: &str) -> Option<&'a DbValue> {
    row.get(&key.to_ascii_uppercase())
}

pub fn oracle_row_to_db_row(row: &oracle::Row) -> Result<DbRow, DbError> {
    let mut output = DbRow::new();
    for (index, column) in row.column_info().iter().enumerate() {
        let value = row.get::<usize, Option<String>>(index)?;
        output.insert(
            column.name().to_ascii_uppercase(),
            DbValue::from_option_string(value),
        );
    }
    Ok(output)
}
