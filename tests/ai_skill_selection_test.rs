use nekotribe_backend::ai::skill_selection::{Error, Registry, Scope};
use serde::Deserialize;
use std::cell::Cell;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Case {
    id: String,
    enabled: Vec<String>,
    purpose: String,
    group_id: Option<i64>,
    skill_id: Option<String>,
    allowed: bool,
    expected: Option<String>,
    selection: Option<String>,
    error: Option<bool>,
}
#[test]
fn shared_selection_vectors_validate_scope_enablement_and_authorization() {
    let doc: serde_json::Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/ai-skill-selection-vectors.json"
    ))
    .unwrap();
    let cases: Vec<Case> = serde_json::from_value(doc["cases"].clone()).unwrap();
    for item in cases {
        let reg = Registry::new(&item.enabled);
        if item.error.unwrap_or(false) && reg.is_err() {
            continue;
        }
        let reg = reg.unwrap();
        let calls = Cell::new(0);
        let scope = Scope {
            actor_id: 7,
            purpose: item.purpose.clone(),
            group_id: item.group_id,
        };
        let result = reg.select(&scope, item.skill_id.as_deref(), |checked| {
            calls.set(calls.get() + 1);
            assert_eq!(checked, &scope);
            if item.allowed {
                Ok(())
            } else {
                Err(Error::Unavailable)
            }
        });
        if item.error.unwrap_or(false) {
            assert!(result.is_err(), "{}", item.id)
        } else {
            let out = result.unwrap();
            assert_eq!(out.id, item.expected.unwrap(), "{}", item.id);
            assert_eq!(out.version, 1);
            assert_eq!(out.selection, item.selection.unwrap());
            assert_eq!(calls.get(), 1)
        }
    }
}
#[test]
fn every_request_rechecks_permission_and_returns_owned_snapshot() {
    let mut enabled = vec!["group-brief".into()];
    let reg = Registry::new(&enabled).unwrap();
    enabled[0] = "writing-draft".into();
    let scope = Scope {
        actor_id: 7,
        purpose: "group".into(),
        group_id: Some(42),
    };
    let calls = Cell::new(0);
    let mut first = reg
        .select(&scope, None, |_| {
            calls.set(calls.get() + 1);
            Ok(())
        })
        .unwrap();
    first.tools.push("publish".into());
    let second = reg
        .select(&scope, None, |_| {
            calls.set(calls.get() + 1);
            Ok(())
        })
        .unwrap();
    assert!(!second.tools.contains(&"publish".into()));
    assert_eq!(calls.get(), 2);
    assert_eq!(
        reg.select(&scope, None, |_| Err(Error::Unavailable)),
        Err(Error::Unavailable)
    );
}
