//! Oracle reader for the group-brief Skill's public activity snapshot.
use crate::db::{
    oracle::{bind_refs, bind_values, BindMap},
    value::DbValue,
};
use oracle::Connection;
use serde::{Deserialize, Serialize};
use std::sync::OnceLock;

const MAX_SAFE_INTEGER: i64 = 9_007_199_254_740_991;

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    Invalid,
    Forbidden,
    Store,
}

pub struct EvidenceQuery<'a> {
    pub lookback_days: i64,
    pub search_term: Option<&'a str>,
    pub match_excerpt: bool,
    pub window_end: Option<&'a str>,
}

#[derive(Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct EvidenceExample {
    pub kind: String,
    pub source_id: i64,
    pub post_id: i64,
    pub excerpt: String,
}

#[derive(Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct GroupEvidence {
    pub window_start: String,
    pub window_end: String,
    pub posts_count: i64,
    pub comments_count: i64,
    pub examples: Vec<EvidenceExample>,
}

pub(super) fn valid_timestamp(value: &str) -> bool {
    static TIMESTAMP: OnceLock<regex::Regex> = OnceLock::new();
    TIMESTAMP
        .get_or_init(|| {
            regex::Regex::new(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}$")
                .expect("fixed timestamp format")
        })
        .is_match(value)
}

fn read_snapshot_row(row: &oracle::Row, result: &mut Option<GroupEvidence>) -> Result<(), Error> {
    let start: String = row.get("WINDOW_START").map_err(|_| Error::Store)?;
    let end: String = row.get("WINDOW_END").map_err(|_| Error::Store)?;
    let posts: i64 = row.get("POSTS_COUNT").map_err(|_| Error::Store)?;
    let comments: i64 = row.get("COMMENTS_COUNT").map_err(|_| Error::Store)?;
    let first = result.is_none();
    if first
        && (!valid_timestamp(&start)
            || !valid_timestamp(&end)
            || start >= end
            || !(0..=MAX_SAFE_INTEGER).contains(&posts)
            || !(0..=MAX_SAFE_INTEGER).contains(&comments))
    {
        return Err(Error::Store);
    }
    let evidence = result.get_or_insert_with(|| GroupEvidence {
        window_start: start.clone(),
        window_end: end.clone(),
        posts_count: posts,
        comments_count: comments,
        examples: Vec::new(),
    });
    if !first
        && (evidence.window_start != start
            || evidence.window_end != end
            || evidence.posts_count != posts
            || evidence.comments_count != comments
            || evidence.examples.is_empty()
            || evidence.examples.len() >= 8)
    {
        return Err(Error::Store);
    }
    let kind: Option<String> = row.get("KIND").map_err(|_| Error::Store)?;
    let source_id: Option<i64> = row.get("SOURCE_ID").map_err(|_| Error::Store)?;
    let post_id: Option<i64> = row.get("POST_ID").map_err(|_| Error::Store)?;
    let excerpt: Option<String> = row.get("EXCERPT").map_err(|_| Error::Store)?;
    match (kind, source_id, post_id, excerpt) {
        (None, None, None, None) if first => Ok(()),
        (Some(kind), Some(source_id), Some(post_id), Some(excerpt))
            if matches!(kind.as_str(), "post" | "comment")
                && (1..=MAX_SAFE_INTEGER).contains(&source_id)
                && (1..=MAX_SAFE_INTEGER).contains(&post_id)
                && (kind != "post" || source_id == post_id)
                && !excerpt.is_empty()
                && excerpt.chars().count() <= 400 =>
        {
            evidence.examples.push(EvidenceExample {
                kind,
                source_id,
                post_id,
                excerpt,
            });
            Ok(())
        }
        _ => Err(Error::Store),
    }
}

/// The actor is authenticated by the caller and group_id comes from the current conversation.
pub fn read_group_evidence(
    connection: &Connection,
    actor: i64,
    group_id: i64,
    query: EvidenceQuery<'_>,
) -> Result<GroupEvidence, Error> {
    if !(1..=MAX_SAFE_INTEGER).contains(&actor)
        || !(1..=MAX_SAFE_INTEGER).contains(&group_id)
        || !matches!(query.lookback_days, 7 | 30)
        || query.search_term.is_some_and(|term| {
            term.is_empty() || term.len() > 256 || term.bytes().any(|ch| ch < 32 || ch == 127)
        })
        || query.window_end.is_some_and(|end| !valid_timestamp(end))
    {
        return Err(Error::Invalid);
    }
    #[derive(Deserialize)]
    struct Statements {
        query: String,
    }
    static SQL: OnceLock<Statements> = OnceLock::new();
    let sql = SQL.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../../contracts/requirements/ai-group-evidence.json"
        ))
        .expect("valid group evidence contract")
    });
    let values = bind_values(BindMap::from([
        ("actor_id".into(), DbValue::I64(actor)),
        ("group_id".into(), DbValue::I64(group_id)),
        ("lookback_days".into(), DbValue::I64(query.lookback_days)),
        (
            "search_term".into(),
            DbValue::from_option_string(query.search_term.map(str::to_owned)),
        ),
        (
            "match_excerpt".into(),
            DbValue::I64(i64::from(query.match_excerpt)),
        ),
        (
            "window_end".into(),
            DbValue::from_option_string(query.window_end.map(str::to_owned)),
        ),
    ]));
    let rows = connection
        .query_named(&sql.query, &bind_refs(&values))
        .map_err(|_| Error::Store)?;
    let mut evidence = None;
    for row in rows {
        read_snapshot_row(&row.map_err(|_| Error::Store)?, &mut evidence)?;
    }
    let result = evidence.ok_or(Error::Forbidden)?;
    if query.window_end.is_some_and(|end| end != result.window_end) {
        return Err(Error::Store);
    }
    Ok(result)
}
