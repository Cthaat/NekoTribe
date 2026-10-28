//! Internal non-streaming provider transport. Tools are proposals only; decoded
//! structured objects still require business validation and authorization.
use super::model_config::SelectionSnapshot;
use serde::Serialize;
use serde_json::{json, Map, Value};
use std::{collections::HashSet, sync::Arc, time::Duration};
use tokio::sync::watch;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransportError(pub &'static str);
impl TransportError {
    pub fn code(&self) -> &'static str {
        self.0
    }
}
impl std::fmt::Display for TransportError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}
impl std::error::Error for TransportError {}
const INVALID: TransportError = TransportError("INVALID_PROVIDER_RESPONSE");
const INVALID_REQUEST: TransportError = TransportError("INVALID_REQUEST");
const LIMIT: usize = 1048576;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolProposal {
    pub id: String,
    pub name: String,
    pub arguments: Map<String, Value>,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InferenceUsage {
    pub input_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InferenceResult {
    pub text: String,
    pub tool_calls: Vec<ToolProposal>,
    pub finish_reason: String,
    pub usage: InferenceUsage,
}
pub type CredentialResolver = Arc<dyn Fn(&str) -> Result<String, TransportError> + Send + Sync>;

pub struct Transport {
    resolver: Option<CredentialResolver>,
    timeout: Duration,
    client: reqwest::Client,
}
fn object(v: &Value) -> Result<&Map<String, Value>, TransportError> {
    v.as_object().ok_or(INVALID)
}
fn depth(v: &Value, max: usize) -> bool {
    let mut stack = vec![(v, 0)];
    while let Some((value, level)) = stack.pop() {
        match value {
            Value::Array(items) => {
                if level >= max {
                    return false;
                }
                stack.extend(items.iter().map(|v| (v, level + 1)));
            }
            Value::Object(items) => {
                if level >= max {
                    return false;
                }
                stack.extend(items.values().map(|v| (v, level + 1)));
            }
            _ => {}
        }
    }
    true
}
fn parse(data: &[u8], max: usize) -> Result<Value, TransportError> {
    // Reject invalid UTF-8/BOM and excess nesting before parsing.
    std::str::from_utf8(data).map_err(|_| INVALID)?;
    let mut level = 0usize;
    let mut quoted = false;
    let mut escaped = false;
    for byte in data {
        if quoted {
            if escaped {
                escaped = false
            } else if *byte == b'\\' {
                escaped = true
            } else if *byte == b'"' {
                quoted = false
            };
            continue;
        }
        match byte {
            b'"' => quoted = true,
            b'{' | b'[' => {
                level += 1;
                if level > max {
                    return Err(INVALID);
                }
            }
            b'}' | b']' => level = level.saturating_sub(1),
            _ => {}
        }
    }
    serde_json::from_slice(data).map_err(|_| INVALID)
}
fn exact(m: &Map<String, Value>, required: &[&str], optional: &[&str]) -> bool {
    required.iter().all(|k| m.contains_key(*k))
        && m.keys()
            .all(|k| required.contains(&k.as_str()) || optional.contains(&k.as_str()))
}
fn tool_name(name: &str) -> bool {
    let mut b = name.bytes();
    let Some(first) = b.next() else { return false };
    name.len() <= 64
        && (first.is_ascii_alphabetic() || first == b'_')
        && b.all(|v| v.is_ascii_alphanumeric() || v == b'_')
}
struct Encoded {
    body: Vec<u8>,
    names: HashSet<String>,
    structured: bool,
}
fn encode_history_messages(
    s: &SelectionSnapshot,
    messages: &[Value],
) -> Result<(Vec<Value>, bool), TransportError> {
    let mut output = Vec::with_capacity(messages.len());
    let mut pending: Vec<(String, String)> = Vec::new();
    let mut cursor = 0usize;
    let mut has_history = false;
    for value in messages {
        let message = value.as_object().ok_or(INVALID_REQUEST)?;
        let role = message
            .get("role")
            .and_then(Value::as_str)
            .ok_or(INVALID_REQUEST)?;
        let content = message
            .get("content")
            .and_then(Value::as_str)
            .ok_or(INVALID_REQUEST)?;
        if role == "tool" {
            if !exact(message, &["role", "content", "toolCallId"], &[]) {
                return Err(INVALID_REQUEST);
            }
            let (id, name) = pending.get(cursor).ok_or(INVALID_REQUEST)?;
            if message.get("toolCallId").and_then(Value::as_str) != Some(id.as_str()) {
                return Err(INVALID_REQUEST);
            }
            output.push(if s.adapter == "ollama" {
                json!({"role":"tool","tool_name":name,"content":content})
            } else {
                json!({"role":"tool","tool_call_id":id,"content":content})
            });
            cursor += 1;
            if cursor == pending.len() {
                pending.clear();
                cursor = 0;
            }
            continue;
        }
        if !pending.is_empty() || !matches!(role, "system" | "user" | "assistant") {
            return Err(INVALID_REQUEST);
        }
        if role != "assistant" || !message.contains_key("toolCalls") {
            if !exact(message, &["role", "content"], &[]) {
                return Err(INVALID_REQUEST);
            }
            output.push(value.clone());
            continue;
        }
        if !exact(message, &["role", "content", "toolCalls"], &[]) {
            return Err(INVALID_REQUEST);
        }
        let calls = message["toolCalls"].as_array().ok_or(INVALID_REQUEST)?;
        if calls.is_empty() || calls.len() > 32 {
            return Err(INVALID_REQUEST);
        }
        let mut ids = HashSet::new();
        let mut provider_calls = Vec::with_capacity(calls.len());
        for (index, raw) in calls.iter().enumerate() {
            let call = raw.as_object().ok_or(INVALID_REQUEST)?;
            if !exact(call, &["id", "name", "arguments"], &[]) {
                return Err(INVALID_REQUEST);
            }
            let id = call["id"].as_str().ok_or(INVALID_REQUEST)?;
            let name = call["name"].as_str().ok_or(INVALID_REQUEST)?;
            let args = call["arguments"].as_object().ok_or(INVALID_REQUEST)?;
            if id.is_empty()
                || id.chars().count() > 128
                || !ids.insert(id.to_owned())
                || !tool_name(name)
            {
                return Err(INVALID_REQUEST);
            }
            pending.push((id.to_owned(), name.to_owned()));
            provider_calls.push(if s.adapter == "ollama" {
                json!({"type":"function","function":{"index":index,"name":name,"arguments":args}})
            } else {
                let arguments = serde_json::to_string(args).map_err(|_| INVALID_REQUEST)?;
                json!({"id":id,"type":"function","function":{"name":name,"arguments":arguments}})
            });
        }
        has_history = true;
        output.push(json!({"role":"assistant","content":content,"tool_calls":provider_calls}));
    }
    if !pending.is_empty() {
        return Err(INVALID_REQUEST);
    }
    Ok((output, has_history))
}
fn encode(s: &SelectionSnapshot, input: &Value) -> Result<Encoded, TransportError> {
    if !depth(input, 64) {
        return Err(INVALID_REQUEST);
    }
    let request = input.as_object().ok_or(INVALID_REQUEST)?;
    if !exact(request, &["messages"], &["tools", "responseSchema"]) {
        return Err(INVALID_REQUEST);
    }
    let messages = request["messages"].as_array().ok_or(INVALID_REQUEST)?;
    if messages.is_empty() || messages.len() > 128 {
        return Err(INVALID_REQUEST);
    }
    let (encoded_messages, has_history) = encode_history_messages(s, messages)?;
    let empty = Vec::new();
    let tools = match request.get("tools") {
        None => &empty,
        Some(v) => v.as_array().ok_or(INVALID_REQUEST)?,
    };
    if tools.len() > 32 {
        return Err(INVALID_REQUEST);
    }
    let mut names = HashSet::new();
    let mut encoded_tools = Vec::new();
    for value in tools {
        let tool = value.as_object().ok_or(INVALID_REQUEST)?;
        if !exact(tool, &["name", "description", "parameters"], &[]) {
            return Err(INVALID_REQUEST);
        }
        let name = tool["name"].as_str().ok_or(INVALID_REQUEST)?;
        if !tool_name(name)
            || !names.insert(name.to_owned())
            || !tool["description"].is_string()
            || !tool["parameters"].is_object()
            || tool["parameters"]["type"] != "object"
        {
            return Err(INVALID_REQUEST);
        }
        encoded_tools.push(json!({"type":"function","function":tool}));
    }
    let schema = request.get("responseSchema");
    if let Some(v) = schema {
        if !v.is_object() || v["type"] != "object" || !tools.is_empty() {
            return Err(INVALID_REQUEST);
        }
    }
    if ((!tools.is_empty() || has_history) && !s.capabilities.iter().any(|v| v == "tools"))
        || (schema.is_some() && !s.capabilities.iter().any(|v| v == "structured-output"))
    {
        return Err(TransportError("UNSUPPORTED_CAPABILITY"));
    }
    let mut body = json!({"model":s.model,"messages":encoded_messages,"stream":false});
    match s.adapter.as_str() {
        "openai-compatible" => {
            body["n"] = json!(1);
            body["max_tokens"] = json!(s.max_output_tokens)
        }
        "ollama" => {
            body["options"] =
                json!({"num_predict":s.max_output_tokens,"num_ctx":s.context_window_tokens})
        }
        _ => return Err(INVALID_REQUEST),
    }
    if !tools.is_empty() {
        body["tools"] = Value::Array(encoded_tools)
    }
    if let Some(schema) = schema {
        if s.adapter == "ollama" {
            body["format"] = schema.clone()
        } else {
            body["response_format"] = json!({"type":"json_schema","json_schema":{"name":"output","strict":true,"schema":schema}})
        }
    }
    if !depth(&body, 70) {
        return Err(INVALID_REQUEST);
    }
    let body = serde_json::to_vec(&body).map_err(|_| INVALID_REQUEST)?;
    if body.len() > LIMIT {
        return Err(INVALID_REQUEST);
    }
    Ok(Encoded {
        body,
        names,
        structured: schema.is_some(),
    })
}
fn tokens(m: &Map<String, Value>, key: &str) -> Result<Option<u64>, TransportError> {
    let Some(v) = m.get(key) else { return Ok(None) };
    let number = v.as_f64().ok_or(INVALID)?;
    if !number.is_finite() || !(0.0..=9007199254740991.0).contains(&number) || number.fract() != 0.0
    {
        return Err(INVALID);
    }
    Ok(Some(number as u64))
}
fn normalize(
    s: &SelectionSnapshot,
    raw: Value,
    names: &HashSet<String>,
    structured: bool,
) -> Result<InferenceResult, TransportError> {
    let response = object(&raw)?;
    let openai = s.adapter == "openai-compatible";
    let (message, mut finish, input_tokens, output_tokens) = if openai {
        let choices = response
            .get("choices")
            .and_then(Value::as_array)
            .ok_or(INVALID)?;
        if choices.len() != 1 {
            return Err(INVALID);
        }
        let choice = object(&choices[0])?;
        if choice.get("index").and_then(Value::as_f64) != Some(0.0) {
            return Err(INVALID);
        }
        let finish = match choice.get("finish_reason").and_then(Value::as_str) {
            Some("stop") => "stop",
            Some("length") => "length",
            Some("tool_calls") => "tool-calls",
            Some("content_filter") => "content-filter",
            _ => return Err(INVALID),
        };
        let empty = Map::new();
        let usage = match response.get("usage") {
            None | Some(Value::Null) => &empty,
            Some(v) => object(v)?,
        };
        (
            object(choice.get("message").ok_or(INVALID)?)?,
            finish,
            tokens(usage, "prompt_tokens")?,
            tokens(usage, "completion_tokens")?,
        )
    } else {
        if response.get("done") != Some(&Value::Bool(true)) {
            return Err(INVALID);
        }
        let finish = match response.get("done_reason").and_then(Value::as_str) {
            Some("stop") => "stop",
            Some("length") => "length",
            _ => return Err(INVALID),
        };
        (
            object(response.get("message").ok_or(INVALID)?)?,
            finish,
            tokens(response, "prompt_eval_count")?,
            tokens(response, "eval_count")?,
        )
    };
    if message.get("role").and_then(Value::as_str) != Some("assistant") {
        return Err(INVALID);
    }
    let empty = Vec::new();
    let calls = match message.get("tool_calls") {
        None | Some(Value::Null) => &empty,
        Some(v) => v.as_array().ok_or(INVALID)?,
    };
    if calls.len() > 32 {
        return Err(INVALID);
    }
    let mut proposals = Vec::new();
    let mut ids = HashSet::new();
    for (index, value) in calls.iter().enumerate() {
        let call = object(value)?;
        if (openai || call.contains_key("type"))
            && call.get("type").and_then(Value::as_str) != Some("function")
        {
            return Err(INVALID);
        }
        let function = object(call.get("function").ok_or(INVALID)?)?;
        let name = function
            .get("name")
            .and_then(Value::as_str)
            .ok_or(INVALID)?;
        if !names.contains(name) {
            return Err(INVALID);
        }
        let id = if openai {
            let id = call.get("id").and_then(Value::as_str).ok_or(INVALID)?;
            if id.is_empty() || id.chars().count() > 128 || !ids.insert(id.to_owned()) {
                return Err(INVALID);
            }
            id.to_owned()
        } else {
            format!("ollama-{index}")
        };
        let args = function.get("arguments").ok_or(INVALID)?;
        let args = if openai {
            parse(args.as_str().ok_or(INVALID)?.as_bytes(), 64)?
        } else {
            if !depth(args, 64) {
                return Err(INVALID);
            }
            args.clone()
        };
        proposals.push(ToolProposal {
            id,
            name: name.to_owned(),
            arguments: object(&args)?.clone(),
        });
    }
    if !calls.is_empty() {
        if (openai && finish != "tool-calls") || (!openai && finish != "stop") {
            return Err(INVALID);
        }
        finish = "tool-calls"
    }
    let text = match message.get("content") {
        Some(Value::String(v)) => v.clone(),
        Some(Value::Null) if openai && !calls.is_empty() => String::new(),
        _ => return Err(INVALID),
    };
    if calls.is_empty() && (text.is_empty() || finish == "tool-calls") {
        return Err(INVALID);
    }
    if structured {
        if finish != "stop" {
            return Err(INVALID);
        }
        object(&parse(text.as_bytes(), 64)?)?;
    }
    Ok(InferenceResult {
        text,
        tool_calls: proposals,
        finish_reason: finish.to_owned(),
        usage: InferenceUsage {
            input_tokens,
            output_tokens,
        },
    })
}
async fn cancelled(mut signal: Option<watch::Receiver<bool>>) {
    if let Some(ref mut receiver) = signal {
        loop {
            if *receiver.borrow() {
                return;
            }
            if receiver.changed().await.is_err() {
                break;
            }
        }
    }
    std::future::pending::<()>().await;
}
impl Transport {
    pub fn new(
        resolver: Option<CredentialResolver>,
        timeout_ms: Option<u64>,
    ) -> Result<Self, TransportError> {
        let timeout = timeout_ms.unwrap_or(30000);
        if !(1..=300000).contains(&timeout) {
            return Err(INVALID_REQUEST);
        }
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .retry(reqwest::retry::never())
            .build()
            .map_err(|_| TransportError("PROVIDER_UNAVAILABLE"))?;
        Ok(Self {
            resolver,
            timeout: Duration::from_millis(timeout),
            client,
        })
    }
    /// A true watch value cancels this call. Dropping the future also cancels I/O.
    pub async fn infer(
        &self,
        snapshot: &SelectionSnapshot,
        input: &Value,
        cancel: Option<watch::Receiver<bool>>,
    ) -> Result<InferenceResult, TransportError> {
        if cancel.as_ref().is_some_and(|signal| *signal.borrow()) {
            return Err(TransportError("CANCELLED"));
        }
        let selection = snapshot.clone();
        let encoded = encode(&selection, input)?;
        let path = if selection.adapter == "ollama" {
            "/api/chat"
        } else {
            "/chat/completions"
        };
        let url = reqwest::Url::parse(&format!(
            "{}{path}",
            selection.base_url.trim_end_matches('/')
        ))
        .map_err(|_| INVALID_REQUEST)?;
        if !matches!(url.scheme(), "http" | "https")
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
        {
            return Err(INVALID_REQUEST);
        }
        let mut headers = reqwest::header::HeaderMap::new();
        headers.insert(
            reqwest::header::CONTENT_TYPE,
            reqwest::header::HeaderValue::from_static("application/json"),
        );
        headers.insert(
            reqwest::header::ACCEPT_ENCODING,
            reqwest::header::HeaderValue::from_static("identity"),
        );
        if let Some(reference) = &selection.api_key_env {
            let resolver = self
                .resolver
                .as_ref()
                .ok_or(TransportError("MISSING_CREDENTIAL"))?;
            let key = resolver(reference).map_err(|_| TransportError("MISSING_CREDENTIAL"))?;
            if key.is_empty() || !key.bytes().all(|v| (0x21..=0x7e).contains(&v)) {
                return Err(TransportError("MISSING_CREDENTIAL"));
            }
            let authorization = reqwest::header::HeaderValue::from_str(&format!("Bearer {key}"))
                .map_err(|_| TransportError("MISSING_CREDENTIAL"))?;
            headers.insert(reqwest::header::AUTHORIZATION, authorization);
        }
        let operation = async {
            let mut response = self
                .client
                .post(url)
                .headers(headers)
                .body(encoded.body)
                .send()
                .await
                .map_err(|_| TransportError("PROVIDER_UNAVAILABLE"))?;
            if !response.status().is_success() {
                return Err(TransportError("PROVIDER_REJECTED"));
            }
            let encodings = response
                .headers()
                .get_all(reqwest::header::CONTENT_ENCODING);
            let values: Vec<_> = encodings.iter().collect();
            if !values.is_empty()
                && (values.len() != 1
                    || values[0]
                        .to_str()
                        .map(|v| {
                            !v.trim_matches(|c: char| {
                                matches!(c, ' ' | '\t' | '\n' | '\r' | '\x0b' | '\x0c')
                            })
                            .eq_ignore_ascii_case("identity")
                        })
                        .unwrap_or(true))
            {
                return Err(INVALID);
            }
            let mut bytes = Vec::new();
            while let Some(chunk) = response
                .chunk()
                .await
                .map_err(|_| TransportError("PROVIDER_UNAVAILABLE"))?
            {
                if bytes.len() + chunk.len() > LIMIT {
                    return Err(TransportError("RESPONSE_TOO_LARGE"));
                }
                bytes.extend_from_slice(&chunk)
            }
            normalize(
                &selection,
                parse(&bytes, 70)?,
                &encoded.names,
                encoded.structured,
            )
        };
        tokio::select! {biased;_ = cancelled(cancel)=>Err(TransportError("CANCELLED")),result=tokio::time::timeout(self.timeout,operation)=>result.map_err(|_|TransportError("TIMEOUT"))?}
    }
}
