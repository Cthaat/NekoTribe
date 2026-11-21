use crate::{
    auth::{
        session_repository::{row_number, row_text},
        sessions::NativeState,
        storage_urls::StorageUrlPolicy,
    },
    chat_message_send::write_one,
    db::{
        oracle::{BindMap, DbError},
        tx::{OracleTx, Transaction},
        value::DbValue,
    },
    direct_history::query,
    group_detail::{self, GroupDetail, GroupLookup},
    group_membership::{GROUP, MEMBER},
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    body::{to_bytes, Body},
    extract::{Path, State},
    http::{header::CACHE_CONTROL, HeaderMap, HeaderValue},
    response::{IntoResponse, Response},
    Json,
};
use serde_json::Value;
use std::{collections::{HashMap, HashSet}, sync::OnceLock};

pub struct Patch {
    pub(crate) fields: Vec<(&'static str, DbValue)>,
    pub(crate) tags: Option<Vec<String>>,
}

pub enum Outcome {
    Detail(GroupDetail),
    Forbidden,
    ImageMissing,
}

pub(crate) const IMAGE_MISSING_MESSAGE: &str = "群组图片不存在或已删除";

fn managed_image_key(storage: &StorageUrlPolicy, input: &str) -> Option<String> {
    static PATTERNS: OnceLock<(regex::Regex, regex::Regex)> = OnceLock::new();
    let (alias, key_pattern) = PATTERNS.get_or_init(|| {
        let spec = crate::media::delete::reference_contract();
        (
            regex::Regex::new(&spec.alias_pattern).expect("valid media URL alias regex"),
            regex::Regex::new(&spec.key_pattern).expect("valid media key regex"),
        )
    });
    let url = trim(input);
    let key = if let Some(alias) = alias.captures(url) {
        alias[3].to_owned()
    } else {
        storage.managed_key(url.split(['?', '#']).next()?).ok().flatten()?
    };
    key_pattern.is_match(&key).then_some(key)
}

pub(crate) fn lock_group_images<T: Transaction>(
    tx: &T,
    fields: &mut [(&'static str, DbValue)],
    storage: &StorageUrlPolicy,
) -> Result<bool, DbError> {
    let indices: Vec<_> = fields.iter().enumerate().filter_map(|(index, (field, value))| {
        if matches!(*field, "avatar_url" | "cover_url") {
            value.as_str().map(|url| (index, url.to_owned()))
        } else {
            None
        }
    }).collect();
    let mut urls: Vec<_> = indices.iter().map(|(_, url)| url.clone()).collect();
    if !lock_group_media_urls(tx, &mut urls, storage)? {
        return Ok(false);
    }
    for ((index, _), url) in indices.into_iter().zip(urls) {
        fields[index].1 = DbValue::String(url);
    }
    Ok(true)
}

pub(crate) fn lock_group_media_urls<T: Transaction>(
    tx: &T,
    urls: &mut [String],
    storage: &StorageUrlPolicy,
) -> Result<bool, DbError> {
    let mut targets = Vec::new();
    let mut keys = Vec::new();
    for (index, url) in urls.iter().enumerate() {
        if let Some(key) = managed_image_key(storage, url) {
            if !keys.contains(&key) {
                keys.push(key.clone());
            }
            targets.push((index, key));
        }
    }

    let spec = crate::media::delete::reference_contract();
    let mut assets = Vec::new();
    for pair in keys.chunks(2) {
        let rows = tx.query(&spec.lookup_group_images, BindMap::from([
            ("first_key".into(), DbValue::String(pair[0].clone())),
            ("second_key".into(), DbValue::String(pair[pair.len() - 1].clone())),
        ]))?;
        for row in rows {
            let id = row_number(&row, "MEDIA_ID");
            let key = row_text(&row, "STORAGE_KEY");
            if !(1..=9_007_199_254_740_991).contains(&id) || key.is_empty() {
                return Err(DbError::SchemaNotReady);
            }
            assets.push((id, key));
        }
    }
    if assets.len() != keys.len() {
        return Ok(false);
    }
    assets.sort_unstable_by_key(|(id, _)| *id);

    let mut locked_urls = HashMap::new();
    for (id, key) in assets {
        let locked = tx.query(&spec.lock_group_image, BindMap::from([
            ("media_id".into(), DbValue::I64(id)),
            ("storage_key".into(), DbValue::String(key.clone())),
        ]))?;
        let Some(row) = locked.first() else {
            return Ok(false);
        };
        let url = row_text(row, "PUBLIC_URL");
        if url.is_empty() {
            return Ok(false);
        }
        locked_urls.insert(key, url);
    }
    for (index, key) in targets {
        let Some(url) = locked_urls.get(&key) else {
            return Ok(false);
        };
        urls[index] = url.clone();
    }
    Ok(true)
}

pub(crate) const COLUMNS: [&str; 8] = [
    "name",
    "description",
    "avatar_url",
    "cover_url",
    "privacy",
    "join_approval",
    "post_permission",
    "category",
];
const CLEAR_TAGS: &str = "DELETE FROM n_group_tags WHERE group_id=:group_id";
const INSERT_TAG: &str =
    "INSERT INTO n_group_tags (group_id,tag,tag_lower) VALUES (:group_id,:tag,:tag_lower)";

pub(crate) fn trim(value: &str) -> &str {
    value.trim_matches(|c: char| (c.is_whitespace() && c != '\u{0085}') || c == '\u{feff}')
}

fn tags(input: &Value) -> Result<Vec<String>, ApiError> {
    let bad = || ApiError::bad_request("tags 参数错误");
    let values = input.as_array().ok_or_else(bad)?;
    if values.iter().any(|v| !v.is_string()) {
        return Err(bad());
    }
    let mut seen = HashSet::new();
    let mut tags = Vec::new();
    for raw in values.iter().filter_map(Value::as_str) {
        let raw = trim(raw);
        let mut tag = trim(raw.strip_prefix('#').unwrap_or(raw)).to_owned();
        while tag.len() > 50 || tag.to_lowercase().len() > 50 {
            tag.pop();
        }
        if !tag.is_empty() && seen.insert(tag.to_lowercase()) {
            tags.push(tag);
        }
        if tags.len() == 8 {
            break;
        }
    }
    Ok(tags)
}

pub(crate) fn parse(raw: &[u8]) -> Result<Patch, ApiError> {
    let bad_body = || ApiError::bad_request("请求体必须是 JSON 对象");
    let input: Value = serde_json::from_slice(raw).map_err(|_| bad_body())?;
    let input = input.as_object().ok_or_else(bad_body)?;
    let mut fields = Vec::new();
    for key in COLUMNS {
        let Some(value) = input.get(key) else {
            continue;
        };
        let bad = || ApiError::bad_request(format!("{key} 参数错误"));
        if key == "join_approval" {
            fields.push((
                key,
                DbValue::I64(i64::from(value.as_bool().ok_or_else(bad)?)),
            ));
            continue;
        }
        let nullable = matches!(key, "description" | "avatar_url" | "cover_url" | "category");
        if nullable && value.is_null() {
            fields.push((key, DbValue::Null));
            continue;
        }
        let mut text = value.as_str().ok_or_else(bad)?;
        let valid = match key {
            "name" => !trim(text).is_empty() && text.len() <= 100,
            "description" | "avatar_url" | "cover_url" => text.len() <= 500,
            "privacy" => matches!(text, "public" | "private" | "secret"),
            "post_permission" => matches!(text, "all" | "admin_only" | "moderator_up"),
            "category" => {
                text = trim(text);
                matches!(
                    text,
                    "" | "tech" | "game" | "music" | "art" | "life" | "study" | "work" | "other"
                )
            }
            _ => false,
        };
        if !valid {
            return Err(bad());
        }
        fields.push((
            key,
            if nullable && text.is_empty() {
                DbValue::Null
            } else {
                DbValue::String(text.into())
            },
        ));
    }
    Ok(Patch {
        fields,
        tags: input.get("tags").map(tags).transpose()?,
    })
}

pub(crate) fn execute(
    conn: &oracle::Connection,
    viewer: u64,
    group: u64,
    mut patch: Patch,
    storage: &StorageUrlPolicy,
) -> Result<Outcome, DbError> {
    let group_db = i64::try_from(group).map_err(|_| DbError::SchemaNotReady)?;
    let viewer_db = i64::try_from(viewer).map_err(|_| DbError::SchemaNotReady)?;
    let tx = OracleTx::new(conn);
    let result = (|| {
        let group_binds = BindMap::from([("group_id".into(), DbValue::I64(group_db))]);
        let groups = query(conn, GROUP, group_binds.clone())?;
        let Some(row) = groups.first() else {
            return Ok(Outcome::Detail(GroupDetail::Missing));
        };
        if row_number(row, "IS_ACTIVE") != 1 || row_number(row, "IS_DELETED") != 0 {
            return Ok(Outcome::Detail(GroupDetail::Missing));
        }
        let mut actor_binds = group_binds.clone();
        actor_binds.insert("user_id".into(), DbValue::I64(viewer_db));
        let actors = query(conn, MEMBER, actor_binds)?;
        let Some(actor) = actors.first() else {
            return Ok(Outcome::Forbidden);
        };
        let role = row_text(actor, "ROLE");
        if row_text(actor, "STATUS") != "active"
            || !(role == "admin" || role == "owner" && row_number(row, "OWNER_ID") == viewer_db)
        {
            return Ok(Outcome::Forbidden);
        }

        if !patch.fields.is_empty() || patch.tags.is_some() {
            if !lock_group_images(&tx, &mut patch.fields, storage)? {
                return Ok(Outcome::ImageMissing);
            }
            let mut binds = group_binds.clone();
            let mut clauses = Vec::new();
            for (column, value) in patch.fields {
                clauses.push(format!("{column}=:{column}"));
                binds.insert(column.into(), value);
            }
            clauses.push("updated_at=SYSTIMESTAMP".into());
            write_one(
                &tx,
                &format!(
                    "UPDATE n_groups SET {} WHERE group_id=:group_id",
                    clauses.join(",")
                ),
                binds,
            )?;
        }
        if let Some(tags) = patch.tags {
            tx.execute(CLEAR_TAGS, group_binds.clone())?;
            insert_tags(&tx, group_db, tags)?;
        }
        Ok(Outcome::Detail(group_detail::execute(
            conn,
            viewer,
            GroupLookup::Id(group),
            storage,
        )?))
    })();
    match result {
        Ok(result @ Outcome::Detail(GroupDetail::Found(_))) => match tx.commit() {
            Ok(()) => Ok(result),
            Err(error) => {
                let _ = tx.rollback();
                Err(error)
            }
        },
        other => {
            tx.rollback()?;
            other
        }
    }
}

pub(crate) fn insert_tags(tx: &OracleTx<'_>, group: i64, tags: Vec<String>) -> Result<(), DbError> {
    for tag in tags {
        let binds = BindMap::from([
            ("group_id".into(), DbValue::I64(group)),
            ("tag_lower".into(), DbValue::String(tag.to_lowercase())),
            ("tag".into(), DbValue::String(tag)),
        ]);
        write_one(tx, INSERT_TAG, binds)?;
    }
    Ok(())
}

pub(crate) async fn patch(
    State(state): State<NativeState>,
    Path(id): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    let result = async {
        let (viewer, group) =
            crate::posts::bookmark::interaction_identity(&state, &id, &headers).await?;
        let bytes = to_bytes(body, 1 << 20)
            .await
            .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
        let patch = parse(&bytes)?;
        match state
            .repository
            .patch_group_settings(viewer, group, patch, &state.storage_urls)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?
        {
            Outcome::Detail(GroupDetail::Found(group)) => {
                Ok(Json(V2Response::ok_with_message(group, "group updated")))
            }
            Outcome::Detail(GroupDetail::Missing) => Err(ApiError::not_found("群组不存在")),
            Outcome::Detail(GroupDetail::OwnerMissing) => Err(ApiError::not_found("用户不存在")),
            Outcome::Forbidden => Err(ApiError::unprocessable("无权修改群组")),
            Outcome::ImageMissing => Err(ApiError::bad_request(IMAGE_MISSING_MESSAGE)),
        }
    }
    .await;
    let mut response = result.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn validates_partial_settings_and_preserves_tag_intent() {
        let parsed=parse(r##"{"name":"Cat","join_approval":false,"description":null,"tags":["#猫","Rust"," rust ","#猫"]}"##.as_bytes()).unwrap();
        assert_eq!(
            parsed.fields,
            vec![
                ("name", DbValue::String("Cat".into())),
                ("description", DbValue::Null),
                ("join_approval", DbValue::I64(0))
            ]
        );
        assert_eq!(parsed.tags.unwrap(), vec!["猫", "Rust"]);
        assert!(parse(br#"{ "tags":null }"#).is_err());
        assert!(parse(br#"{ "name":null }"#).is_err());
        assert!(parse(br#"{ "join_approval":1 }"#).is_err());
        assert!(parse(b"{}").unwrap().tags.is_none());
        assert_eq!(parse(br#"{ "tags":[] }"#).unwrap().tags, Some(Vec::new()));
    }
}
