use nekotribe_backend::ai::{
    model_config::SelectionSnapshot,
    transport::{CredentialResolver, Transport, TransportError},
};
use serde_json::{json, Value};
use std::{
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    thread,
    time::Duration,
};

fn vectors() -> Vec<Value> {
    let root: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/ai-inference-transport.json"
    ))
    .unwrap();
    let mut cases = root["cases"].as_array().unwrap().clone();
    assert_eq!(cases.len(), 55);
    let history: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/ai-tool-history.json")).unwrap();
    let extra = history["cases"].as_array().unwrap();
    assert_eq!(extra.len(), 24);
    cases.extend(extra.iter().cloned());
    cases
}
fn selection(v: &Value) -> SelectionSnapshot {
    SelectionSnapshot {
        configuration_revision: v["configurationRevision"].as_u64().unwrap(),
        role: v["role"].as_str().unwrap().into(),
        profile_id: v["profileId"].as_str().unwrap().into(),
        provider_id: v["providerId"].as_str().unwrap().into(),
        adapter: v["adapter"].as_str().unwrap().into(),
        base_url: v["baseUrl"].as_str().unwrap().into(),
        model: v["model"].as_str().unwrap().into(),
        model_version: None,
        api_key_env: v["apiKeyEnv"].as_str().map(String::from),
        capabilities: v["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap().into())
            .collect(),
        context_window_tokens: v["contextWindowTokens"].as_u64().unwrap() as u32,
        max_output_tokens: v["maxOutputTokens"].as_u64().unwrap() as u32,
    }
}

struct FakeServer {
    url: String,
    stop: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<()>>,
}
impl FakeServer {
    fn new<F: Fn(&mut TcpStream) + Send + 'static>(handler: F) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        listener.set_nonblocking(true).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let flag = stop.clone();
        let worker = thread::spawn(move || {
            while !flag.load(Ordering::SeqCst) {
                match listener.accept() {
                    Ok((mut socket, _)) => {
                        socket
                            .set_read_timeout(Some(Duration::from_secs(2)))
                            .unwrap();
                        socket
                            .set_write_timeout(Some(Duration::from_secs(2)))
                            .unwrap();
                        handler(&mut socket)
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(1))
                    }
                    Err(e) => panic!("{e}"),
                }
            }
        });
        Self {
            url,
            stop,
            worker: Some(worker),
        }
    }
}
impl Drop for FakeServer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        self.worker.take().unwrap().join().unwrap();
    }
}
fn read_request(socket: &mut TcpStream) -> (String, Value) {
    let mut data = Vec::new();
    let mut byte = [0];
    while !data.ends_with(b"\r\n\r\n") {
        socket.read_exact(&mut byte).unwrap();
        data.push(byte[0]);
    }
    let headers = String::from_utf8(data).unwrap();
    let length = headers
        .lines()
        .find_map(|line| {
            line.to_ascii_lowercase()
                .strip_prefix("content-length: ")
                .map(|v| v.parse::<usize>().unwrap())
        })
        .unwrap();
    let mut body = vec![0; length];
    socket.read_exact(&mut body).unwrap();
    (headers, serde_json::from_slice(&body).unwrap())
}
fn respond(socket: &mut TcpStream, status: u16, body: &[u8], extra: &str) {
    let _ = write!(
        socket,
        "HTTP/1.1 {status} Synthetic\r\nContent-Length: {}\r\nConnection: close\r\n{extra}\r\n",
        body.len()
    );
    let _ = socket.write_all(body);
}
fn safe_error(error: TransportError, expected: &str) {
    assert_eq!(error.code(), expected);
    assert!(!format!("{error:?}").contains("never-print"));
}

#[tokio::test]
async fn common_transport_vectors() {
    for v in vectors() {
        let calls = Arc::new(Mutex::new(0));
        let seen = calls.clone();
        let case = v.clone();
        let server = FakeServer::new(move |socket| {
            *seen.lock().unwrap() += 1;
            let (headers, body) = read_request(socket);
            assert!(headers.starts_with(&format!(
                "POST {} HTTP/1.1",
                case["expectedPath"].as_str().unwrap()
            )));
            let headers = headers.to_ascii_lowercase();
            assert!(headers.contains("accept-encoding: identity"));
            assert!(!headers.contains("cookie:"));
            if let Some(auth) = case["expectedAuthorization"].as_str() {
                assert!(headers.contains(&format!("authorization: {}", auth.to_ascii_lowercase())))
            } else {
                assert!(!headers.contains("authorization:"))
            };
            if case.get("expectedBody").is_some() {
                assert_eq!(body, case["expectedBody"])
            };
            let response = case["responseText"]
                .as_str()
                .map(String::from)
                .unwrap_or_else(|| case["response"].to_string());
            respond(
                socket,
                case["status"].as_u64().unwrap() as u16,
                response.as_bytes(),
                "",
            );
        });
        let mut s = selection(&v["selection"]);
        let parsed = reqwest::Url::parse(&s.base_url).unwrap();
        s.base_url = format!("{}{}", server.url, parsed.path());
        let credentials = v["credentials"].clone();
        let resolver: CredentialResolver = Arc::new(move |reference| {
            Ok(credentials[reference].as_str().unwrap_or("").to_string())
        });
        let transport = Transport::new(Some(resolver), None).unwrap();
        let result = transport.infer(&s, &v["request"], None).await;
        if let Some(expected) = v["expectedError"].as_str() {
            safe_error(result.unwrap_err(), expected)
        } else {
            assert_eq!(
                serde_json::to_value(result.unwrap()).unwrap(),
                v["expected"],
                "{}",
                v["id"]
            )
        };
        assert_eq!(
            *calls.lock().unwrap(),
            if v["noNetwork"] == true { 0 } else { 1 },
            "{}",
            v["id"]
        );
    }
}

#[tokio::test]
async fn tool_proposal_round_trip_on_both_adapters() {
    let all = vectors();
    for adapter in ["ollama", "openai-compatible"] {
        let first_id = if adapter == "ollama" {
            "TRANSPORT-O03"
        } else {
            "TRANSPORT-C03"
        };
        let last_id = if adapter == "ollama" {
            "TRANSPORT-O01"
        } else {
            "TRANSPORT-C01"
        };
        let first = all.iter().find(|v| v["id"] == first_id).unwrap().clone();
        let last = all.iter().find(|v| v["id"] == last_id).unwrap().clone();
        let count = Arc::new(Mutex::new(0));
        let seen = count.clone();
        let first_response = first["response"].to_string();
        let last_response = last["response"].to_string();
        let selected = adapter.to_owned();
        let server = FakeServer::new(move |socket| {
            let (_, body) = read_request(socket);
            let mut n = seen.lock().unwrap();
            *n += 1;
            if *n == 2 {
                let messages = body["messages"].as_array().unwrap();
                let call = &messages[messages.len() - 2]["tool_calls"][0];
                let result = &messages[messages.len() - 1];
                assert_eq!(call["function"]["name"], "search_public");
                assert_eq!(result["content"], "synthetic tool result");
                if selected == "ollama" {
                    assert_eq!(result["tool_name"], "search_public");
                } else {
                    assert_eq!(result["tool_call_id"], "call-1");
                }
            }
            respond(
                socket,
                200,
                if *n == 1 {
                    first_response.as_bytes()
                } else {
                    last_response.as_bytes()
                },
                "",
            );
        });
        let mut s = selection(&first["selection"]);
        s.base_url = server.url.clone();
        s.api_key_env = None;
        let transport = Transport::new(None, None).unwrap();
        let proposal = transport.infer(&s, &first["request"], None).await.unwrap();
        assert_eq!(proposal.tool_calls.len(), 1);
        let mut request = first["request"].clone();
        let messages = request["messages"].as_array_mut().unwrap();
        messages.push(
            json!({"role":"assistant","content":proposal.text,"toolCalls":proposal.tool_calls}),
        );
        let call_id = messages.last().unwrap()["toolCalls"][0]["id"]
            .as_str()
            .unwrap()
            .to_owned();
        messages
            .push(json!({"role":"tool","content":"synthetic tool result","toolCallId":call_id}));
        let answer = transport.infer(&s, &request, None).await.unwrap();
        assert_eq!(answer.finish_reason, "stop");
        assert_eq!(answer.text, "合成回复");
        assert_eq!(*count.lock().unwrap(), 2);
    }
}

#[tokio::test]
async fn provider_boundaries() {
    let base = &vectors()[1];
    let variants = vec![
        (200, vec![0xff], "", "INVALID_PROVIDER_RESPONSE"),
        (200, b"{".to_vec(), "", "INVALID_PROVIDER_RESPONSE"),
        (
            200,
            base["response"].to_string().into_bytes(),
            "Content-Encoding: gzip\r\n",
            "INVALID_PROVIDER_RESPONSE",
        ),
        (200, vec![b'x'; 1048577], "", "RESPONSE_TOO_LARGE"),
        (
            302,
            b"never-print-secret".to_vec(),
            "Location: /followed\r\n",
            "PROVIDER_REJECTED",
        ),
        (500, b"never-print-secret".to_vec(), "", "PROVIDER_REJECTED"),
    ];
    for (status, body, headers, code) in variants {
        let count = Arc::new(Mutex::new(0));
        let seen = count.clone();
        let server = FakeServer::new(move |socket| {
            *seen.lock().unwrap() += 1;
            read_request(socket);
            respond(socket, status, &body, headers)
        });
        let mut s = selection(&base["selection"]);
        s.base_url = server.url.clone();
        safe_error(
            Transport::new(None, None)
                .unwrap()
                .infer(&s, &base["request"], None)
                .await
                .unwrap_err(),
            code,
        );
        assert_eq!(*count.lock().unwrap(), 1);
    }
    // Chunk framing defeats a Content-Length-only limit implementation.
    let server = FakeServer::new(|socket| {
        read_request(socket);
        let _ = socket.write_all(
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
        );
        let chunk = vec![b'x'; 65536];
        for _ in 0..17 {
            if socket.write_all(b"10000\r\n").is_err()
                || socket.write_all(&chunk).is_err()
                || socket.write_all(b"\r\n").is_err()
            {
                break;
            }
        }
        let _ = socket.write_all(b"0\r\n\r\n");
    });
    let mut s = selection(&base["selection"]);
    s.base_url = server.url.clone();
    safe_error(
        Transport::new(None, None)
            .unwrap()
            .infer(&s, &base["request"], None)
            .await
            .unwrap_err(),
        "RESPONSE_TOO_LARGE",
    );
}

#[tokio::test]
async fn timeout_and_cancellation_cover_body_waits() {
    let base = &vectors()[1];
    for body_wait in [false, true] {
        let server = FakeServer::new(move |socket| {
            read_request(socket);
            if body_wait {
                socket
                    .write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\n{\r\n")
                    .unwrap();
            }
            thread::sleep(Duration::from_millis(120));
        });
        let mut s = selection(&base["selection"]);
        s.base_url = server.url.clone();
        safe_error(
            Transport::new(None, Some(20))
                .unwrap()
                .infer(&s, &base["request"], None)
                .await
                .unwrap_err(),
            "TIMEOUT",
        );
        // Separate server keeps the second request's timeout independent of the first.
        drop(server);
        let server = FakeServer::new(move |socket| {
            read_request(socket);
            if body_wait {
                socket
                    .write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\n{\r\n")
                    .unwrap();
            }
            thread::sleep(Duration::from_millis(120));
        });
        s.base_url = server.url.clone();
        let (tx, rx) = tokio::sync::watch::channel(false);
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(20)).await;
            let _ = tx.send(true);
        });
        safe_error(
            Transport::new(None, None)
                .unwrap()
                .infer(&s, &base["request"], Some(rx))
                .await
                .unwrap_err(),
            "CANCELLED",
        );
    }
}

#[tokio::test]
async fn credentials_request_precedence_and_safe_errors() {
    let base = &vectors()[1];
    let mut s = selection(&base["selection"]);
    s.api_key_env = Some("KEY".into());
    let calls = Arc::new(Mutex::new(0));
    let seen = calls.clone();
    let resolver: CredentialResolver = Arc::new(move |_| {
        *seen.lock().unwrap() += 1;
        Err(TransportError("never-print http://private"))
    });
    let transport = Transport::new(Some(resolver), None).unwrap();
    safe_error(
        transport
            .infer(&s, &json!({"messages":null}), None)
            .await
            .unwrap_err(),
        "INVALID_REQUEST",
    );
    let (_tx, rx) = tokio::sync::watch::channel(true);
    safe_error(
        transport
            .infer(&s, &base["request"], Some(rx))
            .await
            .unwrap_err(),
        "CANCELLED",
    );
    assert_eq!(*calls.lock().unwrap(), 0);
    safe_error(
        transport
            .infer(&s, &base["request"], None)
            .await
            .unwrap_err(),
        "MISSING_CREDENTIAL",
    );
    for key in ["", "has space", "中文", "new\nline"] {
        let resolver: CredentialResolver = Arc::new(move |_| Ok(key.to_owned()));
        safe_error(
            Transport::new(Some(resolver), None)
                .unwrap()
                .infer(&s, &base["request"], None)
                .await
                .unwrap_err(),
            "MISSING_CREDENTIAL",
        );
    }
    for timeout in [0, 300001] {
        safe_error(
            Transport::new(None, Some(timeout)).err().unwrap(),
            "INVALID_REQUEST",
        );
    }
    s.api_key_env = None;
    s.base_url = "http://127.0.0.1:1".into();
    safe_error(
        Transport::new(None, None)
            .unwrap()
            .infer(&s, &base["request"], None)
            .await
            .unwrap_err(),
        "PROVIDER_UNAVAILABLE",
    );
    let request = json!({"messages":[{"role":"user","content":"x".repeat(1048576)}]});
    safe_error(
        transport.infer(&s, &request, None).await.unwrap_err(),
        "INVALID_REQUEST",
    );
}

#[tokio::test]
async fn selection_switch_preserves_in_flight_target() {
    let base = &vectors()[1];
    let (old_tx, old_rx) = std::sync::mpsc::channel();
    let (continue_tx, continue_rx) = std::sync::mpsc::channel();
    let old = FakeServer::new(move |socket| {
        let (_, body) = read_request(socket);
        old_tx.send(body).unwrap();
        continue_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        respond(socket,200,b"{\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"old\"},\"finish_reason\":\"stop\"}]}","");
    });
    let new = FakeServer::new(|socket| {
        read_request(socket);
        respond(socket,200,b"{\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"new\"},\"finish_reason\":\"stop\"}]}","");
    });
    let mut s = selection(&base["selection"]);
    s.base_url = old.url.clone();
    let old_selection = s.clone();
    let request = base["request"].clone();
    let transport = Arc::new(Transport::new(None, None).unwrap());
    let in_flight = transport.clone();
    let pending = tokio::spawn(async move {
        in_flight
            .infer(&old_selection, &request, None)
            .await
            .unwrap()
    });
    let body =
        tokio::task::spawn_blocking(move || old_rx.recv_timeout(Duration::from_secs(2)).unwrap())
            .await
            .unwrap();
    s.base_url = new.url.clone();
    s.model = "new-model".into();
    let new_result = transport.infer(&s, &base["request"], None).await.unwrap();
    continue_tx.send(()).unwrap();
    let old_result = pending.await.unwrap();
    assert_eq!(body["model"], base["selection"]["model"]);
    assert_eq!(old_result.text, "old");
    assert_eq!(new_result.text, "new");
}
