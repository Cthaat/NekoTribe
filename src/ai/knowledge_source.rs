//! Revalidate search candidates against the current business source and conversation scope.
use super::{public_terms_authority, public_terms_source};
use crate::db::{
    oracle::{BindMap, bind_refs, bind_values},
    row::oracle_row_to_db_row,
    value::DbValue,
};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    sync::OnceLock,
};

const MAX_ID: i64 = 999_999_999_999_999;
const MAX_USER: i64 = 9_007_199_254_740_991;
const POST_SQL: &str = "SELECT p.post_id AS source_id,p.post_id AS post_id,p.content AS content FROM n_posts p JOIN n_users post_author ON post_author.user_id=p.author_id AND post_author.is_active=1 WHERE p.post_id=:source_id AND p.post_id BETWEEN 1 AND :max_id AND p.visibility='public' AND p.is_deleted=0 AND DBMS_LOB.GETLENGTH(p.content) BETWEEN 1 AND 65536 AND fn_can_view_post(:viewer_id,p.post_id)=1";
const COMMENT_SQL: &str = "SELECT c.comment_id AS source_id,p.post_id AS post_id,c.content AS content FROM n_comments c JOIN n_posts p ON p.post_id=c.post_id JOIN n_users post_author ON post_author.user_id=p.author_id AND post_author.is_active=1 JOIN n_users comment_author ON comment_author.user_id=c.user_id AND comment_author.is_active=1 WHERE c.comment_id=:source_id AND p.post_id BETWEEN 1 AND :max_id AND c.is_deleted=0 AND DBMS_LOB.GETLENGTH(c.content) BETWEEN 1 AND 65536 AND p.visibility='public' AND p.is_deleted=0 AND fn_can_view_post(:viewer_id,p.post_id)=1 AND NOT EXISTS (SELECT 1 FROM n_user_blocks b WHERE (b.user_id=:viewer_id AND b.target_user_id=c.user_id) OR (b.target_user_id=:viewer_id AND b.user_id=c.user_id))";
const DISCOVER_POST_SQL: &str = "SELECT p.post_id AS source_id,p.post_id AS post_id,p.content AS content FROM n_posts p JOIN n_users post_author ON post_author.user_id=p.author_id AND post_author.is_active=1 WHERE p.post_id BETWEEN 1 AND :max_id AND p.visibility='public' AND p.is_deleted=0 AND fn_can_view_post(:viewer_id,p.post_id)=1 AND DBMS_LOB.GETLENGTH(p.content) BETWEEN 1 AND 65536 AND DBMS_LOB.INSTR(p.content,:term)>0 ORDER BY p.post_id DESC FETCH FIRST :row_limit ROWS ONLY";
const DISCOVER_COMMENT_SQL: &str = "SELECT c.comment_id AS source_id,p.post_id AS post_id,c.content AS content FROM n_comments c JOIN n_posts p ON p.post_id=c.post_id JOIN n_users post_author ON post_author.user_id=p.author_id AND post_author.is_active=1 JOIN n_users comment_author ON comment_author.user_id=c.user_id AND comment_author.is_active=1 WHERE c.comment_id BETWEEN 1 AND :max_id AND p.post_id BETWEEN 1 AND :max_id AND c.is_deleted=0 AND p.visibility='public' AND p.is_deleted=0 AND fn_can_view_post(:viewer_id,p.post_id)=1 AND NOT EXISTS (SELECT 1 FROM n_user_blocks b WHERE (b.user_id=:viewer_id AND b.target_user_id=c.user_id) OR (b.target_user_id=:viewer_id AND b.user_id=c.user_id)) AND DBMS_LOB.GETLENGTH(c.content) BETWEEN 1 AND 65536 AND DBMS_LOB.INSTR(c.content,:term)>0 ORDER BY c.comment_id DESC FETCH FIRST :row_limit ROWS ONLY";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    Invalid,
    Forbidden,
    Contended,
    Store,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ScopeName {
    #[default]
    Public,
    Personal,
    Group,
}

impl ScopeName {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "public" => Some(Self::Public),
            "personal" => Some(Self::Personal),
            "group" => Some(Self::Group),
            _ => None,
        }
    }

    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Public => "public",
            Self::Personal => "personal",
            Self::Group => "group",
        }
    }

    pub(crate) fn resolve(self, group_id: Option<i64>) -> Option<Scope> {
        match (self, group_id) {
            (Self::Public, None) => Some(Scope::Public),
            (Self::Personal, None) => Some(Scope::Personal),
            (Self::Group, Some(id)) if (1..=MAX_USER).contains(&id) => Some(Scope::Group(id)),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scope {
    Public,
    Personal,
    Group(i64),
}

impl Scope {
    fn kinds(self) -> &'static [&'static str] {
        match self {
            Self::Public => &["post", "comment", "terms", "group_post", "group_comment"],
            Self::Personal => &["post"],
            Self::Group(_) => &["group_post", "group_comment"],
        }
    }

    pub(crate) fn allows_kind(self, kind: &str) -> bool {
        self.kinds().contains(&kind)
    }

    pub(crate) fn allows_source(self, source: &Source) -> bool {
        self.allows_kind(&source.kind)
            && match self {
                Self::Public => true,
                Self::Personal => source.group_id == 0,
                Self::Group(group_id) => source.group_id == group_id,
            }
    }
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
    #[serde(skip_serializing_if = "is_zero")]
    pub group_id: i64,
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
    discover_in_scope(reader, viewer, Scope::Public, query, limit)
}

fn discover_in_scope(
    reader: &impl DiscoveryReader,
    viewer: i64,
    scope: Scope,
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
    let kinds = scope.kinds();
    let mut lists = Vec::with_capacity(kinds.len());
    for &kind in kinds {
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
                || !scope.allows_source(&row)
                || !valid_id(row.id)
                || (kind == "terms"
                    && (row.id > 8
                        || validate(
                            viewer,
                            &[Candidate {
                                kind: row.kind.clone(),
                                id: row.id,
                                version: row.version.clone(),
                            }],
                        )
                        .is_err()))
                || !valid_location(kind, row.id, row.post_id, row.group_id)
                || !seen.insert(row.id)
            {
                return Err(Error::Store);
            }
            if row.content.is_empty() || row.content.len() > 65536 {
                continue;
            }
            if kind != "terms" {
                row.version = source_version(kind, row.id, row.post_id, &row.content);
            }
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

/// Search bundled rule texts, checking authority only when there are matches.
pub fn discover_terms_sources(
    reader: &impl public_terms_authority::Reader,
    viewer: i64,
    query: &str,
    limit: usize,
    raw: &serde_json::Value,
) -> Result<Vec<Source>, Error> {
    if !(1..=MAX_USER).contains(&viewer) {
        return Err(Error::Invalid);
    }
    let catalog = public_terms_source::parse(raw).map_err(|_| Error::Store)?;
    let matches =
        public_terms_source::discover(&catalog, query, limit).map_err(|_| Error::Invalid)?;
    if !matches.is_empty() {
        public_terms_authority::read(reader, viewer, raw).map_err(|_| Error::Store)?;
    }
    Ok(matches
        .into_iter()
        .map(|row| Source {
            kind: "terms".into(),
            id: row.id,
            post_id: 0,
            group_id: 0,
            content: std::iter::once(row.title.as_str())
                .chain(row.blocks.iter().map(String::as_str))
                .collect::<Vec<_>>()
                .join("\n"),
            version: row.version,
        })
        .collect())
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
fn group_source_query(kind: &str) -> Option<&'static str> {
    static QUERIES: OnceLock<HashMap<String, String>> = OnceLock::new();
    QUERIES
        .get_or_init(|| {
            serde_json::from_str(include_str!(
                "../../contracts/requirements/ai-group-knowledge-source.json"
            ))
            .unwrap_or_default()
        })
        .get(kind)
        .map(String::as_str)
        .filter(|query| !query.is_empty())
}

fn scoped_query(kind: &str) -> Result<&'static str, Error> {
    static QUERIES: OnceLock<HashMap<String, String>> = OnceLock::new();
    QUERIES
        .get_or_init(|| {
            serde_json::from_str::<serde_json::Value>(include_str!(
                "../../contracts/requirements/ai-knowledge-scope.json"
            ))
            .ok()
            .and_then(|spec| serde_json::from_value(spec["sql"].clone()).ok())
            .unwrap_or_default()
        })
        .get(kind)
        .map(String::as_str)
        .filter(|query| !query.is_empty())
        .ok_or(Error::Store)
}

pub(crate) fn check_membership(
    connection: &oracle::Connection,
    viewer: i64,
    group_id: i64,
) -> Result<(), Error> {
    if !(1..=MAX_USER).contains(&viewer) || !(1..=MAX_USER).contains(&group_id) {
        return Err(Error::Invalid);
    }
    require_row(
        connection,
        scoped_query("membership")?,
        &[("viewer_id", &viewer), ("group_id", &group_id)],
    )
}

pub(crate) fn lock_group_membership(
    connection: &oracle::Connection,
    viewer: i64,
    group_id: i64,
) -> Result<(), Error> {
    require_row(
        connection,
        scoped_query("lock_group")?,
        &[("group_id", &group_id)],
    )?;
    require_row(
        connection,
        scoped_query("lock_membership")?,
        &[("viewer_id", &viewer), ("group_id", &group_id)],
    )
}

fn require_row(
    connection: &oracle::Connection,
    sql: &str,
    binds: &[(&str, &dyn oracle::sql_type::ToSql)],
) -> Result<(), Error> {
    let mut rows = connection.query_named(sql, binds).map_err(row_error)?;
    match rows.next().transpose().map_err(row_error)? {
        Some(_) if rows.next().is_none() => Ok(()),
        Some(_) => Err(Error::Store),
        None => Err(Error::Forbidden),
    }
}

fn row_error(error: oracle::Error) -> Error {
    if error.db_error().is_some_and(|detail| detail.code() == 54) {
        Error::Contended
    } else {
        Error::Store
    }
}
pub(crate) fn validate(viewer: i64, candidates: &[Candidate]) -> Result<(), Error> {
    if !(1..=MAX_USER).contains(&viewer) || candidates.len() > 20 {
        return Err(Error::Invalid);
    }
    let mut seen = HashSet::new();
    for c in candidates {
        if !matches!(
            c.kind.as_str(),
            "post" | "comment" | "terms" | "group_post" | "group_comment"
        ) || !valid_id(c.id)
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
    hydrate_in_scope(reader, viewer, Scope::Public, candidates)
}

fn hydrate_in_scope(
    reader: &impl Reader,
    viewer: i64,
    scope: Scope,
    candidates: &[Candidate],
) -> Result<Vec<Source>, Error> {
    validate(viewer, candidates)?;
    let mut output = Vec::new();
    for candidate in candidates {
        if !scope.allows_kind(&candidate.kind) {
            continue;
        }
        let Some(mut row) = reader.get(viewer, candidate).map_err(|_| Error::Store)? else {
            continue;
        };
        if row.kind != candidate.kind
            || row.id != candidate.id
            || !valid_location(&row.kind, row.id, row.post_id, row.group_id)
        {
            return Err(Error::Store);
        }
        if !scope.allows_source(&row) {
            continue;
        }
        if row.content.is_empty() || row.content.len() > 65536 {
            continue;
        }
        let version = if row.kind == "terms" {
            row.version.clone()
        } else {
            source_version(&row.kind, row.id, row.post_id, &row.content)
        };
        if version == candidate.version {
            row.version = version;
            output.push(row)
        }
    }
    Ok(output)
}

pub(super) fn valid_location(kind: &str, id: i64, post_id: i64, group_id: i64) -> bool {
    if kind == "terms" {
        return post_id == 0 && group_id == 0;
    }
    if !valid_id(post_id) || (matches!(kind, "post" | "group_post") && id != post_id) {
        return false;
    }
    if matches!(kind, "group_post" | "group_comment") {
        return (1..=MAX_USER).contains(&group_id);
    }
    group_id == 0
}

/// The caller supplies an authenticated viewer; the authority is read for every use.
pub fn read_terms_source(
    reader: &impl public_terms_authority::Reader,
    viewer: i64,
    candidate: &Candidate,
    raw: &serde_json::Value,
) -> Result<Option<Source>, Error> {
    validate(viewer, std::slice::from_ref(candidate))?;
    if candidate.kind != "terms" {
        return Err(Error::Invalid);
    }
    public_terms_authority::read(reader, viewer, raw).map_err(|_| Error::Store)?;
    let catalog = public_terms_source::parse(raw).map_err(|_| Error::Store)?;
    let refs = [public_terms_source::Reference {
        kind: "terms".into(),
        id: candidate.id,
        version: candidate.version.clone(),
    }];
    let mut rows = public_terms_source::hydrate(&catalog, &refs).map_err(|_| Error::Store)?;
    let Some(row) = rows.pop() else {
        return Ok(None);
    };
    let content = std::iter::once(row.title.as_str())
        .chain(row.blocks.iter().map(String::as_str))
        .collect::<Vec<_>>()
        .join("\n");
    Ok(Some(Source {
        kind: "terms".into(),
        id: row.id,
        post_id: 0,
        group_id: 0,
        content,
        version: row.version,
    }))
}
struct OracleReader<'a>(&'a oracle::Connection, Scope);
fn discovery_query_parts(
    viewer: i64,
    kind: &str,
    term: &str,
    limit: usize,
) -> Result<(&'static str, BindMap), Error> {
    let query = match kind {
        "post" => DISCOVER_POST_SQL,
        "comment" => DISCOVER_COMMENT_SQL,
        "group_post" => group_source_query("search_group_post").ok_or(Error::Store)?,
        "group_comment" => group_source_query("search_group_comment").ok_or(Error::Store)?,
        _ => return Err(Error::Invalid),
    };
    Ok((
        query,
        BindMap::from([
            ("viewer_id".into(), DbValue::I64(viewer)),
            ("term".into(), DbValue::String(term.into())),
            ("row_limit".into(), DbValue::I64(limit as i64)),
            ("max_id".into(), DbValue::I64(MAX_ID)),
        ]),
    ))
}

fn scoped_discovery_query_parts(
    scope: Scope,
    viewer: i64,
    kind: &str,
    term: &str,
    limit: usize,
) -> Result<(&'static str, BindMap), Error> {
    if scope == Scope::Public {
        return discovery_query_parts(viewer, kind, term, limit);
    }
    let query = match (scope, kind) {
        (Scope::Personal, "post") => scoped_query("search_personal_post")?,
        (Scope::Group(_), "group_post") => scoped_query("search_group_post")?,
        (Scope::Group(_), "group_comment") => scoped_query("search_group_comment")?,
        _ => return Err(Error::Invalid),
    };
    let mut binds = BindMap::from([
        ("viewer_id".into(), DbValue::I64(viewer)),
        ("max_id".into(), DbValue::I64(MAX_ID)),
        ("term".into(), DbValue::String(term.into())),
        ("row_limit".into(), DbValue::I64(limit as i64)),
    ]);
    if let Scope::Group(group_id) = scope {
        binds.insert("group_id".into(), DbValue::I64(group_id));
    }
    Ok((query, binds))
}
impl DiscoveryReader for OracleReader<'_> {
    fn search(
        &self,
        viewer: i64,
        kind: &str,
        term: &str,
        limit: usize,
    ) -> Result<Vec<Source>, Error> {
        if kind == "terms" {
            let raw: serde_json::Value = serde_json::from_str(include_str!(
                "../../contracts/requirements/ai-public-terms-catalog.json"
            ))
            .map_err(|_| Error::Store)?;
            return discover_terms_sources(
                &public_terms_authority::OracleReader(self.0, false),
                viewer,
                term,
                limit,
                &raw,
            );
        }
        let (query, binds) = scoped_discovery_query_parts(self.1, viewer, kind, term, limit)?;
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
            let group_id = if matches!(kind, "group_post" | "group_comment") {
                row.get("GROUP_ID")
                    .and_then(DbValue::as_i64)
                    .ok_or(Error::Store)?
            } else {
                0
            };
            result.push(Source {
                kind: kind.into(),
                id,
                post_id,
                group_id,
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
    discover_scoped_sources(connection, viewer, Scope::Public, query, limit)
}

pub(crate) fn discover_scoped_sources(
    connection: &oracle::Connection,
    viewer: i64,
    scope: Scope,
    query: &str,
    limit: usize,
) -> Result<Vec<Source>, Error> {
    if let Scope::Group(group_id) = scope {
        check_membership(connection, viewer, group_id)?;
    }
    discover_in_scope(
        &OracleReader(connection, scope),
        viewer,
        scope,
        query,
        limit,
    )
}
fn query_parts(viewer: i64, candidate: &Candidate) -> Result<(&'static str, BindMap), Error> {
    let query = match candidate.kind.as_str() {
        "post" => POST_SQL,
        "comment" => COMMENT_SQL,
        "group_post" | "group_comment" => {
            group_source_query(&candidate.kind).ok_or(Error::Store)?
        }
        _ => return Err(Error::Invalid),
    };
    let binds = BindMap::from([
        ("source_id".into(), DbValue::I64(candidate.id)),
        ("max_id".into(), DbValue::I64(MAX_ID)),
        ("viewer_id".into(), DbValue::I64(viewer)),
    ]);
    Ok((query, binds))
}

fn scoped_query_parts(
    scope: Scope,
    viewer: i64,
    candidate: &Candidate,
) -> Result<(&'static str, BindMap), Error> {
    if scope == Scope::Public {
        return query_parts(viewer, candidate);
    }
    let query = match (scope, candidate.kind.as_str()) {
        (Scope::Personal, "post") => scoped_query("personal_post")?,
        (Scope::Group(_), "group_post") => scoped_query("group_post")?,
        (Scope::Group(_), "group_comment") => scoped_query("group_comment")?,
        _ => return Err(Error::Invalid),
    };
    let mut binds = BindMap::from([
        ("viewer_id".into(), DbValue::I64(viewer)),
        ("source_id".into(), DbValue::I64(candidate.id)),
        ("max_id".into(), DbValue::I64(MAX_ID)),
    ]);
    if let Scope::Group(group_id) = scope {
        binds.insert("group_id".into(), DbValue::I64(group_id));
    }
    Ok((query, binds))
}
impl Reader for OracleReader<'_> {
    fn get(&self, viewer: i64, candidate: &Candidate) -> Result<Option<Source>, Error> {
        if candidate.kind == "terms" {
            let raw: serde_json::Value = serde_json::from_str(include_str!(
                "../../contracts/requirements/ai-public-terms-catalog.json"
            ))
            .map_err(|_| Error::Store)?;
            return read_terms_source(
                &public_terms_authority::OracleReader(self.0, false),
                viewer,
                candidate,
                &raw,
            );
        }
        let (query, binds) = scoped_query_parts(self.1, viewer, candidate)?;
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
        let group_id = if matches!(candidate.kind.as_str(), "group_post" | "group_comment") {
            row.get("GROUP_ID")
                .and_then(DbValue::as_i64)
                .ok_or(Error::Store)?
        } else {
            0
        };
        Ok(Some(Source {
            kind: candidate.kind.clone(),
            id,
            post_id,
            group_id,
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
    hydrate_scoped_sources(connection, viewer, Scope::Public, candidates)
}

pub(crate) fn hydrate_scoped_sources(
    connection: &oracle::Connection,
    viewer: i64,
    scope: Scope,
    candidates: &[Candidate],
) -> Result<Vec<Source>, Error> {
    if let Scope::Group(group_id) = scope {
        check_membership(connection, viewer, group_id)?;
    }
    hydrate_in_scope(&OracleReader(connection, scope), viewer, scope, candidates)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn restricted_search_and_hydration_include_the_same_live_scope_predicates() {
        let membership = scoped_query("membership").unwrap();
        let locked_membership = scoped_query("lock_membership").unwrap();
        assert!(
            scoped_query("lock_group")
                .unwrap()
                .ends_with("FOR UPDATE NOWAIT")
        );
        assert_eq!(
            locked_membership.strip_suffix(" FOR UPDATE OF gm.status NOWAIT"),
            Some(membership)
        );
        for (scope, kind) in [
            (Scope::Personal, "post"),
            (Scope::Group(MAX_USER), "group_post"),
            (Scope::Group(MAX_USER), "group_comment"),
        ] {
            let candidate = Candidate {
                kind: kind.into(),
                id: 11,
                version: "a".repeat(64),
            };
            for (sql, binds) in [
                scoped_query_parts(scope, 42, &candidate).unwrap(),
                scoped_discovery_query_parts(scope, 42, kind, "猫", 2).unwrap(),
            ] {
                assert_eq!(binds.get("viewer_id"), Some(&DbValue::I64(42)));
                assert_eq!(binds.contains_key("max_id"), sql.contains(":max_id"));
                assert!(sql.contains("p.is_deleted=0"));
                match scope {
                    Scope::Personal => {
                        assert!(sql.contains("p.author_id=:viewer_id OR EXISTS"));
                        assert!(sql.contains("b.user_id=:viewer_id"));
                        assert!(sql.contains("fn_can_view_post(:viewer_id,p.post_id)=1"));
                        assert!(!binds.contains_key("group_id"));
                    }
                    Scope::Group(group_id) => {
                        assert_eq!(binds.get("group_id"), Some(&DbValue::I64(group_id)));
                        assert!(sql.contains("p.group_id=:group_id"));
                        assert!(sql.contains("gm.user_id=:viewer_id AND gm.status='active'"));
                        assert!(sql.contains("g.is_active=1 AND g.is_deleted=0"));
                        assert!(sql.contains("n_user_blocks"));
                        assert!(!sql.contains("g.privacy='public'"));
                    }
                    Scope::Public => unreachable!(),
                }
            }
        }
    }
    #[test]
    fn discovery_statements_bind_query_and_filter_current_visibility() {
        for kind in ["post", "comment"] {
            let (sql, binds) = discovery_query_parts(42, kind, "猫", 2).unwrap();
            for required in [
                "p.visibility='public'",
                "p.is_deleted=0",
                "post_author.is_active=1",
                "fn_can_view_post(:viewer_id,p.post_id)=1",
                "DBMS_LOB.GETLENGTH(",
                "DBMS_LOB.INSTR(",
                ":term",
                "FETCH FIRST :row_limit ROWS ONLY",
                "p.post_id BETWEEN 1 AND :max_id",
            ] {
                assert!(sql.contains(required));
            }
            if kind == "comment" {
                assert!(sql.contains("c.comment_id BETWEEN 1 AND :max_id"));
                assert!(sql.contains("c.is_deleted=0"));
                assert!(sql.contains("comment_author.is_active=1"));
                assert!(sql.contains("b.user_id=:viewer_id AND b.target_user_id=c.user_id"));
                assert!(sql.contains("b.target_user_id=:viewer_id AND b.user_id=c.user_id"));
            }
            assert_eq!(binds.get("viewer_id"), Some(&DbValue::I64(42)));
            assert_eq!(binds.get("term"), Some(&DbValue::String("猫".into())));
            assert_eq!(binds.get("row_limit"), Some(&DbValue::I64(2)));
            assert_eq!(binds.get("max_id"), Some(&DbValue::I64(MAX_ID)));
        }
    }
    #[test]
    fn group_sources_query_live_public_group_and_bind_viewer() {
        for (kind, table) in [
            ("group_post", "n_group_posts"),
            ("group_comment", "n_group_comments"),
        ] {
            let candidate = Candidate {
                kind: kind.into(),
                id: 11,
                version: "0".repeat(64),
            };
            let (sql, binds) = query_parts(42, &candidate).unwrap();
            assert!(sql.contains(&format!("FROM {table}")));
            assert!(sql.contains("g.privacy='public' AND g.is_active=1 AND g.is_deleted=0"));
            assert!(sql.contains("b.user_id=:viewer_id"));
            assert!(sql.contains("b.target_user_id=:viewer_id"));
            assert!(sql.contains("p.group_id BETWEEN 1 AND :max_id"));
            assert_eq!(binds.get("max_id"), Some(&DbValue::I64(MAX_ID)));
            assert_eq!(binds.get("viewer_id"), Some(&DbValue::I64(42)));
            assert_eq!(binds.get("source_id"), Some(&DbValue::I64(11)));
            let (search, search_binds) = discovery_query_parts(42, kind, "猫", 2).unwrap();
            assert!(search.contains(&format!("FROM {table}")));
            assert!(search.contains("g.privacy='public' AND g.is_active=1 AND g.is_deleted=0"));
            assert!(search.contains("INSTR("));
            assert!(search.contains("FETCH FIRST :row_limit ROWS ONLY"));
            assert!(search.contains("p.group_id BETWEEN 1 AND :max_id"));
            assert!(search.contains("p.post_id BETWEEN 1 AND :max_id"));
            if kind == "group_comment" {
                assert!(sql.contains("p.post_id BETWEEN 1 AND :max_id"));
                assert!(search.contains("c.comment_id BETWEEN 1 AND :max_id"));
            }
            assert_eq!(search_binds.get("max_id"), Some(&DbValue::I64(MAX_ID)));
            assert_eq!(
                search_binds.get("term"),
                Some(&DbValue::String("猫".into()))
            );
            assert_eq!(search_binds.get("viewer_id"), Some(&DbValue::I64(42)));
            assert_eq!(search_binds.get("row_limit"), Some(&DbValue::I64(2)));
            assert!(validate(42, &[candidate]).is_ok());
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
            let (sql, binds) = query_parts(42, &c).unwrap();
            for required in [
                "p.visibility='public'",
                "p.is_deleted=0",
                "post_author.is_active=1",
                "fn_can_view_post(:viewer_id,p.post_id)=1",
                "DBMS_LOB.GETLENGTH(",
            ] {
                assert!(sql.contains(required));
            }
            if kind == "comment" {
                assert!(sql.contains("c.is_deleted=0"));
                assert!(sql.contains("p.post_id=c.post_id"));
                assert!(sql.contains("comment_author.is_active=1"));
                assert!(sql.contains("b.user_id=:viewer_id AND b.target_user_id=c.user_id"));
                assert!(sql.contains("b.target_user_id=:viewer_id AND b.user_id=c.user_id"));
            }
            assert_eq!(binds.get("viewer_id"), Some(&DbValue::I64(42)));
            assert_eq!(binds.get("source_id"), Some(&DbValue::I64(11)));
        }
    }
}
