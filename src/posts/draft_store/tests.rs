use super::*;
use crate::posts::draft_input::{parse_query, parse_schedule};
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

fn saved(status: &str, published_id: Option<u64>) -> DbRow {
    DbRow::from([
        number("DRAFT_ID", 3),
        number("OWNER_ID", 42),
        text("STATUS", status),
        text("PAYLOAD_JSON", r#"{"group_id":null,"content":"post"}"#),
        text("SCHEDULED_AT", "2030-01-02T00:00:00.000Z"),
        text("UPDATED_AT", "2030-01-01T00:00:00.000Z"),
        ("PUBLISHED_POST_ID".into(), nullable_id(published_id)),
    ])
}

#[test]
fn draft_input_preserves_incomplete_payloads_and_checks_scope_and_limits() {
    let ordinary = parse_payload(
        br#"{"group_id":null,"content":" ","media_ids":[7.0],"visibility":"private"}"#,
    )
    .unwrap();
    assert_eq!(
        serde_json::to_value(ordinary.clone()).unwrap()["media_ids"],
        json!([7])
    );
    let Post::Regular(input) = ordinary.post().unwrap() else {
        panic!("expected ordinary post");
    };
    assert_eq!(input.media_ids, [7.0]);
    assert_eq!(input.visibility, "private");
    let incomplete =
        parse_payload(br#"{"group_id":8,"content":"","media_urls":["/storage/one.png"]}"#).unwrap();
    assert!(
        incomplete.post().is_err(),
        "group publishes still require content"
    );
    let regular_blank = parse_payload(br#"{"group_id":null,"content":""}"#).unwrap();
    assert!(regular_blank.post().is_err());
    let large_group = parse_payload(br#"{"group_id":10000000000,"content":""}"#).unwrap();
    assert_eq!(large_group.group_id(), Some(10_000_000_000));
    for raw in [
        r#"{"content":""}"#,
        r#"{"group_id":0,"content":""}"#,
        r#"{"group_id":9007199254740992,"content":""}"#,
        r#"{"group_id":7,"content":"","media_ids":[1]}"#,
        r#"{"group_id":null,"content":"","is_announcement":false}"#,
        r#"{"group_id":null,"content":"","poll":null}"#,
    ] {
        assert!(parse_payload(raw.as_bytes()).is_err(), "{raw}");
    }
}

#[test]
fn cursor_and_cutoff_follow_the_shared_contract() {
    let query = parse_query("before_id=99&group_id=0&limit=50").unwrap();
    assert_eq!(
        (query.before_id, query.group_scope, query.limit),
        (Some(99), Some(0), 50)
    );
    assert_eq!(parse_query("").unwrap().limit, 20);
    for invalid in [
        "limit=51",
        "limit=0",
        "before_id=0",
        "group_id=1&group_id=2",
        "limit=01",
    ] {
        assert!(parse_query(invalid).is_err(), "{invalid}");
    }
    assert_eq!(
        parse_schedule(br#"{"scheduled_at":"2030-01-02T08:00:00+08:00"}"#).unwrap(),
        "2030-01-02T00:00:00.000Z"
    );
    assert!(parse_schedule(br#"{"scheduled_at":"2030-01-02T08:00:00+08:00","extra":1}"#).is_err());
}

#[test]
fn due_claim_and_manual_repeat_share_the_same_publication_receipt() {
    let sql = &contract().sql;
    assert!(sql.candidates.contains("FETCH FIRST 20 ROWS ONLY"));
    assert!(sql.lock_due.contains("draft_id=:draft_id"));
    assert!(sql.lock_due.contains("status='scheduled'"));
    assert!(sql
        .lock_due
        .contains("scheduled_at<=SYS_EXTRACT_UTC(SYSTIMESTAMP)"));
    assert!(sql.lock_due.ends_with("FOR UPDATE SKIP LOCKED"));
    let due_key = BindMap::from([number("draft_id", 3)]);
    let mut published_key = draft_key(42, 3);
    published_key.extend([number("post_id", 17)]);
    let tx = Script::new([
        Step::Query(
            &sql.lock_due,
            due_key.clone(),
            vec![saved("scheduled", None)],
        ),
        Step::Write(SAVEPOINT, BindMap::new(), 0),
        Step::Write(&sql.published, published_key, 1),
        Step::Query(
            &sql.read,
            draft_key(42, 3),
            vec![saved("published", Some(17))],
        ),
        Step::Commit,
    ]);
    let notice = claim_due(&tx, 3, |owner, _| {
        assert_eq!(owner, 42);
        Ok(Ok(17))
    })
    .unwrap()
    .unwrap();
    assert_eq!(notice.post_id, 17);
    tx.done();

    let tx = Script::new([Step::Query(&sql.lock_due, due_key, vec![]), Step::Commit]);
    assert!(
        claim_due(&tx, 3, |_, _| panic!("unavailable claim cannot publish"))
            .unwrap()
            .is_none()
    );
    tx.done();

    let tx = Script::new([
        Step::Query(
            &sql.lock_owner,
            draft_key(42, 3),
            vec![saved("published", Some(17))],
        ),
        Step::Commit,
    ]);
    let storage = StorageUrlPolicy::default();
    let outcome = mutate(&tx, 42, Operation::Publish(3), &storage, |_, _, _| {
        panic!("unexpected draft edit")
    });
    let Outcome::Saved(receipt, None) = complete(&tx, outcome).unwrap() else {
        panic!("expected prior receipt");
    };
    assert_eq!(receipt["published_post_id"], 17);
    tx.done();
}

#[test]
fn permanent_due_failure_rolls_back_post_writes_and_transient_failure_stays_queued() {
    let sql = &contract().sql;
    let due = || {
        Step::Query(
            &sql.lock_due,
            BindMap::from([number("draft_id", 3)]),
            vec![saved("scheduled", None)],
        )
    };
    for (status, reason) in [
        (400, "content_unavailable"),
        (403, "permission_denied"),
        (404, "permission_denied"),
        (422, "permission_denied"),
    ] {
        let mut key = draft_key(42, 3);
        key.extend([text("reason", reason)]);
        let tx = Script::new([
            due(),
            Step::Write(SAVEPOINT, BindMap::new(), 0),
            Step::Write("post write", BindMap::new(), 1),
            Step::Write(ROLLBACK_PUBLICATION, BindMap::new(), 0),
            Step::Write(&sql.failed, key, 1),
            Step::Commit,
        ]);
        assert!(claim_due(&tx, 3, |_, _| {
            tx.execute("post write", BindMap::new())?;
            Ok(Err(ApiError::new(
                StatusCode::from_u16(status).unwrap(),
                1,
                "publication failure",
            )))
        })
        .unwrap()
        .is_none());
        tx.done();
    }

    let tx = Script::new([
        due(),
        Step::Write(SAVEPOINT, BindMap::new(), 0),
        Step::Rollback,
    ]);
    assert!(claim_due(&tx, 3, |_, _| Err(DbError::SemaphoreClosed)).is_err());
    tx.done();
    let tx = Script::new([Step::Rollback]);
    let outcome = publish_locked(&tx, 42, 3, &saved("scheduled", None), false, |_| {
        Ok(Err(ApiError::forbidden("denied")))
    });
    assert!(matches!(
        complete(&tx, outcome).unwrap(),
        Outcome::Rejected(_)
    ));
    tx.done();
}
