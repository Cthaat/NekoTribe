use nekotribe_backend::{
    auth::{
        session_repository::{OracleSessions, SessionExecutor},
        sessions::{SessionRepository, SessionStoreError, StoreFuture},
    },
    db::{oracle::BindMap, row::DbRow, value::DbValue},
    posts::comment_create::CommentNoticeInput,
};
use std::sync::Mutex;

struct Executor {
    calls: Mutex<Vec<(&'static str, BindMap)>>,
    parent_author: i64,
    type_enabled: bool,
    push_enabled: bool,
    fail: bool,
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
            self.calls.lock().unwrap().push((sql, binds.clone()));
            if self.fail {
                return Err(SessionStoreError);
            }
            let row = if sql.contains("COALESCE(display_name") {
                DbRow::from([("NAME".into(), DbValue::String("viewer".into()))])
            } else if sql.starts_with("SELECT author_id FROM n_posts") {
                DbRow::from([("AUTHOR_ID".into(), DbValue::I64(7))])
            } else if sql.starts_with("SELECT user_id FROM n_comments") {
                DbRow::from([("USER_ID".into(), DbValue::I64(self.parent_author))])
            } else if sql.contains("FROM n_comments") {
                let text = if binds["comment_id"] == DbValue::I64(40) {
                    " parent "
                } else {
                    " first\ncomment "
                };
                DbRow::from([
                    ("USER_ID".into(), DbValue::I64(42)),
                    ("POST_ID".into(), DbValue::I64(1)),
                    ("CONTENT".into(), DbValue::String(text.into())),
                ])
            } else if sql.contains("FROM n_posts") {
                DbRow::from([(
                    "CONTENT".into(),
                    DbValue::String(" original\t post ".into()),
                )])
            } else if sql.contains("NVL(us.push_notification_enabled") {
                DbRow::from([
                    (
                        "PUSH_NOTIFICATION_ENABLED".into(),
                        DbValue::I64(i64::from(self.push_enabled)),
                    ),
                    (
                        "TYPE_ENABLED".into(),
                        DbValue::I64(i64::from(self.type_enabled)),
                    ),
                ])
            } else if sql.contains("seq_notification_id.NEXTVAL") {
                DbRow::from([("ID".into(), DbValue::I64(501))])
            } else {
                return Err(SessionStoreError);
            };
            Ok(vec![row])
        })
    }
}
#[tokio::test]
async fn notice_context_preserves_recipients_and_compact_excerpts() {
    let repo = OracleSessions {
        executor: Executor {
            calls: Mutex::new(vec![]),
            parent_author: 8,
            type_enabled: true,
            push_enabled: true,
            fail: false,
        },
    };
    let context = repo.comment_notice_context(42, 1, 100).await.unwrap();
    assert_eq!(context.actor_name, "viewer");
    assert_eq!(context.post_author, Some(7));
    assert_eq!(context.comment_excerpt, "\"first comment\"");
    assert_eq!(context.post_excerpt, "\"original post\"");
    let parent = repo
        .comment_parent_notice(40, context.post_author)
        .await
        .unwrap();
    assert_eq!(parent.author, Some(8));
    assert_eq!(parent.excerpt, "\"parent\"");
    let calls = repo.executor.calls.lock().unwrap();
    assert_eq!(calls.len(), 6);
    for (sql, binds) in calls.iter() {
        if sql.contains("FROM n_comments") {
            assert!(binds.contains_key("comment_id"));
        }
    }
}

#[tokio::test]
async fn notice_storage_honors_self_type_and_push_preferences() {
    for (recipient, type_enabled, push_enabled, expected) in [
        (42, true, true, None),
        (7, false, true, None),
        (7, true, false, Some(false)),
        (7, true, true, Some(true)),
    ] {
        let repo = OracleSessions {
            executor: Executor {
                calls: Mutex::new(vec![]),
                parent_author: 8,
                type_enabled,
                push_enabled,
                fail: false,
            },
        };
        let input = CommentNoticeInput {
            recipient,
            actor: 42,
            comment_id: 100,
            title: "viewer 评论了你的推文".into(),
            message: "你的推文收到了一条新评论。".into(),
            metadata_json: r#"{"event":"comment_created"}"#.into(),
        };
        let stored = repo.store_comment_notification(&input).await.unwrap();
        assert_eq!(stored.as_ref().map(|s| s.push_enabled), expected);
        let calls = repo.executor.calls.lock().unwrap();
        if recipient == 42 {
            assert!(calls.is_empty());
        }
        if stored.is_some() {
            let (_, binds) = calls
                .iter()
                .find(|(sql, _)| sql.starts_with("INSERT INTO n_notifications"))
                .unwrap();
            assert_eq!(binds["user_id"], DbValue::I64(7));
            assert_eq!(binds["type"], DbValue::String("comment".into()));
            assert_eq!(binds["resource_id"], DbValue::I64(100));
            assert_eq!(
                binds["metadata_json"],
                DbValue::String(input.metadata_json.clone())
            );
        }
    }
}
