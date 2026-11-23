use super::*;
use crate::{
    auth::{
        login::{LoginAccount, LoginChallenge},
        sessions::{build_native_router, CorsPolicy, SessionRepository, StoreFuture},
        IssuedToken, TokenCodec, TokenKind,
    },
    db::{
        oracle::{BindMap, DbError},
        row::DbRow,
        tx::Transaction,
        value::DbValue,
    },
};
use http_body_util::BodyExt;
use std::{
    cell::RefCell,
    collections::VecDeque,
    future,
    sync::{Arc, Mutex},
};
use tower::ServiceExt;
use url::Url;

const USER: u64 = 42;

fn engine(redirect: &str) -> Option<GithubOAuth> {
    GithubOAuth::from_lookup(|key| match key {
        "GITHUB_OAUTH_CLIENT_ID" => Some("test-app".into()),
        "GITHUB_OAUTH_CLIENT_SECRET" => Some("test-secret".into()),
        "GITHUB_OAUTH_REDIRECT_URI" => Some(redirect.into()),
        _ => None,
    })
}

fn fixture_engine() -> GithubOAuth {
    engine(&format!("https://nekotribe.example{CALLBACK}")).unwrap()
}

#[tokio::test]
async fn provider_uses_fixed_endpoints_s256_and_numeric_identity() {
    let provider = fixture_engine();
    let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    let authorization = provider.authorization_url("fixture-state", verifier);
    assert_eq!(
        authorization.origin().ascii_serialization(),
        "https://github.com"
    );
    assert_eq!(authorization.path(), "/login/oauth/authorize");
    let pairs: std::collections::BTreeMap<_, _> = authorization.query_pairs().collect();
    assert_eq!(
        pairs["code_challenge"],
        "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    );
    assert_eq!(pairs["code_challenge_method"], "S256");
    assert_eq!(pairs["scope"], "");
    assert_eq!(pairs["allow_signup"], "false");
    assert!(!pairs.contains_key("client_secret"));
    let mut calls = 0;
    let identity = provider
        .verify_with("fixture-code", verifier, |request| {
            calls += 1;
            future::ready(Some(match calls {
                1 => {
                    assert_eq!(
                        request.url().as_str(),
                        "https://github.com/login/oauth/access_token"
                    );
                    assert_eq!(request.method(), reqwest::Method::POST);
                    let form: std::collections::BTreeMap<_, _> =
                        url::form_urlencoded::parse(request.body().unwrap().as_bytes().unwrap())
                            .collect();
                    assert_eq!(form["code"], "fixture-code");
                    assert_eq!(form["code_verifier"], verifier);
                    assert_eq!(form["client_secret"], "test-secret");
                    assert_eq!(
                        form["redirect_uri"],
                        format!("https://nekotribe.example{CALLBACK}")
                    );
                    br#"{"access_token":"fixture-token","token_type":"bearer"}"#.to_vec()
                }
                2 => {
                    assert_eq!(request.url().as_str(), "https://api.github.com/user");
                    assert_eq!(request.method(), reqwest::Method::GET);
                    assert_eq!(request.headers()["authorization"], "Bearer fixture-token");
                    assert!(request.headers()["authorization"].is_sensitive());
                    br#"{"id":9007199254740991,"login":"test-user","email":"unused@example.test"}"#
                        .to_vec()
                }
                _ => panic!("unexpected call"),
            }))
        })
        .await
        .unwrap();
    assert_eq!(calls, 2);
    assert_eq!(identity.id, "9007199254740991");
    assert_eq!(identity.login, "test-user");
}

#[tokio::test]
async fn provider_rejects_invalid_configuration_and_identity_without_network() {
    assert!(engine(&format!("http://localhost:4000{CALLBACK}")).is_some());
    for redirect in [
        format!("http://nekotribe.example{CALLBACK}"),
        format!("https://user@nekotribe.example{CALLBACK}"),
        format!("https://nekotribe.example{CALLBACK}?unexpected=1"),
        format!("https://nekotribe.example{CALLBACK}#fragment"),
        "https://nekotribe.example/wrong-path".into(),
    ] {
        assert!(engine(&redirect).is_none());
    }
    let provider = fixture_engine();
    for profile in [
        json!({"id":9007199254740992_u64,"login":"test"}),
        json!({"id":0,"login":"test"}),
        json!({"id":-1,"login":"test"}),
        json!({"id":1.5,"login":"test"}),
        json!({"id":"123","login":"test"}),
        json!({"id":123,"login":"x".repeat(81)}),
        json!({"id":123,"login":" "}),
    ] {
        let identity = provider
            .verify_with("fixture", "fixture", |request| {
                future::ready(Some(if request.method() == reqwest::Method::POST {
                    br#"{"access_token":"fixture-token","token_type":"bearer"}"#.to_vec()
                } else {
                    serde_json::to_vec(&profile).unwrap()
                }))
            })
            .await;
        assert!(identity.is_none());
    }
}

enum SqlStep {
    Read(&'static str, BindMap, Vec<DbRow>),
    ReadError(&'static str, BindMap, DbError),
    Write(&'static str, BindMap, u64),
    Commit,
    Rollback,
}

struct SqlFixture(RefCell<VecDeque<SqlStep>>);

impl SqlFixture {
    fn new<const N: usize>(steps: [SqlStep; N]) -> Self {
        Self(RefCell::new(steps.into()))
    }
    fn step(&self) -> SqlStep {
        self.0
            .borrow_mut()
            .pop_front()
            .expect("unexpected SQL step")
    }
    fn done(&self) {
        assert!(self.0.borrow().is_empty());
    }
}

impl Transaction for SqlFixture {
    fn query(&self, sql: &str, binds: BindMap) -> Result<Vec<DbRow>, DbError> {
        let (expected_sql, expected_binds, result) = match self.step() {
            SqlStep::Read(sql, binds, rows) => (sql, binds, Ok(rows)),
            SqlStep::ReadError(sql, binds, error) => (sql, binds, Err(error)),
            _ => panic!("unexpected SELECT"),
        };
        assert_eq!(sql, expected_sql);
        assert_eq!(binds, expected_binds);
        result
    }
    fn execute(&self, sql: &str, binds: BindMap) -> Result<u64, DbError> {
        let SqlStep::Write(expected_sql, expected_binds, rows) = self.step() else {
            panic!("unexpected write")
        };
        assert_eq!(sql, expected_sql);
        assert_eq!(binds, expected_binds);
        Ok(rows)
    }
    fn commit(&self) -> Result<(), DbError> {
        assert!(matches!(self.step(), SqlStep::Commit));
        Ok(())
    }
    fn rollback(&self) -> Result<(), DbError> {
        assert!(matches!(self.step(), SqlStep::Rollback));
        Ok(())
    }
}

fn text(name: &str, value: &str) -> (String, DbValue) {
    (name.into(), DbValue::String(value.into()))
}
fn user() -> BindMap {
    BindMap::from([("user_id".into(), DbValue::I64(USER as i64))])
}

fn claims() -> TokenClaims {
    TokenClaims {
        user_id: USER,
        session_id: "original".into(),
        jti: "fixture-jti".into(),
        kind: TokenKind::Access,
        user_name: None,
        issued_at: None,
        expires_at: None,
    }
}

#[test]
fn oracle_transitions_claim_and_consume_under_locks() {
    let sql = &spec().sql;
    let state = digest("fixture-state");
    let key = digest("fixture-flow-key");
    let flow = || BindMap::from([text("flow_id", "fixture-flow")]);
    let callback = || BindMap::from([text("state_hash", &state)]);
    let complete = || {
        BindMap::from([
            text("flow_id", "fixture-flow"),
            text("flow_key_hash", &key),
            text("purpose", "login"),
            ("owner_user_id".into(), DbValue::Null),
            ("owner_session_id".into(), DbValue::Null),
        ])
    };
    let tx = SqlFixture::new([
        SqlStep::Read(
            &sql.callback_lock,
            callback(),
            vec![DbRow::from([
                text("FLOW_ID", "fixture-flow"),
                text("PKCE_VERIFIER", "fixture-verifier"),
            ])],
        ),
        SqlStep::Write(&sql.callback_claim, flow(), 1),
        SqlStep::Commit,
        SqlStep::Read(&sql.callback_lock, callback(), vec![]),
        SqlStep::Rollback,
        SqlStep::Read(
            &sql.complete_lock,
            complete(),
            vec![DbRow::from([text("STATUS", "checking")])],
        ),
        SqlStep::Rollback,
        SqlStep::Write(
            &sql.callback_finish,
            BindMap::from([
                text("flow_id", "fixture-flow"),
                text("status", "verified"),
                text("github_user_id", "123"),
                text("github_login", "fixture"),
            ]),
            1,
        ),
        SqlStep::Commit,
        SqlStep::Read(
            &sql.complete_lock,
            complete(),
            vec![DbRow::from([
                text("STATUS", "verified"),
                text("GITHUB_USER_ID", "123"),
                text("GITHUB_LOGIN", "fixture"),
            ])],
        ),
        SqlStep::Write(&sql.complete_consume, flow(), 1),
        SqlStep::Read(
            &sql.link_for_github,
            BindMap::from([text("github_user_id", "123")]),
            vec![DbRow::from([("USER_ID".into(), DbValue::I64(USER as i64))])],
        ),
        SqlStep::Commit,
        SqlStep::Read(&sql.complete_lock, complete(), vec![]),
        SqlStep::Rollback,
    ]);
    let claim = || Operation::Claim {
        state_hash: state.clone(),
    };
    let finish = || Operation::Complete {
        flow_id: "fixture-flow".into(),
        flow_key_hash: key.clone(),
        session: None,
    };
    assert!(matches!(
        store::run(&tx, claim()).unwrap(),
        Outcome::Claimed { .. }
    ));
    assert!(matches!(
        store::run(&tx, claim()).unwrap(),
        Outcome::Invalid
    ));
    assert!(matches!(
        store::run(&tx, finish()).unwrap(),
        Outcome::Pending
    ));
    assert!(matches!(
        store::run(
            &tx,
            Operation::Record {
                flow_id: "fixture-flow".into(),
                identity: Some(Identity {
                    id: "123".into(),
                    login: "fixture".into()
                })
            }
        )
        .unwrap(),
        Outcome::Recorded
    ));
    assert!(matches!(
        store::run(&tx, finish()).unwrap(),
        Outcome::Login(USER)
    ));
    assert!(matches!(
        store::run(&tx, finish()).unwrap(),
        Outcome::Invalid
    ));
    tx.done();
}

#[test]
fn oracle_link_binds_original_session_and_confirms_existing_identity() {
    let sql = &spec().sql;
    let key = digest("fixture-flow-key");
    for session_id in ["other", "original"] {
        let mut session = claims();
        session.session_id = session_id.into();
        let mut session_binds = user();
        session_binds.extend([
            text("session_id", session_id),
            text("access_jti", "fixture-jti"),
        ]);
        let complete = BindMap::from([
            text("flow_id", "fixture-flow"),
            text("flow_key_hash", &key),
            text("purpose", "link"),
            ("owner_user_id".into(), DbValue::I64(USER as i64)),
            text("owner_session_id", session_id),
        ]);
        let verified = session_id == "original";
        let mut steps = VecDeque::from([
            SqlStep::Read(
                crate::auth::passkey::active_owner_sql(),
                user(),
                vec![DbRow::new()],
            ),
            SqlStep::Write(crate::auth::session_repository::TOUCH_SQL, session_binds, 1),
            SqlStep::Read(
                &sql.complete_lock,
                complete,
                if verified {
                    vec![DbRow::from([
                        text("STATUS", "verified"),
                        text("GITHUB_USER_ID", "123"),
                        text("GITHUB_LOGIN", "register"),
                    ])]
                } else {
                    vec![]
                },
            ),
        ]);
        if verified {
            steps.extend([
                SqlStep::Write(
                    &sql.complete_consume,
                    BindMap::from([text("flow_id", "fixture-flow")]),
                    1,
                ),
                SqlStep::Read(
                    &sql.link_for_user,
                    user(),
                    vec![DbRow::from([
                        text("GITHUB_USER_ID", "123"),
                        text("GITHUB_LOGIN", "before"),
                        text("LINKED_AT", "2026-01-01T00:00:00Z"),
                    ])],
                ),
                SqlStep::Commit,
            ]);
        } else {
            steps.push_back(SqlStep::Rollback);
        }
        let tx = SqlFixture(RefCell::new(steps));
        let result = store::run(
            &tx,
            Operation::Complete {
                flow_id: "fixture-flow".into(),
                flow_key_hash: key.clone(),
                session: Some(session),
            },
        )
        .unwrap();
        match (verified, result) {
            (true, Outcome::Linked(link)) => assert_eq!(link.github_login, "before"),
            (false, Outcome::Invalid) => {}
            _ => panic!("unexpected link result"),
        }
        tx.done();
    }
}

#[allow(deprecated)]
fn nonexistent_table() -> DbError {
    DbError::Oracle(oracle::Error::OciError(oracle::DbError::new(
        942,
        0,
        "mock missing table",
        "oracle",
        "query",
    )))
}

#[test]
fn passkey_fallback_treats_a_missing_github_table_as_unlinked() {
    let sql = &spec().sql.link_for_user;
    let tx = SqlFixture::new([
        SqlStep::Read(
            sql,
            user(),
            vec![DbRow::from([text("GITHUB_USER_ID", "123")])],
        ),
        SqlStep::ReadError(sql, user(), nonexistent_table()),
        SqlStep::ReadError(sql, user(), DbError::SchemaNotReady),
    ]);
    assert!(has_link(&tx, USER).unwrap());
    assert!(!has_link(&tx, USER).unwrap());
    assert!(has_link(&tx, USER).is_err());
    tx.done();
}

#[test]
fn oracle_unlink_locks_owner_and_requires_another_login_method() {
    let sql = &spec().sql;
    for total in [0, 1] {
        let mut session_binds = user();
        session_binds.extend([
            text("session_id", "original"),
            text("access_jti", "fixture-jti"),
        ]);
        let fixture = [
            SqlStep::Read(
                crate::auth::passkey::active_owner_sql(),
                user(),
                vec![DbRow::from([text("PASSWORD_HASH", "!passwordless!")])],
            ),
            SqlStep::Write(crate::auth::session_repository::TOUCH_SQL, session_binds, 1),
            SqlStep::Read(
                &sql.link_for_user,
                user(),
                vec![DbRow::from([text("GITHUB_USER_ID", "123")])],
            ),
            SqlStep::Read(
                &sql.passkey_count,
                user(),
                vec![DbRow::from([("TOTAL".into(), DbValue::I64(total))])],
            ),
        ];
        let mut steps: VecDeque<_> = fixture.into();
        if total > 0 {
            steps.extend([SqlStep::Write(&sql.link_remove, user(), 1), SqlStep::Commit]);
        } else {
            steps.push_back(SqlStep::Rollback);
        }
        let tx = SqlFixture(RefCell::new(steps));
        let result = store::run(&tx, Operation::Remove(claims())).unwrap();
        assert!(matches!(
            (total, result),
            (0, Outcome::Conflict) | (1, Outcome::Removed)
        ));
        tx.done();
    }
}

#[derive(Default)]
struct Repository {
    flow: Mutex<Option<Flow>>,
    denied: Mutex<bool>,
    login_ready: Mutex<Option<String>>,
    remember: Mutex<Option<bool>>,
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
    fn github_oauth(&self, operation: Operation) -> StoreFuture<'_, Outcome> {
        Box::pin(async move {
            Ok(match operation {
                Operation::Ready => Outcome::Ready,
                Operation::Begin {
                    flow,
                    session: None,
                } => {
                    *self.flow.lock().unwrap() = Some(flow);
                    Outcome::Begun
                }
                Operation::Claim { state_hash } if !*self.denied.lock().unwrap() => self
                    .flow
                    .lock()
                    .unwrap()
                    .as_ref()
                    .filter(|flow| flow.state_hash == state_hash)
                    .map(|flow| Outcome::Claimed {
                        flow_id: flow.id.clone(),
                        pkce_verifier: flow.pkce_verifier.clone(),
                    })
                    .unwrap_or(Outcome::Invalid),
                Operation::Record { identity: None, .. } => {
                    *self.denied.lock().unwrap() = true;
                    Outcome::Recorded
                }
                Operation::Complete {
                    flow_key_hash,
                    session: None,
                    ..
                } => {
                    let mut key = self.login_ready.lock().unwrap();
                    if key.as_ref() == Some(&flow_key_hash) {
                        key.take();
                        Outcome::Login(USER)
                    } else {
                        Outcome::Invalid
                    }
                }
                Operation::Read(USER) => Outcome::Link(None),
                _ => Outcome::Invalid,
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
            *self.remember.lock().unwrap() = Some(challenge.remember);
            Ok(true)
        })
    }
}

async fn call(
    app: &Router,
    method: &str,
    uri: &str,
    token: Option<&str>,
    body: Value,
) -> (StatusCode, HeaderMap, String) {
    let mut request = Request::builder().method(method).uri(uri);
    if let Some(token) = token {
        request = request.header("authorization", format!("Bearer {token}"));
    }
    let response = app
        .clone()
        .oneshot(request.body(Body::from(body.to_string())).unwrap())
        .await
        .unwrap();
    assert_eq!(response.headers()["cache-control"], "private, no-store");
    let (parts, body) = response.into_parts();
    (
        parts.status,
        parts.headers,
        String::from_utf8(body.collect().await.unwrap().to_bytes().to_vec()).unwrap(),
    )
}

#[tokio::test]
async fn native_routes_emit_static_denial_and_reuse_two_factor_with_one_time_key() {
    let repo = Arc::new(Repository::default());
    let codec = TokenCodec::new(b"fixture-key-1", b"fixture-key-2").unwrap();
    let token = codec
        .sign(&IssuedToken {
            user_id: USER,
            user_name: "tester".into(),
            session_id: "original".into(),
            kind: TokenKind::Access,
            issued_at: 1_700_000_000,
            expires_at: 1_700_001_000,
            jti: "fixture-jti".into(),
        })
        .unwrap();
    let app = build_native_router(
        codec,
        repo.clone(),
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_001),
    );
    let start = "/api/v2/auth/oauth/github/login/flows";
    assert_eq!(
        call(&app, "POST", start, None, Value::Null).await.0,
        StatusCode::SERVICE_UNAVAILABLE
    );
    let app = app.layer(Extension(fixture_engine()));
    let (status, _, body) = call(&app, "POST", start, None, Value::Null).await;
    assert_eq!(status, StatusCode::OK);
    let response: Value = serde_json::from_str(&body).unwrap();
    let response = &response["data"];
    let flow_id = response["flow_id"].as_str().unwrap();
    let flow_key = response["flow_key"].as_str().unwrap();
    let authority = Url::parse(response["authorization_url"].as_str().unwrap()).unwrap();
    let provider_state = authority
        .query_pairs()
        .find(|(key, _)| key == "state")
        .unwrap()
        .1
        .into_owned();
    {
        let saved = repo.flow.lock().unwrap();
        let saved = saved.as_ref().unwrap();
        assert_eq!(saved.state_hash, digest(&provider_state));
        assert_eq!(saved.flow_key_hash, digest(flow_key));
        let mut nonces = [flow_id, flow_key, &provider_state, &saved.pkce_verifier];
        assert!(nonces.iter().all(|token| valid_nonce(token)));
        nonces.sort_unstable();
        assert!(nonces.windows(2).all(|pair| pair[0] != pair[1]));
    }
    let callback = format!("{CALLBACK}?state={provider_state}&error=external-denial&error_description=sensitive-fixture");
    let (status, headers, denied) = call(&app, "GET", &callback, None, Value::Null).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(headers["referrer-policy"], "no-referrer");
    assert_eq!(denied, HTML);
    assert!(*repo.denied.lock().unwrap());
    assert_eq!(call(&app, "GET", CALLBACK, None, Value::Null).await.2, HTML);
    assert_eq!(
        call(&app, "GET", &callback, None, Value::Null).await.0,
        StatusCode::UNAUTHORIZED
    );
    let binding = "/api/v2/users/me/oauth/github";
    assert_eq!(
        call(&app, "GET", binding, None, Value::Null).await.0,
        StatusCode::UNAUTHORIZED
    );
    let (_, _, body) = call(&app, "GET", binding, Some(&token), Value::Null).await;
    assert!(serde_json::from_str::<Value>(&body).unwrap()["data"]["link"].is_null());

    *repo.login_ready.lock().unwrap() = Some(digest(flow_key));
    let finish = format!("{start}/{flow_id}/complete");
    let wrong = json!({"flow_key":nonce().unwrap(),"remember_me":true});
    assert_eq!(
        call(&app, "POST", &finish, None, wrong).await.0,
        StatusCode::UNAUTHORIZED
    );
    let input = json!({"flow_key":flow_key,"remember_me":true});
    let (status, headers, body) = call(&app, "POST", &finish, None, input.clone()).await;
    assert_eq!(status, StatusCode::OK);
    let body: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(body["data"]["status"], "completed");
    assert_eq!(body["data"]["login"]["two_factor_required"], true);
    assert!(body["data"]["login"].get("tokens").is_none());
    assert!(!headers.contains_key("set-cookie"));
    assert_eq!(*repo.remember.lock().unwrap(), Some(true));
    assert_eq!(
        call(&app, "POST", &finish, None, input).await.0,
        StatusCode::UNAUTHORIZED
    );
}
