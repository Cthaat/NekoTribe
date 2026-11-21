use crate::{
    auth::{sessions::NativeState, storage_urls::StorageUrlPolicy},
    chat_message_send::write_one,
    db::{
        oracle::{BindMap, DbError},
        tx::OracleTx,
        value::DbValue,
    },
    direct_send::next_id,
    group_detail::{self, GroupDetail, GroupLookup},
    group_settings::{self, Patch, COLUMNS},
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    body::{to_bytes, Body},
    extract::State,
    http::{header::CACHE_CONTROL, HeaderMap, HeaderValue},
    response::{IntoResponse, Response},
    Json,
};
use serde_json::Value;

const INSERT_GROUP: &str = "INSERT INTO n_groups
(group_id,name,slug,description,avatar_url,cover_url,category,owner_id,privacy,join_approval,post_permission)
VALUES (:group_id,:name,:slug,:description,:avatar_url,:cover_url,:category,:owner_id,:privacy,:join_approval,:post_permission)";
const INSERT_OWNER: &str = "INSERT INTO n_group_members (group_id,user_id,role,status)
VALUES (:group_id,:owner_id,'owner','active')";
const AUDIT: &str = "INSERT INTO n_group_audit_logs (group_id,actor_id,action)
VALUES (:group_id,:owner_id,'create_group')";

fn slug(name: &str, id: i64) -> String {
    let suffix = format!("-{id}");
    let mut base = String::new();
    for c in name.to_lowercase().chars() {
        if c.is_ascii_lowercase() || c.is_ascii_digit() || ('\u{4e00}'..='\u{9fa5}').contains(&c) {
            if base.len() + suffix.len() + c.len_utf8() > 100 {
                break;
            }
            base.push(c);
        } else if !base.is_empty() && !base.ends_with('-') {
            base.push('-');
        }
    }
    let base = base.trim_end_matches('-');
    format!("{}{suffix}", if base.is_empty() { "group" } else { base })
}

fn parse(raw: &[u8]) -> Result<Patch, ApiError> {
    let mut input = group_settings::parse(raw)?;
    let Some((_, DbValue::String(name))) = input.fields.iter_mut().find(|(key, _)| *key == "name")
    else {
        return Err(ApiError::bad_request("name 参数错误"));
    };
    *name = group_settings::trim(name).to_owned();
    Ok(input)
}

pub(crate) fn execute(
    conn: &oracle::Connection,
    actor: u64,
    mut input: Patch,
    storage: &StorageUrlPolicy,
) -> Result<Option<Value>, DbError> {
    let owner = i64::try_from(actor).map_err(|_| DbError::SchemaNotReady)?;
    let tx = OracleTx::new(conn);
    let result = (|| {
        if !group_settings::lock_group_images(&tx, &mut input.fields, storage)? {
            return Ok(None);
        }
        let id = next_id(conn, "SELECT seq_group_id.NEXTVAL AS id FROM dual")?;
        if !(1..=9_007_199_254_740_991).contains(&id) {
            return Err(DbError::SchemaNotReady);
        }
        let identity = BindMap::from([
            ("group_id".into(), DbValue::I64(id)),
            ("owner_id".into(), DbValue::I64(owner)),
        ]);
        let mut binds = identity.clone();
        binds.extend(input.fields.into_iter().map(|(k, v)| (k.into(), v)));
        for (key, default) in [
            ("privacy", DbValue::String("public".into())),
            ("join_approval", DbValue::I64(0)),
            ("post_permission", DbValue::String("all".into())),
        ] {
            binds.entry(key.into()).or_insert(default);
        }
        for key in COLUMNS {
            binds.entry(key.into()).or_insert(DbValue::Null);
        }
        let Some(DbValue::String(name)) = binds.get("name") else {
            return Err(DbError::SchemaNotReady);
        };
        binds.insert("slug".into(), DbValue::String(slug(name, id)));
        write_one(&tx, INSERT_GROUP, binds)?;
        write_one(&tx, INSERT_OWNER, identity.clone())?;
        group_settings::insert_tags(&tx, id, input.tags.unwrap_or_default())?;
        write_one(&tx, AUDIT, identity)?;
        let GroupDetail::Found(detail) =
            group_detail::execute(conn, actor, GroupLookup::Id(id as u64), storage)?
        else {
            return Err(DbError::SchemaNotReady);
        };
        tx.commit()?;
        Ok(Some(detail))
    })();
    if !matches!(&result, Ok(Some(_))) {
        tx.rollback()?;
    }
    result
}

pub(crate) async fn create(
    State(state): State<NativeState>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    let result = async {
        let actor = crate::posts::bookmark::interaction_actor(&state, &headers).await?;
        let bytes = to_bytes(body, 1 << 20)
            .await
            .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
        let group = state
            .repository
            .create_group(actor, parse(&bytes)?, &state.storage_urls)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?
            .ok_or_else(|| ApiError::bad_request(group_settings::IMAGE_MISSING_MESSAGE))?;
        Ok::<_, ApiError>(Json(V2Response::ok_with_message(group, "group created")))
    }
    .await;
    let mut response = result.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}
