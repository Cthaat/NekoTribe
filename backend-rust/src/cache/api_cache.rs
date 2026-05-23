use std::collections::{BTreeMap, BTreeSet};

use serde::Serialize;

use crate::cache::tags::{
    normalize_key_part, sha256_hex, API_CACHE_HIT_PREFIX, API_CACHE_PREFIX,
    API_CACHE_SCHEMA_VERSION,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CacheTtlPolicy {
    pub ttl_seconds: u64,
    pub max_ttl_seconds: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BuiltCacheKey {
    pub key: String,
    pub hit_key: String,
    pub cache_id: String,
}

#[derive(Debug, Clone, Copy)]
pub struct ApiCacheIdentity<'a> {
    pub namespace: &'a str,
    pub method: &'a str,
    pub path: &'a str,
    pub query: &'a str,
    pub user_id: Option<i64>,
    pub tag_versions: &'a BTreeMap<String, String>,
}

#[derive(Debug, Serialize)]
struct SerializableApiCacheIdentity<'a> {
    schema: &'static str,
    namespace: &'a str,
    method: String,
    path: &'a str,
    query: String,
    scope: String,
    tag_versions: &'a BTreeMap<String, String>,
}

pub fn is_cacheable_request(method: &str, path: &str) -> bool {
    method.eq_ignore_ascii_case("GET")
        && path.starts_with("/api/v2/")
        && !is_sensitive_api_path(method, path)
}

pub fn should_invalidate_after_success(method: &str, path: &str) -> bool {
    let method = method.to_ascii_uppercase();
    !matches!(method.as_str(), "GET" | "HEAD" | "OPTIONS")
        && path.starts_with("/api/v2/")
        && !is_cache_neutral_mutation(method.as_str(), path)
}

pub fn ttl_policy_for_path(path: &str) -> CacheTtlPolicy {
    let segments = path_segments(path);
    let root = segments.first().map(String::as_str);
    let second = segments.get(1).map(String::as_str);
    let third = segments.get(2).map(String::as_str);

    if matches!(root, Some("chat" | "notifications"))
        || (root == Some("auth") && second == Some("sessions"))
    {
        return CacheTtlPolicy {
            ttl_seconds: 20,
            max_ttl_seconds: 120,
        };
    }

    if root == Some("moderation") {
        return CacheTtlPolicy {
            ttl_seconds: 45,
            max_ttl_seconds: 240,
        };
    }

    if (root == Some("posts") && second == Some("trending"))
        || (root == Some("groups") && second == Some("popular"))
        || (root == Some("tags") && second == Some("trending"))
    {
        return CacheTtlPolicy {
            ttl_seconds: 300,
            max_ttl_seconds: 900,
        };
    }

    if matches!(root, Some("posts" | "groups" | "users"))
        && second.is_some_and(is_numeric_segment)
        && third.is_none()
    {
        return CacheTtlPolicy {
            ttl_seconds: 120,
            max_ttl_seconds: 600,
        };
    }

    CacheTtlPolicy {
        ttl_seconds: 60,
        max_ttl_seconds: 300,
    }
}

pub fn tags_for_path(path: &str, user_id: Option<i64>) -> Vec<String> {
    let segments = path_segments(path);
    let root = segments.first().map(String::as_str).unwrap_or("v2");
    let second = segments.get(1).map(String::as_str);
    let third = segments.get(2).map(String::as_str);
    let fourth = segments.get(3).map(String::as_str);
    let mut tags = BTreeSet::new();

    add_viewer_tag(&mut tags, user_id);

    match root {
        "posts" => {
            add_tags(&mut tags, ["posts", "users", "tags"]);
            if second.is_some_and(is_numeric_segment) {
                add_tag(&mut tags, format!("post:{}", second.unwrap_or_default()));
                if let Some(third) = third {
                    add_tag(
                        &mut tags,
                        format!("post:{}:{third}", second.unwrap_or_default()),
                    );
                    if third == "comments" {
                        add_tag(&mut tags, "comments");
                    }
                }
            }
            if second == Some("trending") {
                add_tag(&mut tags, "trending");
            }
        }
        "comments" => add_tags(&mut tags, ["posts", "comments", "users"]),
        "users" => {
            add_tag(&mut tags, "users");
            if second == Some("me") {
                add_tags(&mut tags, ["account", "users"]);
                if let Some(user_id) = user_id {
                    add_tag(&mut tags, format!("user:{user_id}"));
                }
                if matches!(third, Some("posts" | "bookmarks")) {
                    add_tag(&mut tags, "posts");
                }
                if third == Some("groups") {
                    add_tag(&mut tags, "groups");
                }
            } else if second.is_some_and(is_numeric_segment) {
                add_tag(&mut tags, format!("user:{}", second.unwrap_or_default()));
            }
        }
        "groups" => {
            add_tags(&mut tags, ["groups", "users"]);
            if second.is_some_and(is_numeric_segment) {
                add_tag(&mut tags, format!("group:{}", second.unwrap_or_default()));
            }
            if segments.iter().any(|segment| segment == "posts") {
                add_tag(&mut tags, "posts");
            }
            if fourth.is_some_and(is_numeric_segment) {
                add_tag(
                    &mut tags,
                    format!("group-post:{}", fourth.unwrap_or_default()),
                );
            }
        }
        "chat" => add_tags(&mut tags, ["chat", "groups"]),
        "notifications" => add_tags(&mut tags, ["notifications", "users"]),
        "moderation" | "reports" => add_tags(&mut tags, ["moderation", "posts", "users", "groups"]),
        "tags" => add_tags(&mut tags, ["tags", "posts"]),
        "media" => add_tags(&mut tags, ["media", "posts", "users"]),
        "auth" => add_tag(&mut tags, "auth"),
        other => add_tag(&mut tags, other),
    }

    tags.into_iter().collect()
}

pub fn build_api_cache_key(identity: ApiCacheIdentity<'_>) -> BuiltCacheKey {
    let scope = identity
        .user_id
        .map(|id| format!("user:{id}"))
        .unwrap_or_else(|| "anonymous".to_string());
    let serializable = SerializableApiCacheIdentity {
        schema: API_CACHE_SCHEMA_VERSION,
        namespace: identity.namespace,
        method: identity.method.to_ascii_uppercase(),
        path: identity.path,
        query: canonical_query(identity.query),
        scope,
        tag_versions: identity.tag_versions,
    };
    let cache_id =
        sha256_hex(&serde_json::to_string(&serializable).expect("api cache identity serializes"));
    let label = normalize_key_part(identity.path.trim_start_matches("/api/v2/"));

    BuiltCacheKey {
        key: format!(
            "{API_CACHE_PREFIX}:{}:{}:{}",
            identity.namespace,
            label.chars().take(80).collect::<String>(),
            cache_id
        ),
        hit_key: format!(
            "{}:{}:{}",
            API_CACHE_HIT_PREFIX, identity.namespace, cache_id
        ),
        cache_id,
    }
}

fn canonical_query(query: &str) -> String {
    let mut pairs = query
        .split('&')
        .filter(|pair| !pair.is_empty())
        .map(|pair| {
            let mut parts = pair.splitn(2, '=');
            (
                parts.next().unwrap_or_default().to_string(),
                parts.next().unwrap_or_default().to_string(),
            )
        })
        .collect::<Vec<_>>();
    pairs.sort();
    pairs
        .into_iter()
        .map(|(key, value)| format!("{key}={value}"))
        .collect::<Vec<_>>()
        .join("&")
}

fn is_sensitive_api_path(method: &str, path: &str) -> bool {
    let method = method.to_ascii_uppercase();
    path == "/api/v2/auth/otp"
        || path == "/api/v2/auth/otp/verification"
        || path.starts_with("/api/v2/auth/two-factor/challenges")
        || (method == "PATCH" && path == "/api/v2/auth/tokens/current")
}

fn is_cache_neutral_mutation(method: &str, path: &str) -> bool {
    path == "/api/v2/auth/otp"
        || path == "/api/v2/auth/otp/verification"
        || path.starts_with("/api/v2/auth/two-factor/challenges")
        || (method == "PATCH" && path == "/api/v2/auth/tokens/current")
}

fn path_segments(path: &str) -> Vec<String> {
    path.trim_start_matches("/api/v2/")
        .split('/')
        .filter(|segment| !segment.is_empty())
        .map(ToString::to_string)
        .collect()
}

fn is_numeric_segment(segment: &str) -> bool {
    segment.chars().all(|ch| ch.is_ascii_digit()) && !segment.is_empty()
}

fn add_viewer_tag(tags: &mut BTreeSet<String>, user_id: Option<i64>) {
    match user_id {
        Some(user_id) => add_tag(tags, format!("viewer:{user_id}")),
        None => add_tag(tags, "viewer:anonymous"),
    }
}

fn add_tags<const N: usize>(tags: &mut BTreeSet<String>, values: [&str; N]) {
    for value in values {
        add_tag(tags, value);
    }
}

fn add_tag(tags: &mut BTreeSet<String>, value: impl AsRef<str>) {
    tags.insert(normalize_key_part(value.as_ref()));
}
