use crate::{
    auth::{
        session_repository::{nullable_text, profile_date, row_number, row_text},
        sessions::NativeState,
    },
    db::{
        oracle::{BindMap, DbError},
        row::DbRow,
        tx::OracleTx,
        value::DbValue,
    },
    direct_history::query,
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    extract::{Path, State},
    http::{header::CACHE_CONTROL, HeaderMap, HeaderValue},
    response::{IntoResponse, Response},
    Json,
};
use serde_json::{json, Value};

pub(crate) const MEMBERSHIP: &str =
    "SELECT CASE WHEN gm.role IN ('owner','admin','moderator') THEN 1 ELSE 0 END AS can_manage
FROM n_group_members gm JOIN n_groups g ON g.group_id=gm.group_id
WHERE gm.user_id=:user_id AND gm.group_id=:group_id AND gm.status IN ('active','muted')
AND g.is_active=1 AND g.is_deleted=0";
const COUNT: &str =
    "SELECT COUNT(*) AS total FROM n_chat_channels WHERE group_id=:group_id AND is_deleted=0";
pub(crate) const LOCK: &str = "SELECT owner_id FROM n_groups WHERE group_id=:group_id AND is_active=1 AND is_deleted=0 FOR UPDATE";
const INSERT: &str = "INSERT INTO n_chat_channels
(channel_id,group_id,name,channel_type,category,position,created_by)
VALUES (seq_chat_channel_id.NEXTVAL,:group_id,:name,:channel_type,:category,:position,:created_by)";
pub(crate) const SELECT: &str = "SELECT c.channel_id,c.group_id,c.name,c.channel_type,c.category,c.position,
c.is_private,c.created_at,c.updated_at,CASE WHEN cm.user_id IS NULL THEN 0 ELSE 1 END AS is_muted_by_me,
CASE WHEN gm.role IN ('owner','admin','moderator') THEN 1 ELSE 0 END AS can_manage,
(SELECT COUNT(*) FROM n_chat_messages m
 LEFT JOIN n_chat_channel_reads r ON r.channel_id=c.channel_id AND r.user_id=:user_id
 WHERE m.channel_id=c.channel_id AND m.is_deleted=0 AND m.message_id>NVL(r.last_read_message_id,0)) AS unread_count,
lm.message_id AS last_message_id,lm.content AS last_message_content,
COALESCE(lu.display_name,lu.username) AS last_message_author,lm.created_at AS last_message_at
FROM n_chat_channels c
JOIN n_groups g ON g.group_id=c.group_id AND g.is_active=1 AND g.is_deleted=0
JOIN n_group_members gm ON gm.group_id=c.group_id AND gm.user_id=:user_id AND gm.status IN ('active','muted')
LEFT JOIN n_chat_channel_mutes cm ON cm.channel_id=c.channel_id AND cm.user_id=:user_id
LEFT JOIN n_chat_messages lm ON lm.message_id=c.last_message_id AND lm.channel_id=c.channel_id AND lm.is_deleted=0
LEFT JOIN n_users lu ON lu.user_id=lm.author_id
WHERE c.group_id=:group_id AND c.is_deleted=0 AND (c.is_private=0 OR gm.role IN ('owner','admin','moderator'))";
const ORDER: &str = " ORDER BY c.category ASC,c.position ASC,c.created_at ASC,c.channel_id ASC";

pub(crate) fn channel_json(row: &DbRow) -> Result<Value, DbError> {
    let kind = row_text(row, "CHANNEL_TYPE");
    if !matches!(kind.as_str(), "text" | "announcement" | "voice" | "video") {
        return Err(DbError::SchemaNotReady);
    }
    let date = |key| {
        nullable_text(row, key)
            .map(|value| profile_date(&value))
            .unwrap_or_default()
    };
    let last = row_number(row, "LAST_MESSAGE_ID");
    let preview = (last > 0).then(|| json!({
        "message_id": last, "content": row_text(row, "LAST_MESSAGE_CONTENT"),
        "author_name": row_text(row, "LAST_MESSAGE_AUTHOR"), "created_at": date("LAST_MESSAGE_AT")
    }));
    Ok(json!({
        "channel_id":row_number(row,"CHANNEL_ID"),"group_id":row_number(row,"GROUP_ID"),
        "name":row_text(row,"NAME"),"type":kind,"category":nullable_text(row,"CATEGORY").unwrap_or_else(|| "文字频道".into()),
        "position":row_number(row,"POSITION"),"is_private":row_number(row,"IS_PRIVATE")==1,
        "is_muted_by_me":row_number(row,"IS_MUTED_BY_ME")==1,"unread_count":row_number(row,"UNREAD_COUNT"),
        "last_message":preview,"created_at":date("CREATED_AT"),"updated_at":date("UPDATED_AT"),
        "can_manage":row_number(row,"CAN_MANAGE")==1
    }))
}

fn list_in_transaction(
    user: i64,
    group: i64,
    query_rows: impl Fn(&str, BindMap) -> Result<Vec<DbRow>, DbError>,
    insert: impl Fn(&str, BindMap) -> Result<u64, DbError>,
) -> Result<Option<Vec<Value>>, DbError> {
    let group_binds = || BindMap::from([("group_id".into(), DbValue::I64(group))]);
    let member_binds = || {
        let mut binds = group_binds();
        binds.insert("user_id".into(), DbValue::I64(user));
        binds
    };
    let member = || Ok::<_, DbError>(!query_rows(MEMBERSHIP, member_binds())?.is_empty());
    let count = || {
        query_rows(COUNT, group_binds())?
            .first()
            .and_then(|row| row.get("TOTAL"))
            .and_then(DbValue::as_i64)
            .ok_or(DbError::SchemaNotReady)
    };
    if !member()? {
        return Ok(None);
    }
    if count()? == 0 {
        let groups = query_rows(LOCK, group_binds())?;
        let Some(owner) = groups.first() else {
            return Ok(None);
        };
        if !member()? {
            return Ok(None);
        }
        if count()? == 0 {
            for (name, kind, category, position) in [
                ("公告板", "announcement", "公告", 10),
                ("综合讨论", "text", "文字频道", 20),
            ] {
                let mut binds = group_binds();
                binds.extend([
                    ("name".into(), DbValue::String(name.into())),
                    ("channel_type".into(), DbValue::String(kind.into())),
                    ("category".into(), DbValue::String(category.into())),
                    ("position".into(), DbValue::I64(position)),
                    (
                        "created_by".into(),
                        DbValue::I64(row_number(owner, "OWNER_ID")),
                    ),
                ]);
                if insert(INSERT, binds)? != 1 {
                    return Err(DbError::SchemaNotReady);
                }
            }
        }
    }
    let rows = query_rows(&format!("{SELECT}{ORDER}"), member_binds())?;
    if rows.is_empty() && !member()? {
        return Ok(None);
    }
    Ok(Some(
        rows.iter().map(channel_json).collect::<Result<_, _>>()?,
    ))
}

pub(crate) fn execute(
    connection: &oracle::Connection,
    user: u64,
    group: u64,
) -> Result<Option<Vec<Value>>, DbError> {
    let user = i64::try_from(user).map_err(|_| DbError::SchemaNotReady)?;
    let group = i64::try_from(group).map_err(|_| DbError::SchemaNotReady)?;
    let tx = OracleTx::new(connection);
    let result = list_in_transaction(
        user,
        group,
        |sql, binds| query(connection, sql, binds),
        |sql, binds| Ok(tx.execute(sql, binds)?.rows_affected),
    );
    match result {
        Ok(Some(items)) => match tx.commit() {
            Ok(()) => Ok(Some(items)),
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

pub(crate) async fn list(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
) -> Response {
    let result = async {
        let (user, group) =
            crate::posts::bookmark::interaction_identity(&state, &raw, &headers).await?;
        let items = state
            .repository
            .list_chat_channels(user, group)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?
            .ok_or_else(|| ApiError::forbidden("无权访问该群组聊天"))?;
        Ok::<_, ApiError>(Json(V2Response::ok(items)))
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
    use std::cell::Cell;

    #[test]
    fn denied_member_never_reaches_initialization() {
        let result = list_in_transaction(
            42,
            7,
            |sql, binds| {
                assert_eq!(sql, MEMBERSHIP);
                assert_eq!(binds["user_id"], DbValue::I64(42));
                Ok(vec![])
            },
            |_, _| panic!("unexpected write"),
        )
        .unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn default_initialization_recounts_after_lock_and_propagates_second_insert_failure() {
        for (concurrent, fail_second, expected_writes) in
            [(true, false, 0), (false, false, 2), (false, true, 2)]
        {
            let counts = Cell::new(0);
            let writes = Cell::new(0);
            let locked = Cell::new(false);
            let outcome = list_in_transaction(
                42,
                7,
                |sql, binds| {
                    assert_eq!(binds["group_id"], DbValue::I64(7));
                    Ok(match sql {
                        MEMBERSHIP => vec![DbRow::new()],
                        COUNT => {
                            counts.set(counts.get() + 1);
                            vec![DbRow::from([(
                                "TOTAL".into(),
                                DbValue::I64(if concurrent && locked.get() { 2 } else { 0 }),
                            )])]
                        }
                        LOCK => {
                            locked.set(true);
                            vec![DbRow::from([("OWNER_ID".into(), DbValue::I64(9))])]
                        }
                        sql if sql == format!("{SELECT}{ORDER}") => vec![DbRow::from([(
                            "CHANNEL_TYPE".into(),
                            DbValue::String("text".into()),
                        )])],
                        _ => panic!("unexpected query"),
                    })
                },
                |sql, binds| {
                    assert!(locked.get());
                    assert_eq!(sql, INSERT);
                    assert_eq!(binds["created_by"], DbValue::I64(9));
                    writes.set(writes.get() + 1);
                    if fail_second && writes.get() == 2 {
                        return Err(DbError::SchemaNotReady);
                    }
                    Ok(1)
                },
            );
            assert_eq!(counts.get(), 2);
            assert_eq!(writes.get(), expected_writes);
            if fail_second {
                assert!(outcome.is_err());
            } else {
                let items = outcome.unwrap().unwrap();
                assert_eq!(items[0]["last_message"], Value::Null);
                assert_eq!(items[0]["category"], "文字频道");
            }
        }
    }
}
