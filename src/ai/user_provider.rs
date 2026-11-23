//! Account-owned, preset-bound credentials for writing only.
use super::{
    model_config::{self, SelectionSnapshot},
    transport::{CredentialResolver, TransportError},
};
use crate::{
    auth::{
        login::js_trim,
        readiness,
        sessions::{NativeState, SessionRepository},
    },
    db::{
        oracle::BindMap,
        tx::{OracleTx, Transaction},
        value::DbValue,
    },
    httpx::{errors::ApiError, response::V2Response},
    posts::bookmark::interaction_actor,
};
use aes_gcm::{
    Aes256Gcm, KeyInit, Nonce,
    aead::{Aead, Payload},
};
use axum::{
    Extension, Json,
    body::{Body, to_bytes},
    extract::State,
    http::{HeaderMap, Request, StatusCode},
    response::{IntoResponse, Response},
};
use base64::{
    Engine,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    sync::{Arc, OnceLock},
    time::Duration,
};

const MAX_REVISION: u64 = 999_999_999_999_999;
const CREDENTIAL_REFERENCE: &str = "PERSONAL_WRITING_KEY";

#[derive(Deserialize)]
struct Contract {
    default_base_url: String,
    profile_id: String,
    aad_version: String,
    max_key_bytes: usize,
    max_model_length: usize,
    max_base_url_length: usize,
    nonce_bytes: usize,
    tag_bytes: usize,
    test_timeout_ms: u64,
    test_max_response_bytes: usize,
    context_window_tokens: u32,
    max_output_tokens: u32,
    sql: Queries,
}

#[derive(Deserialize)]
struct Queries {
    read: String,
    lock_user: String,
    save: String,
    delete: String,
}

fn contract() -> &'static Contract {
    static CONTRACT: OnceLock<Contract> = OnceLock::new();
    CONTRACT.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../../contracts/requirements/ai-user-provider.json"
        ))
        .expect("valid personal AI provider contract")
    })
}

#[derive(Clone)]
pub struct Settings {
    master: Option<[u8; 32]>,
    provided: Option<String>,
}

impl Settings {
    pub fn from_lookup(get: impl Fn(&str) -> Option<String>) -> Self {
        let master = get("AI_USER_PROVIDER_SECRET_B64")
            .and_then(|text| STANDARD.decode(js_trim(&text)).ok())
            .and_then(|decoded| decoded.try_into().ok());
        let provided = get("AI_USER_PROVIDER_URL").and_then(|url| {
            let url = js_trim(&url).trim_end_matches('/');
            (url.len() <= contract().max_base_url_length
                && model_config::valid_url(url)
                && reqwest::Url::parse(url).is_ok())
            .then(|| url.to_owned())
        });
        Self { master, provided }
    }

    fn endpoint(&self, preset: &str) -> Option<&str> {
        match preset {
            "default" => Some(&contract().default_base_url),
            "provided" => self.provided.as_deref(),
            _ => None,
        }
    }

    fn credential(&self, user: u64, record: &Record) -> Option<String> {
        let endpoint = self.endpoint(&record.preset)?;
        if endpoint != record.base_url {
            return None;
        }
        open(
            self.master.as_ref()?,
            user,
            &record.preset,
            endpoint,
            &record.secret_box,
        )
    }

    fn view(&self, user: u64, record: Option<&Record>) -> Value {
        let mut presets = vec![json!({"id":"default","base_url":contract().default_base_url})];
        if let Some(base) = self.provided.as_ref() {
            presets.push(json!({"id":"provided","base_url":base}));
        }
        let config = record.map(|record| ConfigView {
            preset: &record.preset,
            model: &record.model,
            enabled: record.enabled,
            key_configured: true,
            revision: record.revision,
            reconnect_required: self.credential(user, record).is_none(),
        });
        json!({"setup_available":self.master.is_some(),"presets":presets,"config":config})
    }
}

pub(crate) fn configured(extension: Option<&Extension<Settings>>) -> &Settings {
    static SETTINGS: OnceLock<Settings> = OnceLock::new();
    if let Some(Extension(settings)) = extension {
        settings
    } else {
        SETTINGS.get_or_init(|| Settings::from_lookup(|key| std::env::var(key).ok()))
    }
}

#[derive(Serialize)]
struct ConfigView<'a> {
    preset: &'a str,
    model: &'a str,
    enabled: bool,
    key_configured: bool,
    revision: u64,
    reconnect_required: bool,
}

pub struct Record {
    preset: String,
    base_url: String,
    model: String,
    secret_box: String,
    enabled: bool,
    revision: u64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Input {
    preset: String,
    model: String,
    enabled: bool,
    #[serde(default, deserialize_with = "present_key")]
    api_key: Option<String>,
}

fn present_key<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<String>, D::Error> {
    String::deserialize(d).map(Some)
}

pub enum Operation {
    Read,
    Save(Input, Settings),
    Delete,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    Invalid,
    Missing,
    Conflict,
    Unavailable,
}

fn valid_key(key: &str) -> bool {
    (1..=contract().max_key_bytes).contains(&key.len())
        && key.bytes().all(|byte| (b'!'..=b'~').contains(&byte))
}

fn valid_model(model: &str) -> bool {
    (1..=contract().max_model_length).contains(&model.len())
        && model.as_bytes()[0].is_ascii_alphanumeric()
        && model
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._:/-".contains(&byte))
}

fn aad(user: u64, preset: &str, base_url: &str) -> String {
    format!("{}\n{user}\n{preset}\n{base_url}", contract().aad_version)
}

fn seal(
    master: &[u8; 32],
    user: u64,
    preset: &str,
    base_url: &str,
    api_key: &str,
) -> Option<String> {
    let mut nonce = [0u8; 12];
    getrandom::fill(&mut nonce).ok()?;
    let cipher = Aes256Gcm::new_from_slice(master).ok()?;
    let binding = aad(user, preset, base_url);
    let sealed = cipher
        .encrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: api_key.as_bytes(),
                aad: binding.as_bytes(),
            },
        )
        .ok()?;
    Some(URL_SAFE_NO_PAD.encode([nonce.as_slice(), &sealed].concat()))
}

fn open(
    master: &[u8; 32],
    user: u64,
    preset: &str,
    base_url: &str,
    packed: &str,
) -> Option<String> {
    let spec = contract();
    let overhead = spec.nonce_bytes + spec.tag_bytes;
    if packed.len() > (overhead + spec.max_key_bytes).div_ceil(3) * 4 {
        return None;
    }
    let bytes = URL_SAFE_NO_PAD.decode(packed).ok()?;
    if !(overhead + 1..=overhead + spec.max_key_bytes).contains(&bytes.len()) {
        return None;
    }
    let (nonce, sealed) = bytes.split_at(spec.nonce_bytes);
    let cipher = Aes256Gcm::new_from_slice(master).ok()?;
    let binding = aad(user, preset, base_url);
    let plain = cipher
        .decrypt(
            Nonce::from_slice(nonce),
            Payload {
                msg: sealed,
                aad: binding.as_bytes(),
            },
        )
        .ok()?;
    String::from_utf8(plain).ok().filter(|key| valid_key(key))
}

fn owner(user: u64) -> Result<BindMap, Error> {
    let user = i64::try_from(user)
        .ok()
        .filter(|value| (1..=9_007_199_254_740_991).contains(value))
        .ok_or(Error::Invalid)?;
    Ok(BindMap::from([("user_id".into(), DbValue::I64(user))]))
}

fn read(tx: &impl Transaction, user: u64) -> Result<Option<Record>, Error> {
    let rows = tx
        .query(&contract().sql.read, owner(user)?)
        .map_err(|_| Error::Unavailable)?;
    let row = match rows.as_slice() {
        [] => return Ok(None),
        [row] => row,
        _ => return Err(Error::Unavailable),
    };
    let text = |key: &str| {
        row.get(key)
            .and_then(DbValue::as_str)
            .ok_or(Error::Unavailable)
    };
    let enabled = match row.get("ENABLED").and_then(DbValue::as_i64) {
        Some(0) => false,
        Some(1) => true,
        _ => return Err(Error::Unavailable),
    };
    let revision = row
        .get("REVISION")
        .and_then(DbValue::as_i64)
        .and_then(|value| u64::try_from(value).ok())
        .filter(|value| (1..=MAX_REVISION).contains(value))
        .ok_or(Error::Unavailable)?;
    let preset = text("PRESET_ID")?;
    let model = text("MODEL_NAME")?;
    if !matches!(preset, "default" | "provided") || !valid_model(model) {
        return Err(Error::Unavailable);
    }
    Ok(Some(Record {
        preset: preset.into(),
        base_url: text("BASE_URL")?.into(),
        model: model.into(),
        secret_box: text("SECRET_BOX")?.into(),
        enabled,
        revision,
    }))
}

fn save(
    tx: &impl Transaction,
    user: u64,
    input: Input,
    settings: Settings,
) -> Result<Record, Error> {
    let master = settings.master.as_ref().ok_or(Error::Unavailable)?;
    let base_url = settings
        .endpoint(&input.preset)
        .ok_or(Error::Invalid)?
        .to_owned();
    if !valid_model(&input.model) || input.api_key.as_deref().is_some_and(|key| !valid_key(key)) {
        return Err(Error::Invalid);
    }
    let previous = read(tx, user)?;
    let revision = previous.as_ref().map_or(1, |record| record.revision + 1);
    if revision > MAX_REVISION {
        return Err(Error::Unavailable);
    }
    let secret_box = if let Some(ref key) = input.api_key {
        seal(master, user, &input.preset, &base_url, key).ok_or(Error::Unavailable)?
    } else {
        let previous = previous.ok_or(Error::Invalid)?;
        if previous.preset != input.preset || settings.credential(user, &previous).is_none() {
            return Err(Error::Conflict);
        }
        previous.secret_box
    };
    let record = Record {
        preset: input.preset,
        model: input.model,
        base_url,
        secret_box,
        enabled: input.enabled,
        revision,
    };
    let mut binds = owner(user)?;
    binds.extend([
        ("preset_id".into(), DbValue::String(record.preset.clone())),
        ("base_url".into(), DbValue::String(record.base_url.clone())),
        ("model_name".into(), DbValue::String(record.model.clone())),
        (
            "secret_box".into(),
            DbValue::String(record.secret_box.clone()),
        ),
        ("enabled".into(), DbValue::I64(i64::from(record.enabled))),
        ("revision".into(), DbValue::I64(record.revision as i64)),
    ]);
    if tx
        .execute(&contract().sql.save, binds)
        .map_err(|_| Error::Unavailable)?
        != 1
    {
        return Err(Error::Unavailable);
    }
    Ok(record)
}

fn transaction(
    tx: &impl Transaction,
    user: u64,
    operation: Operation,
) -> Result<Option<Record>, Error> {
    if matches!(operation, Operation::Read) {
        return read(tx, user);
    }
    let result = (|| {
        let owners = tx
            .query(&contract().sql.lock_user, owner(user)?)
            .map_err(|_| Error::Unavailable)?;
        if owners.len() != 1 {
            return Err(Error::Unavailable);
        }
        match operation {
            Operation::Read => unreachable!(),
            Operation::Save(input, settings) => save(tx, user, input, settings).map(Some),
            Operation::Delete => {
                let affected = tx
                    .execute(&contract().sql.delete, owner(user)?)
                    .map_err(|_| Error::Unavailable)?;
                if affected > 1 {
                    return Err(Error::Unavailable);
                }
                Ok(None)
            }
        }
    })();
    if result.is_ok() {
        tx.commit().map_err(|_| Error::Unavailable)?;
    } else {
        tx.rollback().map_err(|_| Error::Unavailable)?;
    }
    result
}

pub(crate) fn execute(
    connection: &oracle::Connection,
    user: u64,
    operation: Operation,
) -> Result<Option<Record>, Error> {
    let snapshot =
        readiness::collect_ai_user_provider_snapshot(connection).map_err(|_| Error::Unavailable)?;
    readiness::validate_feature_snapshot(&snapshot, "ai-user-provider")
        .map_err(|_| Error::Unavailable)?;
    transaction(&OracleTx::new(connection), user, operation)
}

async fn run(
    repository: &dyn SessionRepository,
    user: u64,
    operation: Operation,
) -> Result<Option<Record>, Error> {
    repository
        .personal_ai_provider(user, operation)
        .await
        .map_err(|_| Error::Unavailable)?
}

pub(crate) async fn writing_connection(
    repository: &dyn SessionRepository,
    settings: &Settings,
    user: u64,
) -> Result<Option<(SelectionSnapshot, CredentialResolver)>, Error> {
    if settings.master.is_none() {
        return Ok(None);
    }
    let Some(record) = run(repository, user, Operation::Read)
        .await?
        .filter(|record| record.enabled)
    else {
        return Ok(None);
    };
    let key = settings
        .credential(user, &record)
        .ok_or(Error::Unavailable)?;
    let resolver: CredentialResolver = Arc::new(move |reference| {
        if reference == CREDENTIAL_REFERENCE {
            Ok(key.clone())
        } else {
            Err(TransportError("MISSING_CREDENTIAL"))
        }
    });
    let spec = contract();
    let selection = SelectionSnapshot {
        configuration_revision: record.revision,
        role: "writing".into(),
        profile_id: spec.profile_id.clone(),
        provider_id: spec.profile_id.clone(),
        adapter: "openai-compatible".into(),
        base_url: record.base_url,
        model: record.model,
        model_version: None,
        api_key_env: Some(CREDENTIAL_REFERENCE.into()),
        capabilities: vec![],
        context_window_tokens: spec.context_window_tokens,
        max_output_tokens: spec.max_output_tokens,
    };
    Ok(Some((selection, resolver)))
}

async fn verify_model(record: &Record, key: &str) -> Result<(), Error> {
    let spec = contract();
    let timeout = Duration::from_millis(spec.test_timeout_ms);
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .retry(reqwest::retry::never())
        .build()
        .map_err(|_| Error::Unavailable)?;
    let request = async {
        let mut response = client
            .get(format!("{}/models", record.base_url))
            .bearer_auth(key)
            .send()
            .await
            .map_err(|_| Error::Unavailable)?;
        if !response.status().is_success()
            || response
                .content_length()
                .is_some_and(|length| length > spec.test_max_response_bytes as u64)
        {
            return Err(Error::Unavailable);
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| Error::Unavailable)? {
            if chunk.len() > spec.test_max_response_bytes - bytes.len() {
                return Err(Error::Unavailable);
            }
            bytes.extend_from_slice(&chunk);
        }
        let response: Value = serde_json::from_slice(&bytes).map_err(|_| Error::Unavailable)?;
        if !response["data"].as_array().is_some_and(|models| {
            models
                .iter()
                .any(|model| model["id"].as_str() == Some(record.model.as_str()))
        }) {
            return Err(Error::Unavailable);
        }
        Ok(())
    };
    tokio::time::timeout(timeout, request)
        .await
        .map_err(|_| Error::Unavailable)?
}

fn failure(error: Error) -> ApiError {
    match error {
        Error::Invalid => ApiError::bad_request("AI 提供方参数错误"),
        Error::Missing => ApiError::not_found("未配置 AI 提供方"),
        Error::Conflict => ApiError::conflict("请重新连接 AI 提供方"),
        Error::Unavailable => ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            50301,
            "服务暂不可用，请稍后重试。",
        ),
    }
}

pub(crate) async fn connection(
    State(state): State<NativeState>,
    settings: Option<Extension<Settings>>,
    request: Request<Body>,
) -> Response {
    async {
        let (parts, body) = request.into_parts();
        let actor = interaction_actor(&state, &parts.headers).await?;
        let settings = configured(settings.as_ref());
        let repository = state.repository.as_ref();
        let value = match parts.method {
            axum::http::Method::GET => {
                let record = if settings.master.is_some() {
                    run(repository, actor, Operation::Read)
                        .await
                        .map_err(failure)?
                } else {
                    None
                };
                settings.view(actor, record.as_ref())
            }
            axum::http::Method::PUT => {
                let invalid = || failure(Error::Invalid);
                let raw = to_bytes(body, 4096).await.map_err(|_| invalid())?;
                if raw.iter().find(|value| !value.is_ascii_whitespace()) != Some(&b'{') {
                    return Err(invalid());
                }
                let input: Input = serde_json::from_slice(&raw).map_err(|_| invalid())?;
                if !matches!(input.preset.as_str(), "default" | "provided")
                    || !valid_model(&input.model)
                    || input.api_key.as_deref().is_some_and(|key| !valid_key(key))
                {
                    return Err(invalid());
                }
                if settings.master.is_none() {
                    return Err(failure(Error::Unavailable));
                }
                if settings.endpoint(&input.preset).is_none() {
                    return Err(invalid());
                }
                let record = run(repository, actor, Operation::Save(input, settings.clone()))
                    .await
                    .map_err(failure)?
                    .ok_or_else(|| failure(Error::Unavailable))?;
                settings.view(actor, Some(&record))
            }
            axum::http::Method::DELETE => {
                run(repository, actor, Operation::Delete)
                    .await
                    .map_err(failure)?;
                Value::Null
            }
            _ => return Err(failure(Error::Invalid)),
        };
        Ok::<_, ApiError>(Json(V2Response::ok(value)))
    }
    .await
    .into_response()
}

pub(crate) async fn test_connection(
    State(state): State<NativeState>,
    settings: Option<Extension<Settings>>,
    headers: HeaderMap,
) -> Response {
    async {
        let actor = interaction_actor(&state, &headers).await?;
        let settings = configured(settings.as_ref());
        if settings.master.is_none() {
            return Err(failure(Error::Unavailable));
        }
        let record = run(state.repository.as_ref(), actor, Operation::Read)
            .await
            .map_err(failure)?
            .ok_or_else(|| failure(Error::Missing))?;
        let key = settings
            .credential(actor, &record)
            .ok_or_else(|| failure(Error::Conflict))?;
        verify_model(&record, &key).await.map_err(failure)?;
        Ok::<_, ApiError>(Json(V2Response::ok(json!({"verified":true}))))
    }
    .await
    .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::{oracle::DbError, row::DbRow};
    use std::{cell::RefCell, collections::HashMap};

    #[test]
    fn opens_shared_aes256gcm_envelope_only_for_exact_owner_and_preset() {
        let spec: Value = serde_json::from_str(include_str!(
            "../../contracts/requirements/ai-user-provider.json"
        ))
        .unwrap();
        let vector = &spec["crypto_vector"];
        let master: [u8; 32] = STANDARD
            .decode(vector["fixture_master_b64"].as_str().unwrap())
            .unwrap()
            .try_into()
            .unwrap();
        let packed = vector["fixture_box"].as_str().unwrap();
        let base = vector["base_url"].as_str().unwrap();
        let owner = vector["owner_id"].as_u64().unwrap();
        let preset = vector["preset"].as_str().unwrap();
        assert_eq!(
            open(&master, owner, preset, base, packed).as_deref(),
            vector["fixture_key"].as_str()
        );
        assert!(open(&master, owner + 1, preset, base, packed).is_none());
        assert!(open(&master, owner, "default", base, packed).is_none());
        assert!(open(&master, owner, preset, &base.to_ascii_lowercase(), packed).is_none());
        assert!(open(&master, owner, preset, &base.replace(":443", ""), packed).is_none());
    }

    #[derive(Default)]
    struct MemoryTx {
        rows: RefCell<HashMap<i64, DbRow>>,
        events: RefCell<Vec<&'static str>>,
    }

    impl Transaction for MemoryTx {
        fn query(&self, sql: &str, binds: BindMap) -> Result<Vec<DbRow>, DbError> {
            assert_eq!(binds.len(), 1);
            let id = binds["user_id"].as_i64().unwrap();
            if sql == contract().sql.lock_user {
                self.events.borrow_mut().push("lock owner");
                return Ok(vec![DbRow::new()]);
            }
            assert_eq!(sql, contract().sql.read);
            self.events.borrow_mut().push("read owner");
            Ok(self.rows.borrow().get(&id).cloned().into_iter().collect())
        }

        fn execute(&self, sql: &str, mut binds: BindMap) -> Result<u64, DbError> {
            let id = binds.remove("user_id").unwrap().as_i64().unwrap();
            if sql == contract().sql.delete {
                self.events.borrow_mut().push("delete owner");
                return Ok(u64::from(self.rows.borrow_mut().remove(&id).is_some()));
            }
            assert_eq!(sql, contract().sql.save);
            self.events.borrow_mut().push("save owner");
            let row = binds
                .into_iter()
                .map(|(key, value)| (key.to_ascii_uppercase(), value))
                .collect();
            self.rows.borrow_mut().insert(id, row);
            Ok(1)
        }

        fn commit(&self) -> Result<(), DbError> {
            self.events.borrow_mut().push("commit");
            Ok(())
        }
        fn rollback(&self) -> Result<(), DbError> {
            self.events.borrow_mut().push("rollback");
            Ok(())
        }
    }

    fn settings(provided: &str) -> Settings {
        Settings::from_lookup(|key| match key {
            "AI_USER_PROVIDER_SECRET_B64" => Some(STANDARD.encode([9; 32])),
            "AI_USER_PROVIDER_URL" => Some(provided.into()),
            _ => None,
        })
    }

    #[test]
    fn saves_ciphertext_under_owner_lock_and_refuses_to_reuse_key_on_address_drift() {
        let tx = MemoryTx::default();
        let configured = settings(" https://Example.com:443/v1/// ");
        assert_eq!(
            configured.endpoint("provided"),
            Some("https://Example.com:443/v1")
        );
        let input = |key: Option<&str>| Input {
            preset: "provided".into(),
            model: "fixture-v1".into(),
            enabled: true,
            api_key: key.map(str::to_owned),
        };
        let first = transaction(
            &tx,
            42,
            Operation::Save(input(Some("fixture-key")), configured.clone()),
        )
        .unwrap()
        .unwrap();
        assert_eq!(
            *tx.events.borrow(),
            ["lock owner", "read owner", "save owner", "commit"]
        );
        assert_eq!(first.revision, 1);
        assert_eq!(
            configured.credential(42, &first).as_deref(),
            Some("fixture-key")
        );
        assert!(configured.credential(43, &first).is_none());
        assert!(transaction(&tx, 43, Operation::Read).unwrap().is_none());
        let response = configured.view(42, Some(&first)).to_string();
        assert!(!response.contains(&first.secret_box) && !response.contains("fixture-key"));

        let second = transaction(&tx, 42, Operation::Save(input(None), configured))
            .unwrap()
            .unwrap();
        assert_eq!((second.revision, second.secret_box), (2, first.secret_box));
        tx.events.borrow_mut().clear();
        let changed = settings("https://Example.com/v2");
        assert!(matches!(
            transaction(&tx, 42, Operation::Save(input(None), changed)),
            Err(Error::Conflict)
        ));
        assert_eq!(
            *tx.events.borrow(),
            ["lock owner", "read owner", "rollback"]
        );
        assert_eq!(
            transaction(&tx, 42, Operation::Read)
                .unwrap()
                .unwrap()
                .revision,
            2
        );
        assert!(transaction(&tx, 42, Operation::Delete).unwrap().is_none());
        assert!(transaction(&tx, 42, Operation::Delete).unwrap().is_none());
    }

    #[derive(Default)]
    struct Repository {
        database: std::sync::Mutex<MemoryTx>,
        assistant: std::sync::Mutex<Option<super::super::conversation_store::AssistantInput>>,
        quota: std::sync::atomic::AtomicUsize,
        deny_skill: std::sync::atomic::AtomicBool,
    }

    impl SessionRepository for Repository {
        fn touch<'a>(
            &'a self,
            claims: &'a crate::auth::TokenClaims,
        ) -> crate::auth::sessions::StoreFuture<'a, u64> {
            Box::pin(async move { Ok(u64::from(claims.user_id == 42)) })
        }
        fn revoke<'a>(&'a self, _: u64, _: &'a str) -> crate::auth::sessions::StoreFuture<'a, u64> {
            Box::pin(async { Ok(0) })
        }
        fn revoke_others<'a>(
            &'a self,
            _: u64,
            _: &'a str,
        ) -> crate::auth::sessions::StoreFuture<'a, u64> {
            Box::pin(async { Ok(0) })
        }

        fn personal_ai_provider(
            &self,
            user: u64,
            operation: Operation,
        ) -> crate::auth::sessions::StoreFuture<'_, Result<Option<Record>, Error>> {
            Box::pin(async move {
                Ok(transaction(
                    &*self.database.lock().unwrap(),
                    user,
                    operation,
                ))
            })
        }

        fn ai_conversation(
            &self,
            actor: u64,
            operation: super::super::conversation_store::AiOperation,
            _: super::super::conversation_store::ModerationPolicy,
        ) -> crate::auth::sessions::StoreFuture<
            '_,
            Result<Value, super::super::conversation_store::Error>,
        > {
            use super::super::conversation_store::{AiOperation, Error};
            Box::pin(async move {
                assert_eq!(actor, 42);
                Ok(match operation {
                    AiOperation::Read(_) => Ok(json!({"purpose":"writing"})),
                    AiOperation::Recent(_) => {
                        Ok(json!([{"role":"user","sequence_no":1,"content":" draft a sample "}]))
                    }
                    AiOperation::Availability => Ok(
                        json!({"knowledge":true,"writing":true,"group":false,"moderation":false}),
                    ),
                    AiOperation::WritingSkill(_, _) => {
                        if self.deny_skill.load(std::sync::atomic::Ordering::Relaxed) {
                            Err(Error::Forbidden)
                        } else {
                            Ok(json!(3))
                        }
                    }
                    AiOperation::Assistant {
                        input,
                        skill_generation,
                        ..
                    } => {
                        assert_eq!(skill_generation, 3);
                        *self.assistant.lock().unwrap() = Some(input);
                        Ok(json!({"sequence_no":2,"role":"assistant"}))
                    }
                    _ => panic!("unexpected operation"),
                })
            })
        }
    }

    impl super::super::model_quota::AiModelQuotaLimiter for Repository {
        fn reserve(&self, actor: u64, cost: u64) -> super::super::model_quota::QuotaFuture<'_> {
            assert_eq!((actor, cost), (42, 1));
            self.quota
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            Box::pin(async { Ok(0) })
        }
    }

    fn test_app(
        repository: Arc<Repository>,
        settings: Settings,
        platform: &str,
    ) -> (axum::Router, String) {
        use crate::auth::{
            TokenCodec,
            sessions::{CorsPolicy, build_native_router},
        };
        let auth: Value =
            serde_json::from_str(include_str!("../../contracts/scenarios/auth-tokens.json"))
                .unwrap();
        let token = auth["cases"]
            .as_array()
            .unwrap()
            .iter()
            .find(|v| v["id"] == "access-hs256")
            .unwrap()["token"]
            .as_str()
            .unwrap();
        let codec = TokenCodec::new(
            auth["keys"]["access"].as_str().unwrap().as_bytes(),
            auth["keys"]["refresh"].as_str().unwrap().as_bytes(),
        )
        .unwrap();
        let platform = json!({"schemaVersion":1,"revision":81,"providers":[{"id":"local","adapter":"openai-compatible","baseUrl":platform}],
            "models":[{"id":"platform","providerId":"local","model":"fixture-platform","capabilities":["tools","structured-output"],"contextWindowTokens":8192,"maxOutputTokens":512}],
            "bindings":{"knowledge":"platform","writing":"platform","agent":"platform","moderation":"platform"}}).to_string();
        let app = build_native_router(
            codec,
            repository.clone(),
            CorsPolicy::default(),
            Arc::new(|| 1_700_000_000),
        )
        .layer(Extension(super::super::model_quota::AiModelQuota(
            repository,
        )))
        .layer(Extension(settings))
        .layer(Extension(super::super::writing::Settings::from_lookup(
            &|name| (name == "AI_MODEL_CONFIG_JSON").then(|| platform.clone()),
        )));
        (app, format!("Bearer {token}"))
    }

    async fn request(
        app: &axum::Router,
        token: &str,
        method: &str,
        path: &str,
        body: &str,
    ) -> (u16, String) {
        use tower::ServiceExt;
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(method)
                    .uri(path)
                    .header("authorization", token)
                    .body(Body::from(body.to_owned()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.headers()["cache-control"], "private, no-store");
        let status = response.status().as_u16();
        let body = String::from_utf8(
            to_bytes(response.into_body(), 65536)
                .await
                .unwrap()
                .to_vec(),
        )
        .unwrap();
        assert!(!body.contains("fixture-only-credential") && !body.contains("secret_box"));
        (status, body)
    }

    #[tokio::test]
    async fn native_routes_test_saved_connection_and_route_only_authorized_writing() {
        use axum::{
            Router,
            http::HeaderMap,
            routing::{get, post},
        };
        use std::sync::atomic::{AtomicUsize, Ordering};
        const CONFIG: &str = "/api/v2/users/me/ai-provider";
        const TEST: &str = "/api/v2/users/me/ai-provider/test";
        const GENERATE: &str =
            "/api/v2/ai/conversations/f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb/generate";
        const AVAILABILITY: &str = "/api/v2/ai/availability";
        let model_checks = Arc::new(AtomicUsize::new(0));
        let checked = model_checks.clone();
        let personal_calls = Arc::new(AtomicUsize::new(0));
        let used = personal_calls.clone();
        let provider = Router::new().route("/provider/models", get(move |headers: HeaderMap| {
            let checked = checked.clone();
            async move {
                checked.fetch_add(1, Ordering::Relaxed);
                assert_eq!(headers["authorization"], "Bearer fixture-only-credential");
                Json(json!({"data":[{"id":"fixture-personal"}]}))
            }
        })).route("/provider/chat/completions", post(move |headers: HeaderMap, Json(body): Json<Value>| {
            let used = used.clone();
            async move {
                used.fetch_add(1, Ordering::Relaxed);
                assert_eq!(headers["authorization"], "Bearer fixture-only-credential");
                assert_eq!(body["model"], "fixture-personal");
                assert_eq!(body["stream"], true);
                ([ ("content-type", "text/event-stream") ], concat!(
                    "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"personal draft\"},\"finish_reason\":null}]}\n\n",
                    "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
                    "data: [DONE]\n\n"
                )).into_response()
            }
        })).route("/platform/chat/completions", post(|headers: HeaderMap, Json(body): Json<Value>| async move {
            assert!(headers.get("authorization").is_none());
            assert_eq!(body["model"], "fixture-platform");
            Json(json!({"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"platform draft"}}]}))
        }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move { axum::serve(listener, provider).await.unwrap() });
        let repository = Arc::new(Repository::default());
        let (app, token) = test_app(
            repository.clone(),
            settings(&format!("{base}/provider/")),
            &format!("{base}/platform"),
        );
        assert_eq!(request(&app, &token, "POST", TEST, "").await.0, 404);
        assert_eq!(
            request(
                &app,
                &token,
                "PUT",
                CONFIG,
                r#"{"preset":"provided","model":"fixture-personal","enabled":false}"#
            )
            .await
            .0,
            400
        );
        assert_eq!(request(&app,&token,"PUT",CONFIG,r#"{"preset":"provided","model":"fixture-personal","enabled":false,"url":"https://invalid.test"}"#).await.0,400);
        let (status, body) = request(&app,&token,"PUT",CONFIG,r#"{"preset":"provided","model":"fixture-personal","enabled":false,"api_key":"fixture-only-credential"}"#).await;
        assert_eq!(status, 200);
        let json: Value = serde_json::from_str(&body).unwrap();
        assert_eq!(
            json["data"]["config"],
            json!({"preset":"provided","model":"fixture-personal","enabled":false,"key_configured":true,"revision":1,"reconnect_required":false})
        );
        assert_eq!(request(&app, &token, "POST", TEST, "").await.0, 200);
        assert_eq!(model_checks.load(Ordering::Relaxed), 1);
        assert_eq!(
            request(
                &app,
                &token,
                "PUT",
                CONFIG,
                r#"{"preset":"provided","model":"fixture-personal","enabled":true}"#
            )
            .await
            .0,
            200
        );
        let (personal_only, _) = test_app(
            repository.clone(),
            settings(&format!("{base}/provider")),
            "invalid-platform-url",
        );
        let (_, body) = request(&personal_only, &token, "GET", AVAILABILITY, "").await;
        let inference = &serde_json::from_str::<Value>(&body).unwrap()["data"]["inference"];
        assert_eq!(inference["writing"], true);
        assert_eq!(inference["knowledge"], false);
        repository.deny_skill.store(true, Ordering::Relaxed);
        assert_eq!(request(&app, &token, "POST", GENERATE, "").await.0, 403);
        assert_eq!(personal_calls.load(Ordering::Relaxed), 0);
        repository.deny_skill.store(false, Ordering::Relaxed);
        use tower::ServiceExt;
        let stream = app
            .clone()
            .oneshot(
                Request::post(GENERATE)
                    .header("authorization", &token)
                    .header("accept", "text/event-stream")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(stream.status(), 200);
        let stream = to_bytes(stream.into_body(), 4096).await.unwrap();
        let stream = std::str::from_utf8(&stream).unwrap();
        assert!(stream.contains("event: delta\ndata: {\"text\":\"personal draft\"}"));
        assert!(stream.contains("event: done") && !stream.contains("fixture-only-credential"));
        {
            let saved = repository.assistant.lock().unwrap();
            let saved = saved.as_ref().unwrap();
            assert_eq!(
                (
                    saved.model_id.as_str(),
                    saved.config_revision,
                    saved.content.as_str()
                ),
                ("personal-writing", 2, "personal draft")
            );
        }
        assert_eq!(repository.quota.load(Ordering::Relaxed), 1);
        let (changed, _) = test_app(
            repository.clone(),
            settings(&format!("{base}/changed")),
            &format!("{base}/platform"),
        );
        let (status, body) = request(&changed, &token, "GET", CONFIG, "").await;
        assert_eq!(status, 200);
        assert_eq!(
            serde_json::from_str::<Value>(&body).unwrap()["data"]["config"]["reconnect_required"],
            true
        );
        let (_, body) = request(&changed, &token, "GET", AVAILABILITY, "").await;
        assert_eq!(
            serde_json::from_str::<Value>(&body).unwrap()["data"]["inference"]["writing"],
            false
        );
        assert_eq!(request(&changed, &token, "POST", TEST, "").await.0, 409);
        assert_eq!(request(&changed, &token, "POST", GENERATE, "").await.0, 503);
        assert_eq!(personal_calls.load(Ordering::Relaxed), 1);
        let (disabled, _) = test_app(
            repository.clone(),
            Settings::from_lookup(|_| None),
            &format!("{base}/platform"),
        );
        let (_, body) = request(&disabled, &token, "GET", CONFIG, "").await;
        assert_eq!(
            serde_json::from_str::<Value>(&body).unwrap()["data"]["setup_available"],
            false
        );
        assert_eq!(
            request(&disabled, &token, "DELETE", CONFIG, "").await.0,
            200
        );
        assert_eq!(
            request(&disabled, &token, "DELETE", CONFIG, "").await.0,
            200
        );
        assert_eq!(request(&app, &token, "POST", GENERATE, "").await.0, 200);
        assert_eq!(
            repository
                .assistant
                .lock()
                .unwrap()
                .as_ref()
                .unwrap()
                .model_id,
            "platform"
        );
        task.abort();
    }

    #[tokio::test]
    async fn connection_probe_rejects_redirects_oversized_responses_and_missing_models() {
        use axum::{Router, routing::get};
        use std::sync::atomic::{AtomicUsize, Ordering};
        let hits = Arc::new(AtomicUsize::new(0));
        let target = hits.clone();
        let router = Router::new()
            .route(
                "/redirect/models",
                get(|| async { (StatusCode::TEMPORARY_REDIRECT, [("location", "/target")]) }),
            )
            .route(
                "/large/models",
                get(|| async { "0".repeat(contract().test_max_response_bytes + 1) }),
            )
            .route(
                "/missing/models",
                get(|| async { Json(json!({"data":[{"id":"other"}]})) }),
            )
            .route(
                "/target",
                get(move || async move {
                    target.fetch_add(1, Ordering::Relaxed);
                    StatusCode::OK
                }),
            );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
        for path in ["redirect", "large", "missing"] {
            let record = Record {
                preset: "provided".into(),
                base_url: format!("{base}/{path}"),
                model: "fixture".into(),
                secret_box: String::new(),
                enabled: false,
                revision: 1,
            };
            assert_eq!(
                verify_model(&record, "fixture-only-credential").await,
                Err(Error::Unavailable)
            );
        }
        assert_eq!(hits.load(Ordering::Relaxed), 0);
        task.abort();
    }
}
