use crate::{
    auth::{
        login::js_trim,
        readiness,
        session_repository::{media_json, row_number, row_text},
        sessions::NativeState,
    },
    db::{
        oracle::{BindMap, DbError},
        tx::{OracleTx, Transaction},
        value::DbValue,
    },
    direct_history::{conversation_id, map_message, normalize_author},
    httpx::{errors::ApiError, response::V2Response},
    media::private_read::{PrivateKey, content_url},
    notification_websocket::MAX_SOCKET_ID,
};
use axum::{
    Json,
    body::{Body, to_bytes},
    extract::{Path, State},
    http::{HeaderMap, HeaderValue, Request, StatusCode, header::CACHE_CONTROL},
    response::{IntoResponse, Response},
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{collections::HashMap, sync::OnceLock};

#[derive(Deserialize)]
pub(crate) struct Contract {
    pub max_media: usize,
    pub max_content_bytes: usize,
    max_emoji_bytes: usize,
    max_emoji_utf16_units: usize,
    pub sql: Sql,
}

#[derive(Deserialize)]
pub(crate) struct Sql {
    asset_lock: String,
    asset_free: String,
    asset_is_linked: String,
    pub insert_media: String,
    query_message: String,
    pub insert_reply: String,
    add_reaction: String,
    remove_reaction: String,
    list_media: String,
    list_replies: String,
    list_reactions: String,
    pub private_media_read: String,
    attachment_table_present: String,
    any_extras_table_present: String,
}

pub(crate) fn contract() -> &'static Contract {
    static CONTRACT: OnceLock<Contract> = OnceLock::new();
    CONTRACT.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../contracts/requirements/direct-message-extras.json"
        ))
        .expect("valid direct message extras contract")
    })
}

pub(crate) fn safe_id(value: &Value) -> Option<i64> {
    value
        .as_f64()
        .filter(|id| *id >= 1.0 && *id <= MAX_SOCKET_ID as f64 && id.fract() == 0.0)
        .map(|id| id as i64)
}

pub(crate) fn require_schema(connection: &oracle::Connection) -> Result<(), DbError> {
    let snapshot = readiness::collect_direct_extras_snapshot(connection)?;
    readiness::validate_feature_snapshot(&snapshot, "direct-message-extras")
        .map_err(|_| DbError::SchemaNotReady)
}

fn oracle_missing_table(error: &DbError) -> bool {
    matches!(error, DbError::Oracle(error) if error.db_error().is_some_and(|error| error.code() == 942))
}

const OWNER_SCHEMA: &str = "SELECT 1 FROM dual WHERE USER=SYS_CONTEXT('USERENV','CURRENT_SCHEMA')";

pub(crate) fn metadata_ready(connection: &oracle::Connection, allow_legacy: bool) -> Result<bool, DbError> {
    if allow_legacy {
        let tx = OracleTx::new(connection);
        if tx.query(&contract().sql.any_extras_table_present, BindMap::new())?.is_empty() {
            if tx.query(OWNER_SCHEMA, BindMap::new())?.is_empty() {
                return Err(DbError::SchemaNotReady);
            }
            return Ok(false);
        }
    }
    require_schema(connection)?;
    Ok(true)
}

fn missing_owned_table(
    tx: &impl Transaction,
    error: &DbError,
    probe: &str,
) -> Result<bool, DbError> {
    Ok(oracle_missing_table(error)
        && tx.query(probe, BindMap::new())?.is_empty()
        && !tx.query(OWNER_SCHEMA, BindMap::new())?.is_empty())
}

pub(crate) fn attachment_table_absent(
    tx: &impl Transaction,
    error: &DbError,
) -> Result<bool, DbError> {
    missing_owned_table(tx, error, &contract().sql.attachment_table_present)
}

pub(crate) fn linked_asset(tx: &impl Transaction, id: DbValue) -> Result<bool, DbError> {
    let binds = BindMap::from([("media_id".into(), id)]);
    match tx.query(&contract().sql.asset_is_linked, binds) {
        Ok(rows) => Ok(!rows.is_empty()),
        Err(error) if attachment_table_absent(tx, &error)? => Ok(false),
        Err(error) => Err(error),
    }
}

pub(crate) fn lock_assets(
    tx: &impl Transaction,
    sender: i64,
    ids: &[i64],
) -> Result<bool, DbError> {
    let sql = &contract().sql;
    let mut ordered_ids = ids.to_vec();
    ordered_ids.sort_unstable();
    for id in ordered_ids {
        let binds = BindMap::from([("media_id".into(), DbValue::I64(id))]);
        let mut owner_binds = binds.clone();
        owner_binds.insert("user_id".into(), DbValue::I64(sender));
        let rows = tx.query(&sql.asset_lock, owner_binds)?;
        let valid = rows
            .first()
            .and_then(|row| row.get("STORAGE_KEY"))
            .and_then(DbValue::as_str)
            .and_then(|key| PrivateKey::new(key, "chat"))
            .is_some();
        if !valid || tx.query(&sql.asset_free, binds)?.is_empty() {
            return Ok(false);
        }
    }
    Ok(true)
}

pub(crate) fn message_exists(
    tx: &impl Transaction,
    conversation: i64,
    message: i64,
) -> Result<bool, DbError> {
    let binds = BindMap::from([
        ("conversation_id".into(), DbValue::I64(conversation)),
        ("message_id".into(), DbValue::I64(message)),
    ]);
    Ok(!tx.query(&contract().sql.query_message, binds)?.is_empty())
}

pub(crate) fn visible_content(content: &str) -> &str {
    if content == " " { "" } else { content }
}

pub(crate) fn enrich(
    tx: &impl Transaction,
    viewer: i64,
    messages: &mut [Value],
) -> Result<(), DbError> {
    if messages.is_empty() {
        return Ok(());
    }
    let by_id: HashMap<_, _> = messages
        .iter()
        .enumerate()
        .map(|(index, value)| {
            let id = safe_id(&value["message_id"]).ok_or(DbError::SchemaNotReady)?;
            Ok((id, index))
        })
        .collect::<Result<_, DbError>>()?;
    let ids: Vec<_> = by_id.keys().copied().collect();
    let binds = BindMap::from([(
        "message_ids".into(),
        DbValue::String(json!(ids).to_string()),
    )]);
    let sql = &contract().sql;
    let media = tx.query(&sql.list_media, binds.clone())?;
    let replies = tx.query(&sql.list_replies, binds.clone())?;
    let mut reaction_binds = binds;
    reaction_binds.insert("viewer_id".into(), DbValue::I64(viewer));
    let reactions = tx.query(&sql.list_reactions, reaction_binds)?;
    for row in media {
        let Some(&index) = by_id.get(&row_number(&row, "MESSAGE_ID")) else {
            continue;
        };
        let url = content_url(row_number(&row, "MEDIA_ID")).ok_or(DbError::SchemaNotReady)?;
        let mut value = media_json(&row);
        value["public_url"] = url.into();
        value["thumbnail_url"] = Value::Null;
        append(&mut messages[index]["media"], value);
    }
    for row in replies {
        let Some(&index) = by_id.get(&row_number(&row, "MESSAGE_ID")) else {
            continue;
        };
        messages[index]["reply_to"] = json!({
            "message_id": row_number(&row, "REPLY_ID"),
            "content": visible_content(&row_text(&row, "REPLY_CONTENT")),
            "author_name": row_text(&row, "REPLY_AUTHOR_NAME"),
        });
    }
    for row in reactions {
        let Some(&index) = by_id.get(&row_number(&row, "MESSAGE_ID")) else {
            continue;
        };
        append(
            &mut messages[index]["reactions"],
            json!({
                "emoji": row_text(&row, "EMOJI"),
                "count": row_number(&row, "REACTION_COUNT"),
                "reacted_by_me": row_number(&row, "REACTED_BY_ME") == 1,
            }),
        );
    }
    Ok(())
}

fn append(field: &mut Value, item: Value) {
    match field {
        Value::Array(items) => items.push(item),
        _ => *field = Value::Array(vec![item]),
    }
}

pub enum Operation {
    Read,
    Reaction { add: bool, emoji: String },
}

pub enum Outcome {
    Forbidden,
    Missing,
    Unavailable,
    Found {
        message: Value,
        notify_peer: Option<u64>,
    },
}

const EXACT: &str = "SELECT dm.message_id,dm.conversation_id,dm.sender_id AS user_id,dm.content,dm.is_deleted,
dm.created_at,dm.updated_at,dm.edited_at,dm.deleted_at,u.username,u.avatar_url,u.display_name,u.bio,u.location,u.website,
u.is_verified,u.followers_count,u.following_count,u.posts_count,u.likes_count,fn_get_user_relationship(:viewer_id,u.user_id) AS relation
FROM n_direct_messages dm JOIN v_user_profile_public u ON u.user_id=dm.sender_id
WHERE dm.conversation_id=:conversation_id AND dm.message_id=:message_id AND dm.is_deleted=0";

pub(crate) fn execute(
    connection: &oracle::Connection,
    viewer: u64,
    conversation: u64,
    id: u64,
    operation: Operation,
) -> Result<Outcome, DbError> {
    let tx = OracleTx::new(connection);
    let result = transact(&tx, viewer, conversation, id, operation, || {
        require_schema(connection)
    });
    match result {
        Ok(outcome @ Outcome::Found { .. }) => {
            if let Err(error) = tx.commit() {
                let _ = tx.rollback();
                return Err(error);
            }
            Ok(outcome)
        }
        other => {
            tx.rollback()?;
            other
        }
    }
}

fn transact(
    tx: &impl Transaction,
    viewer: u64,
    conversation: u64,
    id: u64,
    operation: Operation,
    schema: impl FnOnce() -> Result<(), DbError>,
) -> Result<Outcome, DbError> {
    let viewer = i64::try_from(viewer).map_err(|_| DbError::SchemaNotReady)?;
    let conversation = i64::try_from(conversation).map_err(|_| DbError::SchemaNotReady)?;
    let id = i64::try_from(id).map_err(|_| DbError::SchemaNotReady)?;
    let Some(peer) = crate::direct_send::locked_recipient(tx, viewer, conversation)? else {
        return Ok(Outcome::Forbidden);
    };
    if !message_exists(tx, conversation, id)? {
        return Ok(Outcome::Missing);
    }
    if schema().is_err() {
        return Ok(Outcome::Unavailable);
    }
    let mut notify_peer = None;
    if let Operation::Reaction { add, emoji } = operation {
        let sql = &contract().sql;
        let changed = tx.execute(
            if add {
                &sql.add_reaction
            } else {
                &sql.remove_reaction
            },
            BindMap::from([
                ("message_id".into(), DbValue::I64(id)),
                ("user_id".into(), DbValue::I64(viewer)),
                ("emoji".into(), DbValue::String(emoji)),
            ]),
        )?;
        match changed {
            0 => {}
            1 => notify_peer = Some(peer),
            _ => return Err(DbError::SchemaNotReady),
        }
    }
    let rows = tx.query(
        EXACT,
        BindMap::from([
            ("conversation_id".into(), DbValue::I64(conversation)),
            ("message_id".into(), DbValue::I64(id)),
            ("viewer_id".into(), DbValue::I64(viewer)),
        ]),
    )?;
    let mut message = map_message(rows.first().ok_or(DbError::SchemaNotReady)?, viewer);
    enrich(tx, viewer, std::slice::from_mut(&mut message))?;
    Ok(Outcome::Found {
        message,
        notify_peer,
    })
}

fn parse_emoji(bytes: &[u8]) -> Result<String, ApiError> {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Payload {
        emoji: String,
    }
    let invalid = || ApiError::bad_request("emoji 参数错误");
    let input: Payload = serde_json::from_slice(bytes).map_err(|_| invalid())?;
    let emoji = js_trim(&input.emoji);
    let contract = contract();
    if emoji.is_empty()
        || emoji.len() > contract.max_emoji_bytes
        || emoji.encode_utf16().count() > contract.max_emoji_utf16_units
    {
        return Err(invalid());
    }
    Ok(emoji.to_owned())
}

fn no_store(mut response: Response) -> Response {
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}

async fn handle(
    state: &NativeState,
    path: (String, String),
    headers: &HeaderMap,
    reaction: Option<(bool, Body)>,
) -> Result<Json<V2Response<Value>>, ApiError> {
    let user = crate::posts::bookmark::interaction_actor(state, headers).await?;
    let conversation = conversation_id(&path.0)?;
    let id = conversation_id(&path.1).map_err(|_| ApiError::bad_request("message_id 参数错误"))?;
    let operation = match reaction {
        Some((add, body)) => {
            let bytes = to_bytes(body, 1 << 20)
                .await
                .map_err(|_| ApiError::bad_request("请求体格式错误"))?;
            Operation::Reaction {
                add,
                emoji: parse_emoji(&bytes)?,
            }
        }
        None => Operation::Read,
    };
    let server_error = || ApiError::server_error("服务器内部错误");
    let (mut message, peer) = match state
        .repository
        .direct_message_extras(user, conversation, id, operation)
        .await
        .map_err(|_| server_error())?
    {
        Outcome::Forbidden => return Err(ApiError::forbidden("无权访问该私聊会话")),
        Outcome::Missing => return Err(ApiError::not_found("私信不存在")),
        Outcome::Unavailable => {
            return Err(ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                50301,
                "私信功能暂不可用",
            ));
        }
        Outcome::Found {
            message,
            notify_peer,
        } => (message, notify_peer),
    };
    if let (Some(peer), Some(publisher)) = (peer, &state.notification_publisher) {
        if publisher
            .publish_direct_updated(user, peer, conversation, id)
            .await
            .is_err()
        {
            eprintln!("direct message update delivery unavailable");
        }
    }
    normalize_author(&mut message, &state.storage_urls).map_err(|_| server_error())?;
    Ok(Json(V2Response::ok(message)))
}

pub(crate) async fn get(
    State(state): State<NativeState>,
    Path(path): Path<(String, String)>,
    headers: HeaderMap,
) -> Response {
    no_store(handle(&state, path, &headers, None).await.into_response())
}

pub(crate) async fn react(
    State(state): State<NativeState>,
    Path(path): Path<(String, String)>,
    request: Request<Body>,
) -> Response {
    let (parts, body) = request.into_parts();
    let add = parts.method == axum::http::Method::POST;
    no_store(
        handle(&state, path, &parts.headers, Some((add, body)))
            .await
            .into_response(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::row::DbRow;
    use std::cell::{Cell, RefCell};

    struct ReceiptTx {
        participant: bool,
        live: bool,
        reacted: Cell<bool>,
        writes: Cell<usize>,
    }

    impl Transaction for ReceiptTx {
        fn query(&self, statement: &str, binds: BindMap) -> Result<Vec<DbRow>, DbError> {
            let sql = &contract().sql;
            let rows = if statement.contains("n_direct_conversations")
                && statement.contains("FOR UPDATE")
            {
                assert_eq!(binds["user_id"], DbValue::I64(42));
                assert_eq!(binds["conversation_id"], DbValue::I64(11));
                self.participant
                    .then(|| DbRow::from([("RECIPIENT".into(), DbValue::I64(57))]))
            } else if statement == sql.query_message {
                assert_eq!(binds["conversation_id"], DbValue::I64(11));
                assert_eq!(binds["message_id"], DbValue::I64(12));
                self.live.then(DbRow::new)
            } else if statement == EXACT {
                Some(DbRow::from([
                    ("MESSAGE_ID".into(), DbValue::I64(12)),
                    ("USER_ID".into(), DbValue::I64(57)),
                    ("CONTENT".into(), DbValue::String(" ".into())),
                ]))
            } else if statement == sql.list_media {
                Some(DbRow::from([
                    ("MESSAGE_ID".into(), DbValue::I64(12)),
                    ("MEDIA_ID".into(), DbValue::I64(3)),
                    (
                        "PUBLIC_URL".into(),
                        DbValue::String("private/chat/raw-key".into()),
                    ),
                    (
                        "THUMBNAIL_URL".into(),
                        DbValue::String("private/chat/raw-thumbnail".into()),
                    ),
                ]))
            } else if statement == sql.list_replies {
                Some(DbRow::from([
                    ("MESSAGE_ID".into(), DbValue::I64(12)),
                    ("REPLY_ID".into(), DbValue::I64(10)),
                    ("REPLY_CONTENT".into(), DbValue::String("text".into())),
                    ("REPLY_AUTHOR_NAME".into(), DbValue::String("Alice".into())),
                ]))
            } else {
                assert_eq!(statement, sql.list_reactions);
                assert_eq!(binds["viewer_id"], DbValue::I64(42));
                self.reacted.get().then(|| {
                    DbRow::from([
                        ("MESSAGE_ID".into(), DbValue::I64(12)),
                        ("EMOJI".into(), DbValue::String("🐱".into())),
                        ("REACTION_COUNT".into(), DbValue::I64(1)),
                        ("REACTED_BY_ME".into(), DbValue::I64(1)),
                    ])
                })
            };
            Ok(rows.into_iter().collect())
        }

        fn execute(&self, statement: &str, binds: BindMap) -> Result<u64, DbError> {
            let sql = &contract().sql;
            let add = statement == sql.add_reaction;
            assert!(add || statement == sql.remove_reaction);
            assert_eq!(binds["user_id"], DbValue::I64(42));
            assert_eq!(binds["message_id"], DbValue::I64(12));
            assert_eq!(binds["emoji"], DbValue::String("🐱".into()));
            self.writes.set(self.writes.get() + 1);
            Ok(u64::from(self.reacted.replace(add) != add))
        }

        fn commit(&self) -> Result<(), DbError> {
            unreachable!()
        }
        fn rollback(&self) -> Result<(), DbError> {
            unreachable!()
        }
    }

    #[test]
    fn exact_receipt_uses_current_viewer_without_marking_and_idempotent_changes_only_notify_once() {
        let tx = ReceiptTx {
            participant: true,
            live: true,
            reacted: Cell::new(false),
            writes: Cell::new(0),
        };
        let read = transact(&tx, 42, 11, 12, Operation::Read, || Ok(())).unwrap();
        let Outcome::Found {
            message,
            notify_peer: None,
        } = read
        else {
            panic!("expected exact receipt")
        };
        assert_eq!(message["media"][0]["public_url"], "/api/v2/media/3/content");
        assert!(message["media"][0]["thumbnail_url"].is_null());
        assert_eq!(
            message["reply_to"],
            json!({"message_id":10,"content":"text","author_name":"Alice"})
        );
        assert_eq!(message["content"], "");
        assert_eq!(tx.writes.get(), 0);

        for (add, recipient) in [
            (true, Some(57)),
            (true, None),
            (false, Some(57)),
            (false, None),
        ] {
            let result = transact(
                &tx,
                42,
                11,
                12,
                Operation::Reaction {
                    add,
                    emoji: "🐱".into(),
                },
                || Ok(()),
            )
            .unwrap();
            let Outcome::Found {
                message,
                notify_peer,
            } = result
            else {
                panic!("expected updated receipt")
            };
            assert_eq!(notify_peer, recipient);
            if add {
                assert_eq!(
                    message["reactions"],
                    json!([{"emoji":"🐱","count":1,"reacted_by_me":true}])
                );
            } else {
                assert!(message.get("reactions").is_none());
            }
        }
        assert_eq!(tx.writes.get(), 4);
    }

    #[test]
    fn reaction_denials_do_not_write() {
        for (participant, live) in [(false, true), (true, false), (true, true)] {
            let tx = ReceiptTx {
                participant,
                live,
                reacted: Cell::new(false),
                writes: Cell::new(0),
            };
            let result = transact(
                &tx,
                42,
                11,
                12,
                Operation::Reaction {
                    add: true,
                    emoji: "🐱".into(),
                },
                || Err(DbError::SchemaNotReady),
            )
            .unwrap();
            assert!(match (participant, live) {
                (false, _) => matches!(result, Outcome::Forbidden),
                (_, false) => matches!(result, Outcome::Missing),
                _ => matches!(result, Outcome::Unavailable),
            });
            assert_eq!(tx.writes.get(), 0);
        }
    }

    struct AssetTx {
        free: bool,
        locks: RefCell<Vec<i64>>,
    }

    impl Transaction for AssetTx {
        fn query(&self, sql: &str, binds: BindMap) -> Result<Vec<DbRow>, DbError> {
            let id = match binds["media_id"] {
                DbValue::I64(id) => id,
                _ => panic!("expected media ID"),
            };
            if sql == contract().sql.asset_lock {
                assert_eq!(binds["user_id"], DbValue::I64(42));
                self.locks.borrow_mut().push(id);
                let key = if id == 4 {
                    "public/wrong.png"
                } else {
                    "private/chat/test/image.png"
                };
                Ok(vec![DbRow::from([(
                    "STORAGE_KEY".into(),
                    DbValue::String(key.into()),
                )])])
            } else {
                assert_eq!(sql, contract().sql.asset_free);
                Ok(if self.free {
                    vec![DbRow::new()]
                } else {
                    vec![]
                })
            }
        }
        fn execute(&self, _: &str, _: BindMap) -> Result<u64, DbError> {
            unreachable!()
        }
        fn commit(&self) -> Result<(), DbError> {
            unreachable!()
        }
        fn rollback(&self) -> Result<(), DbError> {
            unreachable!()
        }
    }

    #[test]
    fn assets_require_a_private_chat_key_and_exclusive_link_under_sorted_owner_locks() {
        let tx = AssetTx {
            free: true,
            locks: RefCell::new(vec![]),
        };
        assert!(lock_assets(&tx, 42, &[5, 3]).unwrap());
        assert_eq!(*tx.locks.borrow(), [3, 5]);
        assert!(!lock_assets(&tx, 42, &[4]).unwrap());
        let tx = AssetTx {
            free: false,
            locks: RefCell::new(vec![]),
        };
        assert!(!lock_assets(&tx, 42, &[3]).unwrap());
    }

    #[test]
    fn emoji_parser_trims_and_enforces_both_limits() {
        assert_eq!(parse_emoji(r#"{"emoji":" 🐱 "}"#.as_bytes()).unwrap(), "🐱");
        for emoji in [" ".into(), "a".repeat(17), "中".repeat(11), "🐱".repeat(9)] {
            assert!(parse_emoji(json!({"emoji":emoji}).to_string().as_bytes()).is_err());
        }
        assert!(parse_emoji(br#"{"emoji":"x","user_id":13}"#).is_err());
    }
}
