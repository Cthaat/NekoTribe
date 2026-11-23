use crate::{
    auth::{session_repository::row_number, sessions::NativeState},
    db::{
        oracle::{BindMap, DbError},
        row::DbRow,
        tx::{OracleTx, Transaction},
        value::DbValue,
    },
    direct_extras::{message_exists, safe_id},
    direct_history::conversation_id,
    httpx::{errors::ApiError, response::V2Response},
    notification_websocket::MAX_SOCKET_ID,
};
use axum::{
    Json,
    body::{Body, to_bytes},
    extract::{Path, State},
    http::{HeaderMap, HeaderValue, Request, header::CACHE_CONTROL},
    response::{IntoResponse, Response},
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::sync::OnceLock;

#[derive(Deserialize)]
pub(crate) struct Contract {
    pub typing_min_interval_ms: u64,
    pub sql: Sql,
}

#[derive(Deserialize)]
pub(crate) struct Sql {
    pub direct_typing_peer: String,
    pub direct_read_delivery: String,
    read_status: String,
    advance_read: String,
}

pub(crate) fn contract() -> &'static Contract {
    static CONTRACT: OnceLock<Contract> = OnceLock::new();
    CONTRACT.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../contracts/requirements/chat-realtime-details.json"
        ))
        .expect("valid chat realtime contract")
    })
}

pub struct ReadAdvance {
    pub recipient: u64,
    pub message: u64,
}

pub enum Outcome {
    Forbidden,
    InvalidCursor,
    Found {
        status: Value,
        advance: Option<ReadAdvance>,
    },
}

pub(crate) fn signed_id(id: u64) -> Result<i64, DbError> {
    if (1..=MAX_SOCKET_ID).contains(&id) {
        Ok(id as i64)
    } else {
        Err(DbError::SchemaNotReady)
    }
}

pub(crate) fn actor_binds(user: i64, conversation: i64) -> BindMap {
    BindMap::from([
        ("user_id".into(), DbValue::I64(user)),
        ("conversation_id".into(), DbValue::I64(conversation)),
    ])
}

pub(crate) fn advance(
    tx: &impl Transaction,
    reader: i64,
    conversation: i64,
    message: u64,
) -> Result<bool, DbError> {
    let mut binds = actor_binds(reader, conversation);
    binds.insert(
        "last_read_message_id".into(),
        DbValue::I64(signed_id(message)?),
    );
    match tx.execute(&contract().sql.advance_read, binds)? {
        0 => Ok(false),
        1 => Ok(true),
        _ => Err(DbError::SchemaNotReady),
    }
}

fn map_status(row: &DbRow) -> Value {
    let cursor = |key| {
        u64::try_from(row_number(row, key))
            .ok()
            .filter(|id| (1..=MAX_SOCKET_ID).contains(id))
    };
    json!({
        "conversation_id": row_number(row,"CONVERSATION_ID"),
        "last_read_message_id": cursor("LAST_READ_MESSAGE_ID"),
        "participant_last_read_message_id": cursor("PARTICIPANT_LAST_READ_MESSAGE_ID"),
        "unread_count": row_number(row,"UNREAD_COUNT"),
    })
}

fn transact(
    tx: &impl Transaction,
    user: i64,
    conversation: i64,
    cursor: Option<u64>,
) -> Result<Outcome, DbError> {
    let mut changed = None;
    if let Some(message) = cursor {
        let Some(recipient) = crate::direct_send::locked_recipient(tx, user, conversation)? else {
            return Ok(Outcome::Forbidden);
        };
        if !message_exists(tx, conversation, signed_id(message)?)? {
            return Ok(Outcome::InvalidCursor);
        }
        if advance(tx, user, conversation, message)? {
            changed = Some(ReadAdvance { recipient, message });
        }
    }
    let rows = tx.query(&contract().sql.read_status, actor_binds(user, conversation))?;
    let Some(row) = rows.first() else {
        if cursor.is_some() {
            return Err(DbError::SchemaNotReady);
        }
        return Ok(Outcome::Forbidden);
    };
    Ok(Outcome::Found {
        status: map_status(row),
        advance: changed,
    })
}

pub(crate) fn execute(
    connection: &oracle::Connection,
    user: u64,
    conversation: u64,
    cursor: Option<u64>,
) -> Result<Outcome, DbError> {
    let tx = OracleTx::new(connection);
    let result = transact(&tx, signed_id(user)?, signed_id(conversation)?, cursor);
    if cursor.is_none() {
        return result;
    }
    match result {
        Ok(outcome @ Outcome::Found { .. }) => match tx.commit() {
            Ok(()) => Ok(outcome),
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

pub(crate) async fn publish(
    state: &NativeState,
    reader: u64,
    conversation: u64,
    changed: Option<ReadAdvance>,
) {
    let (Some(changed), Some(publisher)) = (changed, &state.notification_publisher) else {
        return;
    };
    if publisher
        .publish_direct_read(reader, changed.recipient, conversation, changed.message)
        .await
        .is_err()
    {
        eprintln!("direct read delivery unavailable");
    }
}

fn parse_cursor(bytes: &[u8]) -> Result<u64, ApiError> {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Payload {
        last_read_message_id: Value,
    }
    let invalid = || ApiError::bad_request("last_read_message_id 参数错误");
    let input: Payload = serde_json::from_slice(bytes).map_err(|_| invalid())?;
    safe_id(&input.last_read_message_id)
        .map(|id| id as u64)
        .ok_or_else(invalid)
}

async fn handle(
    state: &NativeState,
    path: &str,
    headers: &HeaderMap,
    body: Option<Body>,
) -> Result<Json<V2Response<Value>>, ApiError> {
    let user = crate::posts::bookmark::interaction_actor(state, headers).await?;
    let conversation = conversation_id(path)?;
    let cursor = match body {
        Some(body) => Some(parse_cursor(
            &to_bytes(body, 1 << 20)
                .await
                .map_err(|_| ApiError::bad_request("请求体格式错误"))?,
        )?),
        None => None,
    };
    match state
        .repository
        .direct_read_status(user, conversation, cursor)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?
    {
        Outcome::Forbidden => Err(ApiError::forbidden("无权访问该私聊会话")),
        Outcome::InvalidCursor => Err(ApiError::bad_request("last_read_message_id 参数错误")),
        Outcome::Found { status, advance } => {
            publish(state, user, conversation, advance).await;
            Ok(Json(V2Response::ok(status)))
        }
    }
}

fn no_store(mut response: Response) -> Response {
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}

pub(crate) async fn get(
    State(state): State<NativeState>,
    Path(path): Path<String>,
    headers: HeaderMap,
) -> Response {
    no_store(handle(&state, &path, &headers, None).await.into_response())
}

pub(crate) async fn put(
    State(state): State<NativeState>,
    Path(path): Path<String>,
    request: Request<Body>,
) -> Response {
    let (parts, body) = request.into_parts();
    no_store(
        handle(&state, &path, &parts.headers, Some(body))
            .await
            .into_response(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    struct ReadTx {
        participant: bool,
        valid: bool,
        cursor: Cell<i64>,
        writes: Cell<u32>,
    }

    impl Transaction for ReadTx {
        fn query(&self, statement: &str, binds: BindMap) -> Result<Vec<DbRow>, DbError> {
            assert_eq!(binds["conversation_id"], DbValue::I64(7));
            if statement.contains("FOR UPDATE") {
                assert_eq!(binds["user_id"], DbValue::I64(42));
                return Ok(self
                    .participant
                    .then(|| DbRow::from([("RECIPIENT".into(), DbValue::I64(9))]))
                    .into_iter()
                    .collect());
            }
            if statement == contract().sql.read_status {
                assert_eq!(binds["user_id"], DbValue::I64(42));
                return Ok(self
                    .participant
                    .then(|| {
                        DbRow::from([
                            ("CONVERSATION_ID".into(), DbValue::I64(7)),
                            (
                                "LAST_READ_MESSAGE_ID".into(),
                                DbValue::I64(self.cursor.get()),
                            ),
                            ("UNREAD_COUNT".into(), DbValue::I64(2)),
                        ])
                    })
                    .into_iter()
                    .collect());
            }
            assert!(statement.contains("is_deleted=0"));
            assert!(matches!(binds["message_id"], DbValue::I64(7 | 8 | 9)));
            Ok(self.valid.then(DbRow::new).into_iter().collect())
        }
        fn execute(&self, statement: &str, binds: BindMap) -> Result<u64, DbError> {
            assert_eq!(statement, contract().sql.advance_read);
            assert!(
                statement.contains("WHERE NVL(r.last_read_message_id,0)<s.last_read_message_id")
            );
            let DbValue::I64(cursor) = binds["last_read_message_id"] else {
                panic!("expected bound cursor")
            };
            self.writes.set(self.writes.get() + 1);
            let previous = self.cursor.get();
            self.cursor.set(previous.max(cursor));
            Ok(u64::from(cursor > previous))
        }
        fn commit(&self) -> Result<(), DbError> {
            unreachable!()
        }
        fn rollback(&self) -> Result<(), DbError> {
            unreachable!()
        }
    }

    #[test]
    fn advances_only_when_actor_cursor_increases_and_preserves_current_status() {
        let tx = ReadTx {
            participant: true,
            valid: true,
            cursor: Cell::new(0),
            writes: Cell::new(0),
        };
        let Outcome::Found {
            status,
            advance: None,
        } = transact(&tx, 42, 7, None).unwrap()
        else {
            panic!("expected status")
        };
        assert_eq!(
            status,
            json!({"conversation_id":7,"last_read_message_id":null,"participant_last_read_message_id":null,"unread_count":2})
        );
        assert_eq!(tx.writes.get(), 0);
        for (requested, expected, event) in
            [(8, 8, true), (8, 8, false), (7, 8, false), (9, 9, true)]
        {
            let Outcome::Found { status, advance } = transact(&tx, 42, 7, Some(requested)).unwrap()
            else {
                panic!("expected cursor receipt")
            };
            assert_eq!(status["last_read_message_id"], expected);
            assert_eq!(
                advance.map(|event| (event.recipient, event.message)),
                event.then_some((9, requested))
            );
        }
    }

    #[test]
    fn denies_other_conversations_or_invalid_cursors_before_writing() {
        for participant in [false, true] {
            let tx = ReadTx {
                participant,
                valid: false,
                cursor: Cell::new(0),
                writes: Cell::new(0),
            };
            let outcome = transact(&tx, 42, 7, Some(8)).unwrap();
            assert!(matches!(
                (participant, outcome),
                (false, Outcome::Forbidden) | (true, Outcome::InvalidCursor)
            ));
            assert_eq!(tx.writes.get(), 0);
        }
        for body in [
            r#"{"last_read_message_id":0}"#,
            r#"{"last_read_message_id":"8"}"#,
            r#"{"last_read_message_id":8,"user_id":3}"#,
        ] {
            assert!(parse_cursor(body.as_bytes()).is_err());
        }
    }
}
