//! Internal conversation persistence. Callers must authenticate the actor first.
use crate::{
    auth::{
        login::js_trim,
        readiness,
        session_repository::{nullable_text, profile_date, row_number, row_text},
    },
    db::{
        oracle::{bind_refs, bind_values, BindMap},
        row::oracle_row_to_db_row,
        tx::OracleTx,
        value::DbValue,
    },
};
use std::collections::HashSet;

const MAX_SAFE_ID: i64 = 9_007_199_254_740_991;
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    Invalid,
    NotFound,
    Forbidden,
    SchemaUnavailable,
    Store,
}
#[derive(Debug, Clone)]
pub struct Input {
    pub purpose: String,
    pub group_id: Option<i64>,
    pub title: String,
}
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct Record {
    #[serde(rename = "conversation_id")]
    pub id: String,
    pub purpose: String,
    pub group_id: Option<i64>,
    pub title: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct UserMessage {
    pub message_id: String,
    pub conversation_id: String,
    pub sequence_no: i64,
    pub role: &'static str,
}
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct HistoryMessage {
    pub message_id: String,
    pub conversation_id: String,
    pub sequence_no: i64,
    pub role: String,
    pub content: String,
    pub model_id: Option<String>,
    pub model_version: Option<String>,
    pub config_revision: Option<i64>,
    pub created_at: String,
}
#[derive(Clone)]
pub struct ModerationPolicy {
    allow_all: bool,
    accounts: HashSet<String>,
}
#[derive(Clone)]
pub enum AiOperation {
    Create(Input),
    Read(String),
    Append { id: String, content: String },
    List { id: String, after: i64, limit: i64 },
}
pub fn execute_operation(
    connection: &oracle::Connection,
    user: u64,
    operation: AiOperation,
    policy: &ModerationPolicy,
) -> Result<serde_json::Value, Error> {
    let user = i64::try_from(user).map_err(|_| Error::Invalid)?;
    match operation {
        AiOperation::Create(input) => {
            serde_json::to_value(create(connection, user, input, policy)?)
        }
        AiOperation::Read(id) => serde_json::to_value(read(connection, user, &id, policy)?),
        AiOperation::Append { id, content } => serde_json::to_value(append_user_message(
            connection, user, &id, &content, policy,
        )?),
        AiOperation::List { id, after, limit } => {
            serde_json::to_value(list_messages(connection, user, &id, after, limit, policy)?)
        }
    }
    .map_err(|_| Error::Store)
}
impl ModerationPolicy {
    pub fn new(allow_all: &str, accounts: &str) -> Self {
        let allow_all = matches!(
            js_trim(allow_all).to_lowercase().as_str(),
            "1" | "true" | "yes" | "on"
        );
        let mut accounts: HashSet<_> = accounts
            .split(',')
            .map(|s| js_trim(s).to_lowercase())
            .filter(|s| !s.is_empty())
            .collect();
        if accounts.is_empty() {
            accounts.insert("v2_admin".into());
        }
        Self {
            allow_all,
            accounts,
        }
    }
}
pub(crate) fn validate(mut input: Input) -> Result<Input, Error> {
    match (input.purpose.as_str(), input.group_id) {
        ("group", Some(id)) if (1..=MAX_SAFE_ID).contains(&id) => {}
        ("knowledge" | "writing" | "moderation", None) => {}
        _ => return Err(Error::Invalid),
    }
    input.title = js_trim(&input.title).to_owned();
    if input.title.encode_utf16().count() > 200 {
        return Err(Error::Invalid);
    }
    Ok(input)
}
pub(crate) fn valid_uuid(id: &str) -> bool {
    id.len() == 36
        && uuid::Uuid::parse_str(id).is_ok_and(|u| {
            u.get_version_num() == 4
                && u.get_variant() == uuid::Variant::RFC4122
                && u.hyphenated().to_string().eq_ignore_ascii_case(id)
        })
}
trait Transaction {
    fn check_schema(&self) -> Result<(), Error>;
    fn authorize(&self, user: i64, input: &Input, policy: &ModerationPolicy) -> Result<(), Error>;
    fn insert(&self, user: i64, id: &str, input: &Input) -> Result<(), Error>;
    fn read(&self, user: i64, id: &str) -> Result<Option<Record>, Error>;
    fn commit(&self) -> Result<(), Error>;
    fn rollback(&self) -> Result<(), Error>;
}
trait MessageTransaction: Transaction {
    fn read_locked(&self, user: i64, id: &str) -> Result<Option<Record>, Error>;
    fn next_sequence(&self, id: &str) -> Result<i64, Error>;
    fn insert_message(
        &self,
        id: &str,
        message_id: &str,
        sequence: i64,
        content: &str,
    ) -> Result<(), Error>;
    fn touch(&self, user: i64, id: &str) -> Result<(), Error>;
}
trait HistoryTransaction: Transaction {
    fn messages(
        &self,
        user: i64,
        id: &str,
        after: i64,
        limit: i64,
    ) -> Result<Vec<HistoryMessage>, Error>;
}
fn run_history(
    tx: &impl HistoryTransaction,
    user: i64,
    id: &str,
    after: i64,
    limit: i64,
    policy: &ModerationPolicy,
) -> Result<Vec<HistoryMessage>, Error> {
    if !(1..=MAX_SAFE_ID).contains(&user)
        || !(0..=9_999_999_999).contains(&after)
        || !(1..=50).contains(&limit)
    {
        return Err(Error::Invalid);
    }
    if !valid_uuid(id) {
        return Err(Error::NotFound);
    }
    tx.check_schema()?;
    let check_access = || {
        let record = tx.read(user, id)?.ok_or(Error::NotFound)?;
        let scope = validate(Input {
            purpose: record.purpose,
            group_id: record.group_id,
            title: String::new(),
        })
        .map_err(|_| Error::Store)?;
        tx.authorize(user, &scope, policy)
    };
    let result = (|| {
        check_access()?;
        let messages = tx.messages(user, id, after, limit)?;
        check_access()?;
        Ok(messages)
    })();
    match result {
        Ok(messages) => {
            tx.commit()?;
            Ok(messages)
        }
        Err(error) => {
            tx.rollback()?;
            Err(error)
        }
    }
}
fn run_append(
    tx: &impl MessageTransaction,
    user: i64,
    id: &str,
    content: &str,
    policy: &ModerationPolicy,
) -> Result<UserMessage, Error> {
    if !(1..=MAX_SAFE_ID).contains(&user) {
        return Err(Error::Invalid);
    }
    if !valid_uuid(id) {
        return Err(Error::NotFound);
    }
    if content.is_empty() || content.len() > 65536 {
        return Err(Error::Invalid);
    }
    tx.check_schema()?;
    let result = (|| {
        let record = tx.read_locked(user, id)?.ok_or(Error::NotFound)?;
        let scope = validate(Input {
            purpose: record.purpose,
            group_id: record.group_id,
            title: String::new(),
        })
        .map_err(|_| Error::Store)?;
        tx.authorize(user, &scope, policy)?;
        let sequence = tx.next_sequence(id)?;
        if !(1..=9_999_999_999).contains(&sequence) {
            return Err(Error::Store);
        }
        let message_id = uuid::Uuid::new_v4().to_string();
        tx.insert_message(id, &message_id, sequence, content)?;
        tx.touch(user, id)?;
        tx.authorize(user, &scope, policy)?;
        Ok(UserMessage {
            message_id,
            conversation_id: id.to_owned(),
            sequence_no: sequence,
            role: "user",
        })
    })();
    match result {
        Ok(message) => {
            tx.commit()?;
            Ok(message)
        }
        Err(error) => {
            tx.rollback()?;
            Err(error)
        }
    }
}
fn run(
    tx: &impl Transaction,
    user: i64,
    id: &str,
    input: Option<Input>,
    policy: &ModerationPolicy,
) -> Result<Record, Error> {
    if !(1..=MAX_SAFE_ID).contains(&user) {
        return Err(Error::Invalid);
    }
    if !valid_uuid(id) {
        return Err(Error::NotFound);
    }
    let input = input.map(validate).transpose()?;
    tx.check_schema()?;
    let result = (|| {
        if let Some(ref input) = input {
            tx.authorize(user, input, policy)?;
            tx.insert(user, id, input)?;
        }
        let record = tx.read(user, id)?.ok_or(Error::NotFound)?;
        let scope = validate(Input {
            purpose: record.purpose.clone(),
            group_id: record.group_id,
            title: String::new(),
        })
        .map_err(|_| Error::Store)?;
        tx.authorize(user, &scope, policy)?;
        Ok(record)
    })();
    match result {
        Ok(record) => {
            tx.commit()?;
            Ok(record)
        }
        Err(error) => {
            tx.rollback()?;
            Err(error)
        }
    }
}

struct OracleConversation<'a>(&'a oracle::Connection);
impl Transaction for OracleConversation<'_> {
    fn check_schema(&self) -> Result<(), Error> {
        let snapshot = readiness::collect_ai_conversation_snapshot(self.0)
            .map_err(|_| Error::SchemaUnavailable)?;
        readiness::validate_feature_snapshot(&snapshot, "ai-conversations")
            .map_err(|_| Error::SchemaUnavailable)
    }
    fn authorize(&self, user: i64, input: &Input, policy: &ModerationPolicy) -> Result<(), Error> {
        match input.purpose.as_str() {
            "group" => {
                let values = bind_values(BindMap::from([
                    ("user_id".into(), DbValue::I64(user)),
                    (
                        "group_id".into(),
                        DbValue::I64(input.group_id.ok_or(Error::Store)?),
                    ),
                    ("role".into(), DbValue::String("admin".into())),
                ]));
                let allowed = self.0.query_row_as_named::<Option<i64>>("SELECT fn_has_group_permission(:user_id,:group_id,:role) AS allowed FROM dual", &bind_refs(&values)).map_err(|_| Error::Store)?;
                if allowed != Some(1) {
                    return Err(Error::Forbidden);
                }
            }
            "moderation" if !policy.allow_all => {
                let values = bind_values(BindMap::from([("user_id".into(), DbValue::I64(user))]));
                let mut rows = self.0.query_named("SELECT username,email FROM n_users WHERE user_id=:user_id AND is_active=1 AND status='active'", &bind_refs(&values)).map_err(|_| Error::Store)?;
                let row = rows
                    .next()
                    .transpose()
                    .map_err(|_| Error::Store)?
                    .ok_or(Error::Forbidden)?;
                let row = oracle_row_to_db_row(&row).map_err(|_| Error::Store)?;
                if !policy
                    .accounts
                    .contains(&row_text(&row, "USERNAME").to_lowercase())
                    && !policy
                        .accounts
                        .contains(&row_text(&row, "EMAIL").to_lowercase())
                {
                    return Err(Error::Forbidden);
                }
            }
            _ => {}
        }
        Ok(())
    }
    fn insert(&self, user: i64, id: &str, input: &Input) -> Result<(), Error> {
        let binds = BindMap::from([
            ("conversation_id".into(), DbValue::String(id.into())),
            ("owner_user_id".into(), DbValue::I64(user)),
            ("purpose".into(), DbValue::String(input.purpose.clone())),
            (
                "group_id".into(),
                input.group_id.map(DbValue::I64).unwrap_or(DbValue::Null),
            ),
            (
                "title".into(),
                if input.title.is_empty() {
                    DbValue::Null
                } else {
                    DbValue::String(input.title.clone())
                },
            ),
        ]);
        let result = OracleTx::new(self.0).execute("INSERT INTO n_ai_conversations (conversation_id,owner_user_id,purpose,group_id,title) VALUES (:conversation_id,:owner_user_id,:purpose,:group_id,:title)", binds).map_err(|_| Error::Store)?;
        if result.rows_affected != 1 {
            return Err(Error::Store);
        }
        Ok(())
    }
    fn read(&self, user: i64, id: &str) -> Result<Option<Record>, Error> {
        self.read_owned(user, id, false)
    }
    fn commit(&self) -> Result<(), Error> {
        OracleTx::new(self.0).commit().map_err(|_| Error::Store)
    }
    fn rollback(&self) -> Result<(), Error> {
        OracleTx::new(self.0).rollback().map_err(|_| Error::Store)
    }
}
impl OracleConversation<'_> {
    fn read_owned(&self, user: i64, id: &str, lock: bool) -> Result<Option<Record>, Error> {
        let values = bind_values(BindMap::from([
            ("conversation_id".into(), DbValue::String(id.into())),
            ("owner_user_id".into(), DbValue::I64(user)),
        ]));
        let query = if lock {
            "SELECT conversation_id,purpose,group_id,title,created_at,updated_at FROM n_ai_conversations WHERE conversation_id=:conversation_id AND owner_user_id=:owner_user_id FOR UPDATE"
        } else {
            "SELECT conversation_id,purpose,group_id,title,created_at,updated_at FROM n_ai_conversations WHERE conversation_id=:conversation_id AND owner_user_id=:owner_user_id"
        };
        let mut rows = self
            .0
            .query_named(query, &bind_refs(&values))
            .map_err(|_| Error::Store)?;
        let Some(row) = rows.next().transpose().map_err(|_| Error::Store)? else {
            return Ok(None);
        };
        let row = oracle_row_to_db_row(&row).map_err(|_| Error::Store)?;
        if rows.next().is_some() {
            return Err(Error::Store);
        }
        let group_id = nullable_text(&row, "GROUP_ID").map(|_| row_number(&row, "GROUP_ID"));
        Ok(Some(Record {
            id: row_text(&row, "CONVERSATION_ID"),
            purpose: row_text(&row, "PURPOSE"),
            group_id,
            title: nullable_text(&row, "TITLE"),
            created_at: nullable_text(&row, "CREATED_AT")
                .map(|s| profile_date(&s))
                .unwrap_or_default(),
            updated_at: nullable_text(&row, "UPDATED_AT")
                .map(|s| profile_date(&s))
                .unwrap_or_default(),
        }))
    }
}
impl MessageTransaction for OracleConversation<'_> {
    fn read_locked(&self, user: i64, id: &str) -> Result<Option<Record>, Error> {
        self.read_owned(user, id, true)
    }
    fn next_sequence(&self, id: &str) -> Result<i64, Error> {
        let values = bind_values(BindMap::from([(
            "conversation_id".into(),
            DbValue::String(id.into()),
        )]));
        self.0.query_row_as_named::<i64>("SELECT NVL(MAX(sequence_no),0)+1 AS next_sequence FROM n_ai_messages WHERE conversation_id=:conversation_id", &bind_refs(&values)).map_err(|_| Error::Store)
    }
    fn insert_message(
        &self,
        id: &str,
        message_id: &str,
        sequence: i64,
        content: &str,
    ) -> Result<(), Error> {
        use oracle::sql_type::{Clob, ToSql};
        use std::io::Write;
        let mut clob = Clob::new(self.0).map_err(|_| Error::Store)?;
        clob.write_all(content.as_bytes())
            .map_err(|_| Error::Store)?;
        let binds: &[(&str, &dyn ToSql)] = &[
            ("message_id", &message_id),
            ("conversation_id", &id),
            ("sequence_no", &sequence),
            ("content", &clob),
        ];
        let result = self.0.execute_named("INSERT INTO n_ai_messages (message_id,conversation_id,sequence_no,role,content) VALUES (:message_id,:conversation_id,:sequence_no,'user',:content)", binds).map_err(|_| Error::Store)?;
        if result.row_count().map_err(|_| Error::Store)? != 1 {
            return Err(Error::Store);
        }
        Ok(())
    }
    fn touch(&self, user: i64, id: &str) -> Result<(), Error> {
        let binds = BindMap::from([
            ("conversation_id".into(), DbValue::String(id.into())),
            ("owner_user_id".into(), DbValue::I64(user)),
        ]);
        let result = OracleTx::new(self.0).execute("UPDATE n_ai_conversations SET updated_at=CURRENT_TIMESTAMP WHERE conversation_id=:conversation_id AND owner_user_id=:owner_user_id", binds).map_err(|_| Error::Store)?;
        if result.rows_affected != 1 {
            return Err(Error::Store);
        }
        Ok(())
    }
}
impl HistoryTransaction for OracleConversation<'_> {
    fn messages(
        &self,
        user: i64,
        id: &str,
        after: i64,
        limit: i64,
    ) -> Result<Vec<HistoryMessage>, Error> {
        let values = bind_values(BindMap::from([
            ("conversation_id".into(), DbValue::String(id.into())),
            ("owner_user_id".into(), DbValue::I64(user)),
            ("after_sequence".into(), DbValue::I64(after)),
            ("row_limit".into(), DbValue::I64(limit)),
        ]));
        let rows = self.0.query_named("SELECT m.message_id,m.conversation_id,m.sequence_no,m.role,m.content,m.model_id,m.model_version,m.config_revision,m.created_at FROM n_ai_messages m JOIN n_ai_conversations c ON c.conversation_id=m.conversation_id WHERE m.conversation_id=:conversation_id AND c.owner_user_id=:owner_user_id AND m.sequence_no>:after_sequence ORDER BY m.sequence_no ASC FETCH FIRST :row_limit ROWS ONLY", &bind_refs(&values)).map_err(|_| Error::Store)?;
        rows.map(|row| {
            let row =
                oracle_row_to_db_row(&row.map_err(|_| Error::Store)?).map_err(|_| Error::Store)?;
            let content = row
                .get("CONTENT")
                .and_then(DbValue::as_str)
                .ok_or(Error::Store)?
                .to_owned();
            let revision =
                nullable_text(&row, "CONFIG_REVISION").map(|_| row_number(&row, "CONFIG_REVISION"));
            Ok(HistoryMessage {
                message_id: row_text(&row, "MESSAGE_ID"),
                conversation_id: row_text(&row, "CONVERSATION_ID"),
                sequence_no: row_number(&row, "SEQUENCE_NO"),
                role: row_text(&row, "ROLE"),
                content,
                model_id: nullable_text(&row, "MODEL_ID"),
                model_version: nullable_text(&row, "MODEL_VERSION"),
                config_revision: revision,
                created_at: nullable_text(&row, "CREATED_AT")
                    .map(|s| profile_date(&s))
                    .unwrap_or_default(),
            })
        })
        .collect()
    }
}
pub fn create(
    connection: &oracle::Connection,
    user: i64,
    input: Input,
    policy: &ModerationPolicy,
) -> Result<Record, Error> {
    run(
        &OracleConversation(connection),
        user,
        &uuid::Uuid::new_v4().to_string(),
        Some(input),
        policy,
    )
}
pub fn read(
    connection: &oracle::Connection,
    user: i64,
    id: &str,
    policy: &ModerationPolicy,
) -> Result<Record, Error> {
    run(&OracleConversation(connection), user, id, None, policy)
}
/// The caller must authenticate the actor and supply a trusted moderation policy.
pub fn append_user_message(
    connection: &oracle::Connection,
    user: i64,
    id: &str,
    content: &str,
    policy: &ModerationPolicy,
) -> Result<UserMessage, Error> {
    run_append(&OracleConversation(connection), user, id, content, policy)
}
/// The caller must authenticate the actor and supply a trusted moderation policy.
pub fn list_messages(
    connection: &oracle::Connection,
    user: i64,
    id: &str,
    after: i64,
    limit: i64,
    policy: &ModerationPolicy,
) -> Result<Vec<HistoryMessage>, Error> {
    run_history(
        &OracleConversation(connection),
        user,
        id,
        after,
        limit,
        policy,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::{Cell, RefCell};

    struct Fake {
        events: RefCell<Vec<&'static str>>,
        checks: Cell<u32>,
        revoked: bool,
    }
    impl Transaction for Fake {
        fn check_schema(&self) -> Result<(), Error> {
            self.events.borrow_mut().push("schema");
            Ok(())
        }
        fn authorize(&self, _: i64, _: &Input, _: &ModerationPolicy) -> Result<(), Error> {
            self.events.borrow_mut().push("authorize");
            self.checks.set(self.checks.get() + 1);
            if self.revoked && self.checks.get() > 1 {
                Err(Error::Forbidden)
            } else {
                Ok(())
            }
        }
        fn insert(&self, _: i64, _: &str, _: &Input) -> Result<(), Error> {
            self.events.borrow_mut().push("insert");
            Ok(())
        }
        fn read(&self, _: i64, id: &str) -> Result<Option<Record>, Error> {
            self.events.borrow_mut().push("read");
            Ok(Some(Record {
                id: id.into(),
                purpose: "group".into(),
                group_id: Some(12),
                title: None,
                created_at: String::new(),
                updated_at: String::new(),
            }))
        }
        fn commit(&self) -> Result<(), Error> {
            self.events.borrow_mut().push("commit");
            Ok(())
        }
        fn rollback(&self) -> Result<(), Error> {
            self.events.borrow_mut().push("rollback");
            Ok(())
        }
    }
    impl MessageTransaction for Fake {
        fn read_locked(&self, user: i64, id: &str) -> Result<Option<Record>, Error> {
            self.events.borrow_mut().push("lock");
            self.read(user, id)
        }
        fn next_sequence(&self, _: &str) -> Result<i64, Error> {
            self.events.borrow_mut().push("sequence");
            Ok(1)
        }
        fn insert_message(&self, _: &str, _: &str, _: i64, _: &str) -> Result<(), Error> {
            self.events.borrow_mut().push("message");
            Ok(())
        }
        fn touch(&self, _: i64, _: &str) -> Result<(), Error> {
            self.events.borrow_mut().push("touch");
            Ok(())
        }
    }
    impl HistoryTransaction for Fake {
        fn messages(
            &self,
            _: i64,
            id: &str,
            after: i64,
            limit: i64,
        ) -> Result<Vec<HistoryMessage>, Error> {
            self.events.borrow_mut().push("messages");
            assert_eq!((after, limit), (1, 10));
            Ok(vec![HistoryMessage {
                message_id: "message".into(),
                conversation_id: id.into(),
                sequence_no: 2,
                role: "user".into(),
                content: "第二条".into(),
                model_id: None,
                model_version: None,
                config_revision: None,
                created_at: String::new(),
            }])
        }
    }
    #[test]
    fn history_rechecks_group_permission_before_returning_messages() {
        let tx = Fake {
            events: RefCell::new(vec![]),
            checks: Cell::new(0),
            revoked: true,
        };
        assert_eq!(
            run_history(
                &tx,
                1,
                "af9da41c-7296-4f51-91f4-141f5c6e3c01",
                1,
                10,
                &ModerationPolicy::new("", "")
            ),
            Err(Error::Forbidden)
        );
        assert_eq!(
            *tx.events.borrow(),
            vec![
                "schema",
                "read",
                "authorize",
                "messages",
                "read",
                "authorize",
                "rollback"
            ]
        );
    }
    #[test]
    fn history_returns_ordered_content_and_rejects_invalid_page() {
        let tx = Fake {
            events: RefCell::new(vec![]),
            checks: Cell::new(0),
            revoked: false,
        };
        let id = "af9da41c-7296-4f51-91f4-141f5c6e3c01";
        assert_eq!(
            run_history(&tx, 1, id, -1, 10, &ModerationPolicy::new("", "")),
            Err(Error::Invalid)
        );
        assert!(tx.events.borrow().is_empty());
        let result = run_history(&tx, 1, id, 1, 10, &ModerationPolicy::new("", "")).unwrap();
        assert_eq!(
            (result[0].sequence_no, result[0].content.as_str()),
            (2, "第二条")
        );
        assert_eq!(
            *tx.events.borrow(),
            vec![
                "schema",
                "read",
                "authorize",
                "messages",
                "read",
                "authorize",
                "commit"
            ]
        );
    }
    #[test]
    fn user_message_rechecks_group_permission_before_commit() {
        let tx = Fake {
            events: RefCell::new(vec![]),
            checks: Cell::new(0),
            revoked: true,
        };
        assert_eq!(
            run_append(
                &tx,
                1,
                "af9da41c-7296-4f51-91f4-141f5c6e3c01",
                "hello",
                &ModerationPolicy::new("", "")
            ),
            Err(Error::Forbidden)
        );
        assert_eq!(
            *tx.events.borrow(),
            vec![
                "schema",
                "lock",
                "read",
                "authorize",
                "sequence",
                "message",
                "touch",
                "authorize",
                "rollback"
            ]
        );
    }
    #[test]
    fn user_message_checks_utf8_length_before_touching_database() {
        let tx = Fake {
            events: RefCell::new(vec![]),
            checks: Cell::new(0),
            revoked: false,
        };
        let id = "af9da41c-7296-4f51-91f4-141f5c6e3c01";
        assert_eq!(
            run_append(
                &tx,
                1,
                id,
                &"猫".repeat(21846),
                &ModerationPolicy::new("", "")
            ),
            Err(Error::Invalid)
        );
        assert!(tx.events.borrow().is_empty());
    }
    #[test]
    fn user_message_commits_after_lock_and_permission_recheck() {
        let tx = Fake {
            events: RefCell::new(vec![]),
            checks: Cell::new(0),
            revoked: false,
        };
        let id = "af9da41c-7296-4f51-91f4-141f5c6e3c01";
        let result = run_append(
            &tx,
            1,
            id,
            &"x".repeat(65536),
            &ModerationPolicy::new("", ""),
        )
        .unwrap();
        assert_eq!(result.sequence_no, 1);
        assert_eq!(result.role, "user");
        assert_eq!(result.conversation_id, id);
        assert!(valid_uuid(&result.message_id));
        assert_eq!(
            *tx.events.borrow(),
            vec![
                "schema",
                "lock",
                "read",
                "authorize",
                "sequence",
                "message",
                "touch",
                "authorize",
                "commit"
            ]
        );
    }
    #[test]
    fn revoked_group_permission_rolls_back_before_commit() {
        let tx = Fake {
            events: RefCell::new(vec![]),
            checks: Cell::new(0),
            revoked: true,
        };
        let input = Input {
            purpose: "group".into(),
            group_id: Some(12),
            title: "hello".into(),
        };
        assert_eq!(
            run(
                &tx,
                1,
                "af9da41c-7296-4f51-91f4-141f5c6e3c01",
                Some(input),
                &ModerationPolicy::new("", "")
            ),
            Err(Error::Forbidden)
        );
        assert_eq!(
            *tx.events.borrow(),
            vec![
                "schema",
                "authorize",
                "insert",
                "read",
                "authorize",
                "rollback"
            ]
        );
    }
    #[test]
    fn group_creation_checks_permission_twice_before_commit() {
        let tx = Fake {
            events: RefCell::new(vec![]),
            checks: Cell::new(0),
            revoked: false,
        };
        let input = Input {
            purpose: "group".into(),
            group_id: Some(12),
            title: "hello".into(),
        };
        assert!(run(
            &tx,
            1,
            "af9da41c-7296-4f51-91f4-141f5c6e3c01",
            Some(input),
            &ModerationPolicy::new("", "")
        )
        .is_ok());
        assert_eq!(
            *tx.events.borrow(),
            vec![
                "schema",
                "authorize",
                "insert",
                "read",
                "authorize",
                "commit"
            ]
        );
    }
    #[test]
    fn malformed_inputs_never_reach_storage() {
        let tx = Fake {
            events: RefCell::new(vec![]),
            checks: Cell::new(0),
            revoked: false,
        };
        let policy = ModerationPolicy::new("", "");
        let input = Input {
            purpose: "group".into(),
            group_id: None,
            title: "".into(),
        };
        assert_eq!(
            run(
                &tx,
                1,
                "af9da41c-7296-4f51-91f4-141f5c6e3c01",
                Some(input),
                &policy
            ),
            Err(Error::Invalid)
        );
        assert_eq!(run(&tx, 1, "invalid", None, &policy), Err(Error::NotFound));
        assert_eq!(
            run(
                &tx,
                0,
                "af9da41c-7296-4f51-91f4-141f5c6e3c01",
                None,
                &policy
            ),
            Err(Error::Invalid)
        );
        assert!(tx.events.borrow().is_empty());
    }
    #[test]
    fn input_limits_utf16_title_and_normalizes_policy() {
        let mut input = Input {
            purpose: "writing".into(),
            group_id: None,
            title: format!("  {}  ", "😀".repeat(100)),
        };
        assert_eq!(
            validate(input.clone())
                .unwrap()
                .title
                .encode_utf16()
                .count(),
            200
        );
        input.title.push('a');
        assert!(matches!(validate(input), Err(Error::Invalid)));
        let policy = ModerationPolicy::new(" YES ", " Alice, BOB ");
        assert!(
            policy.allow_all
                && policy.accounts.contains("alice")
                && policy.accounts.contains("bob")
        );
        assert!(ModerationPolicy::new("", "").accounts.contains("v2_admin"));
    }
}
