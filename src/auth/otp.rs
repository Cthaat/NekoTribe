use crate::{
    auth::{
        login::{js_trim, request_body, scalar},
        sessions::NativeState,
    },
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    body::{to_bytes, Body},
    extract::State,
    http::Request,
    response::{IntoResponse, Response},
    Json,
};
use lettre::{
    message::MultiPart, transport::smtp::authentication::Credentials, AsyncSmtpTransport,
    AsyncTransport, Message, Tokio1Executor,
};
use serde_json::{json, Value};
use std::{future::Future, pin::Pin, time::Duration};

#[derive(Clone)]
pub struct OtpEvent {
    pub sequence: u64,
    pub account: String,
    pub kind: String,
    pub channel: String,
    pub hash: String,
    pub id: String,
    pub expires: String,
}
pub type MailFuture<'a> = Pin<Box<dyn Future<Output = Result<(), ()>> + Send + 'a>>;
pub trait OtpMailer: Send + Sync {
    fn send<'a>(&'a self, to: &'a str, code: &'a str) -> MailFuture<'a>;
}
#[derive(Clone, Default, PartialEq, Eq)]
pub struct SmtpConfig {
    host: String,
    port: String,
    user: String,
    password: String,
    #[cfg(test)]
    test_ca: Option<Vec<u8>>,
}
impl std::fmt::Debug for SmtpConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("SmtpConfig [redacted]")
    }
}
impl SmtpConfig {
    pub fn from_lookup(get: &impl Fn(&str) -> Option<String>) -> Self {
        let get_value = |key: &str| {
            get(&format!("NUXT_{key}"))
                .or_else(|| get(key))
                .unwrap_or_default()
        };
        Self {
            host: get_value("SMTP_HOST"),
            port: get_value("SMTP_PORT"),
            user: get_value("SMTP_USER"),
            password: get_value("SMTP_PASS"),
            #[cfg(test)]
            test_ca: None,
        }
    }
}
impl OtpMailer for SmtpConfig {
    fn send<'a>(&'a self, to: &'a str, code: &'a str) -> MailFuture<'a> {
        Box::pin(async move {
            if self.host.is_empty()
                || self.user.is_empty()
                || self.password.is_empty()
                || self.host.contains(['/', '\r', '\n'])
                || to.contains(['\r', '\n'])
                || self.user.contains(['\r', '\n'])
            {
                return Err(());
            }
            let port = self.port.parse::<u16>().map_err(|_| ())?;
            if port == 0 {
                return Err(());
            }
            let message = Message::builder()
                .from(self.user.parse().map_err(|_| ())?)
                .to(to.parse().map_err(|_| ())?)
                .subject("Your verification code")
                .multipart(MultiPart::alternative_plain_html(
                    format!("Your verification code is {code}"),
                    format!("<p>Your verification code is <strong>{code}</strong></p>"),
                ))
                .map_err(|_| ())?;
            #[allow(unused_mut)]
            let mut builder = AsyncSmtpTransport::<Tokio1Executor>::relay(&self.host)
                .map_err(|_| ())?
                .port(port)
                .timeout(Some(Duration::from_secs(15)))
                .credentials(Credentials::new(self.user.clone(), self.password.clone()));
            #[cfg(test)]
            if let Some(cert) = &self.test_ca {
                use lettre::transport::smtp::client::{Certificate, Tls, TlsParameters};
                let ca = Certificate::from_der(cert.clone()).map_err(|_| ())?;
                let tls = TlsParameters::builder(self.host.clone())
                    .add_root_certificate(ca)
                    .build()
                    .map_err(|_| ())?;
                builder = builder.tls(Tls::Wrapper(tls));
            }
            let transport = builder.build();
            tokio::time::timeout(Duration::from_secs(15), transport.send(message))
                .await
                .map_err(|_| ())?
                .map_err(|_| ())?;
            Ok(())
        })
    }
}
fn random_code() -> Result<String, ApiError> {
    let mut code = String::with_capacity(6);
    while code.len() < 6 {
        let mut bytes = [0u8; 16];
        getrandom::fill(&mut bytes).map_err(|_| server_error())?;
        for byte in bytes {
            if byte < 250 {
                code.push(char::from(b'0' + byte % 10));
                if code.len() == 6 {
                    break;
                }
            }
        }
    }
    Ok(code)
}
fn random_id() -> Result<String, ApiError> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).map_err(|_| server_error())?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Ok(format!("otp_{}", uuid::Uuid::from_bytes(bytes)))
}

fn required(body: &Value, key: &str) -> Result<String, ApiError> {
    let value = scalar(body.get(key));
    let value = js_trim(&value);
    if value.is_empty() {
        return Err(ApiError::bad_request(format!("{key} 不能为空")));
    };
    Ok(value.to_owned())
}
fn server_error() -> ApiError {
    ApiError::server_error("服务器内部错误")
}
pub(crate) async fn create_otp(
    State(state): State<NativeState>,
    request: Request<Body>,
) -> Result<Response, ApiError> {
    let (parts, body) = request.into_parts();
    let bytes = to_bytes(body, 1024 * 1024)
        .await
        .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
    let body = request_body(&parts.headers, &bytes)?;
    let account = required(&body, "account")?;
    let kind = required(&body, "type")?;
    if !["register", "password_reset", "change_email"].contains(&kind.as_str()) {
        return Err(ApiError::bad_request("type 参数错误"));
    }
    let channel = match body.get("channel") {
        Some(Value::String(_) | Value::Number(_) | Value::Bool(_)) => scalar(body.get("channel")),
        _ => "email".into(),
    };
    if channel != "email" && channel != "sms" {
        return Err(ApiError::bad_request("channel 参数错误"));
    }
    if channel == "sms" {
        return Err(ApiError::new(
            axum::http::StatusCode::NOT_IMPLEMENTED,
            50101,
            "短信验证码暂不可用",
        ));
    }
    let code = random_code()?;
    let id = random_id()?;
    let expires = (chrono::Utc::now() + chrono::Duration::seconds(300))
        .to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
    let sequence = state
        .repository
        .otp_next_id()
        .await
        .map_err(|_| server_error())?;
    let password = code.clone();
    let hash = tokio::task::spawn_blocking(move || bcrypt::hash(password, 10))
        .await
        .map_err(|_| server_error())?
        .map_err(|_| server_error())?;
    let event = OtpEvent {
        sequence,
        account: account.clone(),
        kind,
        channel,
        hash,
        id: id.clone(),
        expires: expires.clone(),
    };
    state
        .repository
        .otp_insert(&event)
        .await
        .map_err(|_| server_error())?;
    state
        .otp_mailer
        .send(&account, &code)
        .await
        .map_err(|_| server_error())?;
    Ok(Json(V2Response::ok(
        json!({"account":account,"verification_id":id,"expires_at":expires}),
    ))
    .into_response())
}
pub(crate) async fn verify_otp(
    State(state): State<NativeState>,
    request: Request<Body>,
) -> Result<Response, ApiError> {
    let (parts, body) = request.into_parts();
    let bytes = to_bytes(body, 1024 * 1024)
        .await
        .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
    let body = request_body(&parts.headers, &bytes)?;
    let account = required(&body, "account")?;
    let kind = required(&body, "type")?;
    if !["register", "password_reset", "change_email"].contains(&kind.as_str()) {
        return Err(ApiError::bad_request("type 参数错误"));
    }
    let id = required(&body, "verification_id")?;
    let code = required(&body, "code")?;
    let hash = state
        .repository
        .otp_lookup(&account, &kind, &id)
        .await
        .map_err(|_| server_error())?
        .ok_or_else(|| ApiError::bad_request("验证码不存在或已过期"))?;
    let valid = tokio::task::spawn_blocking(move || bcrypt::verify(code, &hash).unwrap_or(false))
        .await
        .map_err(|_| server_error())?;
    if !valid {
        return Err(ApiError::unauthorized("验证码错误"));
    }
    state
        .repository
        .otp_mark(&id)
        .await
        .map_err(|_| server_error())?;
    let at = state
        .repository
        .otp_verified_at(&id)
        .await
        .map_err(|_| server_error())?
        .unwrap_or_else(|| chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true));
    Ok(Json(V2Response::ok(
        json!({"account":account,"verified":true,"verified_at":at}),
    ))
    .into_response())
}

#[cfg(test)]
mod smtp_tests {
    use super::*;
    use rustls::{
        pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer},
        ServerConfig, ServerConnection, StreamOwned,
    };
    use std::{
        io::{BufRead, BufReader, Write},
        net::TcpListener,
        sync::Arc,
        thread,
    };
    const CERT: &[u8] = include_bytes!("../../tests/fixtures/smtp/cert.der");
    const KEY: &[u8] = include_bytes!("../../tests/fixtures/smtp/key.der");
    fn mock_server() -> (u16, thread::JoinHandle<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let task = thread::spawn(move || {
            let config = ServerConfig::builder()
                .with_no_client_auth()
                .with_single_cert(
                    vec![CertificateDer::from(CERT.to_vec())],
                    PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(KEY.to_vec())),
                )
                .unwrap();
            let (tcp, _) = listener.accept().unwrap();
            tcp.set_read_timeout(Some(Duration::from_secs(15))).unwrap();
            tcp.set_write_timeout(Some(Duration::from_secs(15)))
                .unwrap();
            let stream = StreamOwned::new(ServerConnection::new(Arc::new(config)).unwrap(), tcp);
            let mut io = BufReader::new(stream);
            if io.get_mut().write_all(b"220 localhost test\r\n").is_err() {
                return String::new();
            }
            let mut result = String::new();
            let mut data = false;
            loop {
                let mut line = String::new();
                if io.read_line(&mut line).unwrap_or(0) == 0 {
                    break;
                };
                result.push_str(&line);
                let response = if data {
                    if line == ".\r\n" {
                        data = false;
                        Some("250 queued\r\n")
                    } else {
                        None
                    }
                } else if line.starts_with("EHLO ") {
                    Some("250-localhost\r\n250 AUTH PLAIN\r\n")
                } else if line.starts_with("AUTH PLAIN ") {
                    Some("235 authenticated\r\n")
                } else if line.starts_with("MAIL FROM:") || line.starts_with("RCPT TO:") {
                    Some("250 ok\r\n")
                } else if line.starts_with("DATA") {
                    data = true;
                    Some("354 send data\r\n")
                } else if line.starts_with("QUIT") {
                    let _ = io.get_mut().write_all(b"221 bye\r\n");
                    break;
                } else {
                    Some("500 unsupported\r\n")
                };
                if let Some(response) = response {
                    if io.get_mut().write_all(response.as_bytes()).is_err() {
                        break;
                    }
                }
            }
            result
        });
        (port, task)
    }
    #[tokio::test]
    async fn smtp_uses_verified_tls_and_delivers_to_fake_server() {
        let (port, task) = mock_server();
        let smtp = SmtpConfig {
            host: "localhost".into(),
            port: port.to_string(),
            user: "sender@example.test".into(),
            password: "synthetic-mail-password".into(),
            test_ca: Some(CERT.to_vec()),
        };
        assert!(!format!("{smtp:?}").contains("synthetic-mail-password"));
        assert!(smtp.send("recipient@example.test", "123456").await.is_ok());
        let transcript = task.join().unwrap();
        assert!(transcript.contains("RCPT TO:<recipient@example.test>"));
        assert!(transcript.contains("Your verification code is 123456"));
    }
    #[tokio::test]
    async fn smtp_rejects_untrusted_certificate() {
        let (port, task) = mock_server();
        let smtp = SmtpConfig {
            host: "localhost".into(),
            port: port.to_string(),
            user: "sender@example.test".into(),
            password: "synthetic-mail-password".into(),
            test_ca: None,
        };
        assert!(smtp.send("recipient@example.test", "123456").await.is_err());
        let _ = task.join().unwrap();
    }
}
