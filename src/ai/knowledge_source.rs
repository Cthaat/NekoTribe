//! Revalidate index candidates against the current public business source.
use crate::db::{
    oracle::{bind_refs, bind_values, BindMap},
    row::oracle_row_to_db_row,
    value::DbValue,
};
use sha2::{Digest, Sha256};
use std::collections::HashSet;

const MAX_ID: i64 = 999_999_999_999_999;
const MAX_USER: i64 = 9_007_199_254_740_991;
const POST_SQL:&str="SELECT p.post_id AS source_id,p.post_id AS post_id,p.content AS content FROM n_posts p WHERE p.post_id=:source_id AND p.visibility='public' AND p.is_deleted=0 AND DBMS_LOB.GETLENGTH(p.content) BETWEEN 1 AND 65536 AND fn_can_view_post(:viewer_id,p.post_id)=1";
const COMMENT_SQL:&str="SELECT c.comment_id AS source_id,p.post_id AS post_id,c.content AS content FROM n_comments c JOIN n_posts p ON p.post_id=c.post_id WHERE c.comment_id=:source_id AND c.is_deleted=0 AND DBMS_LOB.GETLENGTH(c.content) BETWEEN 1 AND 65536 AND p.visibility='public' AND p.is_deleted=0 AND fn_can_view_post(:viewer_id,p.post_id)=1";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    Invalid,
    Store,
}
#[derive(Debug, Clone, PartialEq, Eq, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Candidate {
    pub kind: String,
    pub id: i64,
    pub version: String,
}
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct Source {
    pub kind: String,
    pub id: i64,
    pub post_id: i64,
    pub content: String,
    pub version: String,
}
pub trait Reader {
    fn get(&self, viewer: i64, candidate: &Candidate) -> Result<Option<Source>, Error>;
}

pub fn source_version(kind: &str, id: i64, post_id: i64, content: &str) -> String {
    let mut hash = Sha256::new();
    hash.update(format!("neko-ai-source-v1\0{kind}\0{id}\0{post_id}\0").as_bytes());
    hash.update(content.as_bytes());
    hex::encode(hash.finalize())
}
fn valid_id(id: i64) -> bool {
    (1..=MAX_ID).contains(&id)
}
fn validate(viewer: i64, candidates: &[Candidate]) -> Result<(), Error> {
    if !(1..=MAX_USER).contains(&viewer) || candidates.len() > 20 {
        return Err(Error::Invalid);
    }
    let mut seen = HashSet::new();
    for c in candidates {
        if !matches!(c.kind.as_str(), "post" | "comment")
            || !valid_id(c.id)
            || c.version.len() != 64
            || !c
                .version
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            || !seen.insert((c.kind.as_str(), c.id))
        {
            return Err(Error::Invalid);
        }
    }
    Ok(())
}
pub fn hydrate(
    reader: &impl Reader,
    viewer: i64,
    candidates: &[Candidate],
) -> Result<Vec<Source>, Error> {
    validate(viewer, candidates)?;
    let mut output = Vec::new();
    for candidate in candidates {
        let Some(mut row) = reader.get(viewer, candidate).map_err(|_| Error::Store)? else {
            continue;
        };
        if row.kind != candidate.kind
            || row.id != candidate.id
            || !valid_id(row.post_id)
            || (row.kind == "post" && row.id != row.post_id)
        {
            return Err(Error::Store);
        }
        if row.content.is_empty() || row.content.len() > 65536 {
            continue;
        }
        let version = source_version(&row.kind, row.id, row.post_id, &row.content);
        if version == candidate.version {
            row.version = version;
            output.push(row)
        }
    }
    Ok(output)
}
struct OracleReader<'a>(&'a oracle::Connection);
fn query_parts(viewer: i64, candidate: &Candidate) -> (&'static str, BindMap) {
    let query = if candidate.kind == "post" {
        POST_SQL
    } else {
        COMMENT_SQL
    };
    let binds = BindMap::from([
        ("source_id".into(), DbValue::I64(candidate.id)),
        ("viewer_id".into(), DbValue::I64(viewer)),
    ]);
    (query, binds)
}
impl Reader for OracleReader<'_> {
    fn get(&self, viewer: i64, candidate: &Candidate) -> Result<Option<Source>, Error> {
        let (query, binds) = query_parts(viewer, candidate);
        let binds = bind_values(binds);
        let mut rows = self
            .0
            .query_named(query, &bind_refs(&binds))
            .map_err(|_| Error::Store)?;
        let Some(row) = rows.next().transpose().map_err(|_| Error::Store)? else {
            return Ok(None);
        };
        let row = oracle_row_to_db_row(&row).map_err(|_| Error::Store)?;
        if rows.next().is_some() {
            return Err(Error::Store);
        }
        let id = row
            .get("SOURCE_ID")
            .and_then(DbValue::as_i64)
            .ok_or(Error::Store)?;
        let post_id = row
            .get("POST_ID")
            .and_then(DbValue::as_i64)
            .ok_or(Error::Store)?;
        let content = row
            .get("CONTENT")
            .and_then(DbValue::as_str)
            .ok_or(Error::Store)?
            .to_owned();
        Ok(Some(Source {
            kind: candidate.kind.clone(),
            id,
            post_id,
            content,
            version: String::new(),
        }))
    }
}
/// Callers must authenticate the viewer before passing their identity.
pub fn hydrate_sources(
    connection: &oracle::Connection,
    viewer: i64,
    candidates: &[Candidate],
) -> Result<Vec<Source>, Error> {
    hydrate(&OracleReader(connection), viewer, candidates)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn statements_filter_public_owner_visible_sources_and_bound_ids() {
        for kind in ["post", "comment"] {
            let c = Candidate {
                kind: kind.into(),
                id: 11,
                version: "0".repeat(64),
            };
            let (sql, binds) = query_parts(42, &c);
            for required in [
                "p.visibility='public'",
                "p.is_deleted=0",
                "fn_can_view_post(:viewer_id,p.post_id)=1",
                "DBMS_LOB.GETLENGTH(",
            ] {
                assert!(sql.contains(required));
            }
            if kind == "comment" {
                assert!(sql.contains("c.is_deleted=0"));
                assert!(sql.contains("p.post_id=c.post_id"));
            }
            assert_eq!(binds.get("viewer_id"), Some(&DbValue::I64(42)));
            assert_eq!(binds.get("source_id"), Some(&DbValue::I64(11)));
        }
    }
}
