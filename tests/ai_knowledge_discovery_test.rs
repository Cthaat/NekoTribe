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
    assert_eq!(f.calls.get(), 2);
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
