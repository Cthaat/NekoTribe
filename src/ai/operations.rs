use super::{
    conversation_http::ModerationSettings,
    model_config::{self, ModelRouter, SelectionSnapshot},
    model_quota::{self, AiModelQuota},
    skill_config_store, writing,
};
use crate::{
    auth::{
        session_repository::{nullable_text, row_number},
        sessions::NativeState,
    },
    db::row::DbRow,
    moderation::appeals::{authorized, private, server_error},
};
use axum::{extract::State, http::HeaderMap, response::Response, Extension, Json};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::{json, Value};
use std::{sync::OnceLock, time::Duration};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Contract {
    roles: Vec<String>,
    health_timeout_milliseconds: u64,
    index_timeout_milliseconds: u64,
    index_status_path: String,
    feedback_sql: String,
}

fn contract() -> &'static Contract {
    static VALUE: OnceLock<Contract> = OnceLock::new();
    VALUE.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../../contracts/requirements/ai-operations.json"
        ))
        .expect("valid AI operations contract")
    })
}

pub(crate) fn feedback_sql() -> &'static str {
    &contract().feedback_sql
}

fn feedback(rows: Vec<DbRow>) -> Vec<Value> {
    rows.iter().map(|row| {
        let helpful = row_number(row, "HELPFUL");
        let incorrect = row_number(row, "INCORRECT");
        let answered = helpful + incorrect;
        json!({
            "model_id": nullable_text(row, "MODEL_ID"),
            "model_version": nullable_text(row, "MODEL_VERSION"),
            "config_revision": nullable_text(row, "CONFIG_REVISION").and_then(|text| text.parse::<u64>().ok()),
            "helpful": helpful, "incorrect": incorrect, "insufficient": row_number(row, "INSUFFICIENT"),
            "accuracy": (answered > 0).then(|| helpful as f64 / answered as f64)
        })
    }).collect()
}

fn skill_status(rows: &[DbRow]) -> Option<Value> {
    let config = skill_config_store::decode_config(rows).ok().flatten()?;
    let items = config.registry.user_availability().skills().map(|skill| json!({
        "id": skill.id, "purpose": skill.purpose, "version": skill.version, "enabled": skill.enabled
    }));
    Some(json!({ "generation": config.generation, "items": items }))
}

async fn get<T: DeserializeOwned>(
    client: &reqwest::Client,
    url: String,
    key: Option<&str>,
    timeout: u64,
) -> Option<T> {
    let mut request = client.get(url).timeout(Duration::from_millis(timeout));
    if let Some(key) = key {
        request = request.bearer_auth(key);
    }
    let response = request.send().await.ok()?;
    if !response.status().is_success() {
        return None;
    }
    response.json().await.ok()
}

#[derive(Deserialize, Serialize)]
struct IndexStatus {
    point_count: u64,
    phase: Option<String>,
    last_success_at: Option<u64>,
    next_at: Option<u64>,
}

async fn index_status(client: &reqwest::Client) -> Option<IndexStatus> {
    let address = std::env::var("AI_KNOWLEDGE_INDEX_URL").ok()?;
    let token = std::env::var("AI_INDEX_SERVICE_TOKEN").ok()?;
    if !model_config::valid_url(&address) || token.len() < 32 {
        return None;
    }
    #[derive(Deserialize)]
    struct IndexResponse {
        version: u8,
        ready: bool,
        status: Option<IndexStatus>,
    }
    let config = contract();
    let response: IndexResponse = get(
        client,
        format!(
            "{}{}",
            address.trim_end_matches('/'),
            config.index_status_path
        ),
        Some(&token),
        config.index_timeout_milliseconds,
    )
    .await?;
    if response.version != 1 || !response.ready {
        return None;
    }
    let mut status = response.status?;
    status.phase = status.phase.filter(|phase| {
        matches!(
            phase.as_str(),
            "syncing" | "pruning" | "waiting" | "stopped"
        )
    });
    Some(status)
}

async fn probe_model(client: &reqwest::Client, model: &SelectionSnapshot) -> &'static str {
    let key = if let Some(reference) = &model.api_key_env {
        match std::env::var(reference) {
            Ok(key) if !key.is_empty() => Some(key),
            _ => return "missing_credential",
        }
    } else {
        None
    };
    let (endpoint, field, model_field) = if model.adapter == "ollama" {
        ("/api/tags", "models", "name")
    } else {
        ("/models", "data", "id")
    };
    let response: Option<Value> = get(
        client,
        format!("{}{endpoint}", model.base_url.trim_end_matches('/')),
        key.as_deref(),
        contract().health_timeout_milliseconds,
    )
    .await;
    let Some(response) = response else {
        return "unreachable";
    };
    let available = response[field].as_array().is_some_and(|rows| {
        rows.iter()
            .any(|row| row[model_field].as_str() == Some(&model.model))
    });
    if available {
        "ready"
    } else {
        "model_unavailable"
    }
}

async fn model_status(
    client: &reqwest::Client,
    settings: writing::Settings,
) -> (Vec<Value>, Vec<String>, Option<u64>) {
    let router = settings
        .configuration()
        .await
        .and_then(|raw| ModelRouter::from_json(&raw).ok());
    let mut nodes = Vec::new();
    let mut revision = None;
    let mut bound = Vec::new();
    for purpose in &contract().roles {
        let role = if purpose == "group" { "agent" } else { purpose };
        let model = router
            .as_ref()
            .and_then(|router| router.select(role, &[]).ok());
        if let Some(model) = &model {
            revision = Some(model.configuration_revision);
            if !nodes.contains(&model.provider_id) {
                nodes.push(model.provider_id.clone());
            }
        }
        bound.push(async move {
            let state = match &model {
                Some(model) => probe_model(client, model).await,
                None => "unconfigured",
            };
            json!({
                "purpose": purpose, "state": state,
                "provider_id": model.as_ref().map(|model| &model.provider_id),
                "model_id": model.as_ref().map(|model| &model.profile_id),
                "model_version": model.and_then(|model| model.model_version)
            })
        });
    }
    (futures_util::future::join_all(bound).await, nodes, revision)
}

pub(crate) async fn read(
    State(state): State<NativeState>,
    moderation: Option<Extension<ModerationSettings>>,
    settings: Option<Extension<writing::Settings>>,
    quota: Option<Extension<AiModelQuota>>,
    headers: HeaderMap,
) -> Response {
    private(async {
        authorized(&state, &headers, moderation).await?;
        let (feedback_rows, skills) = state.repository.ai_operations_data().await.map_err(|_| server_error())?;
        let client = reqwest::Client::builder().redirect(reqwest::redirect::Policy::none())
            .build().map_err(|_| server_error())?;
        let ((models, nodes, revision), index, global_quota) = tokio::join!(
            model_status(&client, settings.map(|value| value.0).unwrap_or_default()),
            index_status(&client),
            model_quota::service_usage(quota.as_ref().map(|value| &value.0))
        );
        Ok(Json(json!({"code":200,"message":"success","meta":null,"data":{
            "backend":"rust", "models":models, "nodes":nodes, "model_config_revision": revision,
            "index":index, "global_quota":global_quota, "feedback":feedback(feedback_rows), "skills":skill_status(&skills)
        }})))
    }.await)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::value::DbValue;

    #[test]
    fn feedback_accuracy_omits_insufficient_votes() {
        let reviewed = DbRow::from([
            ("HELPFUL".into(), DbValue::I64(3)),
            ("INCORRECT".into(), DbValue::I64(1)),
            ("INSUFFICIENT".into(), DbValue::I64(2)),
        ]);
        let insufficient = DbRow::from([("INSUFFICIENT".into(), DbValue::I64(4))]);
        let rows = feedback(vec![reviewed, insufficient]);
        assert_eq!(rows[0]["accuracy"], 0.75);
        assert_eq!(rows[0]["insufficient"], 2);
        assert!(rows[1]["accuracy"].is_null());
    }
}
