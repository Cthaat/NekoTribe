use std::{sync::OnceLock, time::Duration};

use serde::{Deserialize, Serialize};

use super::{
    knowledge_source::{self, Candidate, Scope},
    knowledge_turn::{Hit, TurnError},
};

#[derive(Serialize)]
struct SearchRequest<'a> {
    query: &'a str,
    limit: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    group_id: Option<i64>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SearchResponse {
    version: u8,
    #[serde(default, deserialize_with = "present_group_id")]
    group_id: Option<i64>,
    candidates: Vec<SearchHit>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SearchHit {
    kind: String,
    id: i64,
    version: String,
    #[serde(default, deserialize_with = "present_chunk")]
    chunk: Option<usize>,
}

fn present_chunk<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<usize>, D::Error> {
    usize::deserialize(deserializer).map(Some)
}

fn present_group_id<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<i64>, D::Error> {
    i64::deserialize(deserializer).map(Some)
}

fn client() -> Result<&'static reqwest::Client, TurnError> {
    static HTTP: OnceLock<Option<reqwest::Client>> = OnceLock::new();
    HTTP.get_or_init(|| {
        reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(11))
            .build()
            .ok()
    })
    .as_ref()
    .ok_or(TurnError::Dependency)
}

#[cfg(test)]
fn index_endpoint(address: &str) -> Result<String, TurnError> {
    search_endpoint(address, Scope::Public)
}

fn search_endpoint(address: &str, scope: Scope) -> Result<String, TurnError> {
    if address.len() > 2048 || !super::model_config::valid_url(address) {
        return Err(TurnError::Dependency);
    }
    let path = match scope {
        Scope::Public => "/internal/v1/knowledge/search",
        Scope::Group(_) => "/internal/v1/knowledge/group-search",
        Scope::Personal => return Err(TurnError::InvalidSource),
    };
    Ok(format!("{}{path}", address.trim_end_matches('/')))
}

pub(super) async fn discover(
    address: &str,
    viewer: i64,
    query: &str,
    limit: usize,
) -> Result<Option<Vec<Hit>>, TurnError> {
    discover_scoped(address, viewer, Scope::Public, query, limit).await
}

pub(super) async fn discover_scoped(
    address: &str,
    viewer: i64,
    scope: Scope,
    query: &str,
    limit: usize,
) -> Result<Option<Vec<Hit>>, TurnError> {
    let query = crate::auth::login::js_trim(query);
    if !(1..=20).contains(&limit)
        || query.is_empty()
        || query.len() > 256
        || query.chars().any(|ch| ch <= '\u{1f}' || ch == '\u{7f}')
    {
        return Err(TurnError::InvalidSource);
    }
    let endpoint = search_endpoint(address, scope)?;
    let group_id = match scope {
        Scope::Group(id) if (1..=9_007_199_254_740_991).contains(&id) => Some(id),
        Scope::Group(_) => return Err(TurnError::InvalidSource),
        _ => None,
    };
    let token = std::env::var("AI_INDEX_SERVICE_TOKEN").map_err(|_| TurnError::Dependency)?;
    if !(32..=512).contains(&token.len()) || !token.bytes().all(|b| (b'!'..=b'~').contains(&b)) {
        return Err(TurnError::Dependency);
    }
    let lexical_fallback = group_id.is_some()
        || std::env::var("AI_KNOWLEDGE_INDEX_FALLBACK").is_ok_and(|value| value == "lexical");
    let response = client()?
        .post(endpoint)
        .bearer_auth(token)
        .header("x-neko-knowledge-chunks", "1")
        .header("x-neko-knowledge-group-sources", "1")
        .json(&SearchRequest {
            query,
            limit,
            group_id,
        })
        .send()
        .await;
    let mut response = match response {
        Ok(response) => response,
        Err(error)
            if lexical_fallback
                && (error.is_timeout() || error.is_connect() || error.is_request()) =>
        {
            return Ok(None);
        }
        Err(_) => return Err(TurnError::Dependency),
    };
    if response.status() != reqwest::StatusCode::OK {
        if lexical_fallback && matches!(response.status().as_u16(), 429 | 502 | 503 | 504) {
            return Ok(None);
        }
        return Err(TurnError::Dependency);
    }
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| TurnError::Dependency)? {
        if chunk.len() > 8192 - body.len() {
            return Err(TurnError::Dependency);
        }
        body.extend_from_slice(&chunk);
    }
    parse_response(&body, viewer, scope, group_id, limit).map(Some)
}

fn parse_response(
    body: &[u8],
    viewer: i64,
    scope: Scope,
    group_id: Option<i64>,
    limit: usize,
) -> Result<Vec<Hit>, TurnError> {
    let result: SearchResponse = serde_json::from_slice(body).map_err(|_| TurnError::Dependency)?;
    if result.version != 1
        || result.group_id != group_id
        || result.candidates.len() > limit
        || result
            .candidates
            .iter()
            .any(|hit| !scope.allows_kind(&hit.kind) || hit.chunk.is_some_and(|chunk| chunk > 102))
    {
        return Err(TurnError::Dependency);
    }
    let hits: Vec<_> = result
        .candidates
        .into_iter()
        .map(|hit| Hit {
            source: Candidate {
                kind: hit.kind,
                id: hit.id,
                version: hit.version,
            },
            chunk: hit.chunk,
            indexed: true,
        })
        .collect();
    let refs: Vec<_> = hits.iter().map(|hit| hit.source.clone()).collect();
    knowledge_source::validate(viewer, &refs).map_err(|_| TurnError::Dependency)?;
    Ok(hits)
}

#[cfg(test)]
mod tests {
    use super::{Candidate, SearchResponse, TurnError, discover, index_endpoint, knowledge_source};

    #[test]
    fn group_index_requires_matching_echo_and_only_group_sources() {
        use super::{Scope, SearchRequest, parse_response, search_endpoint};
        use serde_json::json;

        let group_id = 9_007_199_254_740_991;
        let scope = Scope::Group(group_id);
        assert_eq!(
            search_endpoint("http://localhost/", scope).unwrap(),
            "http://localhost/internal/v1/knowledge/group-search"
        );
        let request = SearchRequest {
            query: "term",
            limit: 2,
            group_id: Some(group_id),
        };
        assert_eq!(
            serde_json::to_value(request).unwrap(),
            json!({"query":"term","limit":2,"group_id":group_id})
        );
        for (echo, kind, accepted) in [
            (group_id, "group_post", true),
            (7, "group_post", false),
            (group_id, "post", false),
        ] {
            let response = json!({"version":1,"group_id":echo,"candidates":[{"kind":kind,"id":4,"version":"a".repeat(64)}]});
            assert_eq!(
                parse_response(
                    response.to_string().as_bytes(),
                    42,
                    scope,
                    Some(group_id),
                    2
                )
                .is_ok(),
                accepted
            );
        }
    }

    #[test]
    fn shared_group_response_keeps_version_and_chunk_for_revalidation() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../contracts/scenarios/ai-knowledge-index-fallback.json"
        ))
        .unwrap();
        let item = fixture["cases"]
            .as_array()
            .unwrap()
            .iter()
            .find(|case| case["expect"] == "group")
            .unwrap();
        let result: SearchResponse = serde_json::from_str(item["body"].as_str().unwrap()).unwrap();
        assert_eq!(result.version, 1);
        let [hit] = result.candidates.as_slice() else {
            panic!("expected a group hit")
        };
        assert_eq!(
            (hit.kind.as_str(), hit.id, hit.chunk),
            ("group_comment", 21, Some(2))
        );
        let reference = Candidate {
            kind: hit.kind.clone(),
            id: hit.id,
            version: hit.version.clone(),
        };
        assert!(knowledge_source::validate(42, &[reference]).is_ok());
    }

    #[tokio::test]
    async fn shared_invalid_search_inputs_are_rejected_before_transport() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../contracts/scenarios/ai-knowledge-index-fallback.json"
        ))
        .unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            if case["query"].is_null() && case["limit"].is_null() {
                continue;
            }
            let query = case["query"].as_str().unwrap_or("cats");
            let limit = case["limit"].as_u64().unwrap_or(20) as usize;
            // The malformed address would produce a dependency error if checked first.
            assert!(
                matches!(
                    discover("invalid", 42, query, limit).await,
                    Err(TurnError::InvalidSource)
                ),
                "did not reject {} before transport",
                case["id"]
            );
        }
    }

    #[test]
    fn shared_malformed_success_responses_are_rejected() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../contracts/scenarios/ai-knowledge-index-fallback.json"
        ))
        .unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            if case["status"] != 200 || case["expect"] != "error" {
                continue;
            }
            let body = case["body"].as_str().unwrap();
            assert!(
                serde_json::from_str::<SearchResponse>(body).is_err(),
                "accepted {}",
                case["id"]
            );
        }
    }

    #[test]
    fn shared_index_address_vectors() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../contracts/scenarios/ai-knowledge-index-fallback.json"
        ))
        .unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            let Some(address) = case["address"].as_str() else {
                continue;
            };
            let endpoint = index_endpoint(address);
            if case["noRequest"] == true {
                assert!(endpoint.is_err(), "accepted {}", case["id"]);
            } else {
                assert_eq!(
                    endpoint.ok().as_deref(),
                    Some("http://[::1]:3818/retrieval/internal/v1/knowledge/search")
                );
            }
        }
    }
}
