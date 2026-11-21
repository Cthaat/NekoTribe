use crate::{
    auth::{session_repository::row_number, sessions::NativeState},
    chat_channels::{channel_json, LOCK, MEMBERSHIP, SELECT},
    db::{
        oracle::{BindMap, DbError},
        tx::OracleTx,
        value::DbValue,
    },
    direct_history::query,
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

pub enum Change {
    Create {
        name: String,
        kind: String,
        category: String,
        private: bool,
    },
    Update {
        name: Option<String>,
        category: Option<String>,
        private: Option<bool>,
    },
    Delete,
}

const ACCESS: &str = "SELECT c.group_id FROM n_chat_channels c
JOIN n_groups g ON g.group_id=c.group_id AND g.is_active=1 AND g.is_deleted=0
JOIN n_group_members gm ON gm.group_id=c.group_id AND gm.user_id=:user_id
WHERE c.channel_id=:channel_id AND c.is_deleted=0 AND gm.status IN ('active','muted')
AND gm.role IN ('owner','admin','moderator')";

fn write(
    conn: &oracle::Connection,
    tx: &OracleTx<'_>,
    user: u64,
    id: u64,
    change: Change,
) -> Result<Option<Value>, DbError> {
    let user = DbValue::I64(i64::try_from(user).map_err(|_| DbError::SchemaNotReady)?);
    let id = i64::try_from(id).map_err(|_| DbError::SchemaNotReady)?;
    let create = matches!(change, Change::Create { .. });
    let remove = matches!(change, Change::Delete);
    let channel_binds = || BindMap::from([("channel_id".into(), DbValue::I64(id))]);
    let access = || {
        let mut binds = channel_binds();
        binds.insert("user_id".into(), user.clone());
        query(conn, ACCESS, binds)
    };
    let group = if create {
        id
    } else {
        let rows = access()?;
        let Some(row) = rows.first() else {
            return Ok(None);
        };
        row_number(row, "GROUP_ID")
    };
    let group_binds = || BindMap::from([("group_id".into(), DbValue::I64(group))]);
    let member_binds = || {
        let mut binds = group_binds();
        binds.insert("user_id".into(), user.clone());
        binds
    };
    if query(conn, LOCK, group_binds())?.is_empty() {
        return Ok(None);
    }
    let members = query(
        conn,
        &format!("{MEMBERSHIP} FOR UPDATE OF gm.role"),
        member_binds(),
    )?;
    if members.first().map(|row| row_number(row, "CAN_MANAGE")) != Some(1)
        || !create && access()?.is_empty()
    {
        return Ok(None);
    }

    let mut channel_id = id;
    let changed = match change {
        Change::Create { name, kind, category, private } => {
            let rows = query(conn, "SELECT seq_chat_channel_id.NEXTVAL AS id FROM dual", BindMap::new())?;
            channel_id = rows.first().map(|row| row_number(row, "ID")).ok_or(DbError::SchemaNotReady)?;
            if !(1..=9_007_199_254_740_991).contains(&channel_id) {
                return Err(DbError::SchemaNotReady);
            }
            let mut binds = member_binds();
            binds.extend([
                ("channel_id".into(), DbValue::I64(channel_id)),
                ("name".into(), DbValue::String(name)),
                ("channel_type".into(), DbValue::String(kind)),
                ("category".into(), DbValue::String(category)),
                ("is_private".into(), DbValue::I64(i64::from(private))),
            ]);
            tx.execute("INSERT INTO n_chat_channels
(channel_id,group_id,name,channel_type,category,position,is_private,created_by)
VALUES (:channel_id,:group_id,:name,:channel_type,:category,
(SELECT NVL(MAX(position),0)+10 FROM n_chat_channels WHERE group_id=:group_id),
:is_private,:user_id)", binds)?.rows_affected
        }
        Change::Delete => tx.execute(
            "UPDATE n_chat_channels SET is_deleted=1,updated_at=CURRENT_TIMESTAMP WHERE channel_id=:channel_id AND is_deleted=0",
            channel_binds(),
        )?.rows_affected,
        Change::Update { name, category, private } => {
            let mut binds = channel_binds();
            let mut clauses = Vec::new();
            for (key, clause, value) in [
                ("name", "name=:name", name.map(DbValue::String)),
                ("category", "category=:category", category.map(DbValue::String)),
                ("is_private", "is_private=:is_private", private.map(|value| DbValue::I64(i64::from(value)))),
            ] {
                if let Some(value) = value {
                    clauses.push(clause);
                    binds.insert(key.into(), value);
                }
            }
            if clauses.is_empty() {
                1
            } else {
                clauses.push("updated_at=CURRENT_TIMESTAMP");
                let sql = format!("UPDATE n_chat_channels SET {} WHERE channel_id=:channel_id AND is_deleted=0", clauses.join(","));
                tx.execute(&sql, binds)?.rows_affected
            }
        }
    };
    if changed != 1 {
        return Err(DbError::SchemaNotReady);
    }
    if remove {
        return Ok(Some(Value::Null));
    }
    let mut binds = member_binds();
    binds.insert("channel_id".into(), DbValue::I64(channel_id));
    let rows = query(
        conn,
        &format!("{SELECT} AND c.channel_id=:channel_id"),
        binds,
    )?;
    let row = rows.first().ok_or(DbError::SchemaNotReady)?;
    Ok(Some(channel_json(row)?))
}

pub(crate) fn execute(
    conn: &oracle::Connection,
    user: u64,
    id: u64,
    change: Change,
) -> Result<Option<Value>, DbError> {
    let tx = OracleTx::new(conn);
    match write(conn, &tx, user, id, change) {
        Ok(Some(channel)) => match tx.commit() {
            Ok(()) => Ok(Some(channel)),
            Err(error) => {
                let _ = tx.rollback();
                Err(error)
            }
        },
        result => {
            tx.rollback()?;
            result
        }
    }
}

fn text(value: &Value, fallback: &str) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Number(number) => number.to_string(),
        Value::Bool(value) => value.to_string(),
        _ => fallback.to_owned(),
    }
}

pub(crate) fn channel_boolean(value: &Value) -> bool {
    match value {
        Value::Bool(value) => *value,
        Value::Number(value) => value.as_f64() == Some(1.0),
        Value::String(value) => {
            value == "1" || value.eq_ignore_ascii_case("true") || value.eq_ignore_ascii_case("yes")
        }
        _ => false,
    }
}

fn parse(body: Value, create: bool) -> Result<Change, ApiError> {
    let body = body
        .as_object()
        .ok_or_else(|| ApiError::bad_request("请求体格式错误"))?;
    let name = match body.get("name") {
        value if value.is_some() || create => {
            let name = text(value.unwrap_or(&Value::Null), "");
            let name = name.trim();
            if name.is_empty() || name.len() > 100 {
                return Err(ApiError::bad_request("name 参数错误"));
            }
            Some(name.to_owned())
        }
        _ => None,
    };
    let category = match body.get("category") {
        value if value.is_some() || create => {
            let mut category = text(value.unwrap_or(&Value::Null), "文字频道");
            if category.is_empty() {
                category = "文字频道".into();
            }
            if category.len() > 50 {
                return Err(ApiError::bad_request("category 参数错误"));
            }
            Some(category)
        }
        _ => None,
    };
    let private = body.get("is_private").map(channel_boolean);
    if create {
        let kind = text(body.get("type").unwrap_or(&Value::Null), "text");
        if !matches!(kind.as_str(), "text" | "announcement" | "voice" | "video") {
            return Err(ApiError::bad_request("type 参数错误"));
        }
        Ok(Change::Create {
            name: name.unwrap_or_default(),
            kind,
            category: category.unwrap_or_else(|| "文字频道".into()),
            private: private.unwrap_or(false),
        })
    } else {
        Ok(Change::Update {
            name,
            category,
            private,
        })
    }
}

async fn route(
    state: NativeState,
    raw: String,
    headers: HeaderMap,
    body: Option<(Body, bool)>,
) -> Response {
    let result = async {
        let (user, id) =
            crate::posts::bookmark::interaction_identity(&state, &raw, &headers).await?;
        let change = match body {
            Some((body, create)) => {
                let raw = to_bytes(body, 1 << 20)
                    .await
                    .map_err(|_| ApiError::bad_request("请求体格式错误"))?;
                let value = serde_json::from_slice(&raw)
                    .map_err(|_| ApiError::bad_request("请求体格式错误"))?;
                parse(value, create)?
            }
            None => Change::Delete,
        };
        let message = match change {
            Change::Create { .. } => "chat channel created",
            Change::Update { .. } => "chat channel updated",
            Change::Delete => "chat channel deleted",
        };
        let channel = state
            .repository
            .write_chat_channel(user, id, change)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?
            .ok_or_else(|| ApiError::forbidden("需要群组管理权限"))?;
        Ok::<_, ApiError>(Json(V2Response::ok_with_message(channel, message)))
    }
    .await;
    let mut response = result.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}

pub(crate) async fn create(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    route(state, raw, headers, Some((body, true))).await
}

pub(crate) async fn update(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    route(state, raw, headers, Some((body, false))).await
}

pub(crate) async fn remove(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
) -> Response {
    route(state, raw, headers, None).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_channel_defaults_and_preserves_patch_omissions() {
        assert!(matches!(parse(json!({"name":" 技术交流 "}), true).unwrap(),
            Change::Create {name, kind, category, private:false}
            if name == "技术交流" && kind == "text" && category == "文字频道"));
        assert!(matches!(
            parse(json!({"is_private":false,"type":"voice"}), false).unwrap(),
            Change::Update {
                name: None,
                category: None,
                private: Some(false)
            }
        ));
        assert!(parse(json!({"name":" "}), true).is_err());
        assert!(parse(json!({"name":"x","type":"invalid"}), true).is_err());
    }
}
