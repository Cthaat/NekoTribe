use nekotribe_backend::ai::public_terms_source::{discover, hydrate, parse, Reference};
use serde_json::Value;

fn catalog() -> Value {
    serde_json::from_str(include_str!(
        "../contracts/requirements/ai-public-terms-catalog.json"
    ))
    .unwrap()
}
#[test]
fn matches_shared_versions_and_queries() {
    let vectors: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/ai-public-terms-source-vectors.json"
    ))
    .unwrap();
    let catalog = parse(&catalog()).unwrap();
    for (row, expected) in catalog.iter().zip(vectors["versions"].as_array().unwrap()) {
        assert_eq!(row.id, expected["id"].as_i64().unwrap());
        assert_eq!(row.version, expected["version"].as_str().unwrap())
    }
    for item in vectors["searches"].as_array().unwrap() {
        let found = discover(
            &catalog,
            item["query"].as_str().unwrap(),
            item["limit"].as_u64().unwrap() as usize,
        )
        .unwrap();
        let ids: Vec<_> = found.iter().map(|s| s.id).collect();
        let expected: Vec<_> = item["ids"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_i64().unwrap())
            .collect();
        assert_eq!(ids, expected)
    }
}
#[test]
fn fails_closed_and_returns_owned_results() {
    let input = catalog();
    let catalog = parse(&input).unwrap();
    let mut found = discover(&catalog, "账户", 20).unwrap();
    let reference = Reference {
        kind: "terms".into(),
        id: found[0].id,
        version: found[0].version.clone(),
    };
    found[0].blocks[0] = "changed".into();
    let restored = hydrate(&catalog, std::slice::from_ref(&reference)).unwrap();
    assert_ne!(restored[0].blocks[0], "changed");
    assert!(hydrate(&catalog, &[reference.clone(), reference]).is_err());
    let old = Reference {
        kind: "terms".into(),
        id: catalog[1].id,
        version: catalog[1].version.clone(),
    };
    let mut updated = input.clone();
    updated["documents"][1]["blocks"][0] = Value::String("updated".into());
    assert!(hydrate(&parse(&updated).unwrap(), &[old])
        .unwrap()
        .is_empty());
    for query in ["", "\0", &"x".repeat(257)] {
        assert!(discover(&catalog, query, 10).is_err());
    }
    let mut bad = input;
    bad["documents"][0]["href"] = Value::String("https://invalid".into());
    assert!(parse(&bad).is_err());
}
