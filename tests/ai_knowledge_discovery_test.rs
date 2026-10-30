use nekotribe_backend::ai::knowledge_source::{
    discover, source_version, DiscoveryReader, Error, Source,
};
use std::cell::Cell;

struct Fake {
    calls: Cell<usize>,
    corrupt: bool,
}
impl DiscoveryReader for Fake {
    fn search(
        &self,
        viewer: i64,
        kind: &str,
        term: &str,
        limit: usize,
    ) -> Result<Vec<Source>, Error> {
        self.calls.set(self.calls.get() + 1);
        assert_eq!((viewer, term, limit), (42, "猫", 2));
        if kind == "terms" {
            return Ok(vec![]);
        }
        let id = if kind == "post" { 11 } else { 21 };
        let post_id = if self.corrupt { 12 } else { 11 };
        Ok(vec![Source {
            kind: kind.into(),
            id,
            post_id,
            content: format!("{kind}猫"),
            version: String::new(),
        }])
    }
}
#[test]
fn interleaves_sources_and_calculates_current_version() {
    let f = Fake {
        calls: Cell::new(0),
        corrupt: false,
    };
    let result = discover(&f, 42, "\u{feff}猫 ", 2).unwrap();
    assert_eq!(
        result.iter().map(|x| x.id).collect::<Vec<_>>(),
        vec![11, 21]
    );
    assert_eq!(
        result[1].version,
        source_version("comment", 21, 11, "comment猫")
    );
    assert_eq!(f.calls.get(), 3);
}

struct TermsAuth {
    enabled: Cell<bool>,
    digest: String,
}
impl nekotribe_backend::ai::public_terms_authority::Reader for TermsAuth {
    fn load(
        &self,
    ) -> Result<
        Vec<nekotribe_backend::db::row::DbRow>,
        nekotribe_backend::ai::public_terms_authority::Error,
    > {
        use nekotribe_backend::db::{row::DbRow, value::DbValue};
        Ok(vec![DbRow::from([
            (
                "CATALOG_DIGEST".into(),
                DbValue::String(self.digest.clone()),
            ),
            ("GENERATION".into(), DbValue::String("1".into())),
            (
                "ENABLED".into(),
                DbValue::String(if self.enabled.get() { "1" } else { "0" }.into()),
            ),
        ])])
    }
}
struct Mixed {
    auth: TermsAuth,
    catalog: serde_json::Value,
}
impl DiscoveryReader for Mixed {
    fn search(
        &self,
        viewer: i64,
        kind: &str,
        term: &str,
        limit: usize,
    ) -> Result<Vec<Source>, Error> {
        if kind == "terms" {
            nekotribe_backend::ai::knowledge_source::discover_terms_sources(
                &self.auth,
                viewer,
                term,
                limit,
                &self.catalog,
            )
        } else {
            let id = if kind == "post" { 11 } else { 21 };
            Ok(vec![Source {
                kind: kind.into(),
                id,
                post_id: 11,
                content: "账户内容".into(),
                version: String::new(),
            }])
        }
    }
}
#[test]
fn rules_interleave_with_posts_and_comments_only_under_current_authority() {
    let catalog = serde_json::from_str(include_str!(
        "../contracts/requirements/ai-public-terms-catalog.json"
    ))
    .unwrap();
    let vectors: serde_json::Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/ai-public-terms-source-vectors.json"
    ))
    .unwrap();
    let f = Mixed {
        auth: TermsAuth {
            enabled: Cell::new(true),
            digest: vectors["catalog_digest"].as_str().unwrap().into(),
        },
        catalog,
    };
    let rows = discover(&f, 42, "账户", 3).unwrap();
    assert_eq!(
        rows.iter().map(|r| r.kind.as_str()).collect::<Vec<_>>(),
        vec!["post", "comment", "terms"]
    );
    assert_eq!(rows[2].id, 2);
    assert_eq!(rows[2].post_id, 0);
    assert_eq!(
        rows[2].version,
        vectors["versions"][1]["version"].as_str().unwrap()
    );
    f.auth.enabled.set(false);
    assert_eq!(discover(&f, 42, "账户", 3), Err(Error::Store));
}

#[derive(serde::Deserialize)]
struct VectorCase {
    id: String,
    query: String,
    limit: usize,
    posts: Vec<i64>,
    comments: Vec<i64>,
    authority: String,
    expected: Option<Vec<String>>,
    error: Option<bool>,
}
struct VectorReader {
    item: VectorCase,
    auth: TermsAuth,
    catalog: serde_json::Value,
}
impl DiscoveryReader for VectorReader {
    fn search(
        &self,
        viewer: i64,
        kind: &str,
        term: &str,
        limit: usize,
    ) -> Result<Vec<Source>, Error> {
        if kind == "terms" {
            return nekotribe_backend::ai::knowledge_source::discover_terms_sources(
                &self.auth,
                viewer,
                term,
                limit,
                &self.catalog,
            );
        }
        let ids = if kind == "post" {
            &self.item.posts
        } else {
            &self.item.comments
        };
        Ok(ids
            .iter()
            .take(limit)
            .map(|id| Source {
                kind: kind.into(),
                id: *id,
                post_id: if kind == "post" { *id } else { 11 },
                content: format!("{term} {id}"),
                version: String::new(),
            })
            .collect())
    }
}
#[test]
fn shared_three_backend_discovery_order_vectors() {
    let doc: serde_json::Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/ai-knowledge-discovery-order.json"
    ))
    .unwrap();
    let cases: Vec<VectorCase> = serde_json::from_value(doc["cases"].clone()).unwrap();
    let catalog: serde_json::Value = serde_json::from_str(include_str!(
        "../contracts/requirements/ai-public-terms-catalog.json"
    ))
    .unwrap();
    let vector: serde_json::Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/ai-public-terms-source-vectors.json"
    ))
    .unwrap();
    for item in cases {
        let reader = VectorReader {
            auth: TermsAuth {
                enabled: Cell::new(item.authority == "enabled"),
                digest: vector["catalog_digest"].as_str().unwrap().into(),
            },
            catalog: catalog.clone(),
            item,
        };
        let result = discover(&reader, 42, &reader.item.query, reader.item.limit);
        if reader.item.error.unwrap_or(false) {
            assert!(result.is_err(), "{}", reader.item.id)
        } else {
            let got: Vec<_> = result
                .unwrap()
                .iter()
                .map(|r| format!("{}:{}", r.kind, r.id))
                .collect();
            assert_eq!(
                got,
                reader.item.expected.clone().unwrap(),
                "{}",
                reader.item.id
            )
        }
    }
}
#[test]
fn invalid_requests_do_not_read_and_corrupt_sources_fail_closed() {
    let f = Fake {
        calls: Cell::new(0),
        corrupt: false,
    };
    for (viewer, term, limit) in [
        (0, "猫".to_owned(), 2),
        (42, "".to_owned(), 2),
        (42, "a\0b".to_owned(), 2),
        (42, "x".repeat(257), 2),
        (42, "猫".to_owned(), 0),
        (42, "猫".to_owned(), 21),
    ] {
        assert_eq!(discover(&f, viewer, &term, limit), Err(Error::Invalid));
    }
    assert_eq!(f.calls.get(), 0);
    let bad = Fake {
        calls: Cell::new(0),
        corrupt: true,
    };
    assert_eq!(discover(&bad, 42, "猫", 2), Err(Error::Store));
}
