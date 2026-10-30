use nekotribe_backend::ai::knowledge_source::{
    hydrate, source_version, Candidate, Error, Reader, Source,
};
use serde_json::Value;
use std::cell::Cell;

struct Fake {
    source: Option<Source>,
    fail: bool,
    calls: Cell<usize>,
}
impl Reader for Fake {
    fn get(&self, viewer: i64, _: &Candidate) -> Result<Option<Source>, Error> {
        assert_eq!(viewer, 42);
        self.calls.set(self.calls.get() + 1);
        if self.fail {
            return Err(Error::Store);
        }
        Ok(self.source.clone())
    }
}
#[test]
fn database_reader_does_not_treat_terms_as_posts() {
    let reader = Fake {
        source: None,
        fail: false,
        calls: Cell::new(0),
    };
    let terms = Candidate {
        kind: "terms".into(),
        id: 3,
        version: "b".repeat(64),
    };
    assert_eq!(hydrate(&reader, 42, &[terms]), Err(Error::Invalid));
    assert_eq!(reader.calls.get(), 0);
}
#[test]
fn versions_match_shared_cross_language_vectors() {
    let root: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/ai-knowledge-source-vectors.json"
    ))
    .unwrap();
    for v in root["cases"].as_array().unwrap() {
        assert_eq!(
            source_version(
                v["kind"].as_str().unwrap(),
                v["source_id"].as_i64().unwrap(),
                v["post_id"].as_i64().unwrap(),
                v["content"].as_str().unwrap()
            ),
            v["version"].as_str().unwrap()
        );
    }
}
#[test]
fn hydration_reloads_and_rejects_stale_duplicate_and_inconsistent_sources() {
    let c = Candidate {
        kind: "post".into(),
        id: 11,
        version: source_version("post", 11, 11, "public"),
    };
    let source = Source {
        kind: "post".into(),
        id: 11,
        post_id: 11,
        content: "public".into(),
        version: String::new(),
    };
    let ok = Fake {
        source: Some(source.clone()),
        fail: false,
        calls: Cell::new(0),
    };
    let found = hydrate(&ok, 42, std::slice::from_ref(&c)).unwrap();
    assert_eq!(found[0].content, "public");
    assert_eq!(found[0].version, c.version);
    let stale = Fake {
        source: Some(Source {
            content: "edited".into(),
            ..source.clone()
        }),
        fail: false,
        calls: Cell::new(0),
    };
    assert!(hydrate(&stale, 42, std::slice::from_ref(&c))
        .unwrap()
        .is_empty());
    assert_eq!(
        hydrate(&ok, 42, &[c.clone(), c.clone()]),
        Err(Error::Invalid)
    );
    let corrupt = Fake {
        source: Some(Source {
            post_id: 12,
            ..source
        }),
        fail: false,
        calls: Cell::new(0),
    };
    assert_eq!(
        hydrate(&corrupt, 42, std::slice::from_ref(&c)),
        Err(Error::Store)
    );
    let missing = Fake {
        source: None,
        fail: false,
        calls: Cell::new(0),
    };
    assert!(hydrate(&missing, 42, std::slice::from_ref(&c))
        .unwrap()
        .is_empty());
    let fail = Fake {
        source: None,
        fail: true,
        calls: Cell::new(0),
    };
    assert_eq!(hydrate(&fail, 42, &[c]), Err(Error::Store));
}

#[test]
fn validation_happens_before_reads_and_oversized_content_is_omitted() {
    let reader = Fake {
        source: None,
        fail: false,
        calls: Cell::new(0),
    };
    let candidate = Candidate {
        kind: "post".into(),
        id: 11,
        version: "0".repeat(64),
    };
    assert_eq!(
        hydrate(&reader, 0, std::slice::from_ref(&candidate)),
        Err(Error::Invalid)
    );
    assert_eq!(
        hydrate(&reader, 42, &vec![candidate.clone(); 21]),
        Err(Error::Invalid)
    );
    assert_eq!(
        hydrate(
            &reader,
            42,
            &[Candidate {
                version: "A".repeat(64),
                ..candidate.clone()
            }]
        ),
        Err(Error::Invalid)
    );
    assert_eq!(reader.calls.get(), 0);
    assert!(serde_json::from_str::<Candidate>(&format!(
        r#"{{"kind":"post","id":11,"version":"{}","extra":"private"}}"#,
        candidate.version
    ))
    .is_err());
    let large = Fake {
        source: Some(Source {
            kind: "post".into(),
            id: 11,
            post_id: 11,
            content: "猫".repeat(21846),
            version: String::new(),
        }),
        fail: false,
        calls: Cell::new(0),
    };
    assert!(hydrate(&large, 42, &[candidate]).unwrap().is_empty());
}
