use nekotribe_backend::{
    auth::{
        session_repository::{
            NotificationInput, OracleSessions, SessionExecutor, StoredNotification,
        },
        sessions::{SessionStoreError, StoreFuture},
    },
    db::{oracle::BindMap, row::DbRow, value::DbValue},
};
use std::sync::Mutex;

struct Store {
    active: bool,
    enabled: bool,
    push: bool,
    fail_write: bool,
    calls: Mutex<Vec<(&'static str, BindMap)>>,
}
impl SessionExecutor for Store {
    fn preflight(&self, _: &'static str) -> StoreFuture<'_, ()> {
        Box::pin(async { Ok(()) })
    }
    fn query(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((sql, binds));
            if sql.contains("notification_preferences") {
                Ok(if self.active {
                    vec![DbRow::from([
                        ("TYPE_ENABLED".into(), DbValue::I64(i64::from(self.enabled))),
                        (
                            "PUSH_NOTIFICATION_ENABLED".into(),
                            DbValue::I64(i64::from(self.push)),
                        ),
                    ])]
                } else {
                    vec![]
                })
            } else {
                Ok(vec![DbRow::from([("ID".into(), DbValue::I64(44))])])
            }
        })
    }
    fn execute(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, u64> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((sql, binds));
            if self.fail_write {
                Err(SessionStoreError)
            } else {
                Ok(1)
            }
        })
    }
}
fn input(actor: u64) -> NotificationInput<'static> {
    NotificationInput {
        user_id: 42,
        actor_id: Some(actor),
        kind: "like",
        title: "test",
        message: "test",
        resource_type: Some("post"),
        resource_id: Some(9),
        priority: "normal",
        metadata_json: Some("{}"),
    }
}

#[tokio::test]
async fn stores_notification_only_when_allowed_and_preserves_push_preference() {
    for (active, enabled, push, actor, expected) in [
        (true, true, true, 42, None),
        (false, true, true, 7, None),
        (true, false, true, 7, None),
        (true, true, false, 7, Some(false)),
        (true, true, true, 7, Some(true)),
    ] {
        let repo = OracleSessions {
            executor: Store {
                active,
                enabled,
                push,
                fail_write: false,
                calls: Mutex::new(vec![]),
            },
        };
        let result = repo.store_notification(input(actor)).await.unwrap();
        assert_eq!(
            result,
            expected.map(|push_enabled| StoredNotification {
                id: 44,
                push_enabled
            })
        );
        let calls = repo.executor.calls.lock().unwrap();
        let inserted = calls
            .iter()
            .find(|(sql, _)| sql.starts_with("INSERT INTO n_notifications"));
        assert_eq!(inserted.is_some(), expected.is_some());
        if let Some((_, binds)) = inserted {
            assert_eq!(binds["user_id"], DbValue::I64(42));
            assert_eq!(binds["actor_id"], DbValue::I64(7));
            assert_eq!(binds["resource_id"], DbValue::I64(9));
            assert_eq!(binds["type"], DbValue::String("like".into()));
        }
    }
}
#[tokio::test]
async fn failure_is_not_reported_as_stored() {
    let repo = OracleSessions {
        executor: Store {
            active: true,
            enabled: true,
            push: true,
            fail_write: true,
            calls: Mutex::new(vec![]),
        },
    };
    assert!(repo.store_notification(input(7)).await.is_err());
}

#[tokio::test]
async fn invalid_recipient_and_out_of_range_ids_never_reach_database() {
    let repo = OracleSessions {
        executor: Store {
            active: true,
            enabled: true,
            push: true,
            fail_write: false,
            calls: Mutex::new(vec![]),
        },
    };
    let mut zero = input(7);
    zero.user_id = 0;
    assert!(repo.store_notification(zero).await.unwrap().is_none());
    let mut overflow = input(7);
    overflow.actor_id = Some(u64::MAX);
    assert!(repo.store_notification(overflow).await.is_err());
    assert!(repo.executor.calls.lock().unwrap().is_empty());
}
