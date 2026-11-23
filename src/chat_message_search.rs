use crate::{
    auth::login::js_trim,
    db::{oracle::BindMap, value::DbValue},
    httpx::errors::ApiError,
    notification_websocket::MAX_SOCKET_ID,
};
use chrono::{DateTime, Datelike, SecondsFormat, Utc};
use serde::Deserialize;
use std::sync::OnceLock;

#[derive(Deserialize)]
struct Contract {
    max_keyword_bytes: usize,
    sql: Sql,
}

#[derive(Deserialize)]
struct Sql {
    keyword: String,
    channel_sender: String,
    direct_sender: String,
    start: String,
    end: String,
}

fn contract() -> &'static Contract {
    static CONTRACT: OnceLock<Contract> = OnceLock::new();
    CONTRACT.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../contracts/requirements/chat-message-search.json"
        ))
        .expect("valid chat message search contract")
    })
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Search {
    pub keyword: Option<String>,
    pub sender_id: Option<i64>,
    pub start_at: Option<DateTime<Utc>>,
    pub end_at: Option<DateTime<Utc>>,
}

#[derive(Clone, Copy)]
pub(crate) enum Scope {
    Channel,
    Direct,
}

impl Search {
    pub(crate) fn parse(query: &str) -> Result<Self, ApiError> {
        let uri = reqwest::Url::parse(&format!("http://localhost/?{query}"))
            .map_err(|_| ApiError::bad_request("搜索参数错误"))?;
        let parameter = |key: &str| {
            let mut matches = uri.query_pairs().filter(|(name, _)| name == key);
            let value = matches.next().map(|(_, value)| value);
            if matches.next().is_some() {
                return Err(invalid(key));
            }
            Ok(value)
        };
        let keyword = parameter("q")?.map(|value| js_trim(&value).to_owned());
        if keyword
            .as_ref()
            .is_some_and(|value| value.len() > contract().max_keyword_bytes)
        {
            return Err(invalid("q"));
        }
        let sender_id = parameter("sender_id")?
            .map(|raw| {
                raw.parse::<u64>()
                    .ok()
                    .filter(|id| {
                        (1..=MAX_SOCKET_ID).contains(id)
                            && !raw.starts_with('0')
                            && raw.bytes().all(|byte| byte.is_ascii_digit())
                    })
                    .map(|id| id as i64)
                    .ok_or_else(|| invalid("sender_id"))
            })
            .transpose()?;
        let start_at = parameter("start_at")?
            .map(|raw| timestamp(&raw, "start_at"))
            .transpose()?;
        let end_at = parameter("end_at")?
            .map(|raw| timestamp(&raw, "end_at"))
            .transpose()?;
        if start_at
            .zip(end_at)
            .is_some_and(|(start, end)| start >= end)
        {
            return Err(invalid("end_at"));
        }
        Ok(Self {
            keyword: keyword.filter(|value| !value.is_empty()),
            sender_id,
            start_at,
            end_at,
        })
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.keyword.is_none()
            && self.sender_id.is_none()
            && self.start_at.is_none()
            && self.end_at.is_none()
    }

    /// Both history statements reuse this predicate and the same filter bindings.
    pub(crate) fn predicates(&self, scope: Scope, binds: &mut BindMap) -> String {
        let sql = &contract().sql;
        let (alias, sender) = match scope {
            Scope::Channel => ("m", &sql.channel_sender),
            Scope::Direct => ("dm", &sql.direct_sender),
        };
        let time_bind = |value: DateTime<Utc>| {
            DbValue::String(value.to_rfc3339_opts(SecondsFormat::Millis, false))
        };
        let mut search = String::new();
        for (predicate, key, value) in [
            (
                &sql.keyword,
                "search_keyword",
                self.keyword.clone().map(DbValue::String),
            ),
            (sender, "search_sender", self.sender_id.map(DbValue::I64)),
            (&sql.start, "search_start", self.start_at.map(time_bind)),
            (&sql.end, "search_end", self.end_at.map(time_bind)),
        ] {
            if let Some(value) = value {
                search.push(' ');
                search.push_str(&predicate.replace("{message}", alias));
                binds.insert(key.to_owned(), value);
            }
        }
        search
    }
}

fn invalid(field: &str) -> ApiError {
    ApiError::bad_request(format!("{field} 参数错误"))
}

fn timestamp(raw: &str, field: &str) -> Result<DateTime<Utc>, ApiError> {
    let bad = || invalid(field);
    if !matches!(raw.as_bytes().get(10), Some(b'T' | b't')) {
        return Err(bad());
    }
    let instant = DateTime::parse_from_rfc3339(raw)
        .map_err(|_| bad())?
        .to_utc();
    // Oracle's timestamp mask accepts four-digit civil years and ordinary seconds.
    if !(1..=9999).contains(&instant.year()) || instant.timestamp_subsec_nanos() >= 1_000_000_000 {
        return Err(bad());
    }
    DateTime::from_timestamp_millis(instant.timestamp_millis()).ok_or_else(bad)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn combines_literal_search_with_exact_sender_and_normalized_bounds() {
        let filters = Search::parse("q=+CaT%25_%27+&sender_id=42&start_at=2026-01-01T08:00:00.123456%2B08:00&end_at=2026-01-01T00:00:00.125Z").unwrap();
        for (scope, alias, sender) in [
            (Scope::Channel, "m", "author_id"),
            (Scope::Direct, "dm", "sender_id"),
        ] {
            let mut binds = BindMap::new();
            let predicate = filters.predicates(scope, &mut binds);
            assert!(predicate.contains(&format!(
                "INSTR(LOWER({alias}.content), LOWER(:search_keyword)) > 0"
            )));
            assert!(predicate.contains(&format!("AND {alias}.{sender} = :search_sender")));
            assert!(predicate.contains(&format!("AND {alias}.created_at >=")));
            assert!(predicate.contains(&format!("AND {alias}.created_at <")));
            assert!(!predicate.contains("CaT"));
            assert_eq!(binds["search_keyword"], DbValue::String("CaT%_'".into()));
            assert_eq!(binds["search_sender"], DbValue::I64(42));
            assert_eq!(
                binds["search_start"],
                DbValue::String("2026-01-01T00:00:00.123+00:00".into())
            );
            assert_eq!(
                binds["search_end"],
                DbValue::String("2026-01-01T00:00:00.125+00:00".into())
            );
        }
    }

    #[test]
    fn rejects_invalid_filters_and_equal_millisecond_bounds() {
        for query in [
            "sender_id=0",
            "sender_id=9007199254740992",
            "sender_id=1e2",
            "sender_id=2&sender_id=3",
            "q=a&q=b",
            "start_at=",
            "start_at=2026-01-01",
            "end_at=2026-01-01+00:00:00Z",
            "end_at=2026-01-01T00:00:60Z",
            "start_at=0001-01-01T00:00:00%2B01:00",
            "start_at=2026-01-01T00:00:00.123001Z&end_at=2026-01-01T00:00:00.123999Z",
            "start_at=2026-01-01T00:00:01Z&end_at=2026-01-01T00:00:00Z",
        ] {
            assert!(Search::parse(query).is_err(), "{query}");
        }
        assert!(Search::parse(&format!("q={}", "é".repeat(201))).is_err());
        assert!(Search::parse("q=+%EF%BB%BF+").unwrap().is_empty());
        assert!(
            !Search::parse("end_at=2026-01-01T00:00:00Z")
                .unwrap()
                .is_empty()
        );
    }
}
