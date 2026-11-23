use super::{decode_credential_id, decode_exact, encode, invalid_proof, spec, StoredProof};
use crate::httpx::errors::ApiError;
use serde::Deserialize;
use std::time::Duration;
use webauthn_rs::prelude::*;
use webauthn_rs_proto::{
    PublicKeyCredentialDescriptor, RegisteredExtensions, ResidentKeyRequirement,
    UserVerificationPolicy,
};

const APK_ORIGIN: &str = "android:apk-key-hash:";
pub(super) const MAX_USER_ID: u64 = 9_999_999_999;

#[derive(Clone)]
pub struct PasskeyEngine {
    pub(super) webauthn: Webauthn,
    origins: Vec<String>,
}

impl PasskeyEngine {
    pub fn from_lookup(lookup: impl Fn(&str) -> Option<String>) -> Option<Self> {
        let rp = lookup("WEBAUTHN_RP_ID")?.trim().to_ascii_lowercase();
        if rp.len() > 253
            || rp.parse::<std::net::IpAddr>().is_ok()
            || !rp.split('.').all(|label| {
                (1..=63).contains(&label.len())
                    && !label.starts_with('-')
                    && !label.ends_with('-')
                    && label
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b == b'-')
            })
        {
            return None;
        }
        let raw = lookup("WEBAUTHN_ORIGINS")?;
        let allowed = raw
            .split(',')
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(origin)
            .collect::<Option<Vec<_>>>()?;
        if allowed.is_empty() {
            return None;
        }
        // The library builder requires a domain-based primary URL. This URL is
        // only a configuration bootstrap when no web origin has that domain.
        // Each verified client's exact origin must also occur in `origins`.
        let rp_url = Url::parse(&format!("https://{rp}/")).ok()?;
        if rp_url.domain() != Some(rp.as_str()) {
            return None;
        }
        let mut builder = WebauthnBuilder::new(&rp, &rp_url)
            .ok()?
            .rp_name("NekoTribe")
            .timeout(Duration::from_millis(spec().timeout_ms));
        for (_, parsed) in &allowed {
            builder = builder.append_allowed_origin(parsed);
        }
        Some(Self {
            webauthn: builder.build().ok()?,
            origins: allowed.into_iter().map(|(value, _)| value).collect(),
        })
    }

    pub(super) fn register_options(
        &self,
        user: u64,
        username: &str,
        display: &str,
        excluded: Vec<Vec<u8>>,
    ) -> WebauthnResult<(CreationChallengeResponse, PasskeyRegistration)> {
        let (mut options, state) = self.webauthn.start_passkey_registration(
            Uuid::from_u128(u128::from(user)),
            username,
            display,
            None,
        )?;
        options
            .public_key
            .pub_key_cred_params
            .retain(|param| param.alg == spec().algorithm);
        // Keep the potentially unbounded browser hint outside the short-lived
        // serialized state. Oracle's credential PK enforces uniqueness.
        options.public_key.exclude_credentials = Some(
            excluded
                .into_iter()
                .map(|id| PublicKeyCredentialDescriptor {
                    type_: "public-key".into(),
                    id,
                    transports: None,
                })
                .collect(),
        );
        let selection = options
            .public_key
            .authenticator_selection
            .as_mut()
            .ok_or(WebauthnError::Configuration)?;
        selection.resident_key = Some(ResidentKeyRequirement::Required);
        selection.require_resident_key = true;
        Ok((options, state))
    }

    pub(super) fn registration_proof(
        &self,
        proof: RegisterPublicKeyCredential,
        state: StoredProof,
    ) -> Result<Credential, ApiError> {
        validate_id(&proof.type_, &proof.id, &proof.raw_id)?;
        self.check_client_data(&proof.response.client_data_json, &state.challenge)?;
        let registration: PasskeyRegistration =
            serde_json::from_str(&state.engine_state).map_err(|_| invalid_proof())?;
        let credential: Credential = self
            .webauthn
            .finish_passkey_registration(&proof, &registration)
            .map_err(|_| invalid_proof())?
            .into();
        if credential.cred_id != proof.raw_id
            || !credential.user_verified
            || !canonical_key(&credential)
        {
            return Err(invalid_proof());
        }
        Ok(credential)
    }

    pub(super) fn authentication_proof(
        &self,
        proof: &PublicKeyCredential,
        state: StoredProof,
    ) -> Result<(String, u64, DiscoverableAuthentication), ApiError> {
        validate_id(&proof.type_, &proof.id, &proof.raw_id)?;
        self.check_client_data(&proof.response.client_data_json, &state.challenge)?;
        let (handle, raw_id) = self
            .webauthn
            .identify_discoverable_authentication(proof)
            .map_err(|_| invalid_proof())?;
        let user = u64::try_from(handle.as_u128())
            .ok()
            .filter(|id| (1..=MAX_USER_ID).contains(id))
            .ok_or_else(invalid_proof)?;
        let state = serde_json::from_str(&state.engine_state).map_err(|_| invalid_proof())?;
        Ok((encode(raw_id), user, state))
    }

    fn check_client_data(&self, bytes: &[u8], expected_challenge: &str) -> Result<(), ApiError> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct ClientData {
            origin: String,
            challenge: String,
            cross_origin: Option<bool>,
        }
        let data: ClientData = serde_json::from_slice(bytes).map_err(|_| invalid_proof())?;
        if data.cross_origin.unwrap_or(false)
            || !self.origins.contains(&data.origin)
            || data.challenge != expected_challenge
        {
            return Err(invalid_proof());
        }
        Ok(())
    }
}

fn origin(raw: &str) -> Option<(String, Url)> {
    if let Some(apk) = raw.strip_prefix(APK_ORIGIN) {
        decode_exact(apk, 32)?;
        return Some((raw.to_owned(), Url::parse(raw).ok()?));
    }
    let url = Url::parse(raw).ok()?;
    if (url.scheme() != "https" && !(url.scheme() == "http" && url.host_str() == Some("localhost")))
        || !url.has_host()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.path() != "/"
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return None;
    }
    (raw == url.origin().ascii_serialization()).then(|| (raw.to_owned(), url))
}

fn validate_id(kind: &str, id: &str, raw: &[u8]) -> Result<(), ApiError> {
    if kind != "public-key" || decode_credential_id(id).as_deref() != Some(raw) {
        return Err(invalid_proof());
    }
    Ok(())
}

pub(super) fn canonical_key(credential: &Credential) -> bool {
    credential.cred.type_ == COSEAlgorithm::ES256
        && matches!(&credential.cred.key, COSEKeyType::EC_EC2(key)
            if key.curve == ECDSACurve::SECP256R1 && key.x.len() == 32 && key.y.len() == 32)
        && (!credential.backup_state || credential.backup_eligible)
}

pub(super) fn restore_credential(
    id: Vec<u8>,
    x: Vec<u8>,
    y: Vec<u8>,
    counter: u32,
    backup_eligible: bool,
    backup_state: bool,
) -> Credential {
    Credential {
        cred_id: id,
        cred: COSEKey {
            type_: COSEAlgorithm::ES256,
            key: COSEKeyType::EC_EC2(COSEEC2Key {
                curve: ECDSACurve::SECP256R1,
                x,
                y,
            }),
        },
        counter,
        transports: None,
        user_verified: true,
        backup_eligible,
        backup_state,
        registration_policy: UserVerificationPolicy::Required,
        extensions: RegisteredExtensions::none(),
        attestation: ParsedAttestation::default(),
        attestation_format: AttestationFormat::None,
    }
}

pub(super) fn counter_increases(previous: u32, actual: u32) -> bool {
    (previous == 0 && actual == 0) || actual > previous
}
