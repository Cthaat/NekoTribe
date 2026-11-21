use std::{sync::OnceLock, time::Duration};

use serde::{Deserialize, Serialize};

use super::{
    knowledge_source::{self, Candidate},
    knowledge_turn::{Hit, TurnError},
};

#[derive(Serialize)]
struct SearchRequest<'a> {
    query: &'a str,
    limit: usize,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SearchResponse {
    version: u8,
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

fn index_endpoint(address: &str) -> Result<String, TurnError> {
    if address.len() > 2048 || !super::model_config::valid_url(address) {
        return Err(TurnError::Dependency);
    }
    Ok(format!(
        "{}/internal/v1/knowledge/search",
        address.trim_end_matches('/')
    ))
}

pub(super) async fn discover(
    address: &str,
    viewer: i64,
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
    let endpoint = index_endpoint(address)?;
    let token = std::env::var("AI_INDEX_SERVICE_TOKEN").map_err(|_| TurnError::Dependency)?;
    if !(32..=512).contains(&token.len()) || !token.bytes().all(|b| (b'!'..=b'~').contains(&b)) {
        return Err(TurnError::Dependency);
    }
    let lexical_fallback =
        std::env::var("AI_KNOWLEDGE_INDEX_FALLBACK").is_ok_and(|value| value == "lexical");
    let response = client()?
        .post(endpoint)
        .bearer_auth(token)
        .header("x-neko-knowledge-chunks", "1")
        .header("x-neko-knowledge-group-sources", "1")
        .json(&SearchRequest { query, limit })
        .send()
        .await;
    let mut response = match response {
        Ok(response) => response,
        Err(error)
            if lexical_fallback
                && (error.is_timeout() || error.is_connect() || error.is_request()) =>
        {
            return Ok(None)
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
    let result: SearchResponse =
        serde_json::from_slice(&body).map_err(|_| TurnError::Dependency)?;
    if result.version != 1
        || result.candidates.len() > limit
        || result
            .candidates
            .iter()
            .any(|hit| hit.chunk.is_some_and(|chunk| chunk > 102))
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
    Ok(Some(hits))
}

#[cfg(test)]
mod tests {
    use super::{discover, index_endpoint, knowledge_source, Candidate, SearchResponse, TurnError};

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
