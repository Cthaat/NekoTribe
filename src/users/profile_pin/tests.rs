use super::*;
use crate::db::row::DbRow;
use std::{cell::RefCell, collections::VecDeque};

enum Step<'a> {
    Query(&'a str, BindMap, Vec<DbRow>),
    Write(&'a str, BindMap, u64),
    Commit,
    Rollback,
}

struct Script<'a>(RefCell<VecDeque<Step<'a>>>);

impl<'a> Script<'a> {
    fn new(steps: impl Into<VecDeque<Step<'a>>>) -> Self {
        Self(RefCell::new(steps.into()))
    }
    fn done(&self) {
        assert!(self.0.borrow().is_empty());
    }
}

impl Transaction for Script<'_> {
    fn query(&self, sql: &str, binds: BindMap) -> Result<Vec<DbRow>, DbError> {
        let Some(Step::Query(expected, expected_binds, rows)) = self.0.borrow_mut().pop_front()
        else {
            panic!("unexpected query {sql}");
        };
        assert_eq!((sql, binds), (expected, expected_binds));
        Ok(rows)
    }

    fn execute(&self, sql: &str, binds: BindMap) -> Result<u64, DbError> {
        let Some(Step::Write(expected, expected_binds, changed)) = self.0.borrow_mut().pop_front()
        else {
            panic!("unexpected write {sql}");
        };
        assert_eq!((sql, binds), (expected, expected_binds));
        Ok(changed)
    }

    fn commit(&self) -> Result<(), DbError> {
        assert!(matches!(
            self.0.borrow_mut().pop_front(),
            Some(Step::Commit)
        ));
        Ok(())
    }

    fn rollback(&self) -> Result<(), DbError> {
        assert!(matches!(
            self.0.borrow_mut().pop_front(),
            Some(Step::Rollback)
        ));
        Ok(())
    }
}

#[test]
fn owner_lock_serializes_merge_and_clear_and_rejects_unreadable_posts() {
    let sql = sql();
    assert!(sql.owner.ends_with("FOR UPDATE"));
    assert!(sql
        .eligible
        .contains("p.author_id=:user_id AND p.is_deleted=0"));
    assert!(sql
        .eligible
        .contains("fn_can_view_post(:user_id,p.post_id)=1"));
    assert!(sql.eligible.ends_with("FOR UPDATE OF p.post_id"));
    let actor = BindMap::from([number("user_id", 42)]);
    let owner = || Step::Query(&sql.owner, actor.clone(), vec![DbRow::new()]);
    for id in [7, 8] {
        let post = BindMap::from([number("user_id", 42), number("post_id", id)]);
        let tx = Script::new([
            owner(),
            Step::Query(&sql.eligible, post.clone(), vec![DbRow::new()]),
            Step::Write(&sql.write, post, 1),
            Step::Commit,
        ]);
        assert_eq!(run(&tx, 42, Operation::Set(id)).unwrap(), Outcome::Set(id));
        tx.done();
    }
    let post = BindMap::from([number("user_id", 42), number("post_id", 9)]);
    let tx = Script::new([
        owner(),
        Step::Query(&sql.eligible, post, vec![]),
        Step::Rollback,
    ]);
    assert_eq!(
        run(&tx, 42, Operation::Set(9)).unwrap(),
        Outcome::Ineligible
    );
    tx.done();
    for removed in [1, 0] {
        let tx = Script::new([
            owner(),
            Step::Write(&sql.remove, actor.clone(), removed),
            Step::Commit,
        ]);
        assert_eq!(run(&tx, 42, Operation::Clear).unwrap(), Outcome::Cleared);
        tx.done();
    }
    let tx = Script::new([Step::Query(&sql.owner, actor, vec![]), Step::Rollback]);
    assert_eq!(
        run(&tx, 42, Operation::Clear).unwrap(),
        Outcome::MissingOwner
    );
    tx.done();
}

#[test]
fn reading_uses_original_visibility_and_stays_read_only() {
    let sql = sql();
    assert!(sql.read.contains("JOIN v_post_feed_item"));
    assert!(sql.read.contains("p.author_id=t.user_id"));
    assert!(sql
        .read
        .contains("fn_can_view_post(:viewer_id,p.post_id)=1"));
    let binds = BindMap::from([number("profile_id", 12), number("viewer_id", 42)]);
    let tx = Script::new([Step::Query(
        &sql.read,
        binds.clone(),
        vec![DbRow::from([number("POST_ID", 7)])],
    )]);
    assert_eq!(
        run(&tx, 42, Operation::Read(12)).unwrap(),
        Outcome::Read(Some(7))
    );
    tx.done();
    let tx = Script::new([Step::Query(&sql.read, binds, vec![])]);
    assert_eq!(
        run(&tx, 42, Operation::Read(12)).unwrap(),
        Outcome::Read(None)
    );
    tx.done();
}

#[test]
fn missing_profile_pin_schema_fails_the_read_only_catalog_check() {
    let mut pin_table_checked = false;
    let snapshot = readiness::collect_feature_with("profile-pinned-post", |sql, binds| {
        assert!(sql.starts_with("SELECT "));
        if sql.contains("SYS_CONTEXT") {
            return Ok(vec![json!({ "USER_NAME": "APP", "SCHEMA_NAME": "APP" })]);
        }
        assert!(sql.contains("FROM user_tables"));
        if binds.get("name").and_then(DbValue::as_str) == Some("N_USER_PINNED_POSTS") {
            pin_table_checked = true;
        }
        Ok(vec![])
    })
    .unwrap();
    assert!(pin_table_checked);
    assert!(readiness::validate_feature_snapshot(&snapshot, "profile-pinned-post").is_err());
}
