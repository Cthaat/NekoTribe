use crate::{
    auth::login::js_trim,
    db::{
        oracle::{BindMap, DbError},
        tx::OracleTx,
        value::DbValue,
    },
    media::private_bind::{self, Target},
    posts::{create_request::PostCreateInput, markdown, polls},
};

const MAX_SAFE_ID: u64 = 9_007_199_254_740_991;
const REFERENCE_SQL: &str = "SELECT p.post_id FROM n_posts p WHERE p.post_id=:post_id AND p.is_deleted=0 AND fn_can_view_post(:user_id,p.post_id)=1";
const NEXT_POST_SQL: &str = "SELECT seq_post_id.NEXTVAL AS id FROM dual";
const INSERT_POST_SQL: &str = "INSERT INTO n_posts (post_id,author_id,content,post_type,reply_to_post_id,repost_of_post_id,quoted_post_id,visibility,language,location) SELECT :post_id,:author_id,:content,:post_type,:reply_to_post_id,:repost_of_post_id,:quoted_post_id,:visibility,'zh',:location FROM dual";
const INSERT_REFERENCED_POST_SQL: &str = "INSERT INTO n_posts (post_id,author_id,content,post_type,reply_to_post_id,repost_of_post_id,quoted_post_id,visibility,language,location) SELECT :post_id,:author_id,:content,:post_type,:reply_to_post_id,:repost_of_post_id,:quoted_post_id,:visibility,'zh',:location FROM dual WHERE EXISTS (SELECT 1 FROM n_posts p WHERE p.post_id=:source_post_id AND p.is_deleted=0 AND fn_can_view_post(:author_id,p.post_id)=1)";
pub(super) const INSERT_MEDIA_SQL: &str = "INSERT INTO n_post_media (post_id,media_id,sort_order) SELECT :post_id,media_id,:sort_order FROM n_media_assets WHERE media_id=:media_id AND owner_user_id=:user_id AND status IN ('uploaded','processing','ready')";
const LOCK_MEDIA_SQL: &str = "SELECT media_id,storage_key FROM n_media_assets WHERE media_id=:media_id AND owner_user_id=:user_id AND status IN ('uploaded','processing','ready') FOR UPDATE";

pub(super) fn lock_post_media<T: PostCreateTransaction>(
    tx: &T,
    actor: u64,
    media: &[f64],
    target: Target,
) -> Result<bool, DbError> {
    let mut ordered = media.to_vec();
    ordered.sort_by(f64::total_cmp);
    for id in ordered {
        let binds = BindMap::from([
            ("media_id".into(), DbValue::F64(id)),
            ("user_id".into(), DbValue::I64(actor as i64)),
        ]);
        let rows = tx.query(LOCK_MEDIA_SQL, binds)?;
        let Some(row) = rows.first() else {
            return Ok(false);
        };
        if !private_bind::can_attach(tx, row, DbValue::F64(id), target)? {
            return Ok(false);
        }
    }
    Ok(true)
}
pub(super) const MERGE_TAG_SQL: &str = "MERGE INTO n_tags t USING (SELECT :name AS name, LOWER(:name) AS name_lower FROM dual) src ON (t.name_lower=src.name_lower) WHEN NOT MATCHED THEN INSERT (tag_id,name,name_lower) VALUES (seq_tag_id.NEXTVAL,src.name,src.name_lower)";
pub(super) const ATTACH_TAG_SQL: &str = "INSERT INTO n_post_tags (post_id,tag_id) SELECT :post_id,tag_id FROM n_tags WHERE name_lower=LOWER(:name) AND NOT EXISTS (SELECT 1 FROM n_post_tags WHERE post_id=:post_id AND tag_id=n_tags.tag_id)";
pub(super) const ATTACH_MENTION_SQL: &str = "INSERT INTO n_post_mentions (post_id,mentioned_user_id) SELECT :post_id,user_id FROM n_users WHERE user_id=:user_id AND NOT EXISTS (SELECT 1 FROM n_post_mentions WHERE post_id=:post_id AND mentioned_user_id=:user_id)";

#[derive(Debug, PartialEq, Eq)]
pub enum PostCreation {
    Created(u64),
    ReferenceUnavailable,
    MediaUnavailable,
    ContentEmpty,
    Invalid,
    PublishForbidden,
    PollUnavailable,
    PollCutoff,
    MarkdownUnavailable,
}

#[doc(hidden)]
pub use crate::db::tx::Transaction as PostCreateTransaction;

#[doc(hidden)]
pub fn run<T: PostCreateTransaction>(
    tx: &T,
    actor: u64,
    input: &PostCreateInput,
) -> Result<PostCreation, DbError> {
    create(tx, actor, input, true)
}

pub(super) fn create_in_transaction<T: PostCreateTransaction>(
    tx: &T,
    actor: u64,
    input: &PostCreateInput,
) -> Result<PostCreation, DbError> {
    create(tx, actor, input, false)
}

fn create<T: PostCreateTransaction>(
    tx: &T,
    actor: u64,
    input: &PostCreateInput,
    finalize: bool,
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
        || (input.poll.is_some() && input.post_type() != "post")
        || (input.markdown.is_some() && input.post_type() != "post")
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
    if input.poll.is_some() && polls::require_schema(tx).is_err() {
        return Ok(PostCreation::PollUnavailable);
    }
    if input.markdown.is_some() && markdown::require_schema(tx).is_err() {
        return Ok(PostCreation::MarkdownUnavailable);
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

    let result=(|| {
        if !crate::moderation::publish_policy::allowed(actor as i64,|sql,binds|tx.query(sql,binds))? {
            return Ok(PostCreation::PublishForbidden);
        }
        write_post(tx, actor, id, source, input, &media)
    })();
    if !finalize {
        return result;
    }
    match result {
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
    if !lock_post_media(tx, actor, media, Target::post(id as i64, &input.visibility))? {
        return Ok(PostCreation::MediaUnavailable);
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
    if let Some(draft) = &input.poll {
        if !polls::attach(tx, polls::Target::Regular(id as i64), draft)? {
            return Ok(PostCreation::PollCutoff);
        }
    }
    if let Some(body) = &input.markdown {
        markdown::attach(tx, markdown::Source::Post(id as i64), body)?;
    }
    Ok(PostCreation::Created(id))
}

fn nullable_id(id: Option<u64>) -> DbValue {
    id.map(|id| DbValue::I64(id as i64))
        .unwrap_or(DbValue::Null)
}

pub(super) fn nullable_string(value: &str) -> DbValue {
    if value.is_empty() {
        DbValue::Null
    } else {
        DbValue::String(value.to_owned())
    }
}

pub(super) fn unique_ids(values: &[f64], limit: usize) -> Vec<f64> {
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

pub(super) fn unique_tags(values: &[String]) -> Vec<&str> {
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

pub fn execute(
    connection: &oracle::Connection,
    actor: u64,
    input: &PostCreateInput,
) -> Result<PostCreation, DbError> {
    run(&OracleTx::new(connection), actor, input)
}
