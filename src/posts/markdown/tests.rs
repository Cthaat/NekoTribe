use super::*;
use crate::{
    auth::storage_urls::StorageUrlPolicy,
    db::row::DbRow,
    group_post_write::{self, Creation, PostInput},
    posts::{
        create_request::parse_create_body,
        create_transaction::{self, PostCreation},
        draft_input::{parse_payload, Post},
        update_request::parse_update_body,
        update_transaction::{self, PostUpdate},
    },
};
use serde_json::{json, Value};
use std::cell::RefCell;

const LONG: &str = "  # Title\r\n\r\n```rust\nlet x = 1;\n```\n<b>raw HTML</b>  ";

#[test]
fn ordinary_edit_and_draft_markdown_preserve_raw_text_and_apply_utf8_limit() {
    let raw = |body: Value| body.to_string().into_bytes();
    let create = |body: Value| parse_create_body(&raw(body), "application/json", None);
    let edit = |body: Value| parse_update_body(&raw(body), "application/json");
    assert_eq!(
        create(json!({"content":"summary","markdown":LONG}))
            .unwrap()
            .markdown
            .as_deref(),
        Some(LONG)
    );
    assert!(create(json!({"content":"summary","markdown":LONG,"quoted_post_id":9})).is_err());
    assert!(create(json!({"content":"summary","markdown":LONG,"reply_to_post_id":9})).is_err());
    assert!(parse_create_body(
        &raw(json!({"content":"summary","markdown":LONG})),
        "application/json",
        Some(9)
    )
    .is_err());
    for value in [
        json!(null),
        json!(42),
        json!(" \u{feff}\n"),
        json!("中".repeat(5462)),
    ] {
        assert!(create(json!({"content":"summary","markdown":value})).is_err());
    }
    assert_eq!(edit(json!({})).unwrap().markdown, None);
    assert_eq!(edit(json!({"markdown":null})).unwrap().markdown, Some(None));
    assert_eq!(
        edit(json!({"markdown":LONG})).unwrap().markdown,
        Some(Some(LONG.into()))
    );

    let full = format!("{}a", "中".repeat(5461));
    assert_eq!(full.len(), 16384);
    assert!(validate(&full).is_ok());
    let markdown = format!("# Heading\n{}", "\n".repeat(16000));
    for group in [json!(null), json!(7)] {
        let input = raw(json!({"group_id":group,"content":"summary","markdown":markdown}));
        assert!(input.len() > 16384 && input.len() < 65536);
        let draft = parse_payload(&input).unwrap();
        assert_eq!(
            serde_json::to_value(draft.clone()).unwrap()["markdown"],
            markdown
        );
        assert!(draft.clone().post().unwrap().has_markdown());
        match draft.post().unwrap() {
            Post::Regular(input) => assert_eq!(input.markdown.as_deref(), Some(markdown.as_str())),
            Post::Group { input, .. } => {
                assert_eq!(input.markdown.as_deref(), Some(markdown.as_str()))
            }
        }
    }
}

struct PostStore {
    ready: bool,
    reject_markdown: bool,
    kind: &'static str,
    writes: RefCell<Vec<(String, BindMap)>>,
    commits: RefCell<Vec<&'static str>>,
}

impl Default for PostStore {
    fn default() -> Self {
        Self {
            ready: true,
            reject_markdown: false,
            kind: "post",
            writes: RefCell::default(),
            commits: RefCell::default(),
        }
    }
}

fn txt(key: &str, text: &str) -> (String, DbValue) {
    (key.into(), DbValue::String(text.into()))
}
fn num(key: &str, value: i64) -> (String, DbValue) {
    (key.into(), DbValue::I64(value))
}

fn metadata(sql: &str) -> Option<Vec<DbRow>> {
    let catalog: Value = serde_json::from_str(include_str!(
        "../../../contracts/requirements/post-markdown-schema-catalog.json"
    ))
    .unwrap();
    let table = &catalog["feature"]["steps"][0];
    if sql.contains("FROM user_tab_columns") {
        let rows = table["columns"]
            .as_array()
            .unwrap()
            .iter()
            .map(|column| {
                let name = column["name"].as_str().unwrap();
                let kind = column["type"].as_str().unwrap();
                let mut out = DbRow::from([
                    txt("COLUMN_NAME", name),
                    txt(
                        "NULLABLE",
                        if column["nullable"] == true { "Y" } else { "N" },
                    ),
                ]);
                if let Some(precision) = kind
                    .strip_prefix("NUMBER(")
                    .and_then(|number| number.strip_suffix(')'))
                {
                    out.extend([
                        txt("DATA_TYPE", "NUMBER"),
                        num("DATA_PRECISION", precision.parse().unwrap()),
                        num("DATA_SCALE", 0),
                    ]);
                } else {
                    out.extend([txt("DATA_TYPE", kind)]);
                }
                out
            })
            .collect();
        return Some(rows);
    }
    let constraints = table["constraints"].as_array().unwrap();
    if sql.contains("FROM user_constraints c") {
        return Some(
            constraints
                .iter()
                .map(|constraint| {
                    let mut row = DbRow::from([
                        txt("CONSTRAINT_NAME", constraint["name"].as_str().unwrap()),
                        txt("CONSTRAINT_TYPE", constraint["type"].as_str().unwrap()),
                        txt("STATUS", "ENABLED"),
                        txt("VALIDATED", "VALIDATED"),
                    ]);
                    for (expected, column) in [
                        ("expression", "SEARCH_CONDITION_VC"),
                        ("referencedTable", "REFERENCED_TABLE"),
                        ("deleteRule", "DELETE_RULE"),
                    ] {
                        if let Some(value) = constraint[expected].as_str() {
                            row.extend([txt(column, value)]);
                        }
                    }
                    row
                })
                .collect(),
        );
    }
    if sql.contains("FROM user_cons_columns c") {
        return Some(
            constraints
                .iter()
                .flat_map(|constraint| {
                    constraint["columns"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .enumerate()
                        .map(move |(index, column)| {
                            let mut row = DbRow::from([
                                txt("CONSTRAINT_NAME", constraint["name"].as_str().unwrap()),
                                txt("COLUMN_NAME", column.as_str().unwrap()),
                            ]);
                            if let Some(referenced) = constraint["referencedColumns"]
                                .get(index)
                                .and_then(Value::as_str)
                            {
                                row.extend([txt("REFERENCED_COLUMN", referenced)]);
                            }
                            row
                        })
                })
                .collect(),
        );
    }
    None
}

impl Transaction for PostStore {
    fn query(&self, sql: &str, binds: BindMap) -> Result<Vec<DbRow>, DbError> {
        if sql.contains("SYS_CONTEXT") {
            return Ok(vec![DbRow::from([
                txt("USER_NAME", "APP"),
                txt("SCHEMA_NAME", "APP"),
            ])]);
        }
        if sql.contains("FROM user_tables") {
            return Ok(
                if self.ready && binds["name"].as_str() == Some("N_POST_MARKDOWN") {
                    vec![DbRow::new()]
                } else {
                    vec![]
                },
            );
        }
        if let Some(rows) = metadata(sql) {
            return Ok(rows);
        }
        if sql.contains("NEXTVAL AS id") {
            return Ok(vec![DbRow::from([num("ID", 20)])]);
        }
        if sql.contains(" AS allowed FROM dual") {
            return Ok(vec![DbRow::from([num("ALLOWED", 1)])]);
        }
        if sql.contains("FROM n_users") || sql.contains("FROM n_groups") {
            return Ok(vec![DbRow::new()]);
        }
        if sql.contains("SELECT author_id,is_deleted,post_type") {
            return Ok(vec![DbRow::from([
                num("AUTHOR_ID", 42),
                num("IS_DELETED", 0),
                txt("POST_TYPE", self.kind),
                txt("CONTENT", "summary"),
            ])]);
        }
        if sql.contains("COUNT(*) AS total FROM n_post_media") {
            return Ok(vec![DbRow::from([num("TOTAL", 0)])]);
        }
        panic!("unexpected query: {sql}");
    }

    fn execute(&self, sql: &str, binds: BindMap) -> Result<u64, DbError> {
        self.writes.borrow_mut().push((sql.to_owned(), binds));
        if self.reject_markdown && sql.contains("n_post_markdown") {
            return Err(DbError::SemaphoreClosed);
        }
        Ok(if sql == contract().sql.update { 0 } else { 1 })
    }

    fn commit(&self) -> Result<(), DbError> {
        self.commits.borrow_mut().push("commit");
        Ok(())
    }
    fn rollback(&self) -> Result<(), DbError> {
        self.commits.borrow_mut().push("rollback");
        Ok(())
    }
}

#[test]
fn create_and_replace_markdown_share_the_post_transaction() {
    let input = parse_create_body(
        br##"{"content":"summary","markdown":"# Heading"}"##,
        "application/json",
        None,
    )
    .unwrap();
    let tx = PostStore::default();
    assert_eq!(
        create_transaction::run(&tx, 42, &input).unwrap(),
        PostCreation::Created(20)
    );
    assert_eq!(*tx.commits.borrow(), ["commit"]);
    let writes = tx.writes.borrow();
    assert!(writes[0].0.starts_with("INSERT INTO n_posts"));
    assert_eq!(writes[1].0, contract().sql.insert);
    assert_eq!(writes[1].1["markdown_body"].as_str(), Some("# Heading"));
    assert_eq!(writes[1].1["post_id"].as_i64(), Some(20));

    let tx = PostStore {
        reject_markdown: true,
        ..Default::default()
    };
    assert!(create_transaction::run(&tx, 42, &input).is_err());
    assert_eq!(*tx.commits.borrow(), ["rollback"]);
    let tx = PostStore {
        ready: false,
        ..Default::default()
    };
    assert_eq!(
        create_transaction::run(&tx, 42, &input).unwrap(),
        PostCreation::MarkdownUnavailable
    );
    assert!(tx.writes.borrow().is_empty());

    let body = parse_update_body(br###"{"markdown":"## Replaced"}"###, "application/json").unwrap();
    let tx = PostStore::default();
    assert_eq!(
        update_transaction::run(&tx, 42, 20, &body).unwrap(),
        PostUpdate::Updated
    );
    let writes = tx.writes.borrow();
    assert!(writes[0].0.starts_with("UPDATE n_posts SET updated_at"));
    assert_eq!(writes[1].0, contract().sql.update);
    assert_eq!(writes[2].0, contract().sql.insert);
    assert_eq!(writes[2].1["markdown_body"].as_str(), Some("## Replaced"));
    assert_eq!(*tx.commits.borrow(), ["commit"]);

    let remove = parse_update_body(br#"{"markdown":null}"#, "application/json").unwrap();
    let tx = PostStore::default();
    assert_eq!(
        update_transaction::run(&tx, 42, 20, &remove).unwrap(),
        PostUpdate::Updated
    );
    assert_eq!(tx.writes.borrow()[1].0, contract().sql.remove);
    for kind in ["reply", "quote", "repost"] {
        let tx = PostStore {
            kind,
            ..Default::default()
        };
        assert_eq!(
            update_transaction::run(&tx, 42, 20, &remove).unwrap(),
            PostUpdate::MarkdownNotAllowed
        );
        assert!(tx.writes.borrow().is_empty());
    }
}

#[test]
fn group_markdown_attaches_only_to_the_group_post_without_committing_the_caller_transaction() {
    let tx = PostStore::default();
    let input = PostInput {
        content: "summary".into(),
        media: "".into(),
        announcement: false,
        poll: None,
        markdown: Some(LONG.into()),
    };
    let result =
        group_post_write::create_in_transaction(&tx, 42, 7, input, &StorageUrlPolicy::default())
            .unwrap();
    assert!(matches!(result, Creation::Created(20)));
    let writes = tx.writes.borrow();
    assert!(writes[0].0.starts_with("INSERT INTO n_group_posts"));
    assert_eq!(writes[1].0, contract().sql.insert);
    assert_eq!(writes[1].1["group_post_id"].as_i64(), Some(20));
    assert_eq!(writes[1].1["post_id"], DbValue::Null);
    assert_eq!(writes[1].1["markdown_body"].as_str(), Some(LONG));
    assert!(tx.commits.borrow().is_empty());
}

#[test]
fn legacy_read_omits_markdown_only_for_an_absent_owned_table() {
    struct Reader {
        exists: bool,
        owned: bool,
    }
    impl Transaction for Reader {
        fn query(&self, sql: &str, _: BindMap) -> Result<Vec<DbRow>, DbError> {
            if sql == OWNER_SCHEMA {
                return Ok(if self.owned {
                    vec![DbRow::new()]
                } else {
                    vec![]
                });
            }
            if sql == contract().sql.present {
                return Ok(if self.exists {
                    vec![DbRow::new()]
                } else {
                    vec![]
                });
            }
            assert_eq!(sql, contract().sql.read);
            #[allow(deprecated)]
            Err(DbError::Oracle(oracle::Error::OciError(
                oracle::DbError::new(942, 0, "synthetic", "", ""),
            )))
        }
        fn execute(&self, _: &str, _: BindMap) -> Result<u64, DbError> {
            panic!("unexpected write");
        }
        fn commit(&self) -> Result<(), DbError> {
            panic!("unexpected commit");
        }
        fn rollback(&self) -> Result<(), DbError> {
            panic!("unexpected rollback");
        }
    }
    assert_eq!(
        read(
            &Reader {
                exists: false,
                owned: true
            },
            Source::Post(20)
        )
        .unwrap(),
        None
    );
    assert!(matches!(
        read(
            &Reader {
                exists: true,
                owned: true
            },
            Source::GroupPost(20)
        ),
        Err(DbError::SchemaNotReady)
    ));
    assert!(matches!(
        read(
            &Reader {
                exists: false,
                owned: false
            },
            Source::Post(20)
        ),
        Err(DbError::SchemaNotReady)
    ));
}
