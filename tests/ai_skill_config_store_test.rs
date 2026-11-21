use nekotribe_backend::{
    ai::{
        skill_config_store::{load, Error, Reader},
        skill_selection::Scope,
    },
    db::{row::DbRow, value::DbValue},
};
use std::{
    cell::{Cell, RefCell},
    collections::BTreeMap,
};

struct Fake {
    rows: RefCell<Vec<DbRow>>,
    calls: Cell<usize>,
    fail: bool,
}
impl Reader for Fake {
    fn load(&self) -> Result<Vec<DbRow>, Error> {
        self.calls.set(self.calls.get() + 1);
        if self.fail {
            Err(Error::Unavailable)
        } else {
            Ok(self.rows.borrow().clone())
        }
    }
}
fn row(g: &str, ids: &str) -> DbRow {
    BTreeMap::from([
        ("GENERATION".into(), DbValue::String(g.into())),
        ("ENABLED_IDS".into(), DbValue::String(ids.into())),
    ])
}

#[test]
fn reloads_each_request_and_refuses_disabled_skill() {
    let reader = Fake {
        rows: RefCell::new(vec![row("2", r#"["writing-draft"]"#)]),
        calls: Cell::new(0),
        fail: false,
    };
    let a = load(&reader, 42).unwrap();
    assert_eq!(a.generation, 2);
    let scope = Scope {
        actor_id: 42,
        purpose: "writing".into(),
        group_id: None,
    };
    assert_eq!(
        a.registry.select(&scope, None, |_| Ok(())).unwrap().id,
        "writing-draft"
    );
    *reader.rows.borrow_mut() = vec![row("3", "[]")];
    let b = load(&reader, 42).unwrap();
    assert_eq!(b.generation, 3);
    assert!(b.registry.select(&scope, None, |_| Ok(())).is_err());
    assert_eq!(reader.calls.get(), 2);
    assert!(load(&reader, 0).is_err());
    assert_eq!(reader.calls.get(), 2);
}
#[test]
fn rejects_missing_corrupt_and_unavailable_configuration() {
    let valid = row("1", "[]");
    let cases = vec![
        vec![],
        vec![valid.clone(), valid],
        vec![row("0", "[]")],
        vec![row("1.5", "[]")],
        vec![row("1000000000000000", "[]")],
        vec![row("1", "null")],
        vec![row("1", r#"["unknown"]"#)],
        vec![row("1", r#"["writing-draft","writing-draft"]"#)],
        vec![row("1", &" ".repeat(513))],
        vec![row("1", "[null]")],
    ];
    for rows in cases {
        let f = Fake {
            rows: RefCell::new(rows),
            calls: Cell::new(0),
            fail: false,
        };
        assert!(matches!(load(&f, 42), Err(Error::Unavailable)));
    }
    let f = Fake {
        rows: RefCell::new(vec![]),
        calls: Cell::new(0),
        fail: true,
    };
    assert!(matches!(load(&f, 42), Err(Error::Unavailable)));
}
