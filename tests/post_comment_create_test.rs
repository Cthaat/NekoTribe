use nekotribe_backend::{
    auth::{
        session_repository::{OracleSessions, SessionExecutor},
        sessions::{SessionRepository, SessionStoreError, StoreFuture},
    },
    db::{oracle::BindMap, row::DbRow, value::DbValue},
    posts::comment_create::CommentCreation,
};
use std::sync::Mutex;

struct Executor {
    hidden: bool,
    muted: bool,
    parent_missing: bool,
    lose_visibility: bool,
    lose_parent: bool,
    fail_read: bool,
    calls: Mutex<Vec<(&'static str, BindMap)>>,
}
impl SessionExecutor for Executor {
    fn insert_post_comment(
        &self,
        _actor: i64,
        sql: &'static str,
        binds: BindMap,
    ) -> StoreFuture<'_, Option<u64>> {
        Box::pin(async move {
            if self.muted {
                return Ok(None);
            }
            self.execute(sql, binds).await.map(Some)
        })
    }
    fn preflight(&self, _: &'static str) -> StoreFuture<'_, ()> {
        Box::pin(async { Ok(()) })
    }
    fn execute(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, u64> {
        Box::pin(async move {
            self.calls.lock().unwrap().push((sql, binds));
            Ok(u64::from(!self.lose_visibility && !self.lose_parent))
        })
    }
    fn query(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
        Box::pin(async move {
            let mut calls = self.calls.lock().unwrap();
            calls.push((sql, binds));
            if sql.contains("FROM n_posts p") {
                let checks = calls
                    .iter()
                    .filter(|(q, _)| q.contains("FROM n_posts p") && q.starts_with("SELECT"))
                    .count();
                return Ok(if self.hidden || (self.lose_visibility && checks > 1) {
                    vec![]
                } else {
                    vec![DbRow::from([("POST_ID".into(), DbValue::I64(1))])]
                });
            }
            if sql.contains("seq_comment_id.NEXTVAL") {
                return Ok(vec![DbRow::from([("ID".into(), DbValue::I64(100))])]);
            }
            if sql.contains("NVL(c.root_comment_id") {
                return Ok(if self.parent_missing {
                    vec![]
                } else {
                    vec![DbRow::from([("ROOT_COMMENT_ID".into(), DbValue::I64(30))])]
                });
            }
            if sql.contains("FROM v_post_comment_list_item") {
                if self.fail_read {
                    return Err(SessionStoreError);
                }
                let parent = calls
                    .iter()
                    .find(|(q, _)| q.starts_with("INSERT INTO n_comments"))
                    .unwrap()
                    .1["parent_comment_id"]
                    .clone();
                let root = calls
                    .iter()
                    .find(|(q, _)| q.starts_with("INSERT INTO n_comments"))
                    .unwrap()
                    .1["root_comment_id"]
                    .clone();
                return Ok(vec![DbRow::from([
                    ("COMMENT_ID".into(), DbValue::I64(100)),
                    ("POST_ID".into(), DbValue::I64(1)),
                    ("USER_ID".into(), DbValue::I64(42)),
                    ("PARENT_COMMENT_ID".into(), parent),
                    ("ROOT_COMMENT_ID".into(), root),
                    ("CONTENT".into(), DbValue::String("hello".into())),
                    ("IS_LIKED".into(), DbValue::I64(0)),
                ])]);
            }
            Err(SessionStoreError)
        })
    }
}

#[tokio::test]
async fn create_comment_repository_checks_visibility_parent_and_commit_boundaries() {
    for (
        hidden,
        parent_missing,
        lose_visibility,
        lose_parent,
        fail_read,
        parent,
        expected,
        writes,
    ) in [
        (false, false, false, false, false, None, "muted", 0),
        (true, false, false, false, false, None, "post", 0),
        (false, true, false, false, false, Some(40), "parent", 0),
        (false, false, true, false, false, None, "post", 1),
        (false, false, false, true, false, Some(40), "parent", 1),
        (false, false, false, false, true, None, "failure", 1),
        (false, false, false, false, false, None, "root", 1),
        (false, false, false, false, false, Some(40), "reply", 1),
    ] {
        let repo = OracleSessions {
            executor: Executor {
                hidden,
                muted: expected == "muted",
                parent_missing,
                lose_visibility,
                lose_parent,
                fail_read,
                calls: Mutex::new(vec![]),
            },
        };
        let result = repo.create_post_comment(42, 1, "hello", parent).await;
        match expected {
            "muted" => assert!(matches!(result.unwrap(), CommentCreation::PublishForbidden)),
            "failure" => assert!(result.is_err()),
            "post" => assert_eq!(result.unwrap(), CommentCreation::PostUnavailable),
            "parent" => assert_eq!(result.unwrap(), CommentCreation::ParentUnavailable),
            _ => match result.unwrap() {
                CommentCreation::Created(value) => {
                    assert_eq!(value["comment_id"], 100);
                    assert_eq!(value["author_id"], 42);
                    assert_eq!(
                        value["root_comment_id"],
                        if expected == "root" { 100 } else { 30 }
                    );
                }
                other => panic!("unexpected result {other:?}"),
            },
        }
        let calls = repo.executor.calls.lock().unwrap();
        let writes_seen: Vec<_> = calls
            .iter()
            .filter(|(sql, _)| sql.starts_with("INSERT INTO n_comments"))
            .collect();
        assert_eq!(writes_seen.len(), writes);
        for (sql, binds) in calls.iter().filter(|(sql, _)| {
            sql.starts_with("INSERT INTO n_comments") || sql.contains("NVL(c.root_comment_id")
        }) {
            for required in [
                "fn_can_view_post(:viewer_id,c.post_id)=1",
                "c.comment_id=:parent_comment_id",
                "c.post_id=:post_id",
                "c.is_deleted=0",
                "p.is_deleted=0",
                "post_author.is_active=1",
                "comment_author.is_active=1",
                "b.user_id=:viewer_id AND b.target_user_id=c.user_id",
                "b.target_user_id=:viewer_id AND b.user_id=c.user_id",
            ] {
                assert!(sql.contains(required), "{sql}");
            }
            assert_eq!(binds["viewer_id"], DbValue::I64(42));
            assert_eq!(binds["post_id"], DbValue::I64(1));
        }
        for (sql, binds) in calls
            .iter()
            .filter(|(sql, _)| sql.contains("FROM v_post_comment_list_item"))
        {
            assert!(
                sql.contains("c.user_id=:viewer_id")
                    && sql.contains("fn_can_view_post(:viewer_id,c.post_id)=1")
            );
            assert_eq!(binds["viewer_id"], DbValue::I64(42));
        }
    }
}
