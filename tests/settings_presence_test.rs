use axum::{body::Body, http::Request};
use nekotribe_backend::{
    auth::{
        otp::SmtpConfig,
        session_repository::{OracleSessions, SessionExecutor},
        sessions::{
            build_native_router_with_realtime_and_publisher, CorsPolicy, RefreshPolicy,
            SessionRepository, SessionStoreError, StoreFuture,
        },
        storage_urls::StorageUrlPolicy,
        TokenCodec,
    },
    db::{oracle::BindMap, row::DbRow, value::DbValue},
    notification_events::{
        encode_presence_event, EventError, NotificationPublisher, PublishFuture,
    },
    users::{settings_patch::SettingsPatch, settings_read::SettingsRead},
};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

#[derive(Default)]
struct State {
    commits: usize,
    reads: usize,
    frames: Vec<String>,
}
struct Executor {
    row: Option<DbRow>,
    mode: String,
    state: Arc<Mutex<State>>,
    require_commit: bool,
}
impl SessionExecutor for Executor {
    fn execute(&self, _: &'static str, _: BindMap) -> StoreFuture<'_, u64> {
        Box::pin(async { Ok(1) })
    }
    fn preflight(&self, _: &'static str) -> StoreFuture<'_, ()> {
        Box::pin(async { Ok(()) })
    }
    fn patch_user_settings<'a>(
        &'a self,
        _: u64,
        _: &'a SettingsPatch,
    ) -> StoreFuture<'a, SettingsRead> {
        Box::pin(async move {
            if self.mode == "store-error" {
                return Err(SessionStoreError);
            }
            self.state.lock().unwrap().commits += 1;
            let fixture: Value = serde_json::from_str(include_str!(
                "../contracts/scenarios/user-settings-client-response-vectors.json"
            ))
            .unwrap();
            Ok(SettingsRead::Ready(fixture["base"]["data"].clone()))
        })
    }
    fn query(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
        Box::pin(async move {
            assert!(sql.contains("NUMTODSINTERVAL(90") && sql.contains("revoked_at IS NULL"));
            assert_eq!(binds.get("user_id").and_then(DbValue::as_i64), Some(42));
            let mut state = self.state.lock().unwrap();
            if self.require_commit {
                assert_eq!(state.commits, 1);
            }
            state.reads += 1;
            if self.mode == "lookup-error" {
                return Err(SessionStoreError);
            }
            Ok(self.row.iter().cloned().collect())
        })
    }
}
struct Publisher {
    state: Arc<Mutex<State>>,
    fail: bool,
}
impl NotificationPublisher for Publisher {
    fn publish<'a>(
        &'a self,
        _: u64,
        _: &'a str,
        _: &'a serde_json::Map<String, Value>,
    ) -> PublishFuture<'a> {
        Box::pin(async { Ok(()) })
    }
    fn publish_presence<'a>(
        &'a self,
        data: &'a serde_json::Map<String, Value>,
    ) -> PublishFuture<'a> {
        Box::pin(async move {
            self.state
                .lock()
                .unwrap()
                .frames
                .push(encode_presence_event(data, "test-instance", 1700000000000)?);
            if self.fail {
                Err(EventError)
            } else {
                Ok(())
            }
        })
    }
}
fn vectors() -> Value {
    serde_json::from_str(include_str!(
        "../contracts/scenarios/user-settings-presence.json"
    ))
    .unwrap()
}
fn row(flag: f64, status: &str, last: Option<&str>) -> DbRow {
    DbRow::from([
        ("SHOW_ONLINE_STATUS".into(), DbValue::F64(flag)),
        ("ONLINE_STATUS".into(), DbValue::String(status.into())),
        (
            "LAST_SEEN_AT".into(),
            last.map(|s| DbValue::String(s.into()))
                .unwrap_or(DbValue::Null),
        ),
    ])
}

#[tokio::test]
async fn shared_settings_presence_http() {
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
    for case in vectors()["cases"].as_array().unwrap() {
        let mode = case["mode"].as_str().unwrap();
        let state = Arc::new(Mutex::new(State::default()));
        let hidden = mode == "hidden";
        let repository = OracleSessions {
            executor: Executor {
                row: Some(row(
                    if hidden { 0.0 } else { 1.0 },
                    if hidden { "hidden" } else { "online" },
                    Some("2026-01-01T00:00:00.000Z"),
                )),
                mode: mode.into(),
                state: state.clone(),
                require_commit: true,
            },
        };
        let codec = TokenCodec::new(
            tokens["keys"]["access"].as_str().unwrap().as_bytes(),
            tokens["keys"]["refresh"].as_str().unwrap().as_bytes(),
        )
        .unwrap();
        let publisher: Option<Arc<dyn NotificationPublisher>> = if mode == "publisher-absent" {
            None
        } else {
            Some(Arc::new(Publisher {
                state: state.clone(),
                fail: mode == "publish-error",
            }))
        };
        let app = build_native_router_with_realtime_and_publisher(
            codec,
            Arc::new(repository),
            CorsPolicy::default(),
            Arc::new(|| 1700000000),
            RefreshPolicy::default(),
            StorageUrlPolicy::default(),
            Arc::new(SmtpConfig::default()),
            None,
            publisher,
        );
        let request = Request::patch("/api/v2/users/me/settings")
            .header("Content-Type", "application/json")
            .header("Authorization", format!("Bearer {token}"))
            .body(Body::from(case["body"].to_string()))
            .unwrap();
        let response = app.oneshot(request).await.unwrap();
        assert_eq!(
            response.status().as_u16() as u64,
            case["status"].as_u64().unwrap(),
            "{case}"
        );
        assert_eq!(response.headers()["cache-control"], "private, no-store");
        let bytes = axum::body::to_bytes(response.into_body(), 8192)
            .await
            .unwrap();
        assert!(!String::from_utf8_lossy(&bytes).contains("secret"));
        let state = state.lock().unwrap();
        assert_eq!(
            state.reads as u64,
            case["reads"].as_u64().unwrap(),
            "{case}"
        );
        assert_eq!(
            state.frames.len() as u64,
            case["publishes"].as_u64().unwrap(),
            "{case}"
        );
        if case.get("expectedStatus").is_some() {
            let frame: Value = serde_json::from_str(&state.frames[0]).unwrap();
            assert_eq!(
                frame["data"],
                json!({"user_id":42,"online_status":case["expectedStatus"],"last_seen_at":case["expectedLastSeen"],"server_id":"test-instance"})
            );
        }
    }
}
#[tokio::test]
async fn shared_presence_query() {
    for case in vectors()["queryCases"].as_array().unwrap() {
        for strings in [false, true] {
            let mut value = if case["missing"] == true {
                None
            } else {
                Some(row(
                    case["flag"].as_f64().unwrap(),
                    case["status"].as_str().unwrap(),
                    case["lastSeen"].as_str(),
                ))
            };
            if strings {
                if let Some(row) = value.as_mut() {
                    if let Some(DbValue::F64(flag)) = row.get("SHOW_ONLINE_STATUS") {
                        row.insert(
                            "SHOW_ONLINE_STATUS".into(),
                            DbValue::String(flag.to_string()),
                        );
                    }
                }
            }
            let repo = OracleSessions {
                executor: Executor {
                    row: value,
                    mode: "ok".into(),
                    state: Arc::new(Mutex::new(State::default())),
                    require_commit: false,
                },
            };
            let result = repo.user_presence(42).await;
            if case["error"] == true {
                assert!(result.is_err(), "{case}");
            } else {
                assert_eq!(
                    result.unwrap(),
                    json!({"user_id":42,"online_status":case["expectedStatus"],"last_seen_at":case["expectedLastSeen"]}),
                    "{case} strings={strings}"
                );
            }
        }
    }
}
#[test]
fn shared_presence_event() {
    for case in vectors()["eventCases"].as_array().unwrap() {
        let result = encode_presence_event(
            case["data"].as_object().unwrap(),
            case["serverId"].as_str().unwrap(),
            case["timestamp"].as_i64().unwrap(),
        );
        assert_eq!(result.is_ok(), case["valid"].as_bool().unwrap(), "{case}");
        if let Ok(text) = result {
            let frame: Value = serde_json::from_str(&text).unwrap();
            assert_eq!(
                frame,
                json!({"type":"presence_update","data":{"user_id":case["data"]["user_id"],"online_status":case["data"]["online_status"],"last_seen_at":if case["data"]["online_status"]=="hidden"{Value::Null}else{case["data"]["last_seen_at"].clone()},"server_id":case["serverId"]},"timestamp":case["timestamp"]})
            );
        }
    }
}
