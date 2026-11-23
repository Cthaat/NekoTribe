use crate::{
    auth::{login::js_trim, readiness},
    db::{
        oracle::{BindMap, DbError},
        row::DbRow,
        tx::{OracleTx, Transaction},
        value::DbValue,
    },
    httpx::errors::ApiError,
};
use chrono::{DateTime, Datelike, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use std::{collections::HashSet, sync::OnceLock};

#[derive(Deserialize)]
struct Contract {
    min_options: usize,
    max_options: usize,
    max_option_bytes: usize,
    sql: Sql,
}

#[derive(Deserialize)]
struct Sql {
    insert_poll: String,
    insert_option: String,
    read: String,
    insert_ballot: String,
    insert_vote: String,
    any_table_present: String,
}

fn contract() -> &'static Contract {
    static CONTRACT: OnceLock<Contract> = OnceLock::new();
    CONTRACT.get_or_init(|| {
        serde_json::from_str(include_str!("../../contracts/requirements/post-polls.json"))
            .expect("valid post polls contract")
    })
}

#[derive(Clone, Debug, Serialize)]
pub struct Draft {
    options: Vec<String>,
    multiple: bool,
    closes_at: String,
}

impl Draft {
    pub(super) fn cutoff(&self) -> &str {
        &self.closes_at
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DraftBody {
    options: Vec<String>,
    multiple: bool,
    closes_at: String,
}

pub(crate) fn parse_draft(raw: &str) -> Result<Draft, ApiError> {
    let invalid = || ApiError::bad_request("poll 参数错误");
    let DraftBody {
        options,
        multiple,
        closes_at,
    } = serde_json::from_str(raw).map_err(|_| invalid())?;
    let policy = contract();
    if !(policy.min_options..=policy.max_options).contains(&options.len()) {
        return Err(invalid());
    }
    let options: Vec<_> = options
        .iter()
        .map(|value| js_trim(value).to_owned())
        .collect();
    let mut unique = HashSet::with_capacity(options.len());
    for text in &options {
        if text.is_empty() || text.len() > policy.max_option_bytes {
            return Err(ApiError::bad_request("投票选项参数错误"));
        }
        if !unique.insert(text) {
            return Err(ApiError::bad_request("投票选项不能重复"));
        }
    }
    let closes_at = utc_milliseconds(&closes_at)
        .ok_or_else(|| ApiError::bad_request("投票截止时间参数错误"))?;
    Ok(Draft { options, multiple, closes_at })
}

pub(super) fn utc_milliseconds(raw: &str) -> Option<String> {
    DateTime::parse_from_rfc3339(raw)
        .ok()
        .filter(|_| {
            let bytes = raw.as_bytes();
            bytes.get(10) == Some(&b'T')
                && !raw.ends_with('z')
                && bytes.get(17..19).is_some_and(|second| second < &b"60"[..])
        })
        .map(|date| date.with_timezone(&Utc))
        .filter(|date| (1..=9999).contains(&date.year()))
        .map(|date| date.to_rfc3339_opts(SecondsFormat::Millis, true))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BallotBody {
    option_ids: Vec<f64>,
}

pub(crate) fn parse_ballot(raw: &[u8]) -> Result<Vec<i64>, ApiError> {
    let invalid = || ApiError::bad_request("option_ids 参数错误");
    let BallotBody { option_ids } = serde_json::from_slice(raw).map_err(|_| invalid())?;
    let max = contract().max_options;
    if !(1..=max).contains(&option_ids.len()) {
        return Err(invalid());
    }
    let mut choices = Vec::with_capacity(option_ids.len());
    for choice in option_ids {
        if !(1.0..=max as f64).contains(&choice)
            || choice.fract() != 0.0
            || choices.contains(&(choice as i64))
        {
            return Err(invalid());
        }
        choices.push(choice as i64);
    }
    Ok(choices)
}

const OWNER_SCHEMA: &str = "SELECT 1 FROM dual WHERE USER=SYS_CONTEXT('USERENV','CURRENT_SCHEMA')";
const NEXT_ID: &str = "SELECT seq_post_poll_id.NEXTVAL AS id FROM dual";

pub(crate) fn require_schema(tx: &impl Transaction) -> Result<(), DbError> {
    let snapshot = readiness::collect_feature_with("post-polls", |sql, binds| {
        tx.query(sql, binds)?
            .iter()
            .map(|row| serde_json::to_value(row).map_err(|_| DbError::SchemaNotReady))
            .collect()
    })?;
    readiness::validate_feature_snapshot(&snapshot, "post-polls")
        .map_err(|_| DbError::SchemaNotReady)
}

fn no_owned_poll_tables(tx: &impl Transaction) -> Result<bool, DbError> {
    Ok(!tx.query(OWNER_SCHEMA, BindMap::new())?.is_empty()
        && tx
            .query(&contract().sql.any_table_present, BindMap::new())?
            .is_empty())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Target {
    Regular(i64),
    Group { group_id: i64, post_id: i64 },
}

impl Target {
    fn post_id(self) -> i64 {
        match self {
            Self::Regular(id) | Self::Group { post_id: id, .. } => id,
        }
    }
}

fn number(key: &str, number: i64) -> (String, DbValue) {
    (key.into(), DbValue::I64(number))
}

fn integer(row: &DbRow, field: &str) -> Result<i64, DbError> {
    row.get(field)
        .and_then(DbValue::as_i64)
        .ok_or_else(|| DbError::ExpectedNumber(field.into()))
}

pub(crate) fn attach(
    tx: &impl Transaction,
    target: Target,
    draft: &Draft,
) -> Result<bool, DbError> {
    let id_row = tx.query(NEXT_ID, BindMap::new())?;
    let poll_id = integer(id_row.first().ok_or(DbError::SchemaNotReady)?, "ID")?;
    if !(1..=9_007_199_254_740_991).contains(&poll_id) {
        return Err(DbError::SchemaNotReady);
    }
    let (regular, group) = match target {
        Target::Regular(id) => (DbValue::I64(id), DbValue::Null),
        Target::Group { post_id, .. } => (DbValue::Null, DbValue::I64(post_id)),
    };
    let sql = &contract().sql;
    match tx.execute(
        &sql.insert_poll,
        BindMap::from([
            number("poll_id", poll_id),
            ("post_id".into(), regular),
            ("group_post_id".into(), group),
            number("allow_multiple", i64::from(draft.multiple)),
            ("closes_at".into(), DbValue::String(draft.closes_at.clone())),
        ]),
    )? {
        0 => return Ok(false),
        1 => {}
        _ => return Err(DbError::SchemaNotReady),
    }
    for (index, text) in draft.options.iter().enumerate() {
        if tx.execute(
            &sql.insert_option,
            BindMap::from([
                number("poll_id", poll_id),
                number("option_id", index as i64 + 1),
                ("option_text".into(), DbValue::String(text.clone())),
            ]),
        )? != 1
        {
            return Err(DbError::SchemaNotReady);
        }
    }
    Ok(true)
}

#[derive(Debug, PartialEq, Serialize)]
pub struct PollOption {
    pub option_id: i64,
    pub text: String,
    pub votes_count: i64,
    pub percent: f64,
}

#[derive(Debug, PartialEq, Serialize)]
pub struct Poll {
    pub poll_id: i64,
    pub multiple: bool,
    pub closes_at: String,
    pub closed: bool,
    pub total_ballots: i64,
    pub my_option_ids: Vec<i64>,
    pub options: Vec<PollOption>,
}

pub enum History {
    Ready(Vec<Option<Poll>>),
    Unavailable,
}

pub(crate) fn read_regular_history(
    connection: &oracle::Connection,
    viewer: Option<u64>,
    ids: Vec<u64>,
) -> Result<History, DbError> {
    let tx = OracleTx::new(connection);
    let results = ids
        .into_iter()
        .map(|id| read(&tx, viewer, Target::Regular(id as i64), true))
        .collect();
    match results {
        Ok(polls) => Ok(History::Ready(polls)),
        Err(DbError::SchemaNotReady) => Ok(History::Unavailable),
        Err(error) => Err(error),
    }
}

pub(crate) fn read(
    tx: &impl Transaction,
    viewer: Option<u64>,
    target: Target,
    allow_legacy: bool,
) -> Result<Option<Poll>, DbError> {
    let rows = match tx.query(
        &contract().sql.read,
        BindMap::from([
            (
                "viewer_id".into(),
                viewer
                    .map(|id| DbValue::I64(id as i64))
                    .unwrap_or(DbValue::Null),
            ),
            number("post_id", target.post_id()),
            number(
                "is_group",
                i64::from(matches!(target, Target::Group { .. })),
            ),
        ]),
    ) {
        Ok(rows) => rows,
        Err(error) if has_oracle_code(&error, 942) => {
            if allow_legacy && no_owned_poll_tables(tx)? {
                return Ok(None);
            }
            return Err(DbError::SchemaNotReady);
        }
        Err(error) => return Err(error),
    };
    let Some(first) = rows.first() else {
        return Ok(None);
    };
    let total = integer(first, "TOTAL_BALLOTS")?;
    let mut poll = Poll {
        poll_id: integer(first, "POLL_ID")?,
        multiple: integer(first, "ALLOW_MULTIPLE")? == 1,
        closes_at: required_text(first, "CLOSES_AT")?,
        closed: integer(first, "IS_CLOSED")? == 1,
        total_ballots: total,
        my_option_ids: Vec::new(),
        options: Vec::with_capacity(rows.len()),
    };
    for row in &rows {
        let option_id = integer(row, "OPTION_ID")?;
        let votes = integer(row, "VOTES_COUNT")?;
        if integer(row, "SELECTED")? == 1 {
            poll.my_option_ids.push(option_id);
        }
        poll.options.push(PollOption {
            option_id,
            text: required_text(row, "OPTION_TEXT")?,
            votes_count: votes,
            percent: if total == 0 {
                0.0
            } else {
                (votes as f64 * 1000.0 / total as f64).round() / 10.0
            },
        });
    }
    Ok(Some(poll))
}

fn required_text(row: &DbRow, key: &str) -> Result<String, DbError> {
    row.get(key)
        .and_then(DbValue::as_str)
        .map(str::to_owned)
        .ok_or(DbError::SchemaNotReady)
}

pub enum Operation {
    Read,
    Vote(Vec<i64>),
}

#[derive(Debug, PartialEq)]
pub enum Outcome {
    Found(Poll),
    MissingPost,
    MissingGroup,
    MissingPoll,
    Forbidden,
    Closed,
    Duplicate,
    InvalidChoice,
    Unavailable,
}

const REGULAR_VISIBLE: &str =
    "SELECT p.post_id FROM n_posts p WHERE p.post_id=:post_id AND p.is_deleted=0
 AND EXISTS (SELECT 1 FROM v_post_feed_item v WHERE v.post_id=p.post_id)
 AND fn_can_view_post(:viewer_id,p.post_id)=1";

pub(crate) fn execute(
    connection: &oracle::Connection,
    viewer: Option<u64>,
    target: Target,
    operation: Operation,
) -> Result<Outcome, DbError> {
    let tx = OracleTx::new(connection);
    if require_schema(&tx).is_err() {
        return Ok(Outcome::Unavailable);
    }
    match run(&tx, viewer, target, operation) {
        Err(DbError::SchemaNotReady) => Ok(Outcome::Unavailable),
        result => result,
    }
}

fn run(
    tx: &impl Transaction,
    viewer: Option<u64>,
    target: Target,
    operation: Operation,
) -> Result<Outcome, DbError> {
    let voting = matches!(operation, Operation::Vote(_));
    let result = transact(tx, viewer, target, operation);
    if !voting {
        return result;
    }
    match result {
        Ok(outcome @ Outcome::Found(_)) => {
            if let Err(error) = tx.commit() {
                let _ = tx.rollback();
                return Err(error);
            }
            Ok(outcome)
        }
        other => {
            tx.rollback()?;
            other
        }
    }
}

fn transact(
    tx: &impl Transaction,
    viewer: Option<u64>,
    target: Target,
    operation: Operation,
) -> Result<Outcome, DbError> {
    let voting = matches!(operation, Operation::Vote(_));
    match target {
        Target::Regular(post_id) => {
            let sql = if voting {
                format!("{REGULAR_VISIBLE} FOR UPDATE OF p.post_id")
            } else {
                REGULAR_VISIBLE.to_owned()
            };
            let visible = tx.query(
                &sql,
                BindMap::from([
                    number("post_id", post_id),
                    (
                        "viewer_id".into(),
                        viewer
                            .map(|id| DbValue::I64(id as i64))
                            .unwrap_or(DbValue::Null),
                    ),
                ]),
            )?;
            if visible.is_empty() {
                return Ok(Outcome::MissingPost);
            }
        }
        Target::Group { group_id, post_id } => {
            let Some(viewer) = viewer else {
                return Ok(Outcome::Forbidden);
            };
            let actor = viewer as i64;
            if voting
                && tx
                    .query(
                        crate::group_post_write::LOCK,
                        BindMap::from([number("group_id", group_id)]),
                    )?
                    .is_empty()
            {
                return Ok(Outcome::MissingGroup);
            }
            let rows = tx.query(
                crate::group_content::POSTS,
                BindMap::from([
                    number("viewer_id", actor),
                    number("group_id", group_id),
                    number("post_id", post_id),
                    number("start_row", 1),
                    number("end_row", 1),
                    ("post_type".into(), DbValue::String("all".into())),
                ]),
            )?;
            let first = rows.first().ok_or(DbError::SchemaNotReady)?;
            if integer(first, "GROUP_ALLOWED")? != 1 {
                return Ok(Outcome::MissingGroup);
            }
            if first.get("POST_ID").and_then(DbValue::as_i64) != Some(post_id) {
                return Ok(Outcome::MissingPost);
            }
            if voting {
                let rows = tx.query(
                    crate::group_post_write::POST,
                    BindMap::from([number("user_id", actor), number("group_id", group_id)]),
                )?;
                if integer(rows.first().ok_or(DbError::SchemaNotReady)?, "ALLOWED")? != 1 {
                    return Ok(Outcome::Forbidden);
                }
            }
        }
    }
    let Some(poll) = read(tx, viewer, target, false)? else {
        return Ok(Outcome::MissingPoll);
    };
    let Operation::Vote(choices) = operation else {
        return Ok(Outcome::Found(poll));
    };
    let actor = viewer.ok_or(DbError::SchemaNotReady)?;
    if poll.closed {
        return Ok(Outcome::Closed);
    }
    if !poll.my_option_ids.is_empty() {
        return Ok(Outcome::Duplicate);
    }
    if (!poll.multiple && choices.len() != 1)
        || choices.is_empty()
        || choices
            .iter()
            .any(|id| !poll.options.iter().any(|option| option.option_id == *id))
    {
        return Ok(Outcome::InvalidChoice);
    }

    let sql = &contract().sql;
    let binds = BindMap::from([
        number("poll_id", poll.poll_id),
        number("user_id", actor as i64),
    ]);
    match tx.execute(&sql.insert_ballot, binds.clone()) {
        Ok(0) => return Ok(Outcome::Closed),
        Ok(1) => {}
        Err(error) if has_oracle_code(&error, 1) => return Ok(Outcome::Duplicate),
        Err(error) => return Err(error),
        Ok(_) => return Err(DbError::SchemaNotReady),
    }
    for id in choices {
        let mut binds = binds.clone();
        binds.insert("option_id".into(), DbValue::I64(id));
        if tx.execute(&sql.insert_vote, binds)? != 1 {
            return Err(DbError::SchemaNotReady);
        }
    }
    Ok(Outcome::Found(
        read(tx, Some(actor), target, false)?.ok_or(DbError::SchemaNotReady)?,
    ))
}

fn has_oracle_code(error: &DbError, code: i32) -> bool {
    matches!(error, DbError::Oracle(error) if error.db_error().is_some_and(|error| error.code() == code))
}

#[cfg(test)]
mod tests;
