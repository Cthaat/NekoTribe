//! SELECT-only Nuxt-compatible metadata checks for native 2FA entry points.
//! All dictionary reads for one check use a single Oracle connection.
use std::collections::{BTreeMap, BTreeSet};

use serde_json::{json, Map, Value};

use crate::{
    auth::sessions::SessionStoreError,
    db::{
        oracle::{self, BindMap, DbError},
        row::oracle_row_to_db_row,
        value::DbValue,
    },
};

pub type SchemaSnapshot = Value;

fn catalog(feature: &str) -> Result<Value, SessionStoreError> {
    let (content, expected_id, count) = match feature {
        "two-factor" => (
            include_str!("../../contracts/requirements/two-factor-schema-catalog.json"),
            "AUTH-2FA-SCHEMA-CATALOG",
            9,
        ),
        "media" => (
            include_str!("../../contracts/requirements/media-schema-catalog.json"),
            "MEDIA-SCHEMA-CATALOG",
            1,
        ),
        "user-settings" => (
            include_str!("../../contracts/requirements/user-settings-schema-catalog.json"),
            "USER-SETTINGS-SCHEMA-CATALOG",
            5,
        ),
        "ai-conversations" => (
            include_str!("../../contracts/requirements/ai-conversation-schema-catalog.json"),
            "AI-CONVERSATION-SCHEMA-CATALOG",
            3,
        ),
        _ => return Err(SessionStoreError),
    };
    let value: Value = serde_json::from_str(content).map_err(|_| SessionStoreError)?;
    if value["id"] != expected_id
        || value["revision"] != 1
        || value["feature"]["id"] != feature
        || value["feature"]["steps"].as_array().map(Vec::len) != Some(count)
        || value["migrationChecksums"]
            .as_object()
            .is_none_or(|v| v.is_empty())
    {
        return Err(SessionStoreError);
    }
    Ok(value)
}

fn text<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key)?.as_str()
}
fn number(value: &Value) -> Option<i64> {
    value.as_i64().or_else(|| {
        let parsed = if let Some(text) = value.as_str() {
            text.trim().parse::<f64>().ok()?
        } else {
            value.as_f64()?
        };
        if parsed.is_finite() && parsed.fract() == 0.0 && parsed.abs() <= 9_007_199_254_740_991.0 {
            Some(parsed as i64)
        } else {
            None
        }
    })
}
fn array<'a>(value: &'a Value, key: &str) -> Option<&'a Vec<Value>> {
    value.get(key)?.as_array()
}

// Matches Nuxt's normalization of SQL syntax while preserving quoted literals.
fn js_whitespace(c: char) -> bool {
    matches!(c, '\u{0009}'..='\u{000d}' | '\u{0020}' | '\u{00a0}' | '\u{1680}' | '\u{2000}'..='\u{200a}' | '\u{2028}' | '\u{2029}' | '\u{202f}' | '\u{205f}' | '\u{3000}' | '\u{feff}')
}

fn normalized(value: Option<&str>) -> String {
    let mut result = String::new();
    let mut chars = value.unwrap_or("").chars().peekable();
    let mut quoted = false;
    while let Some(c) = chars.next() {
        if c == '\'' {
            result.push(c);
            if quoted && chars.peek() == Some(&'\'') {
                result.push(chars.next().unwrap());
            } else {
                quoted = !quoted;
            }
        } else if quoted {
            result.push(c);
        } else if !js_whitespace(c) && c != '"' {
            result.extend(c.to_uppercase());
        }
    }
    loop {
        if !result.starts_with('(') || !result.ends_with(')') {
            break;
        }
        let mut depth = 0i32;
        let mut quoted = false;
        let chars: Vec<char> = result.chars().collect();
        let mut early = false;
        let mut i = 0;
        while i + 1 < chars.len() {
            if chars[i] == '\'' {
                if quoted && i + 1 < chars.len() && chars[i + 1] == '\'' {
                    i += 2;
                    continue;
                }
                quoted = !quoted;
            } else if !quoted {
                if chars[i] == '(' {
                    depth += 1;
                }
                if chars[i] == ')' {
                    depth -= 1;
                    if depth == 0 {
                        early = true;
                        break;
                    }
                }
            }
            i += 1;
        }
        if early {
            break;
        }
        result = chars[1..chars.len() - 1].iter().collect();
    }
    // The catalog uses only literal IN sets; normalize order and duplicates.
    if let Some((head, tail)) = result.split_once("IN(") {
        if !head.is_empty()
            && head
                .chars()
                .enumerate()
                .all(|(i, c)| c.is_ascii_uppercase() || (i > 0 && (c.is_ascii_digit() || c == '_')))
            && tail.ends_with(')')
        {
            let members: Vec<_> = tail[..tail.len() - 1].split(',').collect();
            let literal =
                regex::Regex::new(r"^(?:'(?:[^']|'')*'|-?\d+(?:\.\d+)?)$").expect("static regex");
            if members.iter().all(|s| literal.is_match(s)) {
                let sorted: BTreeSet<_> = members.into_iter().collect();
                return format!(
                    "{head}IN({})",
                    sorted.into_iter().collect::<Vec<_>>().join(",")
                );
            }
        }
    }
    result
}

fn normalized_json(value: Option<&Value>) -> Option<String> {
    match value {
        None | Some(Value::Null) => Some(normalized(None)),
        Some(Value::String(value)) => Some(normalized(Some(value))),
        Some(Value::Number(value)) => Some(normalized(Some(&value.to_string()))),
        Some(Value::Bool(value)) => Some(normalized(Some(if *value { "true" } else { "false" }))),
        _ => None,
    }
}

fn matches_column(expected: &Value, actual: &Value) -> bool {
    let Some(kind) = text(expected, "type") else {
        return false;
    };
    let Some(nullable) = expected.get("nullable").and_then(Value::as_bool) else {
        return false;
    };
    let Some(actual_default) = normalized_json(actual.get("DATA_DEFAULT")) else {
        return false;
    };
    let Some(expected_default) = normalized_json(expected.get("default")) else {
        return false;
    };
    if text(actual, "NULLABLE") != Some(if nullable { "Y" } else { "N" })
        || actual_default != expected_default
    {
        return false;
    }
    if kind == "NUMBER" {
        return text(actual, "DATA_TYPE") == Some("NUMBER")
            && actual.get("DATA_PRECISION").is_none_or(Value::is_null)
            && actual.get("DATA_SCALE").is_none_or(Value::is_null);
    }
    if let Some(inner) = kind
        .strip_prefix("NUMBER(")
        .and_then(|s| s.strip_suffix(')'))
    {
        let mut parts = inner.split(',');
        let precision = parts.next().and_then(|s| s.parse::<i64>().ok());
        let scale = parts
            .next()
            .and_then(|s| s.parse::<i64>().ok())
            .unwrap_or(0);
        let actual_scale = match actual.get("DATA_SCALE") {
            Some(Value::Null) => Some(0),
            Some(value) => number(value),
            None => None,
        };
        return text(actual, "DATA_TYPE") == Some("NUMBER")
            && precision == actual.get("DATA_PRECISION").and_then(number)
            && actual_scale == Some(scale);
    }
    if let Some(inner) = kind
        .strip_prefix("VARCHAR2(")
        .and_then(|s| s.strip_suffix(')'))
    {
        return text(actual, "DATA_TYPE") == Some("VARCHAR2")
            && inner.parse::<i64>().ok() == actual.get("CHAR_LENGTH").and_then(number);
    }
    text(actual, "DATA_TYPE")
        == Some(if kind == "TIMESTAMP" {
            "TIMESTAMP(6)"
        } else {
            kind
        })
}

fn matches_constraint(expected: &Value, actual: &Value) -> bool {
    let Some(kind) = text(expected, "type") else {
        return false;
    };
    if text(actual, "CONSTRAINT_TYPE") != Some(kind)
        || text(actual, "STATUS") != Some("ENABLED")
        || text(actual, "VALIDATED") != Some("VALIDATED")
    {
        return false;
    }
    if kind == "C" {
        return normalized(text(actual, "SEARCH_CONDITION_VC"))
            == normalized(text(expected, "expression"));
    }
    if expected.get("columns") != actual.get("columns") {
        return false;
    }
    kind != "R"
        || (expected.get("referencedTable") == actual.get("REFERENCED_TABLE")
            && expected.get("deleteRule") == actual.get("DELETE_RULE")
            && expected.get("referencedColumns") == actual.get("referencedColumns"))
}

fn matches_table(expected: &Value, actual: &Value) -> bool {
    let Some(columns) = array(expected, "columns") else {
        return false;
    };
    let Some(actual_columns) = array(actual, "columns") else {
        return false;
    };
    let Some(constraints) = array(expected, "constraints") else {
        return false;
    };
    let Some(actual_constraints) = array(actual, "constraints") else {
        return false;
    };
    columns.iter().all(|c| {
        actual_columns
            .iter()
            .find(|a| text(a, "COLUMN_NAME") == text(c, "name"))
            .is_some_and(|a| matches_column(c, a))
    }) && constraints
        .iter()
        .all(|c| actual_constraints.iter().any(|a| matches_constraint(c, a)))
}

pub fn validate_snapshot(snapshot: &SchemaSnapshot) -> Result<(), SessionStoreError> {
    validate_feature_snapshot(snapshot, "two-factor")
}
pub fn validate_feature_snapshot(
    snapshot: &SchemaSnapshot,
    feature_name: &str,
) -> Result<(), SessionStoreError> {
    let spec = catalog(feature_name)?;
    let owner = snapshot.get("owner").ok_or(SessionStoreError)?;
    let user = text(owner, "user")
        .filter(|s| !s.is_empty())
        .ok_or(SessionStoreError)?;
    if text(owner, "schema") != Some(user) {
        return Err(SessionStoreError);
    }
    let tables = snapshot
        .get("tables")
        .and_then(Value::as_object)
        .ok_or(SessionStoreError)?;
    let ledger = snapshot
        .get("ledgerPresent")
        .and_then(Value::as_bool)
        .ok_or(SessionStoreError)?;
    if ledger {
        let expected = spec.get("ledger").ok_or(SessionStoreError)?;
        let actual = tables.get("N_SCHEMA_MIGRATIONS").ok_or(SessionStoreError)?;
        if !matches_table(expected, actual) {
            return Err(SessionStoreError);
        }
        let checksums = spec
            .get("migrationChecksums")
            .and_then(Value::as_object)
            .ok_or(SessionStoreError)?;
        let records = array(snapshot, "records").ok_or(SessionStoreError)?;
        for record in records {
            let id = text(record, "STEP_ID").ok_or(SessionStoreError)?;
            let expected = checksums
                .get(id)
                .and_then(Value::as_str)
                .ok_or(SessionStoreError)?;
            let actual = text(record, "CHECKSUM").ok_or(SessionStoreError)?;
            if expected != actual {
                return Err(SessionStoreError);
            }
        }
    }
    let feature = spec.get("feature").ok_or(SessionStoreError)?;
    for step in array(feature, "steps").ok_or(SessionStoreError)? {
        let name = text(step, "name").ok_or(SessionStoreError)?;
        match text(step, "kind") {
            Some("table" | "column") => {
                let table = text(step, "table").ok_or(SessionStoreError)?;
                if !tables.get(table).is_some_and(|a| matches_table(step, a)) {
                    return Err(SessionStoreError);
                }
            }
            Some("sequence") => {
                let actual = snapshot
                    .get("sequences")
                    .and_then(|v| v.get(name))
                    .ok_or(SessionStoreError)?;
                if actual.get("INCREMENT_BY").and_then(number) != Some(1)
                    || text(actual, "CYCLE_FLAG") != Some("N")
                {
                    return Err(SessionStoreError);
                }
            }
            Some("index") => {
                let actual = snapshot
                    .get("indexes")
                    .and_then(|v| v.get(name))
                    .ok_or(SessionStoreError)?;
                let wanted = array(step, "columns").ok_or(SessionStoreError)?;
                let cols = array(actual, "columns").ok_or(SessionStoreError)?;
                if text(actual, "TABLE_NAME") != text(step, "table")
                    || text(actual, "UNIQUENESS") != Some("NONUNIQUE")
                    || text(actual, "STATUS") != Some("VALID")
                    || cols.len() != wanted.len()
                    || !cols.iter().zip(wanted).all(|(a, e)| {
                        text(a, "COLUMN_NAME") == e.as_str() && text(a, "DESCEND") == Some("ASC")
                    })
                {
                    return Err(SessionStoreError);
                }
            }
            _ => return Err(SessionStoreError),
        }
    }
    Ok(())
}

fn query(
    connection: &::oracle::Connection,
    sql: &'static str,
    binds: BindMap,
) -> Result<Vec<Value>, DbError> {
    debug_assert!(sql.starts_with("SELECT "));
    let values = oracle::bind_values(binds);
    let refs = oracle::bind_refs(&values);
    connection
        .query_named(sql, &refs)?
        .map(|row| {
            let row = oracle_row_to_db_row(&row?)?;
            Ok(serde_json::to_value(row).expect("serializable database row"))
        })
        .collect()
}
fn bind(key: &str, value: &str) -> BindMap {
    BTreeMap::from([(key.to_owned(), DbValue::String(value.to_owned()))])
}

/// Collects only public Oracle dictionary metadata and ledger checksums; no DDL.
pub(crate) fn collect_snapshot(connection: &::oracle::Connection) -> Result<Value, DbError> {
    collect_feature_with("two-factor", |sql, binds| query(connection, sql, binds))
}
pub(crate) fn collect_media_snapshot(connection: &::oracle::Connection) -> Result<Value, DbError> {
    collect_feature_with("media", |sql, binds| query(connection, sql, binds))
}
pub(crate) fn collect_user_settings_snapshot(
    connection: &::oracle::Connection,
) -> Result<Value, DbError> {
    collect_feature_with("user-settings", |sql, binds| query(connection, sql, binds))
}
pub(crate) fn collect_ai_conversation_snapshot(
    connection: &::oracle::Connection,
) -> Result<Value, DbError> {
    collect_feature_with("ai-conversations", |sql, binds| {
        query(connection, sql, binds)
    })
}

/// Collects an Oracle dictionary snapshot through an injected SELECT executor.
pub fn collect_with<F>(read: F) -> Result<Value, DbError>
where
    F: FnMut(&'static str, BindMap) -> Result<Vec<Value>, DbError>,
{
    collect_feature_with("two-factor", read)
}
pub fn collect_feature_with<F>(feature: &str, mut read: F) -> Result<Value, DbError>
where
    F: FnMut(&'static str, BindMap) -> Result<Vec<Value>, DbError>,
{
    let spec = catalog(feature).map_err(|_| DbError::SchemaNotReady)?;
    let steps = spec["feature"]["steps"]
        .as_array()
        .ok_or(DbError::SchemaNotReady)?;
    let mut table_names = BTreeSet::from(["N_SCHEMA_MIGRATIONS".to_owned()]);
    let mut sequence_names = BTreeSet::new();
    let mut index_names = BTreeSet::new();
    for step in steps {
        let name = text(step, "name").ok_or(DbError::SchemaNotReady)?;
        match text(step, "kind") {
            Some("table" | "column") => {
                table_names.insert(
                    text(step, "table")
                        .ok_or(DbError::SchemaNotReady)?
                        .to_owned(),
                );
            }
            Some("sequence") => {
                sequence_names.insert(name.to_owned());
            }
            Some("index") => {
                index_names.insert(name.to_owned());
            }
            _ => return Err(DbError::SchemaNotReady),
        }
    }
    let identity = read("SELECT USER AS USER_NAME, SYS_CONTEXT('USERENV','CURRENT_SCHEMA') AS SCHEMA_NAME FROM dual", BindMap::new())?;
    let owner = identity.first().cloned().unwrap_or(Value::Null);
    let user = text(&owner, "USER_NAME")
        .filter(|v| !v.is_empty())
        .ok_or(DbError::SchemaNotReady)?;
    if text(&owner, "SCHEMA_NAME") != Some(user) {
        return Err(DbError::SchemaNotReady);
    }
    let mut tables = Map::new();
    for table in table_names {
        let exists = read(
            "SELECT table_name AS NAME FROM user_tables WHERE table_name = :name",
            bind("name", &table),
        )?;
        if exists.is_empty() {
            continue;
        }
        let cols = read("SELECT column_name, data_type, data_precision, data_scale, char_length, nullable, data_default FROM user_tab_columns WHERE table_name = :table_name", bind("table_name", &table))?;
        let constraints = read("SELECT c.constraint_name, c.constraint_type, c.search_condition_vc, c.delete_rule, c.status, c.validated, r.table_name AS referenced_table, c.r_owner AS referenced_owner FROM user_constraints c LEFT JOIN user_constraints r ON r.constraint_name = c.r_constraint_name AND c.r_owner = USER WHERE c.table_name = :table_name", bind("table_name", &table))?;
        let constraint_cols = read("SELECT c.constraint_name, c.column_name, c.position, r.column_name AS referenced_column FROM user_cons_columns c LEFT JOIN user_constraints f ON f.constraint_name = c.constraint_name LEFT JOIN user_cons_columns r ON r.constraint_name = f.r_constraint_name AND r.position = c.position AND f.r_owner = USER WHERE c.table_name = :table_name ORDER BY c.constraint_name, c.position", bind("table_name", &table))?;
        let mut enriched = Vec::new();
        for mut item in constraints {
            let name = text(&item, "CONSTRAINT_NAME");
            let rows: Vec<_> = constraint_cols
                .iter()
                .filter(|c| text(c, "CONSTRAINT_NAME") == name)
                .collect();
            let columns: Vec<_> = rows
                .iter()
                .map(|r| r.get("COLUMN_NAME").cloned().unwrap_or(Value::Null))
                .collect();
            let refs: Vec<_> = rows
                .iter()
                .map(|r| r.get("REFERENCED_COLUMN").cloned().unwrap_or(Value::Null))
                .collect();
            if let Some(obj) = item.as_object_mut() {
                obj.insert("columns".into(), json!(columns));
                obj.insert("referencedColumns".into(), json!(refs));
            }
            enriched.push(item);
        }
        tables.insert(table, json!({"columns":cols,"constraints":enriched}));
    }
    let ledger_present = tables.contains_key("N_SCHEMA_MIGRATIONS");
    let records = if ledger_present {
        read(
            "SELECT step_id, checksum FROM n_schema_migrations",
            BindMap::new(),
        )?
    } else {
        Vec::new()
    };
    let mut sequences = Map::new();
    for name in sequence_names {
        if let Some(row) = read("SELECT sequence_name, increment_by, cycle_flag FROM user_sequences WHERE sequence_name = :name", bind("name", &name))?.into_iter().next() { sequences.insert(name, row); }
    }
    let mut indexes = Map::new();
    for name in index_names {
        if let Some(mut row) = read("SELECT index_name, table_name, uniqueness, status FROM user_indexes WHERE index_name = :name", bind("name", &name))?.into_iter().next() {
            let cols = read("SELECT column_name, descend FROM user_ind_columns WHERE index_name = :name ORDER BY column_position", bind("name", &name))?;
            if let Some(obj) = row.as_object_mut() { obj.insert("columns".into(), json!(cols)); }
            indexes.insert(name, row);
        }
    }
    Ok(
        json!({"owner":{"user":owner.get("USER_NAME"),"schema":owner.get("SCHEMA_NAME")}, "ledgerPresent":ledger_present, "tables":tables, "records":records, "sequences":sequences, "indexes":indexes}),
    )
}
