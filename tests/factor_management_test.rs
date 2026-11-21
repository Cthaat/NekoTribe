use axum::{body::Body, http::Request};
use nekotribe_backend::auth::{
    sessions::{build_native_router, CorsPolicy, SessionRepository, StoreFuture},
    TokenClaims, TokenCodec,
};
use serde_json::Value;
use std::sync::Arc;
use tower::ServiceExt;
struct Store;
use aes_gcm::{aead::Aead, Aes256Gcm, KeyInit};
use base64::{engine::general_purpose::STANDARD, Engine};
use http_body_util::BodyExt;
use nekotribe_backend::auth::{
    factor_management::{FactorAction, FactorMutation, FactorOutcome},
    login::{EncryptedSecret, LoginAccount, RecoveryCode},
    sessions::SessionStoreError,
};
use sha2::{Digest, Sha256};
use std::sync::Mutex;
struct ManagementStore {
    case: Value,
    secret: EncryptedSecret,
    hash: String,
    recovery_hash: String,
    writes: Mutex<u64>,
    mutation: Mutex<Option<FactorMutation>>,
}
impl SessionRepository for ManagementStore {
    fn touch<'a>(&'a self, _: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async move { Ok(u64::from(self.case["auth"] != "revoked")) })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn account_credential(&self, _: u64) -> StoreFuture<'_, Option<LoginAccount>> {
        Box::pin(async move {
            if self.case["fault"] == "credential" {
                return Err(SessionStoreError);
            }
            Ok((self.case["fault"] != "missing").then(|| LoginAccount {
                user_id: 42,
                username: "tester".into(),
                password_hash: self.hash.clone(),
                active: self.case["fault"] != "inactive",
                status: "active".into(),
            }))
        })
    }
    fn two_factor_readiness(&self) -> StoreFuture<'_, ()> {
        Box::pin(async move {
            if self.case["fault"] == "schema" {
                Err(SessionStoreError)
            } else {
                Ok(())
            }
        })
    }
    fn login_profile(&self, _: u64) -> StoreFuture<'_, Option<Value>> {
        Box::pin(async move {
            if self.case["fault"] == "profile" {
                return Err(SessionStoreError);
            }
            Ok(Some(
                serde_json::json!({"user_id":42,"username":"tester","email":"fake@example.test"}),
            ))
        })
    }
    fn two_factor_secret(&self, _: u64) -> StoreFuture<'_, Option<EncryptedSecret>> {
        Box::pin(async move {
            if self.case["fault"] == "secret" {
                return Err(SessionStoreError);
            }
            Ok((self.case["secret"] != "absent").then(|| self.secret.clone()))
        })
    }
    fn recovery_codes(&self, _: u64) -> StoreFuture<'_, Vec<RecoveryCode>> {
        Box::pin(async move {
            if self.case["fault"] == "recovery" {
                return Err(SessionStoreError);
            }
            Ok(vec![RecoveryCode {
                id: 1,
                hash: self.recovery_hash.clone(),
            }])
        })
    }
    fn apply_factor_mutation<'a>(
        &'a self,
        user: u64,
        m: &'a FactorMutation,
    ) -> StoreFuture<'a, FactorOutcome> {
        Box::pin(async move {
            assert_eq!(user, 42);
            *self.mutation.lock().unwrap() = Some(m.clone());
            match self.case["fault"].as_str().unwrap_or("") {
                "write" | "commit" => return Err(SessionStoreError),
                "changed" => return Ok(FactorOutcome::Changed),
                "consume" => {
                    assert_eq!(m.recovery_id, Some(1));
                    return Ok(FactorOutcome::RecoveryUsed);
                }
                "commit_applied" => {
                    *self.writes.lock().unwrap() += 1;
                    return Err(SessionStoreError);
                }
                _ => {}
            }
            *self.writes.lock().unwrap() += 1;
            Ok(FactorOutcome::Applied)
        })
    }
}
fn encrypted_test(plain: &str, key: &[u8; 32]) -> EncryptedSecret {
    let iv = [0u8; 12];
    let bytes = Aes256Gcm::new_from_slice(key)
        .unwrap()
        .encrypt(aes_gcm::Nonce::from_slice(&iv), plain.as_bytes())
        .unwrap();
    let n = bytes.len() - 16;
    EncryptedSecret {
        encrypted: STANDARD.encode(&bytes[..n]),
        iv: STANDARD.encode(iv),
        tag: STANDARD.encode(&bytes[n..]),
        enabled: false,
    }
}
#[tokio::test]
async fn shared_factor_management() {
    let f: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/auth-two-factor-management.json"
    ))
    .unwrap();
    let tokens: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = tokens["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    let key: [u8; 32] =
        Sha256::digest(tokens["keys"]["refresh"].as_str().unwrap().as_bytes()).into();
    let hash = bcrypt::hash("test-password", 4).unwrap();
    let recovery_hash = bcrypt::hash("ABCDEFGHIJKLMNO", 4).unwrap();
    for c in f["cases"].as_array().unwrap() {
        let action = c["action"].as_str().unwrap();
        let mut secret = encrypted_test(
            if c["fault"] == "base32" {
                "INVALID!"
            } else {
                f["secret"].as_str().unwrap()
            },
            &key,
        );
        secret.enabled = c["secret"] == "enabled" || (c["secret"].is_null() && action == "disable");
        if c["fault"] == "cipher" {
            secret.tag = "bad".into()
        }
        let store = Arc::new(ManagementStore {
            case: c.clone(),
            secret,
            hash: hash.clone(),
            recovery_hash: recovery_hash.clone(),
            writes: Mutex::new(0),
            mutation: Mutex::new(None),
        });
        let codec = TokenCodec::new(
            tokens["keys"]["access"].as_str().unwrap().as_bytes(),
            tokens["keys"]["refresh"].as_str().unwrap().as_bytes(),
        )
        .unwrap();
        let clock = f["clockUnix"].as_u64().unwrap();
        let app = build_native_router(
            codec,
            store.clone(),
            CorsPolicy::default(),
            Arc::new(move || clock),
        );
        let mut body = f["base"].clone();
        for (k, v) in c["patch"].as_object().unwrap() {
            body[k] = v.clone()
        }
        if body["code"] == "@totp" {
            body["code"] = f["totp"].clone()
        }
        if body["code"] == "@recovery" {
            body["code"] = f["recoveryCode"].clone()
        }
        let (method, path) = if action == "disable" {
            ("DELETE", "/api/v2/users/me/two-factor".to_owned())
        } else {
            ("POST", format!("/api/v2/users/me/two-factor/{action}"))
        };
        let mut req = Request::builder()
            .method(method)
            .uri(path)
            .header("content-type", "application/json");
        if c["auth"] != "none" {
            req = req.header("authorization", format!("Bearer {token}"))
        }
        let res = app
            .oneshot(req.body(Body::from(body.to_string())).unwrap())
            .await
            .unwrap();
        assert_eq!(
            res.status().as_u16(),
            c["status"].as_u64().unwrap() as u16,
            "{}",
            c["id"]
        );
        assert_eq!(
            *store.writes.lock().unwrap(),
            c["writes"].as_u64().unwrap(),
            "{}",
            c["id"]
        );
        assert_eq!(res.headers().get_all("set-cookie").iter().count(), 0);
        let raw = res.into_body().collect().await.unwrap().to_bytes();
        let out: Value = serde_json::from_slice(&raw).unwrap();
        if c["message"].is_string() {
            assert_eq!(out["message"], c["message"], "{}", c["id"])
        }
        assert!(!String::from_utf8_lossy(&raw).contains("test-password"));
        if c["status"] == 200 {
            let guard = store.mutation.lock().unwrap();
            let mutation = guard.as_ref().unwrap();
            if mutation.action == FactorAction::Setup {
                let s = mutation.new_secret.as_ref().unwrap();
                let mut data = STANDARD.decode(&s.encrypted).unwrap();
                data.extend(STANDARD.decode(&s.tag).unwrap());
                let iv = STANDARD.decode(&s.iv).unwrap();
                let plain = Aes256Gcm::new_from_slice(&key)
                    .unwrap()
                    .decrypt(aes_gcm::Nonce::from_slice(&iv), data.as_slice())
                    .unwrap();
                assert_eq!(out["data"]["secret"].as_str().unwrap().as_bytes(), plain);
                assert_eq!(plain.len(), 32);
            }
            if mutation.action == FactorAction::Confirm {
                let codes = out["data"]["recovery_codes"].as_array().unwrap();
                assert_eq!(codes.len(), 10);
                for (code, hash) in codes.iter().zip(&mutation.recovery_hashes) {
                    assert!(bcrypt::verify(
                        code.as_str().unwrap().replace('-', "").to_uppercase(),
                        hash
                    )
                    .unwrap());
                }
            }
        }
    }
}
impl SessionRepository for Store {
    fn touch<'a>(&'a self, _: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(1) })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
}
#[tokio::test]
async fn native_factor_management_routes() {
    let f: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = f["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    for action in ["setup", "confirm", "disable"] {
        let codec = TokenCodec::new(
            f["keys"]["access"].as_str().unwrap().as_bytes(),
            f["keys"]["refresh"].as_str().unwrap().as_bytes(),
        )
        .unwrap();
        let app = build_native_router(
            codec,
            Arc::new(Store),
            CorsPolicy::default(),
            Arc::new(|| 1700000000),
        );
        let (method, path) = if action == "disable" {
            ("DELETE", "/api/v2/users/me/two-factor".to_owned())
        } else {
            ("POST", format!("/api/v2/users/me/two-factor/{action}"))
        };
        let res = app
            .oneshot(
                Request::builder()
                    .method(method)
                    .uri(path)
                    .header("content-type", "application/json")
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::from(
                        r#"{"password":"test-password","code":"123456"}"#,
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_ne!(res.status().as_u16(), 404, "{action}");
        assert_ne!(res.status().as_u16(), 405, "{action}");
    }
}
