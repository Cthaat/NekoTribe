use super::*;
use crate::auth::{
    login::{LoginAccount, LoginChallenge},
    sessions::{build_native_router, CorsPolicy, SessionRepository, StoreFuture},
    IssuedToken, TokenCodec, TokenKind,
};
use http_body_util::BodyExt;
use p256::ecdsa::{signature::Signer, Signature, SigningKey};
use serde_cbor_2::Value as Cbor;
use sha2::{Digest, Sha256};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

const WEB: &str = "https://app.example.test";
const ANDROID: &str = "android:apk-key-hash:BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc";
const RP: &str = "example.test";
const USER: u64 = 42;
const ID: &[u8] = b"test-credential-id";

fn engine(origins: &str) -> Option<PasskeyEngine> {
    PasskeyEngine::from_lookup(|key| match key {
        "WEBAUTHN_RP_ID" => Some(RP.into()),
        "WEBAUTHN_ORIGINS" => Some(origins.into()),
        _ => None,
    })
}

fn client_data(kind: &str, challenge: &[u8], origin: &str, cross_origin: bool) -> Vec<u8> {
    serde_json::to_vec(&json!({
        "type": kind, "challenge": encode(challenge), "origin": origin,
        "crossOrigin": cross_origin,
    }))
    .unwrap()
}

fn auth_data(rp: &str, flags: u8, counter: u32) -> Vec<u8> {
    let mut data = Sha256::digest(rp.as_bytes()).to_vec();
    data.push(flags);
    data.extend(counter.to_be_bytes());
    data
}

fn registration(key: &SigningKey, challenge: &[u8], origin: &str) -> RegisterPublicKeyCredential {
    let mut data = auth_data(RP, 0x4d, 0); // UP, UV, BE, AT
    data.extend([0; 16]);
    data.extend((ID.len() as u16).to_be_bytes());
    data.extend(ID);
    let point = key.verifying_key().to_sec1_point(false);
    let point = point.as_bytes();
    let key = Cbor::Map(
        [
            (Cbor::Integer(1), Cbor::Integer(2)),
            (Cbor::Integer(3), Cbor::Integer(-7)),
            (Cbor::Integer(-1), Cbor::Integer(1)),
            (Cbor::Integer(-2), Cbor::Bytes(point[1..33].to_vec())),
            (Cbor::Integer(-3), Cbor::Bytes(point[33..65].to_vec())),
        ]
        .into_iter()
        .collect(),
    );
    data.extend(serde_cbor_2::to_vec(&key).unwrap());
    let attestation = Cbor::Map(
        [
            (Cbor::Text("fmt".into()), Cbor::Text("none".into())),
            (Cbor::Text("authData".into()), Cbor::Bytes(data)),
            (Cbor::Text("attStmt".into()), Cbor::Map(Default::default())),
        ]
        .into_iter()
        .collect(),
    );
    serde_json::from_value(json!({
        "id": encode(ID), "rawId": encode(ID), "type": "public-key",
        "response": {
            "clientDataJSON": encode(&client_data("webauthn.create", challenge, origin, false)),
            "attestationObject": encode(&serde_cbor_2::to_vec(&attestation).unwrap()),
        }
    }))
    .unwrap()
}

#[derive(Clone, Copy)]
struct Assertion<'a> {
    rp: &'a str,
    origin: &'a str,
    flags: u8,
    counter: u32,
    user: u64,
    cross_origin: bool,
}

impl Assertion<'_> {
    fn sign(self, key: &SigningKey, challenge: &[u8]) -> PublicKeyCredential {
        let client = client_data("webauthn.get", challenge, self.origin, self.cross_origin);
        let data = auth_data(self.rp, self.flags, self.counter);
        let mut signed = data.clone();
        signed.extend(&Sha256::digest(&client));
        let signature: Signature = key.sign(&signed);
        serde_json::from_value(json!({
            "id": encode(ID), "rawId": encode(ID), "type": "public-key",
            "response": {
                "clientDataJSON": encode(&client),
                "authenticatorData": encode(&data),
                "signature": encode(signature.to_der().as_bytes()),
                "userHandle": encode(&u128::from(self.user).to_be_bytes()),
            }
        }))
        .unwrap()
    }
}

fn stored(challenge: &[u8], state: &impl Serialize) -> StoredProof {
    let engine_state = serde_json::to_string(state).unwrap();
    assert!(engine_state.len() < 4_000);
    StoredProof {
        challenge: encode(challenge),
        engine_state,
    }
}

#[test]
fn browser_and_android_registration_and_assertion_use_canonical_key_format() {
    let key = SigningKey::from_slice(&[7; 32]).unwrap();
    for origin in [WEB, ANDROID] {
        let engine = engine(origin).unwrap();
        let (registration_options, registration_state) = engine
            .register_options(USER, "tester", "Test", vec![vec![9; 1000]; 6])
            .unwrap();
        let options = serde_json::to_value(&registration_options.public_key).unwrap();
        assert_eq!(
            options["user"]["id"],
            encode(&u128::from(USER).to_be_bytes())
        );
        assert_eq!(
            options["pubKeyCredParams"],
            json!([{"type":"public-key","alg":-7}])
        );
        assert_eq!(options["authenticatorSelection"]["residentKey"], "required");
        assert_eq!(
            options["authenticatorSelection"]["userVerification"],
            "required"
        );
        assert_eq!(options["excludeCredentials"].as_array().unwrap().len(), 6);
        let challenge = &registration_options.public_key.challenge;
        let registered = engine
            .registration_proof(
                registration(&key, challenge, origin),
                stored(challenge, &registration_state),
            )
            .unwrap();
        let webauthn_rs::prelude::COSEKeyType::EC_EC2(point) = registered.cred.key else {
            panic!("expected P-256 public key");
        };
        let durable = crypto::restore_credential(
            registered.cred_id,
            point.x,
            point.y,
            registered.counter,
            registered.backup_eligible,
            registered.backup_state,
        );
        let (options, state) = engine.webauthn.start_discoverable_authentication().unwrap();
        let challenge = &options.public_key.challenge;
        let assertion = Assertion {
            rp: RP,
            origin,
            flags: 0x1d,
            counter: 7,
            user: USER,
            cross_origin: false,
        };
        let proof = assertion.sign(&key, challenge);
        let (id, user, proof_state) = engine
            .authentication_proof(&proof, stored(challenge, &state))
            .unwrap();
        assert_eq!((id, user), (encode(ID), USER));
        let result = engine
            .webauthn
            .finish_discoverable_authentication_v2(&proof, proof_state, &durable)
            .unwrap();
        assert!(result.user_verified() && result.backup_eligible() && result.backup_state());
        assert_eq!(result.counter(), 7);
    }
}

#[test]
fn authentication_denies_wrong_rp_origin_signature_flags_and_counter() {
    let key = SigningKey::from_slice(&[7; 32]).unwrap();
    let point = key.verifying_key().to_sec1_point(false);
    let point = point.as_bytes();
    let durable = crypto::restore_credential(
        ID.to_vec(),
        point[1..33].to_vec(),
        point[33..65].to_vec(),
        7,
        true,
        false,
    );
    let engine = engine(WEB).unwrap();
    let (options, state) = engine.webauthn.start_discoverable_authentication().unwrap();
    let challenge = &options.public_key.challenge;
    let valid = Assertion {
        rp: RP,
        origin: WEB,
        flags: 0x0d,
        counter: 8,
        user: USER,
        cross_origin: false,
    };
    for failure in [
        Assertion {
            rp: "other.example.test",
            ..valid
        },
        Assertion {
            origin: "https://example.test",
            ..valid
        },
        Assertion {
            cross_origin: true,
            ..valid
        },
        Assertion {
            flags: 0x09,
            ..valid
        }, // Missing UV
        Assertion {
            flags: 0x0c,
            ..valid
        }, // Missing UP
        Assertion {
            flags: 0x05,
            ..valid
        }, // BE changed
        Assertion {
            counter: 7,
            ..valid
        },
        Assertion {
            counter: 0,
            ..valid
        },
    ] {
        let proof = failure.sign(&key, challenge);
        let completed = engine
            .authentication_proof(&proof, stored(challenge, &state))
            .ok()
            .and_then(|(_, _, state)| {
                engine
                    .webauthn
                    .finish_discoverable_authentication_v2(&proof, state, &durable)
                    .ok()
            });
        assert!(completed.is_none());
    }
    let proof = valid.sign(&SigningKey::from_slice(&[17; 32]).unwrap(), challenge);
    let (_, _, state) = engine
        .authentication_proof(&proof, stored(challenge, &state))
        .unwrap();
    assert!(engine
        .webauthn
        .finish_discoverable_authentication_v2(&proof, state, &durable)
        .is_err());
    assert!(crypto::counter_increases(0, 0));
    assert!(crypto::counter_increases(0, 1));
    assert!(!crypto::counter_increases(1, 0));
}

#[test]
fn origin_configuration_disables_invalid_values() {
    for origin in [
        "",
        "http://example.test",
        "https://user@example.test",
        "https://example.test/login",
        "https://example.test/",
        "android:apk-key-hash:short",
    ] {
        assert!(engine(origin).is_none());
    }
    assert!(engine("http://localhost:3000").is_some());
    assert!(engine(&format!("{WEB}, {ANDROID}")).is_some());
}

#[test]
fn readiness_recognizes_both_indexes_and_rejects_index_drift() {
    use crate::auth::readiness::validate_feature_snapshot;
    let catalog: Value = serde_json::from_str(include_str!(
        "../../../contracts/requirements/passkey-auth-schema-catalog.json"
    ))
    .unwrap();
    let mut snapshot = json!({
        "owner":{"user":"TEST_SCHEMA","schema":"TEST_SCHEMA"},
        "tables":{}, "indexes":{}, "ledgerPresent":false,
    });
    for step in catalog["feature"]["steps"].as_array().unwrap() {
        let name = step["name"].as_str().unwrap();
        if step["kind"] == "index" {
            let columns: Vec<_> = step["columns"]
                .as_array()
                .unwrap()
                .iter()
                .map(|column| json!({"COLUMN_NAME":column,"DESCEND":"ASC"}))
                .collect();
            snapshot["indexes"][name] = json!({
                "TABLE_NAME":step["table"],"STATUS":"VALID","UNIQUENESS":"NONUNIQUE","columns":columns,
            });
            continue;
        }
        let columns: Vec<_> = step["columns"]
            .as_array()
            .unwrap()
            .iter()
            .map(|column| {
                let kind = column["type"].as_str().unwrap();
                let mut value = json!({
                    "COLUMN_NAME":column["name"],"DATA_TYPE":"TIMESTAMP(6)",
                    "NULLABLE":if column["nullable"] == true {"Y"} else {"N"},
                    "DATA_DEFAULT":column["default"],
                });
                if let Some(precision) = kind
                    .strip_prefix("NUMBER(")
                    .and_then(|v| v.strip_suffix(')'))
                {
                    value["DATA_TYPE"] = json!("NUMBER");
                    value["DATA_PRECISION"] = json!(precision.parse::<u32>().unwrap());
                    value["DATA_SCALE"] = json!(0);
                } else if let Some(length) = kind
                    .strip_prefix("VARCHAR2(")
                    .and_then(|v| v.strip_suffix(')'))
                {
                    value["DATA_TYPE"] = json!("VARCHAR2");
                    value["CHAR_LENGTH"] = json!(length.parse::<u32>().unwrap());
                    value["CHAR_USED"] = column["charUsed"].clone();
                }
                value
            })
            .collect();
        let constraints: Vec<_> = step["constraints"].as_array().unwrap().iter().map(|constraint| json!({
            "CONSTRAINT_TYPE":constraint["type"],"STATUS":"ENABLED","VALIDATED":"VALIDATED",
            "columns":constraint["columns"],"SEARCH_CONDITION_VC":constraint["expression"],
            "REFERENCED_TABLE":constraint["referencedTable"],"DELETE_RULE":constraint["deleteRule"],
            "referencedColumns":constraint["referencedColumns"],
        })).collect();
        snapshot["tables"][name] = json!({"columns":columns,"constraints":constraints});
    }
    assert!(validate_feature_snapshot(&snapshot, "passkey-auth").is_ok());
    snapshot["indexes"]["IDX_WEBAUTHN_CRED_OWNER"]["columns"]
        .as_array_mut()
        .unwrap()
        .reverse();
    assert!(validate_feature_snapshot(&snapshot, "passkey-auth").is_err());
    snapshot["indexes"]["IDX_WEBAUTHN_CRED_OWNER"]["columns"]
        .as_array_mut()
        .unwrap()
        .reverse();
    snapshot["indexes"]
        .as_object_mut()
        .unwrap()
        .remove("IDX_WEBAUTHN_CHALL_EXPIRY");
    assert!(validate_feature_snapshot(&snapshot, "passkey-auth").is_err());
}

type Challenge = (String, Option<(u64, String)>, StoredProof);

struct Repository {
    challenge: Mutex<Option<Challenge>>,
    credential: Credential,
    pending_factor: Mutex<Option<bool>>,
}

impl SessionRepository for Repository {
    fn touch<'a>(&'a self, claims: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async move { Ok(u64::from(claims.session_id != "revoked")) })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn passkey(&self, operation: Operation) -> StoreFuture<'_, Outcome> {
        Box::pin(async move {
            Ok(match operation {
                Operation::Ready => Outcome::Ready,
                Operation::Owner(USER) => Outcome::Owner {
                    username: "tester".into(),
                    display_name: "Test User".into(),
                    excluded: Vec::new(),
                },
                Operation::Begin { id, session, proof } => {
                    let owner = session.map(|claims| (claims.user_id, claims.session_id));
                    *self.challenge.lock().unwrap() = Some((id, owner, proof));
                    Outcome::Begun
                }
                Operation::Take { id, owner } => {
                    let mut saved = self.challenge.lock().unwrap();
                    if saved
                        .as_ref()
                        .is_some_and(|(stored, binding, _)| *stored == id && *binding == owner)
                    {
                        Outcome::Taken(saved.take().unwrap().2)
                    } else {
                        Outcome::Invalid
                    }
                }
                Operation::Use {
                    id,
                    user,
                    engine,
                    state,
                    proof,
                } => {
                    if id == encode(ID)
                        && user == USER
                        && engine
                            .finish_discoverable_authentication_v2(&proof, state, &self.credential)
                            .is_ok()
                    {
                        Outcome::Used
                    } else {
                        Outcome::Invalid
                    }
                }
                Operation::List(USER) => Outcome::List(vec![]),
                Operation::Delete { id, .. } if id == encode(ID) => Outcome::Conflict,
                _ => Outcome::Missing,
            })
        })
    }
    fn login_account_by_id(&self, user: u64) -> StoreFuture<'_, Option<LoginAccount>> {
        Box::pin(async move {
            Ok((user == USER).then(|| LoginAccount {
                user_id: USER,
                username: "tester".into(),
                password_hash: "!passwordless!".into(),
                status: "active".into(),
                active: true,
            }))
        })
    }
    fn two_factor_readiness(&self) -> StoreFuture<'_, ()> {
        Box::pin(async { Ok(()) })
    }
    fn login_two_factor(&self, _: u64) -> StoreFuture<'_, bool> {
        Box::pin(async { Ok(true) })
    }
    fn login_challenge<'a>(&'a self, challenge: &'a LoginChallenge) -> StoreFuture<'a, bool> {
        Box::pin(async move {
            *self.pending_factor.lock().unwrap() = Some(challenge.remember);
            Ok(true)
        })
    }
}

async fn call(
    app: &Router,
    method: &str,
    path: &str,
    session: Option<&str>,
    body: Value,
) -> (StatusCode, Value) {
    let mut request = Request::builder().method(method).uri(path);
    if let Some(session) = session {
        let token = test_codec()
            .sign(&IssuedToken {
                user_id: USER,
                user_name: "tester".into(),
                session_id: session.into(),
                kind: TokenKind::Access,
                issued_at: 1_700_000_000,
                expires_at: 1_700_000_600,
                jti: "test-jti".into(),
            })
            .unwrap();
        request = request.header("authorization", format!("Bearer {token}"));
    }
    let response = app
        .clone()
        .oneshot(request.body(Body::from(body.to_string())).unwrap())
        .await
        .unwrap();
    assert_eq!(response.headers()["cache-control"], "private, no-store");
    let status = response.status();
    (
        status,
        serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes()).unwrap(),
    )
}

fn test_codec() -> TokenCodec {
    TokenCodec::new(b"example-test-key-1", b"example-test-key-2").unwrap()
}

#[tokio::test]
async fn routes_preserve_session_binding_one_time_proof_and_two_factor() {
    let key = SigningKey::from_slice(&[7; 32]).unwrap();
    let point = key.verifying_key().to_sec1_point(false);
    let point = point.as_bytes();
    let repo = Arc::new(Repository {
        challenge: Mutex::new(None),
        credential: crypto::restore_credential(
            ID.to_vec(),
            point[1..33].to_vec(),
            point[33..65].to_vec(),
            0,
            false,
            false,
        ),
        pending_factor: Mutex::new(None),
    });
    let app = build_native_router(
        test_codec(),
        repo.clone(),
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_001),
    );
    let auth_options = "/api/v2/auth/passkeys/authentication/options";
    let auth_verify = "/api/v2/auth/passkeys/authentication/verification";
    let reg_options = "/api/v2/auth/passkeys/registration/options";
    let reg_verify = "/api/v2/auth/passkeys/registration/verification";
    let owner_list = "/api/v2/users/me/passkeys";
    assert_eq!(
        call(&app, "POST", auth_options, None, Value::Null).await.0,
        StatusCode::SERVICE_UNAVAILABLE
    );
    let app = app.layer(Extension(engine(WEB).unwrap()));
    assert_eq!(
        call(&app, "GET", owner_list, None, Value::Null).await.0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        call(&app, "GET", owner_list, Some("revoked"), Value::Null)
            .await
            .0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        call(&app, "GET", owner_list, Some("original"), Value::Null)
            .await
            .1["data"]["credentials"],
        json!([])
    );
    let target = format!("{owner_list}/{}", encode(ID));
    assert_eq!(
        call(&app, "DELETE", &target, Some("original"), Value::Null)
            .await
            .0,
        StatusCode::CONFLICT
    );
    let (status, data) = call(&app, "POST", reg_options, Some("original"), Value::Null).await;
    assert_eq!(status, StatusCode::OK);
    assert!(data["data"].get("engine_state").is_none());
    let invalid = json!({"challenge_id":data["data"]["challenge_id"],
        "credential":{"id":encode(ID),"rawId":encode(ID),"type":"public-key","response":{}}});
    assert_eq!(
        call(&app, "POST", reg_verify, Some("other"), invalid.clone())
            .await
            .0,
        StatusCode::UNAUTHORIZED
    );
    assert!(repo.challenge.lock().unwrap().is_some());
    assert_eq!(
        call(&app, "POST", reg_verify, Some("original"), invalid)
            .await
            .0,
        StatusCode::UNAUTHORIZED
    );
    assert!(repo.challenge.lock().unwrap().is_none());

    let (_, data) = call(&app, "POST", auth_options, None, Value::Null).await;
    let challenge = URL_SAFE_NO_PAD
        .decode(data["data"]["options"]["challenge"].as_str().unwrap())
        .unwrap();
    let mismatch = Assertion {
        rp: RP,
        origin: WEB,
        flags: 0x05,
        counter: 1,
        user: USER + 1,
        cross_origin: false,
    };
    let invalid = json!({"challenge_id":data["data"]["challenge_id"],
        "credential":mismatch.sign(&key, &challenge)});
    assert_eq!(
        call(&app, "POST", auth_verify, None, invalid).await.0,
        StatusCode::UNAUTHORIZED
    );
    assert!(repo.pending_factor.lock().unwrap().is_none());

    let (_, data) = call(&app, "POST", auth_options, None, Value::Null).await;
    let challenge = URL_SAFE_NO_PAD
        .decode(data["data"]["options"]["challenge"].as_str().unwrap())
        .unwrap();
    let assertion = Assertion {
        rp: RP,
        origin: WEB,
        flags: 0x05,
        counter: 1,
        user: USER,
        cross_origin: false,
    };
    let body = json!({"challenge_id":data["data"]["challenge_id"],
        "credential":assertion.sign(&key, &challenge), "remember_me":true});
    let (status, data) = call(&app, "POST", auth_verify, None, body.clone()).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(data["data"]["two_factor_required"], true);
    assert!(data["data"].get("tokens").is_none());
    assert_eq!(*repo.pending_factor.lock().unwrap(), Some(true));
    assert_eq!(
        call(&app, "POST", auth_verify, None, body).await.0,
        StatusCode::UNAUTHORIZED
    );
}
