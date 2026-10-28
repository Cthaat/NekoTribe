use crate::{
    auth::login::js_trim,
    db::{
        oracle::{bind_refs, bind_values, BindMap, DbError},
        row::{oracle_row_to_db_row, DbRow},
        tx::OracleTx,
        value::DbValue,
    },
    posts::create_request::PostCreateInput,
};

const MAX_SAFE_ID: u64 = 9_007_199_254_740_991;
const REFERENCE_SQL: &str = "SELECT p.post_id FROM n_posts p WHERE p.post_id=:post_id AND p.is_deleted=0 AND fn_can_view_post(:user_id,p.post_id)=1";
const NEXT_POST_SQL: &str = "SELECT seq_post_id.NEXTVAL AS id FROM dual";
const INSERT_POST_SQL: &str = "INSERT INTO n_posts (post_id,author_id,content,post_type,reply_to_post_id,repost_of_post_id,quoted_post_id,visibility,language,location) SELECT :post_id,:author_id,:content,:post_type,:reply_to_post_id,:repost_of_post_id,:quoted_post_id,:visibility,'zh',:location FROM dual";
const INSERT_REFERENCED_POST_SQL: &str = "INSERT INTO n_posts (post_id,author_id,content,post_type,reply_to_post_id,repost_of_post_id,quoted_post_id,visibility,language,location) SELECT :post_id,:author_id,:content,:post_type,:reply_to_post_id,:repost_of_post_id,:quoted_post_id,:visibility,'zh',:location FROM dual WHERE EXISTS (SELECT 1 FROM n_posts p WHERE p.post_id=:source_post_id AND p.is_deleted=0 AND fn_can_view_post(:author_id,p.post_id)=1)";
const INSERT_MEDIA_SQL: &str = "INSERT INTO n_post_media (post_id,media_id,sort_order) SELECT :post_id,media_id,:sort_order FROM n_media_assets WHERE media_id=:media_id AND owner_user_id=:user_id AND status IN ('uploaded','processing','ready')";
const MERGE_TAG_SQL: &str = "MERGE INTO n_tags t USING (SELECT :name AS name, LOWER(:name) AS name_lower FROM dual) src ON (t.name_lower=src.name_lower) WHEN NOT MATCHED THEN INSERT (tag_id,name,name_lower) VALUES (seq_tag_id.NEXTVAL,src.name,src.name_lower)";
const ATTACH_TAG_SQL: &str = "INSERT INTO n_post_tags (post_id,tag_id) SELECT :post_id,tag_id FROM n_tags WHERE name_lower=LOWER(:name) AND NOT EXISTS (SELECT 1 FROM n_post_tags WHERE post_id=:post_id AND tag_id=n_tags.tag_id)";
const ATTACH_MENTION_SQL: &str = "INSERT INTO n_post_mentions (post_id,mentioned_user_id) SELECT :post_id,user_id FROM n_users WHERE user_id=:user_id AND NOT EXISTS (SELECT 1 FROM n_post_mentions WHERE post_id=:post_id AND mentioned_user_id=:user_id)";

#[derive(Debug, PartialEq, Eq)]
pub enum PostCreation {
    Created(u64),
    ReferenceUnavailable,
    MediaUnavailable,
    ContentEmpty,
    Invalid,
}

/// A single connection and transaction; individual writes must never auto-commit.
#[doc(hidden)]
pub trait PostCreateTransaction {
    fn query(&self, sql: &'static str, binds: BindMap) -> Result<Vec<DbRow>, DbError>;
    fn execute(&self, sql: &'static str, binds: BindMap) -> Result<u64, DbError>;
    fn commit(&self) -> Result<(), DbError>;
    fn rollback(&self) -> Result<(), DbError>;
}

#[doc(hidden)]
pub fn run<T: PostCreateTransaction>(
    tx: &T,
    actor: u64,
    input: &PostCreateInput,
) -> Result<PostCreation, DbError> {
    let references = [
        input.reply_to_post_id,
        input.repost_of_post_id,
        input.quoted_post_id,
    ];
    if !(1..=MAX_SAFE_ID).contains(&actor)
        || !matches!(
            input.visibility.as_str(),
            "public" | "followers" | "mentioned" | "private"
        )
        || references.iter().flatten().count() > 1
        || references
            .iter()
            .flatten()
            .any(|id| !(1..=MAX_SAFE_ID).contains(id))
        || input
            .media_ids
            .iter()
            .chain(&input.mention_user_ids)
            .any(|id| !id.is_finite())
    {
        return Ok(PostCreation::Invalid);
    }
    let media = unique_ids(&input.media_ids, 4);
    if input.post_type() != "repost" && js_trim(&input.content).is_empty() && media.is_empty() {
        return Ok(PostCreation::ContentEmpty);
    }
    let source = references.into_iter().flatten().next();
    if let Some(source) = source {
        let rows = tx.query(
            REFERENCE_SQL,
            BindMap::from([
                ("post_id".into(), DbValue::I64(source as i64)),
                ("user_id".into(), DbValue::I64(actor as i64)),
            ]),
        )?;
        if rows.is_empty() {
            return Ok(PostCreation::ReferenceUnavailable);
        }
    }
    let rows = tx.query(NEXT_POST_SQL, BindMap::new())?;
    let id = rows
        .first()
        .and_then(|row| row.get("ID"))
        .and_then(DbValue::as_i64)
        .and_then(|id| u64::try_from(id).ok())
        .filter(|id| (1..=MAX_SAFE_ID).contains(id))
        .ok_or_else(|| DbError::ExpectedNumber("ID".into()))?;

    match write_post(tx, actor, id, source, input, &media) {
        Ok(PostCreation::Created(id)) => {
            if let Err(error) = tx.commit() {
                // A failed commit may already have reached Oracle. Rollback is
                // best effort and cannot establish that the post was not saved.
                let _ = tx.rollback();
                return Err(error);
            }
            Ok(PostCreation::Created(id))
        }
        Ok(outcome) => {
            tx.rollback()?;
            Ok(outcome)
        }
        Err(error) => {
            tx.rollback()?;
            Err(error)
        }
    }
}

fn write_post<T: PostCreateTransaction>(
    tx: &T,
    actor: u64,
    id: u64,
    source: Option<u64>,
    input: &PostCreateInput,
    media: &[f64],
) -> Result<PostCreation, DbError> {
    let mut binds = BindMap::from([
        ("post_id".into(), DbValue::I64(id as i64)),
        ("author_id".into(), DbValue::I64(actor as i64)),
        ("content".into(), nullable_string(&input.content)),
        (
            "post_type".into(),
            DbValue::String(input.post_type().into()),
        ),
        (
            "reply_to_post_id".into(),
            nullable_id(input.reply_to_post_id),
        ),
        (
            "repost_of_post_id".into(),
            nullable_id(input.repost_of_post_id),
        ),
        ("quoted_post_id".into(), nullable_id(input.quoted_post_id)),
        (
            "visibility".into(),
            DbValue::String(input.visibility.clone()),
        ),
        ("location".into(), nullable_string(&input.location)),
    ]);
    let sql = if let Some(source) = source {
        binds.insert("source_post_id".into(), DbValue::I64(source as i64));
        INSERT_REFERENCED_POST_SQL
    } else {
        INSERT_POST_SQL
    };
    match tx.execute(sql, binds)? {
        0 => return Ok(PostCreation::ReferenceUnavailable),
        1 => {}
        _ => return Err(DbError::SchemaNotReady),
    }
    for (index, media_id) in media.iter().enumerate() {
        let attached = tx.execute(
            INSERT_MEDIA_SQL,
            BindMap::from([
                ("post_id".into(), DbValue::I64(id as i64)),
                ("media_id".into(), DbValue::F64(*media_id)),
                ("sort_order".into(), DbValue::I64(index as i64 + 1)),
                ("user_id".into(), DbValue::I64(actor as i64)),
            ]),
        )?;
        if attached != 1 {
            return Ok(PostCreation::MediaUnavailable);
        }
    }
    for tag in unique_tags(&input.tag_names) {
        tx.execute(
            MERGE_TAG_SQL,
            BindMap::from([("name".into(), DbValue::String(tag.to_owned()))]),
        )?;
        tx.execute(
            ATTACH_TAG_SQL,
            BindMap::from([
                ("post_id".into(), DbValue::I64(id as i64)),
                ("name".into(), DbValue::String(tag.to_owned())),
            ]),
        )?;
    }
    for mentioned in unique_ids(&input.mention_user_ids, 50) {
        tx.execute(
            ATTACH_MENTION_SQL,
            BindMap::from([
                ("post_id".into(), DbValue::I64(id as i64)),
                ("user_id".into(), DbValue::F64(mentioned)),
            ]),
        )?;
    }
    Ok(PostCreation::Created(id))
}

fn nullable_id(id: Option<u64>) -> DbValue {
    id.map(|id| DbValue::I64(id as i64))
        .unwrap_or(DbValue::Null)
}

fn nullable_string(value: &str) -> DbValue {
    if value.is_empty() {
        DbValue::Null
    } else {
        DbValue::String(value.to_owned())
    }
}

fn unique_ids(values: &[f64], limit: usize) -> Vec<f64> {
    let mut unique = Vec::with_capacity(limit);
    for value in values {
        if !unique.contains(value) {
            unique.push(*value);
            if unique.len() == limit {
                break;
            }
        }
    }
    unique
}

fn unique_tags(values: &[String]) -> Vec<&str> {
    let mut unique = Vec::with_capacity(20);
    for value in values {
        let value = js_trim(value);
        let value = js_trim(value.strip_prefix('#').unwrap_or(value));
        if !value.is_empty() && !unique.contains(&value) {
            unique.push(value);
            if unique.len() == 20 {
                break;
            }
        }
    }
    unique
}

struct OraclePostTransaction<'a> {
    connection: &'a oracle::Connection,
    tx: OracleTx<'a>,
}

impl PostCreateTransaction for OraclePostTransaction<'_> {
    fn query(&self, sql: &'static str, binds: BindMap) -> Result<Vec<DbRow>, DbError> {
        let values = bind_values(binds);
        let refs = bind_refs(&values);
        self.connection
            .query_named(sql, &refs)?
            .map(|row| oracle_row_to_db_row(&row?))
            .collect()
    }
    fn execute(&self, sql: &'static str, binds: BindMap) -> Result<u64, DbError> {
        Ok(self.tx.execute(sql, binds)?.rows_affected)
    }
    fn commit(&self) -> Result<(), DbError> {
        self.tx.commit()
    }
    fn rollback(&self) -> Result<(), DbError> {
        self.tx.rollback()
    }
}

pub fn execute(
    connection: &oracle::Connection,
    actor: u64,
    input: &PostCreateInput,
) -> Result<PostCreation, DbError> {
    run(
        &OraclePostTransaction {
            connection,
            tx: OracleTx::new(connection),
        },
        actor,
        input,
    )
}
