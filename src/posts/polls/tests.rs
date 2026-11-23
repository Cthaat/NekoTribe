use super::*;
use crate::posts::create_request::parse_create_body;
use serde_json::json;
use std::{cell::RefCell, collections::VecDeque};

enum Step<'a> {
    Query(&'a str, Vec<DbRow>),
    QueryError(&'a str, DbError),
    Write(&'a str, Result<u64, DbError>),
    Commit,
    Rollback,
}

struct Script<'a> {
    steps: RefCell<VecDeque<Step<'a>>>,
    writes: RefCell<Vec<BindMap>>,
}

impl<'a> Script<'a> {
    fn new(steps: impl Into<VecDeque<Step<'a>>>) -> Self {
        Self {
            steps: RefCell::new(steps.into()),
            writes: RefCell::default(),
        }
    }

    fn complete(&self) {
        assert!(self.steps.borrow().is_empty());
    }
}

impl Transaction for Script<'_> {
    fn query(&self, sql: &str, _: BindMap) -> Result<Vec<DbRow>, DbError> {
        match self.steps.borrow_mut().pop_front() {
            Some(Step::Query(expected, rows)) => {
                assert_eq!(expected, sql);
                Ok(rows)
            }
            Some(Step::QueryError(expected, error)) => {
                assert_eq!(expected, sql);
                Err(error)
            }
            _ => panic!("unexpected query: {sql}"),
        }
    }

    fn execute(&self, sql: &str, bindings: BindMap) -> Result<u64, DbError> {
        let Some(Step::Write(expected, result)) = self.steps.borrow_mut().pop_front() else {
            panic!("unexpected write: {sql}");
        };
        assert_eq!(expected, sql);
        self.writes.borrow_mut().push(bindings);
        result
    }

    fn commit(&self) -> Result<(), DbError> {
        assert!(matches!(
            self.steps.borrow_mut().pop_front(),
            Some(Step::Commit)
        ));
        Ok(())
    }

    fn rollback(&self) -> Result<(), DbError> {
        assert!(matches!(
            self.steps.borrow_mut().pop_front(),
            Some(Step::Rollback)
        ));
        Ok(())
    }
}

fn choice_row(id: i64, total: i64, votes: i64, selected: bool, multiple: bool) -> DbRow {
    DbRow::from([
        number("POLL_ID", 22),
        number("ALLOW_MULTIPLE", i64::from(multiple)),
        number("IS_CLOSED", 0),
        number("OPTION_ID", id),
        number("TOTAL_BALLOTS", total),
        number("VOTES_COUNT", votes),
        number("SELECTED", i64::from(selected)),
        (
            "OPTION_TEXT".into(),
            DbValue::String(format!("option {id}")),
        ),
        (
            "CLOSES_AT".into(),
            DbValue::String("2030-01-02T03:04:05.000Z".into()),
        ),
    ])
}

#[test]
fn draft_normalizes_options_and_cutoff_and_preserves_post_rules() {
    let payload = json!({"options":[" a ", "中".repeat(80)],"multiple":true,"closes_at":"2030-01-02T11:04:05.98765+08:00"});
    let draft = parse_draft(&payload.to_string()).unwrap();
    assert_eq!(draft.options, ["a", &"中".repeat(80)]);
    assert_eq!(draft.closes_at, "2030-01-02T03:04:05.987Z");
    assert!(draft.multiple);

    for options in [
        json!(["a"]),
        json!(["a", " a"]),
        json!(["a", 2]),
        json!(["a", "中".repeat(81)]),
        json!(["a", " "]),
    ] {
        let mut invalid = payload.clone();
        invalid["options"] = options;
        assert!(parse_draft(&invalid.to_string()).is_err());
    }
    for cutoff in [
        "2030-02-30T11:04:05Z",
        "2030-01-02 11:04:05Z",
        "2030-01-02T11:04:60Z",
        "2030-01-02T11:04:05",
        "2030-01-02t11:04:05z",
    ] {
        let mut invalid = payload.clone();
        invalid["closes_at"] = cutoff.into();
        assert!(parse_draft(&invalid.to_string()).is_err(), "{cutoff}");
    }
    for body in [
        json!({"poll":payload}),
        json!({"content":"x","reply_to_post_id":5,"poll":payload}),
        json!({"content":"x","quoted_post_id":5,"poll":payload}),
        json!({"content":"x","poll":null}),
    ] {
        assert!(parse_create_body(body.to_string().as_bytes(), "application/json", None).is_err());
    }
    let body = json!({"media_ids":[5],"poll":payload}).to_string();
    assert!(parse_create_body(body.as_bytes(), "application/json", None)
        .unwrap()
        .poll
        .is_some());
    assert!(parse_create_body(body.as_bytes(), "application/json", Some(10)).is_err());
}

#[test]
fn attachment_uses_distinct_post_columns_and_database_cutoff() {
    let sql = &contract().sql;
    let draft =
        parse_draft(r#"{"options":["a","b"],"multiple":false,"closes_at":"2030-01-02T03:04:05Z"}"#)
            .unwrap();
    for target in [
        Target::Regular(8),
        Target::Group {
            group_id: 7,
            post_id: 8,
        },
    ] {
        let tx = Script::new([
            Step::Query(NEXT_ID, vec![DbRow::from([number("ID", 22)])]),
            Step::Write(&sql.insert_poll, Ok(1)),
            Step::Write(&sql.insert_option, Ok(1)),
            Step::Write(&sql.insert_option, Ok(1)),
        ]);
        assert!(attach(&tx, target, &draft).unwrap());
        tx.complete();
        let writes = tx.writes.borrow();
        let (regular, group) = if matches!(target, Target::Regular(_)) {
            (DbValue::I64(8), DbValue::Null)
        } else {
            (DbValue::Null, DbValue::I64(8))
        };
        assert_eq!(writes[0]["post_id"], regular);
        assert_eq!(writes[0]["group_post_id"], group);
        assert_eq!(writes[1]["option_id"], DbValue::I64(1));
        assert_eq!(writes[2]["option_id"], DbValue::I64(2));
    }
    let tx = Script::new([
        Step::Query(NEXT_ID, vec![DbRow::from([number("ID", 22)])]),
        Step::Write(&sql.insert_poll, Ok(0)),
    ]);
    assert!(!attach(&tx, Target::Regular(8), &draft).unwrap());
    tx.complete();
}

#[test]
fn group_votes_require_write_permission_and_return_my_choices_and_percentages() {
    let sql = &contract().sql;
    let target = Target::Group {
        group_id: 7,
        post_id: 8,
    };
    let group = || Step::Query(crate::group_post_write::LOCK, vec![DbRow::new()]);
    let visible = || {
        Step::Query(
            crate::group_content::POSTS,
            vec![DbRow::from([
                number("GROUP_ALLOWED", 1),
                number("POST_ID", 8),
            ])],
        )
    };
    let permission = |allowed| {
        Step::Query(
            crate::group_post_write::POST,
            vec![DbRow::from([number("ALLOWED", allowed)])],
        )
    };
    let tx = Script::new([group(), visible(), permission(0), Step::Rollback]);
    assert_eq!(
        run(&tx, Some(42), target, Operation::Vote(vec![1])).unwrap(),
        Outcome::Forbidden
    );
    tx.complete();

    let tx = Script::new([
        group(),
        visible(),
        permission(1),
        Step::Query(
            &sql.read,
            vec![
                choice_row(1, 2, 1, false, true),
                choice_row(2, 2, 2, false, true),
            ],
        ),
        Step::Write(&sql.insert_ballot, Ok(1)),
        Step::Write(&sql.insert_vote, Ok(1)),
        Step::Write(&sql.insert_vote, Ok(1)),
        Step::Query(
            &sql.read,
            vec![
                choice_row(1, 3, 2, true, true),
                choice_row(2, 3, 3, true, true),
            ],
        ),
        Step::Commit,
    ]);
    let Outcome::Found(poll) = run(&tx, Some(42), target, Operation::Vote(vec![1, 2])).unwrap()
    else {
        panic!("missing poll")
    };
    assert_eq!(poll.my_option_ids, [1, 2]);
    assert_eq!(poll.total_ballots, 3);
    assert_eq!(
        poll.options
            .iter()
            .map(|option| option.percent)
            .collect::<Vec<_>>(),
        [66.7, 100.0]
    );
    tx.complete();
}

#[test]
fn ballot_rolls_back_on_cutoff_duplicate_invalid_choice_and_write_failure() {
    let sql = &contract().sql;
    let target = Target::Regular(8);
    let lock = format!("{REGULAR_VISIBLE} FOR UPDATE OF p.post_id");
    let visible = || Step::Query(&lock, vec![DbRow::new()]);
    let poll = || {
        Step::Query(
            &sql.read,
            vec![
                choice_row(1, 0, 0, false, false),
                choice_row(2, 0, 0, false, false),
            ],
        )
    };
    let duplicate = DbError::Oracle(oracle::Error::OciError(oracle::DbError::new(
        1,
        0,
        "synthetic",
        "",
        "",
    )));
    for (write, outcome) in [
        (Ok(0), Outcome::Closed),
        (Err(duplicate), Outcome::Duplicate),
    ] {
        let tx = Script::new([
            visible(),
            poll(),
            Step::Write(&sql.insert_ballot, write),
            Step::Rollback,
        ]);
        assert_eq!(
            run(&tx, Some(42), target, Operation::Vote(vec![1])).unwrap(),
            outcome
        );
        tx.complete();
    }
    for choices in [vec![3], vec![1, 2]] {
        let tx = Script::new([visible(), poll(), Step::Rollback]);
        assert_eq!(
            run(&tx, Some(42), target, Operation::Vote(choices)).unwrap(),
            Outcome::InvalidChoice
        );
        tx.complete();
    }
    let tx = Script::new([
        visible(),
        poll(),
        Step::Write(&sql.insert_ballot, Ok(1)),
        Step::Write(&sql.insert_vote, Ok(0)),
        Step::Rollback,
    ]);
    assert!(run(&tx, Some(42), target, Operation::Vote(vec![1])).is_err());
    tx.complete();
    let tx = Script::new([Step::Query(REGULAR_VISIBLE, vec![])]);
    assert_eq!(
        run(&tx, None, target, Operation::Read).unwrap(),
        Outcome::MissingPost
    );
    tx.complete();
}

#[test]
fn history_omits_only_when_all_tables_are_absent_in_the_owned_schema() {
    let sql = &contract().sql;
    let target = Target::Regular(8);
    let table_missing = || {
        Step::QueryError(
            &sql.read,
            DbError::Oracle(oracle::Error::OciError(oracle::DbError::new(
                942,
                0,
                "synthetic",
                "",
                "",
            ))),
        )
    };
    let schema_matches = || Step::Query(OWNER_SCHEMA, vec![DbRow::new()]);
    let tx = Script::new([Step::Query(&sql.read, vec![])]);
    assert!(read(&tx, None, target, true).unwrap().is_none());
    tx.complete();
    let tx = Script::new([
        table_missing(),
        schema_matches(),
        Step::Query(&sql.any_table_present, vec![]),
    ]);
    assert!(read(&tx, None, target, true).unwrap().is_none());
    tx.complete();
    let tx = Script::new([table_missing(), Step::Query(OWNER_SCHEMA, vec![])]);
    assert!(matches!(
        read(&tx, None, target, true),
        Err(DbError::SchemaNotReady)
    ));
    tx.complete();
    let tx = Script::new([
        table_missing(),
        schema_matches(),
        Step::Query(&sql.any_table_present, vec![DbRow::new()]),
    ]);
    assert!(matches!(
        read(&tx, None, target, true),
        Err(DbError::SchemaNotReady)
    ));
    tx.complete();
    let tx = Script::new([table_missing()]);
    assert!(matches!(
        read(&tx, None, target, false),
        Err(DbError::SchemaNotReady)
    ));
    tx.complete();
}
