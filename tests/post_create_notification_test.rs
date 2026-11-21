use nekotribe_backend::{
    auth::{
        session_repository::{OracleSessions, SessionExecutor},
        sessions::{SessionRepository, SessionStoreError, StoreFuture},
    },
    db::{oracle::BindMap, row::DbRow, value::DbValue},
    posts::create_notification::PostNoticeInput,
};
use std::sync::Mutex;

#[derive(Default)]
struct Executor {
    calls: Mutex<Vec<(&'static str, BindMap)>>,
    row: Option<DbRow>,
    fail: bool,
    preferences: Option<(bool, bool)>,
}
impl SessionExecutor for Executor {
    fn preflight(&self, _: &'static str) -> StoreFuture<'_, ()> {
        Box::pin(async { Ok(()) })
    }
    fn execute(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, u64> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((sql, binds));
            if self.fail {
                Err(SessionStoreError)
            } else {
                Ok(1)
            }
        })
    }
    fn query(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((sql, binds));
            if self.fail {
                return Err(SessionStoreError);
            }
            if sql.contains("NVL(us.push_notification_enabled") {
                return Ok(self
                    .preferences
                    .map(|(enabled, push)| {
                        DbRow::from([
                            ("TYPE_ENABLED".into(), DbValue::I64(i64::from(enabled))),
                            (
                                "PUSH_NOTIFICATION_ENABLED".into(),
                                DbValue::I64(i64::from(push)),
                            ),
                        ])
                    })
                    .into_iter()
                    .collect());
            }
            if sql.contains("seq_notification_id.NEXTVAL") {
                return Ok(vec![DbRow::from([("ID".into(), DbValue::I64(501))])]);
            }
            Ok(self.row.clone().into_iter().collect())
        })
    }
}

fn repo(column: &str, value: DbValue) -> OracleSessions<Executor> {
    OracleSessions {
        executor: Executor {
            row: Some(DbRow::from([(column.into(), value)])),
            ..Executor::default()
        },
    }
}

#[tokio::test]
async fn actor_name_and_source_reads_use_parameterized_queries_and_null_fallbacks() {
    for value in [
        Some(DbValue::String("viewer".into())),
        Some(DbValue::Null),
        None,
    ] {
        let repository = OracleSessions {
            executor: Executor {
                row: value.clone().map(|v| DbRow::from([("NAME".into(), v)])),
                ..Executor::default()
            },
        };
        let name = repository.post_create_actor_name(42).await.unwrap();
        assert_eq!(
            name,
            if matches!(value, Some(DbValue::String(_))) {
                "viewer"
            } else {
                "有人"
            }
        );
        let calls = repository.executor.calls.lock().unwrap();
        assert_eq!(
            calls[0].0,
            "SELECT COALESCE(display_name,username) AS name FROM n_users WHERE user_id=:user_id"
        );
        assert_eq!(
            calls[0].1,
            BindMap::from([("user_id".into(), DbValue::I64(42))])
        );
    }
    for value in [Some(DbValue::I64(7)), Some(DbValue::Null), None] {
        let repository = OracleSessions {
            executor: Executor {
                row: value
                    .clone()
                    .map(|v| DbRow::from([("AUTHOR_ID".into(), v)])),
                ..Executor::default()
            },
        };
        assert_eq!(
            repository.post_create_source_author(10).await.unwrap(),
            matches!(value, Some(DbValue::I64(7))).then_some(7)
        );
        let calls = repository.executor.calls.lock().unwrap();
        assert_eq!(
            calls[0].0,
            "SELECT author_id FROM n_posts WHERE post_id=:post_id AND is_deleted=0"
        );
        assert_eq!(
            calls[0].1,
            BindMap::from([("post_id".into(), DbValue::I64(10))])
        );
    }
}

#[tokio::test]
async fn database_excerpt_reuses_utf16_and_javascript_whitespace_rules() {
    for (value, expected) in [
        (DbValue::Null, "null".into()),
        (DbValue::String(String::new()), "null".into()),
        (
            DbValue::String("\t source\ntext\u{feff} ".into()),
            "\"source text\"".into(),
        ),
        (DbValue::String(" \n ".into()), "\"\"".into()),
        (
            DbValue::String(format!("{}😀", "x".repeat(159))),
            format!("\"{}\\ud83d...\"", "x".repeat(159)),
        ),
    ] {
        let repository = repo("CONTENT", value);
        assert_eq!(repository.post_create_excerpt(10).await.unwrap(), expected);
        let calls = repository.executor.calls.lock().unwrap();
        assert_eq!(calls[0].0, "SELECT DBMS_LOB.SUBSTR(content,4000,1) AS content FROM n_posts WHERE post_id=:post_id AND is_deleted=0");
        assert_eq!(
            calls[0].1,
            BindMap::from([("post_id".into(), DbValue::I64(10))])
        );
    }
    let repository = OracleSessions {
        executor: Executor::default(),
    };
    assert_eq!(repository.post_create_excerpt(10).await.unwrap(), "null");
}

#[tokio::test]
async fn fractional_mention_recipients_bind_original_number_without_narrowing() {
    let repository = OracleSessions {
        executor: Executor::default(),
    };
    for user in [7.5, -7.5, 0.0, 1e20] {
        assert_eq!(
            repository
                .resolve_post_mention_recipient(user)
                .await
                .unwrap(),
            None
        );
        let calls = repository.executor.calls.lock().unwrap();
        let (sql, binds) = calls.last().unwrap();
        assert_eq!(*sql, "SELECT user_id FROM n_users WHERE user_id=:user_id");
        assert_eq!(
            *binds,
            BindMap::from([("user_id".into(), DbValue::F64(user))])
        );
    }
    assert_eq!(
        repo("USER_ID", DbValue::String("7".into()))
            .resolve_post_mention_recipient(7.0)
            .await
            .unwrap(),
        Some(7)
    );
    assert_eq!(
        repo("USER_ID", DbValue::Null)
            .resolve_post_mention_recipient(7.0)
            .await
            .unwrap(),
        None
    );
}

#[tokio::test]
async fn notification_reads_propagate_sanitized_database_errors() {
    let repository = OracleSessions {
        executor: Executor {
            fail: true,
            ..Executor::default()
        },
    };
    assert_eq!(
        repository
            .post_create_actor_name(42)
            .await
            .unwrap_err()
            .to_string(),
        "session store unavailable"
    );
    assert!(repository.post_create_source_author(10).await.is_err());
    assert!(repository.post_create_excerpt(10).await.is_err());
    assert!(repository
        .resolve_post_mention_recipient(7.5)
        .await
        .is_err());
    assert!(repository.post_create_actor_name(u64::MAX).await.is_err());
    assert!(repository
        .post_create_source_author(u64::MAX)
        .await
        .is_err());
    assert!(repository.post_create_excerpt(u64::MAX).await.is_err());
}

#[tokio::test]
async fn storage_reuses_type_preferences_and_only_push_is_suppressed_globally() {
    for kind in ["comment", "retweet", "mention"] {
        for (recipient, preferences, expected) in [
            (42, Some((true, true)), None),
            (0, Some((true, true)), None),
            (7, None, None),
            (7, Some((false, true)), None),
            (7, Some((true, false)), Some(false)),
            (7, Some((true, true)), Some(true)),
        ] {
            let repository = OracleSessions {
                executor: Executor {
                    preferences,
                    ..Executor::default()
                },
            };
            let input = PostNoticeInput {
                recipient,
                actor: 42,
                resource_id: 100,
                kind,
                title: "title".into(),
                message: "message".into(),
                metadata_json: "{\"event\":\"post_mention\"}".into(),
            };
            let stored = repository
                .store_post_create_notification(&input)
                .await
                .unwrap();
            assert_eq!(stored.as_ref().map(|s| s.push_enabled), expected);
            let calls = repository.executor.calls.lock().unwrap();
            if recipient == 42 || recipient == 0 {
                assert!(calls.is_empty());
            }
            if expected.is_none() {
                assert!(!calls.iter().any(|(sql, _)| sql.starts_with("INSERT")));
                continue;
            }
            assert_eq!(stored.unwrap().id, 501);
            let (_, preferences) = calls
                .iter()
                .find(|(sql, _)| sql.contains("NVL(us.push_notification_enabled"))
                .unwrap();
            assert_eq!(
                preferences["notification_type"],
                DbValue::String(kind.into())
            );
            let (_, binds) = calls
                .iter()
                .find(|(sql, _)| sql.starts_with("INSERT INTO n_notifications"))
                .unwrap();
            assert_eq!(
                binds,
                &BindMap::from([
                    ("notification_id".into(), DbValue::I64(501)),
                    ("user_id".into(), DbValue::I64(7)),
                    ("actor_id".into(), DbValue::I64(42)),
                    ("type".into(), DbValue::String(kind.into())),
                    ("title".into(), DbValue::String(input.title.clone())),
                    ("message".into(), DbValue::String(input.message.clone())),
                    ("resource_type".into(), DbValue::String("post".into())),
                    ("resource_id".into(), DbValue::I64(100)),
                    ("priority".into(), DbValue::String("normal".into())),
                    (
                        "metadata_json".into(),
                        DbValue::String(input.metadata_json.clone())
                    ),
                ])
            );
        }
    }
}
