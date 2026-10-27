use jsonwebtoken::{decode, encode, Algorithm, DecodingKey, EncodingKey, Header, Validation};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

const MAX_SAFE_USER_ID: u64 = 9_007_199_254_740_991;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum TokenKind {
    Access,
    Refresh,
}

impl TokenKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Access => "access",
            Self::Refresh => "refresh",
        }
    }
}

/// Input to HS256 signing; timestamps are Unix seconds and IDs are caller supplied.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IssuedToken {
    pub user_id: u64,
    pub user_name: String,
    pub session_id: String,
    #[serde(rename = "type")]
    pub kind: TokenKind,
    #[serde(rename = "iat")]
    pub issued_at: u64,
    #[serde(rename = "exp")]
    pub expires_at: u64,
    pub jti: String,
}

/// Verified JWT claims do not establish that a session is active or unrevoked.
#[derive(Debug, PartialEq)]
pub struct TokenClaims {
    pub user_id: u64,
    pub user_name: Option<String>,
    pub session_id: String,
    pub kind: TokenKind,
    pub issued_at: Option<f64>,
    pub expires_at: Option<f64>,
    pub jti: String,
}

#[derive(Debug, thiserror::Error)]
pub enum TokenError {
    #[error("invalid token")]
    InvalidToken,
    #[error("invalid token signing input")]
    InvalidInput,
    #[error("token keys must be nonempty")]
    EmptyKey,
    #[error("token signing failed")]
    SigningFailed,
}

// Intentionally no Debug: keep key material outside the diagnostic surface.
pub struct TokenCodec {
    access_encoding: EncodingKey,
    access_decoding: DecodingKey,
    refresh_encoding: EncodingKey,
    refresh_decoding: DecodingKey,
    two_factor_key: [u8; 32],
}

impl TokenCodec {
    pub fn new(access_key: &[u8], refresh_key: &[u8]) -> Result<Self, TokenError> {
        if access_key.is_empty() || refresh_key.is_empty() {
            return Err(TokenError::EmptyKey);
        }
        Ok(Self {
            access_encoding: EncodingKey::from_secret(access_key),
            access_decoding: DecodingKey::from_secret(access_key),
            refresh_encoding: EncodingKey::from_secret(refresh_key),
            refresh_decoding: DecodingKey::from_secret(refresh_key),
            two_factor_key: Sha256::digest(refresh_key).into(),
        })
    }

    pub(crate) fn two_factor_key(&self) -> &[u8; 32] {
        &self.two_factor_key
    }

    pub fn sign(&self, input: &IssuedToken) -> Result<String, TokenError> {
        if !valid_user_id(input.user_id) || input.session_id.is_empty() || input.jti.is_empty() {
            return Err(TokenError::InvalidInput);
        }
        let key = match input.kind {
            TokenKind::Access => &self.access_encoding,
            TokenKind::Refresh => &self.refresh_encoding,
        };
        encode(&Header::new(Algorithm::HS256), input, key).map_err(|_| TokenError::SigningFailed)
    }

    pub fn verify(
        &self,
        token: &str,
        expected_kind: TokenKind,
        now: u64,
    ) -> Result<TokenClaims, TokenError> {
        self.verify_inner(token, expected_kind, now, true)
    }

    /// Nuxt's refresh endpoint does not inspect the refresh JWT's jti.
    pub fn verify_for_rotation(&self, token: &str, now: u64) -> Result<TokenClaims, TokenError> {
        self.verify_inner(token, TokenKind::Refresh, now, false)
    }

    fn verify_inner(
        &self,
        token: &str,
        expected_kind: TokenKind,
        now: u64,
        require_jti: bool,
    ) -> Result<TokenClaims, TokenError> {
        let key = match expected_kind {
            TokenKind::Access => &self.access_decoding,
            TokenKind::Refresh => &self.refresh_decoding,
        };
        // Official API: https://docs.rs/jsonwebtoken/10.3.0/jsonwebtoken/struct.Validation.html
        // Signature and algorithm validation stay enabled. Time is checked below
        // against the injected clock, with Nuxt's zero-leeway exp/nbf boundaries.
        let mut validation = Validation::new(Algorithm::HS256);
        validation.algorithms = vec![Algorithm::HS256, Algorithm::HS384, Algorithm::HS512];
        validation.required_spec_claims.clear();
        validation.validate_exp = false;
        validation.validate_nbf = false;
        // Nuxt supplies no audience constraint for these application tokens.
        validation.validate_aud = false;
        let payload = decode::<Value>(token, key, &validation)
            .map_err(|_| TokenError::InvalidToken)?
            .claims;
        let payload = payload.as_object().ok_or(TokenError::InvalidToken)?;
        let user_id = match payload.get("userId") {
            Some(Value::Number(value)) => value.as_f64(),
            Some(Value::String(value)) => value.trim().parse::<f64>().ok(),
            _ => None,
        }
        .filter(|value| value.is_finite() && value.fract() == 0.0)
        .map(|value| value as u64)
        .filter(|value| valid_user_id(*value))
        .ok_or(TokenError::InvalidToken)?;
        if payload.get("type").and_then(Value::as_str) != Some(expected_kind.as_str()) {
            return Err(TokenError::InvalidToken);
        }
        let string_claim = |name: &str| {
            payload
                .get(name)
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
                .map(str::to_owned)
                .ok_or(TokenError::InvalidToken)
        };
        let number_claim = |name: &str| match payload.get(name) {
            None => Ok(None),
            Some(value) => value
                .as_f64()
                .filter(|number| number.is_finite())
                .map(Some)
                .ok_or(TokenError::InvalidToken),
        };
        let expires_at = number_claim("exp")?;
        let not_before = number_claim("nbf")?;
        if expires_at.is_some_and(|exp| exp <= now as f64)
            || not_before.is_some_and(|nbf| nbf > now as f64)
        {
            return Err(TokenError::InvalidToken);
        }
        Ok(TokenClaims {
            user_id,
            user_name: payload
                .get("userName")
                .and_then(Value::as_str)
                .map(str::to_owned),
            session_id: string_claim("sessionId")?,
            kind: expected_kind,
            // iat is informational, and future iat is accepted like Nuxt.
            issued_at: payload.get("iat").and_then(Value::as_f64),
            expires_at,
            jti: if require_jti {
                string_claim("jti")?
            } else {
                payload
                    .get("jti")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned()
            },
        })
    }
}

fn valid_user_id(user_id: u64) -> bool {
    (1..=MAX_SAFE_USER_ID).contains(&user_id)
}
