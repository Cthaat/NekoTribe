use std::collections::{BTreeMap, BTreeSet};

use regex::Regex;
use serde::Serialize;
use serde_json::Value;

use crate::cache::tags::{
    normalize_key_part, sha256_hex, ORACLE_QUERY_CACHE_HIT_PREFIX, ORACLE_QUERY_CACHE_PREFIX,
    ORACLE_QUERY_CACHE_SCHEMA_VERSION,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BuiltOracleQueryCacheKey {
    pub key: String,
    pub hit_key: String,
    pub cache_id: String,
}

#[derive(Debug, Clone, Copy)]
pub struct OracleQueryCacheIdentity<'a> {
    pub sql: &'a str,
    pub binds: &'a BTreeMap<String, Value>,
    pub options: &'a Value,
    pub viewer_id: Option<i64>,
    pub tag_versions: &'a BTreeMap<String, String>,
}

#[derive(Debug, Serialize)]
struct SerializableOracleCacheIdentity<'a> {
    schema: &'static str,
    sql: String,
    binds: &'a BTreeMap<String, Value>,
    options: &'a Value,
    viewer_id: Option<i64>,
    tag_versions: &'a BTreeMap<String, String>,
}

pub fn is_cacheable_select_sql(sql: &str) -> bool {
    let normalized = normalized_sql_for_match(sql);
    (normalized.starts_with("select ") || normalized.starts_with("with "))
        && !Regex::new(r"\bnextval\b").unwrap().is_match(&normalized)
        && !Regex::new(r"\bfor\s+update\b")
            .unwrap()
            .is_match(&normalized)
        && !is_sensitive_sql(&normalized)
}

pub fn is_mutating_sql(sql: &str) -> bool {
    Regex::new(r"^(insert|update|delete|merge|begin)\b")
        .unwrap()
        .is_match(&normalized_sql_for_match(sql))
}

pub fn is_cache_neutral_mutation_sql(sql: &str) -> bool {
    let normalized = normalized_sql_for_match(sql);
    (normalized.contains("update n_auth_sessions") || normalized.contains("update n_user_sessions"))
        && normalized.contains("last_accessed_at")
        && !normalized.contains("revoked_at")
}

pub fn table_refs(sql: &str) -> Vec<String> {
    let normalized = normalized_sql_for_match(sql);
    let patterns = [
        r#"\bfrom\s+([a-z0-9_$#\."]+)"#,
        r#"\bjoin\s+([a-z0-9_$#\."]+)"#,
        r#"\bupdate\s+([a-z0-9_$#\."]+)"#,
        r#"\binsert\s+into\s+([a-z0-9_$#\."]+)"#,
        r#"\bdelete\s+from\s+([a-z0-9_$#\."]+)"#,
        r#"\bmerge\s+into\s+([a-z0-9_$#\."]+)"#,
    ];
    let mut refs = BTreeSet::new();

    for pattern in patterns {
        let regex = Regex::new(pattern).unwrap();
        for capture in regex.captures_iter(&normalized) {
            if let Some(value) = capture.get(1) {
                refs.insert(normalize_table_name(value.as_str()));
            }
        }
    }

    refs.into_iter().collect()
}

pub fn tags_for_sql(sql: &str, viewer_id: Option<i64>) -> Vec<String> {
    let normalized = normalized_sql_for_match(sql);
    let tables = table_refs(sql);
    let joined = format!("{} {}", normalized, tables.join(" "));
    let mut tags = BTreeSet::from(["oracle".to_string()]);

    for table in &tables {
        tags.insert(normalize_key_part(&format!("table:{table}")));
    }

    if Regex::new(r"tweet|post|timeline|bookmark|like|reply|retweet")
        .unwrap()
        .is_match(&joined)
    {
        add_tags(&mut tags, ["posts", "tweets", "users", "tags", "media"]);
    }
    if joined.contains("comment") {
        add_tags(&mut tags, ["comments", "posts", "users"]);
    }
    if Regex::new(r"user|follow|block|mute")
        .unwrap()
        .is_match(&joined)
    {
        add_tags(&mut tags, ["users"]);
    }
    if Regex::new(r"group|member|invite|audit")
        .unwrap()
        .is_match(&joined)
    {
        add_tags(&mut tags, ["groups"]);
    }
    if joined.contains("notification") {
        add_tags(&mut tags, ["notifications"]);
    }
    if Regex::new(r"chat|channel|message|conversation|reaction")
        .unwrap()
        .is_match(&joined)
    {
        add_tags(&mut tags, ["chat", "groups"]);
    }
    if joined.contains("moderation") || joined.contains("report") || joined.contains("appeal") {
        add_tags(&mut tags, ["moderation", "posts", "users"]);
    }

    match viewer_id {
        Some(viewer_id) => {
            tags.insert(normalize_key_part(&format!("viewer:{viewer_id}")));
        }
        None => {
            tags.insert("viewer:anonymous".to_string());
        }
    }

    tags.into_iter().collect()
}

pub fn build_oracle_query_cache_key(
    identity: OracleQueryCacheIdentity<'_>,
) -> BuiltOracleQueryCacheKey {
    let serializable = SerializableOracleCacheIdentity {
        schema: ORACLE_QUERY_CACHE_SCHEMA_VERSION,
        sql: normalize_sql(identity.sql),
        binds: identity.binds,
        options: identity.options,
        viewer_id: identity.viewer_id,
        tag_versions: identity.tag_versions,
    };
    let cache_id = sha256_hex(
        &serde_json::to_string(&serializable).expect("oracle query cache identity serializes"),
    );
    let label = table_refs(identity.sql)
        .first()
        .map(|table| normalize_key_part(table))
        .unwrap_or_else(|| "oracle".to_string());

    BuiltOracleQueryCacheKey {
        key: format!("{ORACLE_QUERY_CACHE_PREFIX}:oracle:{label}:{cache_id}"),
        hit_key: format!("{ORACLE_QUERY_CACHE_HIT_PREFIX}:oracle:{cache_id}"),
        cache_id,
    }
}

fn normalize_sql(sql: &str) -> String {
    Regex::new(r"\s+")
        .unwrap()
        .replace_all(sql.trim(), " ")
        .to_string()
}

fn strip_leading_sql_comments(sql: &str) -> String {
    let line_comment = Regex::new(r"(?s)^\s*--[^\n\r]*(?:\r?\n|$)").unwrap();
    let block_comment = Regex::new(r"(?s)^\s*/\*.*?\*/").unwrap();
    let mut current = sql.trim().to_string();

    loop {
        let next = block_comment
            .replace(&line_comment.replace(&current, ""), "")
            .trim()
            .to_string();
        if next == current {
            return current;
        }
        current = next;
    }
}

fn normalized_sql_for_match(sql: &str) -> String {
    normalize_sql(&strip_leading_sql_comments(sql)).to_ascii_lowercase()
}

fn is_sensitive_sql(normalized: &str) -> bool {
    [
        "password_hash",
        "access_token",
        "refresh_token",
        "access_jti",
        "refresh_jti",
        "verification_code",
        "n_auth_sessions",
        "n_user_sessions",
        "sessions",
    ]
    .iter()
    .any(|token| normalized.contains(token))
}

fn normalize_table_name(input: &str) -> String {
    input
        .trim_matches('"')
        .rsplit('.')
        .next()
        .unwrap_or(input)
        .to_ascii_lowercase()
}

fn add_tags<const N: usize>(tags: &mut BTreeSet<String>, values: [&str; N]) {
    for value in values {
        tags.insert(normalize_key_part(value));
    }
}
