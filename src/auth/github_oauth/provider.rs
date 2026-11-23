use super::{spec, Identity, CALLBACK};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use reqwest::{header::ACCEPT, Client, Request};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::{future::Future, time::Duration};
use url::Url;

const MAX_SAFE_ID: u64 = 9_007_199_254_740_991;
const USER_AGENT: &str = "NekoTribe-OAuth";

#[derive(Clone)]
pub struct GithubOAuth {
    client: Client,
    client_id: String,
    client_secret: String,
    redirect_uri: Url,
}

impl GithubOAuth {
    pub fn from_lookup(lookup: impl Fn(&str) -> Option<String>) -> Option<Self> {
        let client_id = lookup("GITHUB_OAUTH_CLIENT_ID")?.trim().to_owned();
        let client_secret = lookup("GITHUB_OAUTH_CLIENT_SECRET")?.trim().to_owned();
        let redirect_uri = Url::parse(lookup("GITHUB_OAUTH_REDIRECT_URI")?.trim()).ok()?;
        if client_id.is_empty()
            || client_secret.is_empty()
            || !(redirect_uri.scheme() == "https"
                || (redirect_uri.scheme() == "http"
                    && redirect_uri.host_str() == Some("localhost")))
            || !redirect_uri.has_host()
            || !redirect_uri.username().is_empty()
            || redirect_uri.password().is_some()
            || redirect_uri.path() != CALLBACK
            || redirect_uri.query().is_some()
            || redirect_uri.fragment().is_some()
        {
            return None;
        }
        let client = Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_millis(spec().provider_timeout_ms))
            .user_agent(USER_AGENT)
            .https_only(true)
            .no_proxy()
            .build()
            .ok()?;
        Some(Self {
            client,
            client_id,
            client_secret,
            redirect_uri,
        })
    }

    pub(super) fn authorization_url(&self, state: &str, verifier: &str) -> Url {
        let mut url = Url::parse(&spec().endpoints.authorize).expect("synchronized GitHub URL");
        let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
        url.query_pairs_mut().extend_pairs([
            ("client_id", self.client_id.as_str()),
            ("redirect_uri", self.redirect_uri.as_str()),
            ("state", state),
            ("code_challenge", &challenge),
            ("code_challenge_method", "S256"),
            ("allow_signup", "false"),
            ("scope", ""),
        ]);
        url
    }

    pub(super) async fn verify(&self, code: &str, verifier: &str) -> Option<Identity> {
        tokio::time::timeout(
            Duration::from_millis(spec().provider_timeout_ms),
            self.verify_with(code, verifier, |request| self.receive(request)),
        )
        .await
        .ok()
        .flatten()
    }

    pub(super) async fn verify_with<F, Fut>(
        &self,
        code: &str,
        verifier: &str,
        mut send: F,
    ) -> Option<Identity>
    where
        F: FnMut(Request) -> Fut,
        Fut: Future<Output = Option<Vec<u8>>>,
    {
        #[derive(Deserialize)]
        struct Token {
            access_token: String,
        }
        #[derive(Deserialize)]
        struct Profile {
            id: u64,
            login: String,
        }
        let exchange = self
            .client
            .post(&spec().endpoints.exchange)
            .header(ACCEPT, "application/json")
            .form(&[
                ("client_id", self.client_id.as_str()),
                ("client_secret", self.client_secret.as_str()),
                ("redirect_uri", self.redirect_uri.as_str()),
                ("code", code),
                ("code_verifier", verifier),
            ])
            .build()
            .ok()?;
        let token: Token = serde_json::from_slice(&send(exchange).await?).ok()?;
        if !(1..=2048).contains(&token.access_token.len())
            || !token
                .access_token
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
        {
            return None;
        }
        let request = self
            .client
            .get(&spec().endpoints.profile)
            .header(ACCEPT, "application/vnd.github+json")
            .bearer_auth(token.access_token)
            .build()
            .ok()?;
        let Profile { id, login } = serde_json::from_slice(&send(request).await?).ok()?;
        let login = login.trim();
        if !(1..=MAX_SAFE_ID).contains(&id)
            || !(1..=80).contains(&login.chars().count())
            || login.chars().any(char::is_control)
        {
            return None;
        }
        Some(Identity {
            id: id.to_string(),
            login: login.into(),
        })
    }

    async fn receive(&self, request: Request) -> Option<Vec<u8>> {
        let mut response = self.client.execute(request).await.ok()?;
        let limit = spec().provider_body_max_bytes;
        if !response.status().is_success()
            || response
                .content_length()
                .is_some_and(|length| length > limit as u64)
        {
            return None;
        }
        let mut data = Vec::new();
        while let Some(chunk) = response.chunk().await.ok()? {
            if chunk.len() > limit - data.len() {
                return None;
            }
            data.extend_from_slice(&chunk);
        }
        Some(data)
    }
}
