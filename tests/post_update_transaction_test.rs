use nekotribe_backend::{
    db::{
        oracle::{BindMap, DbError},
        row::DbRow,
        value::DbValue,
    },
    posts::{
        create_transaction::PostCreateTransaction,
        update_request::PostUpdateInput,
        update_transaction::{run, PostUpdate},
    },
};
use std::cell::{Cell, RefCell};

#[derive(Clone, Debug, PartialEq)]
struct Saved {
    content: String,
    media: Vec<f64>,
    tags: Vec<String>,
    mentions: Vec<f64>,
    updated: bool,
}
fn initial() -> Saved {
    Saved {
        content: "old".into(),
        media: vec![8.0],
        tags: vec!["old".into()],
        mentions: vec![7.0],
        updated: false,
    }
}
struct Transaction {
    saved: RefCell<Saved>,
    pending: RefCell<Saved>,
    mode: &'static str,
    calls: RefCell<Vec<(String, BindMap)>>,
    commits: Cell<u32>,
    rollbacks: Cell<u32>,
}
impl Transaction {
    fn new(mode: &'static str) -> Self {
        Self {
            saved: RefCell::new(initial()),
            pending: RefCell::new(initial()),
            mode,
            calls: RefCell::default(),
            commits: Cell::new(0),
            rollbacks: Cell::new(0),
        }
    }
}
impl PostCreateTransaction for Transaction {
    fn query(&self, sql: &str, binds: BindMap) -> Result<Vec<DbRow>, DbError> {
        self.calls.borrow_mut().push((sql.into(), binds));
        if self.mode == "read" {
            return Err(DbError::SchemaNotReady);
        }
        let (lock, allowed) = nekotribe_backend::moderation::publish_policy::queries();
        if sql == lock {
            return Ok(vec![DbRow::from([("USER_ID".into(), DbValue::I64(42))])]);
        }
        if sql == allowed {
            return Ok(vec![DbRow::from([(
                "ALLOWED".into(),
                DbValue::I64(i64::from(!(self.mode == "muted"))),
            )])]);
        }
        if sql.starts_with("SELECT media_id,storage_key FROM n_media_assets") {
            let key = if self.mode.starts_with("private-") {
                "private/post/42/a.txt"
            } else {
                "posts/a.txt"
            };
            return Ok(vec![DbRow::from([
                ("MEDIA_ID".into(), DbValue::I64(1)),
                ("STORAGE_KEY".into(), DbValue::String(key.into())),
            ])]);
        }
        if sql.starts_with("SELECT 1 FROM n_direct_message_media WHERE") {
            return Ok(if self.mode == "private-direct-linked" { vec![DbRow::new()] } else { vec![] });
        }
        if sql.starts_with("SELECT 1 AS permitted")
            || sql.starts_with("SELECT 1 AS found")
        {
            return Ok(if self.mode == "private-linked-elsewhere" {
                vec![]
            } else {
                vec![DbRow::new()]
            });
        }
        if sql.contains("FOR UPDATE") {
            if self.mode == "missing" {
                return Ok(vec![]);
            };
            return Ok(vec![DbRow::from([
                (
                    "AUTHOR_ID".into(),
                    DbValue::I64(if self.mode == "other" { 7 } else { 42 }),
                ),
                (
                    "IS_DELETED".into(),
                    DbValue::I64(i64::from(self.mode == "deleted")),
                ),
                (
                    "POST_TYPE".into(),
                    DbValue::String(
                        if self.mode == "repost" {
                            "repost"
                        } else {
                            "post"
                        }
                        .into(),
                    ),
                ),
                (
                    "CONTENT".into(),
                    DbValue::String(self.saved.borrow().content.clone()),
                ),
                ("VISIBILITY".into(), DbValue::String("private".into())),
            ])]);
        }
        assert!(sql.contains("COUNT(*)"));
        Ok(vec![DbRow::from([(
            "TOTAL".into(),
            DbValue::I64(self.pending.borrow().media.len() as i64),
        )])])
    }
    fn execute(&self, sql: &str, binds: BindMap) -> Result<u64, DbError> {
        self.calls.borrow_mut().push((sql.into(), binds.clone()));
        if !self.mode.is_empty() && sql.starts_with(self.mode) {
            return Err(DbError::SchemaNotReady);
        }
        let mut data = self.pending.borrow_mut();
        if sql.starts_with("UPDATE n_posts") {
            assert!(sql.contains("author_id=:user_id") && sql.contains("is_deleted=0"));
            assert_eq!(binds["user_id"], DbValue::I64(42));
            assert_eq!(binds["post_id"], DbValue::I64(20));
            if self.mode == "race" {
                return Ok(0);
            };
            if let Some(content) = binds.get("content") {
                data.content = content.as_str().unwrap_or_default().into()
            };
            data.updated = true;
        } else if sql.starts_with("DELETE FROM n_post_media") {
            data.media.clear()
        } else if sql.starts_with("INSERT INTO n_post_media") {
            let DbValue::F64(id) = binds["media_id"] else {
                panic!("media ID lost precision")
            };
            if id == 999.0 {
                return Ok(0);
            };
            data.media.push(id)
        } else if sql.starts_with("DELETE FROM n_post_tags") {
            data.tags.clear()
        } else if sql.starts_with("MERGE INTO n_tags") {
        } else if sql.starts_with("INSERT INTO n_post_tags") {
            data.tags.push(binds["name"].as_str().unwrap().into())
        } else if sql.starts_with("DELETE FROM n_post_mentions") {
            data.mentions.clear()
        } else if sql.starts_with("INSERT INTO n_post_mentions") {
            let DbValue::F64(id) = binds["user_id"] else {
                panic!("mention ID lost precision")
            };
            data.mentions.push(id)
        } else {
            panic!("unexpected write {sql}")
        };
        Ok(1)
    }
    fn commit(&self) -> Result<(), DbError> {
        self.commits.set(self.commits.get() + 1);
        if self.mode == "commit" {
            return Err(DbError::SchemaNotReady);
        };
        *self.saved.borrow_mut() = self.pending.borrow().clone();
        if self.mode == "commit-applied" {
            return Err(DbError::SchemaNotReady);
        };
        Ok(())
    }
    fn rollback(&self) -> Result<(), DbError> {
        self.rollbacks.set(self.rollbacks.get() + 1);
        *self.pending.borrow_mut() = self.saved.borrow().clone();
        if self.mode == "rollback" {
            return Err(DbError::SchemaNotReady);
        };
        Ok(())
    }
}

#[test]
fn private_post_update_respects_effective_visibility_and_retained_media() {
    for (mode, visibility, media_ids, expected) in [
        ("private-retained", Some("public"), None, PostUpdate::MediaUnavailable),
        ("private-retained", Some("public"), Some(vec![]), PostUpdate::Updated),
        ("private-retained", Some("public"), Some(vec![8.0]), PostUpdate::MediaUnavailable),
        ("private-retained", None, Some(vec![8.0]), PostUpdate::Updated),
        ("private-linked-elsewhere", None, Some(vec![8.0]), PostUpdate::MediaUnavailable),
        ("private-direct-linked", None, Some(vec![8.0]), PostUpdate::MediaUnavailable),
    ] {
        let tx = Transaction::new(mode);
        let data = PostUpdateInput {
            visibility: visibility.map(str::to_owned),
            media_ids,
            ..Default::default()
        };
        assert_eq!(run(&tx, 42, 20, &data).unwrap(), expected);
        if expected == PostUpdate::MediaUnavailable {
            assert_eq!(*tx.saved.borrow(), initial());
        }
    }
}
fn input() -> PostUpdateInput {
    PostUpdateInput {
        content: Some("new".into()),
        media_ids: Some(vec![3.0, 3.0, 4.0]),
        tag_names: Some(vec!["#new".into()]),
        mention_user_ids: Some(vec![9.0]),
        ..Default::default()
    }
}
#[test]
fn post_update_atomic_writes_and_rollbacks() {
    for mode in [
        "success",
        "muted",
        "missing",
        "deleted",
        "other",
        "race",
        "read",
        "UPDATE n_posts",
        "DELETE FROM n_post_media",
        "INSERT INTO n_post_media",
        "DELETE FROM n_post_tags",
        "MERGE INTO n_tags",
        "INSERT INTO n_post_tags",
        "DELETE FROM n_post_mentions",
        "INSERT INTO n_post_mentions",
        "commit",
        "commit-applied",
        "bad-media",
        "empty",
        "noop",
        "clear",
    ] {
        let tx = Transaction::new(mode);
        let mut data = input();
        if mode == "bad-media" {
            data.media_ids = Some(vec![3.0, 999.0])
        };
        if mode == "empty" {
            data.content = Some("".into());
            data.media_ids = Some(vec![])
        };
        if mode == "noop" {
            data = Default::default()
        };
        if mode == "clear" {
            data.content = None;
            data.media_ids = Some(vec![]);
            data.tag_names = Some(vec![]);
            data.mention_user_ids = Some(vec![])
        }
        let actual = run(&tx, 42, 20, &data);
        let expected = match mode {
            "success" | "noop" | "clear" => Some(PostUpdate::Updated),
            "muted" => Some(PostUpdate::PublishForbidden),
            "missing" | "deleted" | "race" => Some(PostUpdate::Missing),
            "other" => Some(PostUpdate::NotOwner),
            "bad-media" => Some(PostUpdate::MediaUnavailable),
            "empty" => Some(PostUpdate::ContentEmpty),
            _ => None,
        };
        if let Some(expected) = expected {
            assert_eq!(actual.unwrap(), expected, "{mode}")
        } else {
            assert!(actual.is_err(), "{mode}")
        }
        if ["success", "noop", "clear", "commit-applied"].contains(&mode) {
            assert_eq!(tx.commits.get(), 1, "{mode}")
        } else {
            assert_eq!(*tx.saved.borrow(), initial(), "{mode}");
            assert_eq!(tx.rollbacks.get(), 1, "{mode}")
        }
        if mode == "success" {
            assert_eq!(
                *tx.saved.borrow(),
                Saved {
                    content: "new".into(),
                    media: vec![3.0, 4.0],
                    tags: vec!["new".into()],
                    mentions: vec![9.0],
                    updated: true
                }
            )
        }
        if mode == "noop" {
            assert_eq!(*tx.saved.borrow(), initial())
        }
        if mode == "clear" {
            assert!(
                tx.saved.borrow().media.is_empty()
                    && tx.saved.borrow().tags.is_empty()
                    && tx.saved.borrow().mentions.is_empty()
            )
        }
    }
}
