use nekotribe_backend::{
    auth::{
        session_repository::{OracleSessions, SessionExecutor},
        sessions::{SessionRepository, SessionStoreError, StoreFuture},
    },
    db::{
        oracle::{BindMap, DbError},
        row::DbRow,
        value::DbValue,
    },
    posts::{
        create_request::PostCreateInput,
        create_transaction::{run, PostCreateTransaction, PostCreation},
    },
};
use std::{
    cell::{Cell, RefCell},
    collections::{BTreeMap, BTreeSet},
};

#[derive(Clone, Debug, Default, PartialEq)]
struct State {
    posts: BTreeSet<u64>,
    media: Vec<f64>,
    tags: BTreeMap<String, String>,
    post_tags: BTreeSet<String>,
    mentions: Vec<f64>,
}

struct MemoryTransaction {
    persisted: RefCell<State>,
    pending: RefCell<State>,
    calls: RefCell<Vec<(String, BindMap)>>,
    events: RefCell<Vec<&'static str>>,
    source_exists: bool,
    source_deleted: bool,
    source_visible: bool,
    source_changes: bool,
    media: Vec<(f64, u64, &'static str)>,
    fail_at: Option<&'static str>,
    fail_commit: bool,
    commit_applies_before_failure: bool,
    fail_rollback: bool,
    sequences: Cell<usize>,
}

impl Default for MemoryTransaction {
    fn default() -> Self {
        Self {
            persisted: RefCell::default(),
            pending: RefCell::default(),
            calls: RefCell::default(),
            events: RefCell::default(),
            source_exists: true,
            source_deleted: false,
            source_visible: true,
            source_changes: false,
            media: vec![(1.0, 42, "ready"), (2.0, 42, "uploaded")],
            fail_at: None,
            fail_commit: false,
            commit_applies_before_failure: false,
            fail_rollback: false,
            sequences: Cell::new(0),
        }
    }
}

fn integer(binds: &BindMap, name: &str) -> u64 {
    u64::try_from(binds[name].as_i64().unwrap()).unwrap()
}
fn decimal(binds: &BindMap, name: &str) -> f64 {
    let DbValue::F64(value) = binds[name] else {
        panic!("{name} must retain its float binding")
    };
    value
}

impl PostCreateTransaction for MemoryTransaction {
    fn query(&self, sql: &str, binds: BindMap) -> Result<Vec<DbRow>, DbError> {
        self.calls.borrow_mut().push((sql.to_owned(), binds));
        if sql.contains("seq_post_id") {
            self.sequences.set(self.sequences.get() + 1);
            return Ok(vec![DbRow::from([("ID".into(), DbValue::I64(100))])]);
        }
        assert!(sql.contains("p.is_deleted=0") && sql.contains("fn_can_view_post"));
        Ok(
            if self.source_exists && !self.source_deleted && self.source_visible {
                vec![DbRow::from([("POST_ID".into(), DbValue::I64(7))])]
            } else {
                vec![]
            },
        )
    }

    fn execute(&self, sql: &str, binds: BindMap) -> Result<u64, DbError> {
        self.calls
            .borrow_mut()
            .push((sql.to_owned(), binds.clone()));
        if self.fail_at.is_some_and(|step| sql.starts_with(step)) {
            return Err(DbError::SchemaNotReady);
        }
        let mut pending = self.pending.borrow_mut();
        if sql.starts_with("INSERT INTO n_posts ") {
            assert_eq!(integer(&binds, "author_id"), 42);
            if binds.contains_key("source_post_id") {
                assert!(
                    sql.contains("p.is_deleted=0")
                        && sql.contains("fn_can_view_post(:author_id,p.post_id)=1")
                );
                if self.source_changes {
                    return Ok(0);
                }
            }
            pending.posts.insert(integer(&binds, "post_id"));
        } else if sql.starts_with("INSERT INTO n_post_media ") {
            assert!(
                sql.contains("owner_user_id=:user_id")
                    && sql.contains("status IN ('uploaded','processing','ready')")
            );
            let id = decimal(&binds, "media_id");
            let available = self.media.iter().any(|(asset, owner, status)| {
                *asset == id
                    && *owner == integer(&binds, "user_id")
                    && matches!(*status, "uploaded" | "processing" | "ready")
            });
            if !available {
                return Ok(0);
            }
            assert_eq!(
                integer(&binds, "sort_order") as usize,
                pending.media.len() + 1
            );
            pending.media.push(id);
        } else if sql.starts_with("MERGE INTO n_tags ") {
            let name = binds["name"].as_str().unwrap();
            pending
                .tags
                .entry(name.to_lowercase())
                .or_insert_with(|| name.to_owned());
        } else if sql.starts_with("INSERT INTO n_post_tags ") {
            assert!(sql.contains("NOT EXISTS") && sql.contains("LOWER(:name)"));
            pending
                .post_tags
                .insert(binds["name"].as_str().unwrap().to_lowercase());
        } else if sql.starts_with("INSERT INTO n_post_mentions ") {
            assert!(
                sql.contains("FROM n_users WHERE user_id=:user_id") && sql.contains("NOT EXISTS")
            );
            pending.mentions.push(decimal(&binds, "user_id"));
        } else {
            panic!("unexpected write: {sql}");
        }
        assert!(
            self.persisted.borrow().posts.is_empty(),
            "writes must remain isolated before commit"
        );
        Ok(1)
    }

    fn commit(&self) -> Result<(), DbError> {
        self.events.borrow_mut().push("commit");
        if !self.fail_commit || self.commit_applies_before_failure {
            *self.persisted.borrow_mut() = self.pending.borrow().clone();
        }
        if self.fail_commit {
            Err(DbError::SchemaNotReady)
        } else {
            Ok(())
        }
    }
    fn rollback(&self) -> Result<(), DbError> {
        self.events.borrow_mut().push("rollback");
        if self.fail_rollback {
            return Err(DbError::SemaphoreClosed);
        }
        *self.pending.borrow_mut() = self.persisted.borrow().clone();
        Ok(())
    }
}

fn input() -> PostCreateInput {
    PostCreateInput {
        content: " hello ".into(),
        visibility: "public".into(),
        location: "".into(),
        media_ids: vec![],
        tag_names: vec![],
        mention_user_ids: vec![],
        reply_to_post_id: None,
        repost_of_post_id: None,
        quoted_post_id: None,
    }
}

#[test]
fn commits_post_media_new_tags_and_mentions_once() {
    let tx = MemoryTransaction::default();
    let mut data = input();
    data.reply_to_post_id = Some(7);
    data.media_ids = vec![1.0, 2.0];
    data.tag_names = vec!["#Rust".into(), "rust".into(), "开发".into()];
    data.mention_user_ids = vec![8.0, 9.0];
    assert_eq!(run(&tx, 42, &data).unwrap(), PostCreation::Created(100));
    let state = tx.persisted.borrow();
    assert_eq!(state.posts, BTreeSet::from([100]));
    assert_eq!(state.media, vec![1.0, 2.0]);
    assert_eq!(
        state.tags,
        BTreeMap::from([
            ("rust".into(), "Rust".into()),
            ("开发".into(), "开发".into())
        ])
    );
    assert_eq!(
        state.post_tags,
        BTreeSet::from(["rust".into(), "开发".into()])
    );
    assert_eq!(state.mentions, vec![8.0, 9.0]);
    assert_eq!(*tx.events.borrow(), ["commit"]);
}

#[test]
fn missing_deleted_or_invisible_reference_never_allocates_a_post_id() {
    for tx in [
        MemoryTransaction {
            source_exists: false,
            ..Default::default()
        },
        MemoryTransaction {
            source_deleted: true,
            ..Default::default()
        },
        MemoryTransaction {
            source_visible: false,
            ..Default::default()
        },
    ] {
        for reference in 0..3 {
            let mut data = input();
            match reference {
                0 => data.reply_to_post_id = Some(7),
                1 => data.repost_of_post_id = Some(7),
                _ => data.quoted_post_id = Some(7),
            }
            assert_eq!(
                run(&tx, 42, &data).unwrap(),
                PostCreation::ReferenceUnavailable
            );
            assert_eq!(tx.sequences.get(), 0);
            assert!(tx.events.borrow().is_empty());
            assert!(tx.persisted.borrow().posts.is_empty());
        }
    }
}

#[test]
fn changing_reference_visibility_rolls_back_without_creating_relations() {
    let tx = MemoryTransaction {
        source_changes: true,
        ..Default::default()
    };
    let mut data = input();
    data.quoted_post_id = Some(7);
    data.media_ids = vec![1.0];
    assert_eq!(
        run(&tx, 42, &data).unwrap(),
        PostCreation::ReferenceUnavailable
    );
    assert_eq!(tx.sequences.get(), 1);
    assert_eq!(*tx.events.borrow(), ["rollback"]);
    assert_eq!(*tx.persisted.borrow(), State::default());
    assert_eq!(*tx.pending.borrow(), State::default());
}

#[test]
fn every_selected_media_must_exist_be_owned_and_have_an_accepted_status() {
    for media in [vec![], vec![(2.0, 9, "ready")], vec![(2.0, 42, "deleted")]] {
        let tx = MemoryTransaction {
            media: [(1.0, 42, "ready")].into_iter().chain(media).collect(),
            ..Default::default()
        };
        let mut data = input();
        data.content.clear();
        data.media_ids = vec![1.0, 2.0];
        data.tag_names = vec!["must-not-survive".into()];
        assert_eq!(run(&tx, 42, &data).unwrap(), PostCreation::MediaUnavailable);
        assert_eq!(*tx.events.borrow(), ["rollback"]);
        assert_eq!(*tx.persisted.borrow(), State::default());
        assert_eq!(*tx.pending.borrow(), State::default());
    }
}

#[test]
fn every_write_failure_rolls_back_all_preceding_changes() {
    for fail_at in [
        "INSERT INTO n_posts ",
        "INSERT INTO n_post_media ",
        "MERGE INTO n_tags ",
        "INSERT INTO n_post_tags ",
        "INSERT INTO n_post_mentions ",
    ] {
        let tx = MemoryTransaction {
            fail_at: Some(fail_at),
            ..Default::default()
        };
        let mut data = input();
        data.media_ids = vec![1.0];
        data.tag_names = vec!["new tag".into()];
        data.mention_user_ids = vec![9.0];
        assert!(run(&tx, 42, &data).is_err(), "{fail_at}");
        assert_eq!(*tx.events.borrow(), ["rollback"]);
        assert_eq!(*tx.persisted.borrow(), State::default());
        assert_eq!(*tx.pending.borrow(), State::default());
    }
}

#[test]
fn rollback_failure_overrides_business_outcomes_and_commit_failure_is_uncertain() {
    let tx = MemoryTransaction {
        fail_rollback: true,
        ..Default::default()
    };
    let mut data = input();
    data.media_ids = vec![999.0];
    assert!(matches!(run(&tx, 42, &data), Err(DbError::SemaphoreClosed)));
    assert_eq!(*tx.events.borrow(), ["rollback"]);
    for applied in [false, true] {
        let tx = MemoryTransaction {
            fail_commit: true,
            commit_applies_before_failure: applied,
            ..Default::default()
        };
        assert!(run(&tx, 42, &input()).is_err());
        assert_eq!(tx.persisted.borrow().posts.contains(&100), applied);
        assert_eq!(
            tx.events
                .borrow()
                .iter()
                .filter(|event| **event == "commit")
                .count(),
            1
        );
    }
}

#[test]
fn numeric_relations_deduplicate_before_limits_and_bind_exact_floats() {
    let ids = vec![1.5, 1.5, 9_007_199_254_740_992.0, -2.0, 0.0, 88.0];
    let tx = MemoryTransaction {
        media: ids.iter().map(|id| (*id, 42, "processing")).collect(),
        ..Default::default()
    };
    let mut data = input();
    data.media_ids = ids;
    data.mention_user_ids = vec![1.5, 1.5, -2.0, 0.0, -0.0, 9_007_199_254_740_992.0];
    data.mention_user_ids.extend((1..=70).map(f64::from));
    assert_eq!(run(&tx, 42, &data).unwrap(), PostCreation::Created(100));
    let state = tx.persisted.borrow();
    assert_eq!(state.media, [1.5, 9_007_199_254_740_992.0, -2.0, 0.0]);
    assert_eq!(state.mentions.len(), 50);
    assert_eq!(
        &state.mentions[..4],
        [1.5, -2.0, 0.0, 9_007_199_254_740_992.0]
    );
    assert_eq!(state.mentions[49], 46.0);
}

#[test]
fn tags_remove_only_one_hash_use_js_trim_and_limit_case_sensitive_unique_values() {
    let tx = MemoryTransaction::default();
    let mut data = input();
    data.tag_names = vec![
        "\u{feff}# Rust \u{feff}".into(),
        "Rust".into(),
        "rust".into(),
        "##double".into(),
        "#".into(),
        "\u{0085}".into(),
    ];
    data.tag_names.extend((0..30).map(|i| format!("tag{i}")));
    assert_eq!(run(&tx, 42, &data).unwrap(), PostCreation::Created(100));
    let calls = tx.calls.borrow();
    let tags: Vec<&str> = calls
        .iter()
        .filter(|(sql, _)| sql.starts_with("MERGE INTO n_tags "))
        .map(|(_, binds)| binds["name"].as_str().unwrap())
        .collect();
    assert_eq!(tags.len(), 20);
    assert_eq!(&tags[..4], ["Rust", "rust", "#double", "\u{0085}"]);
    assert_eq!(tags[19], "tag15");
    assert_eq!(tx.persisted.borrow().tags.len(), 19);
}

#[test]
fn empty_repost_and_media_only_post_are_allowed_but_other_empty_inputs_are_rejected() {
    let mut empty = input();
    empty.content = "\u{feff} \n".into();
    let tx = MemoryTransaction::default();
    assert_eq!(run(&tx, 42, &empty).unwrap(), PostCreation::ContentEmpty);
    assert!(tx.calls.borrow().is_empty());
    for repost in [false, true] {
        let tx = MemoryTransaction::default();
        let mut data = input();
        data.content.clear();
        if repost {
            data.repost_of_post_id = Some(7)
        } else {
            data.media_ids = vec![1.0]
        }
        assert_eq!(run(&tx, 42, &data).unwrap(), PostCreation::Created(100));
        let calls = tx.calls.borrow();
        let (_, binds) = calls
            .iter()
            .find(|(sql, _)| sql.starts_with("INSERT INTO n_posts "))
            .unwrap();
        assert_eq!(binds["content"], DbValue::Null);
        assert_eq!(binds["location"], DbValue::Null);
        assert_eq!(
            binds["post_type"],
            DbValue::String(if repost { "repost" } else { "post" }.into())
        );
    }
}

#[test]
fn invalid_internal_inputs_are_rejected_before_database_access() {
    let mut cases = vec![(0, input()), (9_007_199_254_740_992, input())];
    let mut conflicting = input();
    conflicting.reply_to_post_id = Some(7);
    conflicting.quoted_post_id = Some(8);
    cases.push((42, conflicting));
    for id in [0, 9_007_199_254_740_992] {
        let mut data = input();
        data.repost_of_post_id = Some(id);
        cases.push((42, data));
    }
    let mut bad_visibility = input();
    bad_visibility.visibility = " public ".into();
    cases.push((42, bad_visibility));
    for (actor, data) in cases {
        let tx = MemoryTransaction::default();
        assert_eq!(run(&tx, actor, &data).unwrap(), PostCreation::Invalid);
        assert!(tx.calls.borrow().is_empty());
    }
}

#[derive(Default)]
struct AtomicExecutor {
    calls: std::sync::Mutex<Vec<(u64, PostCreateInput)>>,
}

impl SessionExecutor for AtomicExecutor {
    fn create_post_atomic<'a>(
        &'a self,
        actor: u64,
        input: &'a PostCreateInput,
    ) -> StoreFuture<'a, PostCreation> {
        self.calls.lock().unwrap().push((actor, input.clone()));
        Box::pin(async { Ok(PostCreation::Created(100)) })
    }
    fn execute(&self, _: &'static str, _: BindMap) -> StoreFuture<'_, u64> {
        panic!("atomic creation must not use independently committed executor writes")
    }
    fn query(&self, _: &'static str, _: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
        panic!("atomic creation must not query through a second connection")
    }
    fn preflight(&self, _: &'static str) -> StoreFuture<'_, ()> {
        panic!("atomic creation must not invoke an unrelated preflight")
    }
}

#[tokio::test]
async fn oracle_sessions_delegates_the_entire_input_to_one_atomic_executor() {
    let repository = OracleSessions {
        executor: AtomicExecutor::default(),
    };
    let mut data = input();
    data.quoted_post_id = Some(7);
    data.media_ids = vec![1.5, 1.5];
    data.mention_user_ids = vec![2.5];
    data.tag_names = vec!["#Tag".into()];
    data.location = "  place  ".into();
    assert_eq!(
        repository.create_post_atomic(42, &data).await.unwrap(),
        PostCreation::Created(100)
    );
    let calls = repository.executor.calls.lock().unwrap();
    assert_eq!(calls.len(), 1);
    let (actor, actual) = &calls[0];
    assert_eq!(*actor, 42);
    assert_eq!(actual.content, data.content);
    assert_eq!(actual.visibility, data.visibility);
    assert_eq!(actual.location, data.location);
    assert_eq!(actual.media_ids, data.media_ids);
    assert_eq!(actual.tag_names, data.tag_names);
    assert_eq!(actual.mention_user_ids, data.mention_user_ids);
    assert_eq!(actual.quoted_post_id, data.quoted_post_id);
    assert_eq!(actual.reply_to_post_id, None);
    assert_eq!(actual.repost_of_post_id, None);
}

struct UnsupportedExecutor;

impl SessionExecutor for UnsupportedExecutor {
    fn execute(&self, _: &'static str, _: BindMap) -> StoreFuture<'_, u64> {
        panic!("missing transaction support must fail safely")
    }
    fn preflight(&self, _: &'static str) -> StoreFuture<'_, ()> {
        Box::pin(async { Err(SessionStoreError) })
    }
}

#[tokio::test]
async fn executor_without_atomic_support_returns_a_store_error() {
    let repository = OracleSessions {
        executor: UnsupportedExecutor,
    };
    assert!(repository.create_post_atomic(42, &input()).await.is_err());
}

#[test]
fn content_location_and_each_reference_remain_parameterized() {
    for kind in ["reply", "repost", "quote"] {
        let tx = MemoryTransaction::default();
        let mut data = input();
        data.content = "  ';DROP TABLE n_posts;--  ".into();
        data.location = "  \t ".into();
        match kind {
            "reply" => data.reply_to_post_id = Some(7),
            "repost" => data.repost_of_post_id = Some(7),
            _ => data.quoted_post_id = Some(7),
        }
        assert_eq!(run(&tx, 42, &data).unwrap(), PostCreation::Created(100));
        let calls = tx.calls.borrow();
        let (sql, binds) = calls
            .iter()
            .find(|(sql, _)| sql.starts_with("INSERT INTO n_posts "))
            .unwrap();
        assert!(!sql.contains("DROP TABLE"));
        assert!(sql.contains(",'zh',"));
        assert_eq!(binds["content"], DbValue::String(data.content));
        assert_eq!(binds["location"], DbValue::String(data.location));
        assert_eq!(binds["post_type"], DbValue::String(kind.into()));
        assert_eq!(binds["source_post_id"], DbValue::I64(7));
    }
}
