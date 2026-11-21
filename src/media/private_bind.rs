use crate::{
    db::{
        oracle::{BindMap, DbError},
        row::DbRow,
        tx::Transaction,
        value::DbValue,
    },
    storage::local_policy::normalize_local_key,
};
use serde::Deserialize;
use std::sync::OnceLock;

#[derive(Deserialize)]
struct BindContract {
    chat: String,
    post: String,
    retained: String,
}

fn contract() -> &'static BindContract {
    static CONTRACT: OnceLock<BindContract> = OnceLock::new();
    CONTRACT.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../../contracts/requirements/media-private-bind.json"
        ))
        .expect("valid private media binding contract")
    })
}

#[derive(Clone, Copy)]
pub(crate) enum Target {
    Chat,
    RestrictedPost(i64),
    PublicPost,
}

impl Target {
    pub(crate) fn post(post_id: i64, visibility: &str) -> Self {
        if matches!(visibility, "private" | "followers" | "mentioned") {
            Self::RestrictedPost(post_id)
        } else {
            Self::PublicPost
        }
    }
}

/// Call after verifying ownership and locking the selected asset row.
pub(crate) fn can_attach(
    tx: &impl Transaction,
    row: &DbRow,
    media_id: DbValue,
    target: Target,
) -> Result<bool, DbError> {
    let key = row
        .get("STORAGE_KEY")
        .and_then(DbValue::as_str)
        .unwrap_or_default();
    if !key
        .split(['/', '\\'])
        .next()
        .is_some_and(|part| part.eq_ignore_ascii_case("private"))
    {
        return Ok(true);
    }
    let mut binds = BindMap::from([("media_id".into(), media_id)]);
    let (prefix, sql) = match target {
        Target::Chat => ("private/chat/", &contract().chat),
        Target::RestrictedPost(post_id) => {
            binds.insert("post_id".into(), DbValue::I64(post_id));
            ("private/post/", &contract().post)
        }
        Target::PublicPost => return Ok(false),
    };
    if !normalize_local_key(key).is_ok_and(|key| key.starts_with(prefix)) {
        return Ok(false);
    }
    match tx.query(sql, binds) {
        Ok(rows) => Ok(!rows.is_empty()),
        Err(error) if super::private_read::missing_schema(&error) => Ok(false),
        Err(error) => Err(error),
    }
}

/// Call while holding the target post row lock.
pub(crate) fn retains_private(tx: &impl Transaction, post_id: i64) -> Result<bool, DbError> {
    let rows = tx.query(
        &contract().retained,
        BindMap::from([("post_id".into(), DbValue::I64(post_id))]),
    )?;
    Ok(!rows.is_empty())
}
