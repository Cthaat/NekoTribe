use axum::{
    body::{to_bytes, Body},
    http::Request,
};
use nekotribe_backend::{
    auth::{
        sessions::{
            build_native_router, CorsPolicy, SessionRepository, SessionStoreError, StoreFuture,
        },
        TokenClaims, TokenCodec,
    },
    users::statements::{StatementQuery, StatementWrite, WriteOutcome},
};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

#[derive(Default)]
struct Flow {
    status: String,
    pending: Option<String>,
    created: usize,
}

#[derive(Default)]
struct Store(Mutex<Flow>);
impl SessionRepository for Store {
    fn touch<'a>(&'a self, claims: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async move { Ok(u64::from(claims.user_id == 42)) })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn account_statements(
        &self,
        actor: u64,
        query: StatementQuery,
    ) -> StoreFuture<'_, (Vec<Value>, i64)> {
        Box::pin(async move {
            assert_eq!(actor, 42);
            assert_eq!(query.status.as_deref(), Some("unread"));
            assert_eq!(query.kind.as_deref(), Some("warning"));
            assert_eq!((query.page.start, query.page.end), (3.0, 4.0));
            Ok((vec![], 2))
        })
    }
    fn write_account_statement(
        &self,
        actor: u64,
        target: u64,
        write: StatementWrite,
    ) -> StoreFuture<'_, WriteOutcome> {
        Box::pin(async move {
            assert_eq!(actor, 42);
            if target == 10 {
                return Err(SessionStoreError);
            }
            if target != 9 {
                return Ok(WriteOutcome::Missing);
            }
            let mut flow = self.0.lock().unwrap();
            match write {
                StatementWrite::Status(status) => {
                    flow.status = status;
                    Ok(WriteOutcome::Applied(json!({
                        "statement_id":target,"status":flow.status,"updated_at":"2026-11-16T08:00:00.000Z"
                    })))
                }
                StatementWrite::Appeal(message) => {
                    if let Some(existing) = &flow.pending {
                        if existing != &message {
                            return Ok(WriteOutcome::Pending);
                        }
                    } else {
                        flow.pending = Some(message);
                        flow.created += 1;
                        flow.status = "appealed".into();
                    }
                    Ok(WriteOutcome::Applied(json!({
                        "statement_id":target,"status":flow.status,"appeal_id":12,"appeal_status":"pending"
                    })))
                }
            }
        })
    }
}

#[tokio::test]
async fn shared_statement_scenarios() {
    let tokens: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = tokens["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    let codec = TokenCodec::new(
        tokens["keys"]["access"].as_str().unwrap().as_bytes(),
        tokens["keys"]["refresh"].as_str().unwrap().as_bytes(),
    )
    .unwrap();
    let store = Arc::new(Store::default());
    let app = build_native_router(
        codec,
        store.clone(),
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_000),
    );
    let vectors: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/account-statements.json"
    ))
    .unwrap();
    for case in vectors["cases"].as_array().unwrap() {
        let mut req = Request::builder()
            .method(case["method"].as_str().unwrap())
            .uri(case["path"].as_str().unwrap())
            .header("Content-Type", "application/json");
        if case["status"] != 401 {
            req = req.header("Authorization", format!("Bearer {token}"));
        }
        let body = case
            .get("body")
            .map_or_else(Body::empty, |value| Body::from(value.to_string()));
        let res = app.clone().oneshot(req.body(body).unwrap()).await.unwrap();
        assert_eq!(
            u64::from(res.status().as_u16()),
            case["status"].as_u64().unwrap(),
            "{}",
            case["id"]
        );
        assert_eq!(res.headers()["Cache-Control"], "private, no-store");
        let payload: Value =
            serde_json::from_slice(&to_bytes(res.into_body(), 8192).await.unwrap()).unwrap();
        if let Some(expected) = case.get("data") {
            assert_eq!(&payload["data"], expected);
        }
        if let Some(meta) = case.get("meta") {
            assert_eq!(payload["data"], json!([]));
            for key in ["page", "page_size", "total"] {
                assert_eq!(payload["meta"][key].as_f64(), meta[key].as_f64());
            }
            assert_eq!(payload["meta"]["has_next"], meta["has_next"]);
        }
    }
    let flow = store.0.lock().unwrap();
    assert_eq!(flow.pending.as_deref(), Some("Check rule application"));
    assert_eq!(flow.created, 1);
}
