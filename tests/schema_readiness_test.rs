use nekotribe_backend::{
    auth::readiness::{collect_with, validate_snapshot, SchemaSnapshot},
    db::oracle::{BindMap, DbError},
};
use serde_json::{json, Value};

#[test]
fn schema_owner_must_match_and_metadata_is_not_assumed_ready() {
    let snapshot = SchemaSnapshot::default();
    assert!(validate_snapshot(&snapshot).is_err());
}

#[test]
fn oracle_expression_whitespace_matches_javascript_rules() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/two-factor-readiness.json"
    ))
    .unwrap();
    let mut snapshot = fixture["baseline"].clone();
    snapshot["tables"]["N_USER_TWO_FACTOR_SECRETS"]["columns"][6]["DATA_DEFAULT"] =
        json!("CURRENT_\u{feff}TIMESTAMP");
    assert!(validate_snapshot(&snapshot).is_ok());
    snapshot["tables"]["N_USER_TWO_FACTOR_SECRETS"]["columns"][6]["DATA_DEFAULT"] =
        json!("CURRENT_\u{0085}TIMESTAMP");
    assert!(validate_snapshot(&snapshot).is_err());
}

#[test]
fn oracle_numeric_text_accepts_equivalent_integers_only() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/two-factor-readiness.json"
    ))
    .unwrap();
    let mut snapshot = fixture["baseline"].clone();
    snapshot["sequences"]["SEQ_2FA_RECOVERY_CODE_ID"]["INCREMENT_BY"] = json!("1.0");
    snapshot["tables"]["N_USER_TWO_FACTOR_SECRETS"]["columns"][0]["DATA_SCALE"] = json!("0.0");
    assert!(validate_snapshot(&snapshot).is_ok());
    snapshot["sequences"]["SEQ_2FA_RECOVERY_CODE_ID"]["INCREMENT_BY"] = json!("1.1");
    assert!(validate_snapshot(&snapshot).is_err());
    snapshot["sequences"]["SEQ_2FA_RECOVERY_CODE_ID"]["INCREMENT_BY"] = json!(1);
    snapshot["tables"]["N_USER_TWO_FACTOR_SECRETS"]["columns"][0]["DATA_SCALE"] = json!("invalid");
    assert!(validate_snapshot(&snapshot).is_err());
}

#[test]
fn non_string_default_is_not_silently_treated_as_null() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/two-factor-readiness.json"
    ))
    .unwrap();
    let mut snapshot = fixture["baseline"].clone();
    snapshot["tables"]["N_USER_TWO_FACTOR_SECRETS"]["columns"][0]["DATA_DEFAULT"] = json!(0);
    assert!(validate_snapshot(&snapshot).is_err());
    snapshot["tables"]["N_AUTH_TWO_FACTOR_CHALLENGES"]["columns"][2]["DATA_DEFAULT"] = json!(0);
    snapshot["tables"]["N_USER_TWO_FACTOR_SECRETS"]["columns"][0]["DATA_DEFAULT"] = Value::Null;
    assert!(validate_snapshot(&snapshot).is_ok());
}

#[test]
fn unknown_or_missing_ledger_checksum_never_matches_a_missing_catalog_value() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/two-factor-readiness.json"
    ))
    .unwrap();
    let mut snapshot = fixture["baseline"].clone();
    snapshot["records"] = json!([{"STEP_ID":"unknown-step", "CHECKSUM":null}]);
    assert!(validate_snapshot(&snapshot).is_err());
    snapshot["records"][0] = json!({"STEP_ID":"unknown-step"});
    assert!(validate_snapshot(&snapshot).is_err());
}

#[test]
fn shared_nuxt_readiness_cases_cover_metadata_and_checksum_drift() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/two-factor-readiness.json"
    ))
    .unwrap();
    assert_eq!(fixture["id"], "AUTH-2FA-READINESS");
    let cases = fixture["cases"].as_array().unwrap();
    assert!(cases.len() >= 30);
    for case in cases {
        let mut snapshot = fixture["baseline"].clone();
        for mutation in case["mutations"].as_array().unwrap() {
            let path = mutation["path"].as_array().unwrap();
            let mut target = &mut snapshot;
            for part in &path[..path.len() - 1] {
                target = if let Some(key) = part.as_str() {
                    target.get_mut(key).unwrap()
                } else {
                    target.get_mut(part.as_u64().unwrap() as usize).unwrap()
                };
            }
            let last = path.last().unwrap();
            match (mutation["op"].as_str().unwrap(), last.as_str()) {
                ("set", Some(key)) => {
                    target
                        .as_object_mut()
                        .unwrap()
                        .insert(key.to_owned(), mutation["value"].clone());
                }
                ("delete", Some(key)) => {
                    target.as_object_mut().unwrap().remove(key);
                }
                ("set", None) => {
                    target[last.as_u64().unwrap() as usize] = mutation["value"].clone();
                }
                ("delete", None) => {
                    target
                        .as_array_mut()
                        .unwrap()
                        .remove(last.as_u64().unwrap() as usize);
                }
                _ => panic!("unknown fixture mutation"),
            }
        }
        assert_eq!(
            validate_snapshot(&snapshot).is_ok(),
            case["ready"].as_bool().unwrap(),
            "{}",
            case["id"]
        );
    }
}

#[test]
fn collector_uses_only_parameterized_selects_and_builds_a_valid_snapshot() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/two-factor-readiness.json"
    ))
    .unwrap();
    let baseline = &fixture["baseline"];
    let mut calls = 0;
    let result = collect_with(|sql: &'static str, binds: BindMap| {
        calls += 1;
        assert!(sql.starts_with("SELECT "));
        let name = binds.get("name").or_else(|| binds.get("table_name")).and_then(|v| v.as_str()).unwrap_or("");
        if sql.contains("SYS_CONTEXT") { return Ok(vec![json!({"USER_NAME":baseline["owner"]["user"], "SCHEMA_NAME":baseline["owner"]["schema"]})]); }
        if sql.contains("FROM user_tables") { return Ok(if baseline["tables"].get(name).is_some() {vec![json!({"NAME":name})]} else {vec![]}); }
        if sql.contains("FROM user_tab_columns") { return Ok(baseline["tables"][name]["columns"].as_array().unwrap().clone()); }
        if sql.contains("FROM user_constraints c") { return Ok(baseline["tables"][name]["constraints"].as_array().unwrap().clone()); }
        if sql.contains("FROM user_cons_columns c") {
            let mut rows = Vec::new();
            for constraint in baseline["tables"][name]["constraints"].as_array().unwrap() {
                for (i, column) in constraint["columns"].as_array().unwrap().iter().enumerate() {
                    rows.push(json!({"CONSTRAINT_NAME":constraint["CONSTRAINT_NAME"], "COLUMN_NAME":column,
                        "POSITION":i+1, "REFERENCED_COLUMN":constraint["referencedColumns"].get(i)}));
                }
            }
            return Ok(rows);
        }
        if sql.contains("FROM n_schema_migrations") { return Ok(baseline["records"].as_array().unwrap().clone()); }
        if sql.contains("FROM user_sequences") { return Ok(baseline["sequences"].get(name).cloned().into_iter().collect()); }
        if sql.contains("FROM user_indexes") { return Ok(baseline["indexes"].get(name).cloned().into_iter().collect()); }
        if sql.contains("FROM user_ind_columns") { return Ok(baseline["indexes"][name]["columns"].as_array().unwrap().clone()); }
        panic!("unexpected SQL in collector");
    }).unwrap();
    assert!(calls >= 20);
    assert!(validate_snapshot(&result).is_ok());
    assert!(collect_with(|_, _| Err(DbError::SemaphoreClosed)).is_err());
}

#[test]
fn collector_rejects_mismatched_owner_before_other_queries() {
    let mut calls = 0;
    let result = collect_with(|_, _| {
        calls += 1;
        Ok(vec![json!({"USER_NAME":"OWNER", "SCHEMA_NAME":"OTHER"})])
    });
    assert!(result.is_err());
    assert_eq!(calls, 1);
}
