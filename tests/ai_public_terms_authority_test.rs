use nekotribe_backend::{
    ai::public_terms_authority::{catalog_digest, read, Authority, Error, Reader},
    db::{row::DbRow, value::DbValue},
};
use serde_json::Value;
use std::cell::Cell;

fn catalog() -> Value {
    serde_json::from_str(include_str!(
        "../contracts/requirements/ai-public-terms-catalog.json"
    ))
    .unwrap()
}
fn digest() -> String {
    let v: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/ai-public-terms-source-vectors.json"
    ))
    .unwrap();
    v["catalog_digest"].as_str().unwrap().into()
}
struct Fake {
    rows: Vec<DbRow>,
    fail: bool,
    calls: Cell<usize>,
}
impl Reader for Fake {
    fn load(&self) -> Result<Vec<DbRow>, Error> {
        self.calls.set(self.calls.get() + 1);
        if self.fail {
            Err(Error::Unavailable)
        } else {
            Ok(self.rows.clone())
        }
    }
}
fn row(d: &str, g: &str, e: &str) -> DbRow {
    DbRow::from([
        ("CATALOG_DIGEST".into(), DbValue::String(d.into())),
        ("GENERATION".into(), DbValue::String(g.into())),
        ("ENABLED".into(), DbValue::String(e.into())),
    ])
}

#[test]
fn digest_matches_shared_vector_and_detects_changes() {
    let original = catalog();
    let expected = digest();
    assert_eq!(catalog_digest(&original).unwrap(), expected);
    let mut reordered = original.clone();
    reordered["documents"].as_array_mut().unwrap().reverse();
    assert_eq!(catalog_digest(&reordered).unwrap(), expected);
    reordered["documents"][0]["title"] = "updated title".into();
    assert_ne!(catalog_digest(&reordered).unwrap(), expected);
    assert!(catalog_digest(&serde_json::json!({})).is_err());
}
#[test]
fn only_current_enabled_singleton_can_be_used() {
    let d = digest();
    let valid = row(&d, "7", "1");
    let reader = Fake {
        rows: vec![valid.clone()],
        fail: false,
        calls: Cell::new(0),
    };
    assert_eq!(
        read(&reader, 42, &catalog()),
        Ok(Authority {
            digest: d.clone(),
            generation: 7
        })
    );
    assert_eq!(read(&reader, 42, &catalog()).unwrap().generation, 7);
    assert_eq!(reader.calls.get(), 2);
    assert_eq!(read(&reader, 0, &catalog()), Err(Error::InvalidViewer));
    assert_eq!(reader.calls.get(), 2);
    let cases = vec![
        vec![],
        vec![valid.clone(), valid],
        vec![row(&d, "7", "0")],
        vec![row(&"0".repeat(64), "7", "1")],
        vec![row(&d, "0", "1")],
        vec![row(&d, "1.5", "1")],
        vec![row(&d, "1000000000000000", "1")],
        vec![row(&d, "7", "1.5")],
    ];
    for rows in cases {
        let f = Fake {
            rows,
            fail: false,
            calls: Cell::new(0),
        };
        assert_eq!(read(&f, 42, &catalog()), Err(Error::Unavailable));
    }
    let f = Fake {
        rows: vec![],
        fail: true,
        calls: Cell::new(0),
    };
    assert_eq!(read(&f, 42, &catalog()), Err(Error::Unavailable));
}
