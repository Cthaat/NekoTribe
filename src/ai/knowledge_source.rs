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
const DISCOVER_POST_SQL:&str="SELECT p.post_id AS source_id,p.post_id AS post_id,p.content AS content FROM n_posts p WHERE p.visibility='public' AND p.is_deleted=0 AND fn_can_view_post(:viewer_id,p.post_id)=1 AND DBMS_LOB.GETLENGTH(p.content) BETWEEN 1 AND 65536 AND DBMS_LOB.INSTR(p.content,:term)>0 ORDER BY p.post_id DESC FETCH FIRST :row_limit ROWS ONLY";
const DISCOVER_COMMENT_SQL:&str="SELECT c.comment_id AS source_id,p.post_id AS post_id,c.content AS content FROM n_comments c JOIN n_posts p ON p.post_id=c.post_id WHERE c.is_deleted=0 AND p.visibility='public' AND p.is_deleted=0 AND fn_can_view_post(:viewer_id,p.post_id)=1 AND DBMS_LOB.GETLENGTH(c.content) BETWEEN 1 AND 65536 AND DBMS_LOB.INSTR(c.content,:term)>0 ORDER BY c.comment_id DESC FETCH FIRST :row_limit ROWS ONLY";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    Invalid,
    Store,
}
#[derive(Debug, Clone, PartialEq, Eq, serde::Deserialize, serde::Serialize)]
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
    #[serde(skip_serializing_if = "is_zero")]
    pub post_id: i64,
    pub content: String,
    pub version: String,
}
fn is_zero(value: &i64) -> bool {
    *value == 0
}
pub trait Reader {
    fn get(&self, viewer: i64, candidate: &Candidate) -> Result<Option<Source>, Error>;
}
pub trait DiscoveryReader {
    fn search(
        &self,
        viewer: i64,
        kind: &str,
        term: &str,
        limit: usize,
    ) -> Result<Vec<Source>, Error>;
}

/// Internal exact text search. Callers must revalidate sources before and after generation.
pub fn discover(
    reader: &impl DiscoveryReader,
    viewer: i64,
    query: &str,
    limit: usize,
) -> Result<Vec<Source>, Error> {
    let term = crate::auth::login::js_trim(query);
    if !(1..=MAX_USER).contains(&viewer)
        || !(1..=20).contains(&limit)
        || term.is_empty()
        || term.len() > 256
        || term.chars().any(|c| c <= '\u{1f}' || c == '\u{7f}')
    {
        return Err(Error::Invalid);
    }
    let mut lists = Vec::with_capacity(2);
    for kind in ["post", "comment"] {
        let rows = reader
            .search(viewer, kind, term, limit)
            .map_err(|_| Error::Store)?;
        if rows.len() > limit {
            return Err(Error::Store);
        }
        let mut seen = HashSet::new();
        let mut valid = Vec::new();
        for mut row in rows {
            if row.kind != kind
                || !valid_id(row.id)
                || !valid_id(row.post_id)
                || (kind == "post" && row.id != row.post_id)
                || !seen.insert(row.id)
            {
                return Err(Error::Store);
            }
            if row.content.is_empty() || row.content.len() > 65536 {
                continue;
            }
            row.version = source_version(kind, row.id, row.post_id, &row.content);
            valid.push(row);
        }
        lists.push(valid);
    }
    let mut output = Vec::with_capacity(limit);
    for index in 0..limit {
        for list in &lists {
            if let Some(row) = list.get(index) {
                if output.len() < limit {
                    output.push(row.clone());
                }
            }
        }
    }
    Ok(output)
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
pub(crate) fn validate(viewer: i64, candidates: &[Candidate]) -> Result<(), Error> {
    if !(1..=MAX_USER).contains(&viewer) || candidates.len() > 20 {
        return Err(Error::Invalid);
    }
    let mut seen = HashSet::new();
    for c in candidates {
        if !matches!(c.kind.as_str(), "post" | "comment" | "terms")
            || !valid_id(c.id)
            || (c.kind == "terms" && c.id > 8)
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
    if candidates.iter().any(|candidate| candidate.kind == "terms") {
        return Err(Error::Invalid);
    }
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
fn discovery_query_parts(
    viewer: i64,
    kind: &str,
    term: &str,
    limit: usize,
) -> (&'static str, BindMap) {
    let query = if kind == "post" {
        DISCOVER_POST_SQL
    } else {
        DISCOVER_COMMENT_SQL
    };
    (
        query,
        BindMap::from([
            ("viewer_id".into(), DbValue::I64(viewer)),
            ("term".into(), DbValue::String(term.into())),
            ("row_limit".into(), DbValue::I64(limit as i64)),
        ]),
    )
}
impl DiscoveryReader for OracleReader<'_> {
    fn search(
        &self,
        viewer: i64,
        kind: &str,
        term: &str,
        limit: usize,
    ) -> Result<Vec<Source>, Error> {
        let (query, binds) = discovery_query_parts(viewer, kind, term, limit);
        let binds = bind_values(binds);
        let rows = self
            .0
            .query_named(query, &bind_refs(&binds))
            .map_err(|_| Error::Store)?;
        let mut result = Vec::new();
        for row in rows {
            if result.len() >= limit {
                return Err(Error::Store);
            }
            let row =
                oracle_row_to_db_row(&row.map_err(|_| Error::Store)?).map_err(|_| Error::Store)?;
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
            result.push(Source {
                kind: kind.into(),
                id,
                post_id,
                content,
                version: String::new(),
            });
        }
        Ok(result)
    }
}
/// Callers must authenticate the viewer before passing their identity.
pub fn discover_sources(
    connection: &oracle::Connection,
    viewer: i64,
    query: &str,
    limit: usize,
) -> Result<Vec<Source>, Error> {
    discover(&OracleReader(connection), viewer, query, limit)
}
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
        if !matches!(candidate.kind.as_str(), "post" | "comment") {
            return Err(Error::Invalid);
        }
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
    fn discovery_statements_bind_query_and_filter_current_visibility() {
        for kind in ["post", "comment"] {
            let (sql, binds) = discovery_query_parts(42, kind, "猫", 2);
            for required in [
                "p.visibility='public'",
                "p.is_deleted=0",
                "fn_can_view_post(:viewer_id,p.post_id)=1",
                "DBMS_LOB.GETLENGTH(",
                "DBMS_LOB.INSTR(",
                ":term",
                "FETCH FIRST :row_limit ROWS ONLY",
            ] {
                assert!(sql.contains(required));
            }
            if kind == "comment" {
                assert!(sql.contains("c.is_deleted=0"));
            }
            assert_eq!(binds.get("viewer_id"), Some(&DbValue::I64(42)));
            assert_eq!(binds.get("term"), Some(&DbValue::String("猫".into())));
            assert_eq!(binds.get("row_limit"), Some(&DbValue::I64(2)));
        }
    }
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
