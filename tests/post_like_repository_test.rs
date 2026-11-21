use nekotribe_backend::{
    auth::{
        session_repository::{OracleSessions, SessionExecutor},
        sessions::{SessionRepository, SessionStoreError, StoreFuture},
    },
    db::{oracle::BindMap, row::DbRow, value::DbValue},
    posts::like::excerpt_json,
};
use std::sync::Mutex;

struct Executor {
    visibility: Vec<bool>,
    affected: u64,
    author: Option<i64>,
    enabled: bool,
    push: bool,
    fail_write: bool,
    calls: Mutex<Vec<(&'static str, BindMap)>>,
}
impl SessionExecutor for Executor {
    fn preflight(&self, _: &'static str) -> StoreFuture<'_, ()> {
        Box::pin(async { Ok(()) })
    }
    fn query(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
        Box::pin(async move {
            let mut calls = self.calls.lock().unwrap();
            let visibility_index = calls
                .iter()
                .filter(|(q, _)| q.starts_with("SELECT p.post_id"))
                .count();
            calls.push((sql, binds));
            let row = if sql.starts_with("SELECT p.post_id") {
                self.visibility
                    .get(visibility_index)
                    .copied()
                    .unwrap_or(false)
                    .then(|| DbRow::from([("POST_ID".into(), DbValue::I64(1))]))
            } else if sql.contains("n_post_stats") {
                Some(DbRow::from([("LIKES_COUNT".into(), DbValue::I64(3))]))
            } else if sql.starts_with("SELECT c.user_id,c.post_id,DBMS_LOB.SUBSTR") {
                assert!(sql.contains("comment_author.is_active=1"));
                assert!(sql.contains("FROM n_user_blocks"));
                assert_eq!(calls.last().unwrap().1["viewer_id"], DbValue::I64(42));
                self.author.map(|v| {
                    DbRow::from([
                        ("USER_ID".into(), DbValue::I64(v)),
                        ("POST_ID".into(), DbValue::I64(1)),
                        (
                            "CONTENT".into(),
                            DbValue::String("  comment\n text ".into()),
                        ),
                    ])
                })
            } else if sql.starts_with("SELECT author_id") {
                self.author
                    .map(|v| DbRow::from([("AUTHOR_ID".into(), DbValue::I64(v))]))
            } else if sql.starts_with("SELECT COALESCE") {
                Some(DbRow::from([(
                    "NAME".into(),
                    DbValue::String("小猫".into()),
                )]))
            } else if sql.starts_with("SELECT DBMS_LOB.SUBSTR(content") {
                Some(DbRow::from([(
                    "CONTENT".into(),
                    DbValue::String("  hello\n world ".into()),
                )]))
            } else if sql.contains("notification_preferences") {
                Some(DbRow::from([
                    ("TYPE_ENABLED".into(), DbValue::I64(i64::from(self.enabled))),
                    (
                        "PUSH_NOTIFICATION_ENABLED".into(),
                        DbValue::I64(i64::from(self.push)),
                    ),
                ]))
            } else if sql.contains("seq_notification_id") {
                Some(DbRow::from([("ID".into(), DbValue::I64(44))]))
            } else {
                return Err(SessionStoreError);
            };
            Ok(row.into_iter().collect())
        })
    }
    fn execute(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, u64> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((sql, binds));
            if self.fail_write {
                return Err(SessionStoreError);
            };
            Ok(if sql.contains("n_post_likes") {
                self.affected
            } else {
                1
            })
        })
    }
}

#[tokio::test]
async fn comment_like_notification_maps_content_and_preferences() {
    for (author, enabled, push, expected) in [
        (Some(9), true, true, Some(true)),
        (Some(9), true, false, Some(false)),
        (Some(9), false, true, None),
        (Some(42), true, true, None),
        (None, true, true, None),
    ] {
        let r = repo(vec![], 0, author, enabled, push);
        let result = r.prepare_comment_like_notification(42, 20).await.unwrap();
        assert_eq!(result.as_ref().map(|v| v.push_enabled), expected);
        if let Some(v) = result {
            assert_eq!((v.recipient, v.id), (9, 44));
            let calls = r.executor.calls.lock().unwrap();
            let (_, binds) = calls
                .iter()
                .find(|(sql, _)| sql.starts_with("INSERT INTO n_notifications"))
                .unwrap();
            assert_eq!(binds["user_id"], DbValue::I64(9));
            assert_eq!(binds["resource_type"], DbValue::String("comment".into()));
            assert_eq!(binds["resource_id"], DbValue::I64(20));
            let DbValue::String(metadata) = &binds["metadata_json"] else {
                panic!("missing metadata")
            };
            let v: serde_json::Value = serde_json::from_str(metadata).unwrap();
            assert_eq!(v["post_id"], 1);
            assert_eq!(v["target_post_id"], 1);
            assert_eq!(v["comment_id"], 20);
            assert_eq!(v["comment_excerpt"], "comment text");
            assert_eq!(v["post_excerpt"], "hello world");
            assert_eq!(v["event"], "comment_like");
        }
    }
}
fn repo(
    visibility: Vec<bool>,
    affected: u64,
    author: Option<i64>,
    enabled: bool,
    push: bool,
) -> OracleSessions<Executor> {
    OracleSessions {
        executor: Executor {
            visibility,
            affected,
            author,
            enabled,
            push,
            fail_write: false,
            calls: Mutex::new(vec![]),
        },
    }
}

#[tokio::test]
async fn insert_like_is_scoped_idempotent_and_checks_visibility_again() {
    for (visibility, affected, expected) in [
        (vec![true], 1, Some(true)),
        (vec![true, true], 0, Some(false)),
        (vec![false], 0, None),
        (vec![true, false], 0, None),
    ] {
        let r = repo(visibility, affected, Some(9), true, true);
        let result = r.add_post_like(42, 1).await.unwrap();
        assert_eq!(result.as_ref().map(|v| v.inserted), expected);
        if let Some(v) = result {
            assert_eq!(v.count, 3.0)
        }
        for (sql, binds) in r
            .executor
            .calls
            .lock()
            .unwrap()
            .iter()
            .filter(|(sql, _)| sql.starts_with("INSERT INTO n_post_likes"))
        {
            assert!(
                sql.contains("fn_can_view_post(:user_id,:post_id)=1") && sql.contains("NOT EXISTS")
            );
            assert_eq!(binds["post_id"], DbValue::I64(1));
            assert_eq!(binds["user_id"], DbValue::I64(42));
        }
    }
}

#[tokio::test]
async fn notification_preparation_respects_recipient_and_preferences() {
    for (author, enabled, push, expected) in [
        (Some(9), true, true, Some(true)),
        (Some(9), true, false, Some(false)),
        (Some(9), false, true, None),
        (Some(42), true, true, None),
        (None, true, true, None),
    ] {
        let r = repo(vec![], 0, author, enabled, push);
        let result = r.prepare_post_like_notification(42, 1).await.unwrap();
        assert_eq!(result.as_ref().map(|v| v.push_enabled), expected);
        if let Some(v) = result {
            assert_eq!((v.recipient, v.id), (9, 44));
            let calls = r.executor.calls.lock().unwrap();
            let (_, binds) = calls
                .iter()
                .find(|(sql, _)| sql.starts_with("INSERT INTO n_notifications"))
                .unwrap();
            assert_eq!(binds["user_id"], DbValue::I64(9));
            assert_eq!(binds["actor_id"], DbValue::I64(42));
            assert_eq!(binds["title"], DbValue::String("小猫 赞了你的推文".into()));
            let DbValue::String(metadata) = &binds["metadata_json"] else {
                panic!("missing metadata")
            };
            let v: serde_json::Value = serde_json::from_str(metadata).unwrap();
            assert_eq!(v["post_excerpt"], "hello world");
            assert_eq!(v["event"], "post_like");
        }
    }
}

#[test]
fn excerpt_matches_js_whitespace_and_utf16_boundary() {
    assert_eq!(excerpt_json(None), "null");
    assert_eq!(excerpt_json(Some("")), "null");
    assert_eq!(excerpt_json(Some(" \u{00a0} \n")), "\"\"");
    assert_eq!(excerpt_json(Some(" a\u{00a0} b ")), "\"a b\"");
    assert_eq!(
        excerpt_json(Some(&("a".repeat(159) + "😀suffix"))),
        format!("\"{}\\ud83d...\"", "a".repeat(159))
    );
    assert_eq!(
        excerpt_json(Some(&("😀".repeat(80) + "x"))),
        format!("\"{}...\"", "😀".repeat(80))
    );
}

#[test]
fn raw_json_retains_unpaired_utf16_escape() {
    let raw = r#"{"post_excerpt":"prefix\ud83d..."}"#;
    let parsed = serde_json::value::RawValue::from_string(raw.to_owned()).unwrap();
    assert_eq!(parsed.get(), raw);
}
