use crate::{
    auth::login::js_trim,
    db::{
        oracle::{BindMap, DbError},
        tx::OracleTx,
        value::DbValue,
    },
    media::private_bind::{self, Target},
    posts::{
        create_transaction::{
            lock_post_media, nullable_string, unique_ids, unique_tags, PostCreateTransaction,
            ATTACH_MENTION_SQL, ATTACH_TAG_SQL, INSERT_MEDIA_SQL, MERGE_TAG_SQL,
        },
        update_request::PostUpdateInput,
    },
};
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum PostUpdate {
    Updated,
    Missing,
    NotOwner,
    MediaUnavailable,
    ContentEmpty,
    Invalid,
    PublishForbidden,
}
pub fn run<T: PostCreateTransaction>(
    tx: &T,
    actor: u64,
    id: u64,
    input: &PostUpdateInput,
) -> Result<PostUpdate, DbError> {
    if !(1..=9_007_199_254_740_991).contains(&actor) || !(1..=9_007_199_254_740_991).contains(&id) {
        return Ok(PostUpdate::Invalid);
    }
    match write(tx, actor, id, input) {
        Ok(PostUpdate::Updated) => {
            if let Err(error) = tx.commit() {
                let _ = tx.rollback();
                return Err(error);
            };
            Ok(PostUpdate::Updated)
        }
        Ok(result) => {
            tx.rollback()?;
            Ok(result)
        }
        Err(error) => {
            tx.rollback()?;
            Err(error)
        }
    }
}
fn write<T: PostCreateTransaction>(
    tx: &T,
    actor: u64,
    id: u64,
    input: &PostUpdateInput,
) -> Result<PostUpdate, DbError> {
    if !crate::moderation::publish_policy::allowed(actor as i64,|sql,binds|tx.query(sql,binds))? {
        return Ok(PostUpdate::PublishForbidden);
    }
    let post_bind = BindMap::from([("post_id".into(), DbValue::I64(id as i64))]);
    let rows=tx.query("SELECT author_id,is_deleted,post_type,visibility,DBMS_LOB.SUBSTR(content,4000,1) AS content FROM n_posts WHERE post_id=:post_id FOR UPDATE",post_bind.clone())?;
    let Some(row) = rows.first() else {
        return Ok(PostUpdate::Missing);
    };
    let number = |key: &str| {
        row.get(key)
            .and_then(DbValue::as_i64)
            .ok_or_else(|| DbError::ExpectedNumber(key.into()))
    };
    if number("IS_DELETED")? == 1 {
        return Ok(PostUpdate::Missing);
    };
    if number("AUTHOR_ID")? != actor as i64 {
        return Ok(PostUpdate::NotOwner);
    }
    if input.visibility.as_deref() == Some("public")
        && input.media_ids.is_none()
        && private_bind::retains_private(tx, id as i64)?
    {
        return Ok(PostUpdate::MediaUnavailable);
    }
    let kind = row
        .get("POST_TYPE")
        .and_then(DbValue::as_str)
        .unwrap_or_default();
    let content = input.content.as_deref().unwrap_or_else(|| {
        row.get("CONTENT")
            .and_then(DbValue::as_str)
            .unwrap_or_default()
    });
    let media_count = if let Some(media) = &input.media_ids {
        unique_ids(media, 4).len()
    } else {
        let counts = tx.query(
            "SELECT COUNT(*) AS total FROM n_post_media WHERE post_id=:post_id",
            post_bind.clone(),
        )?;
        counts
            .first()
            .and_then(|r| r.get("TOTAL"))
            .and_then(DbValue::as_i64)
            .and_then(|n| usize::try_from(n).ok())
            .ok_or_else(|| DbError::ExpectedNumber("TOTAL".into()))?
    };
    if kind != "repost" && js_trim(content).is_empty() && media_count == 0 {
        return Ok(PostUpdate::ContentEmpty);
    }
    let mut fields = Vec::new();
    let mut binds = post_bind.clone();
    binds.insert("user_id".into(), DbValue::I64(actor as i64));
    for (name, value) in [
        ("content", &input.content),
        ("visibility", &input.visibility),
        ("language", &input.language),
        ("location", &input.location),
    ] {
        if let Some(value) = value {
            fields.push(format!("{name}=:{name}"));
            binds.insert(name.into(), nullable_string(value));
        }
    }
    if !fields.is_empty()
        || input.media_ids.is_some()
        || input.tag_names.is_some()
        || input.mention_user_ids.is_some()
    {
        fields.push("updated_at=CURRENT_TIMESTAMP".into());
        let changed=tx.execute(&format!("UPDATE n_posts SET {} WHERE post_id=:post_id AND author_id=:user_id AND is_deleted=0",fields.join(",")),binds)?;
        if changed == 0 {
            return Ok(PostUpdate::Missing);
        };
        if changed != 1 {
            return Err(DbError::SchemaNotReady);
        }
    }
    if let Some(media) = &input.media_ids {
        let media = unique_ids(media, 4);
        let visibility = input.visibility.as_deref().unwrap_or_else(|| {
            row.get("VISIBILITY").and_then(DbValue::as_str).unwrap_or_default()
        });
        if !lock_post_media(tx, actor, &media, Target::post(id as i64, visibility))? {
            return Ok(PostUpdate::MediaUnavailable);
        }
        tx.execute(
            "DELETE FROM n_post_media WHERE post_id=:post_id",
            post_bind.clone(),
        )?;
        for (index, media) in media.into_iter().enumerate() {
            let n = tx.execute(
                INSERT_MEDIA_SQL,
                BindMap::from([
                    ("post_id".into(), DbValue::I64(id as i64)),
                    ("user_id".into(), DbValue::I64(actor as i64)),
                    ("media_id".into(), DbValue::F64(media)),
                    ("sort_order".into(), DbValue::I64(index as i64 + 1)),
                ]),
            )?;
            if n != 1 {
                return Ok(PostUpdate::MediaUnavailable);
            }
        }
    }
    if let Some(tags) = &input.tag_names {
        tx.execute(
            "DELETE FROM n_post_tags WHERE post_id=:post_id",
            post_bind.clone(),
        )?;
        for tag in unique_tags(tags) {
            tx.execute(
                MERGE_TAG_SQL,
                BindMap::from([("name".into(), DbValue::String(tag.into()))]),
            )?;
            tx.execute(
                ATTACH_TAG_SQL,
                BindMap::from([
                    ("post_id".into(), DbValue::I64(id as i64)),
                    ("name".into(), DbValue::String(tag.into())),
                ]),
            )?;
        }
    }
    if let Some(mentions) = &input.mention_user_ids {
        tx.execute(
            "DELETE FROM n_post_mentions WHERE post_id=:post_id",
            post_bind,
        )?;
        for user in unique_ids(mentions, 50) {
            tx.execute(
                ATTACH_MENTION_SQL,
                BindMap::from([
                    ("post_id".into(), DbValue::I64(id as i64)),
                    ("user_id".into(), DbValue::F64(user)),
                ]),
            )?;
        }
    }
    Ok(PostUpdate::Updated)
}
pub fn execute(
    connection: &oracle::Connection,
    actor: u64,
    id: u64,
    input: &PostUpdateInput,
) -> Result<PostUpdate, DbError> {
    run(&OracleTx::new(connection), actor, id, input)
}
