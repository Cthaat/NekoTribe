//! Persist a published media object and map its ready row in one transaction.
use crate::{
    auth::readiness,
    db::{
        oracle::{bind_refs, bind_values, BindMap},
        row::{oracle_row_to_db_row, DbRow},
        tx::OracleTx,
        value::DbValue,
    },
};

pub(crate) const PRIVATE_SCOPE_PREFLIGHT_SQL: &str =
    "SELECT access_scope FROM n_media_assets WHERE 1 = 0";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PrivateScope {
    Chat,
    Post,
}

impl PrivateScope {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Chat => "chat",
            Self::Post => "post",
        }
    }
}

#[derive(Clone, Debug)]
pub enum MediaAccess {
    Public(String),
    Private(PrivateScope),
}

#[derive(Clone, Debug)]
pub struct MediaUpload {
    pub user_id: i64,
    pub size: i64,
    pub key: String,
    pub access: MediaAccess,
    pub filename: String,
    pub media_type: String,
    pub mime_type: String,
    pub width: Option<f64>,
    pub height: Option<f64>,
    pub duration: Option<f64>,
    pub thumbnail_url: Option<String>,
    pub alt_text: Option<String>,
    pub description: Option<String>,
}

#[derive(Debug)]
pub enum MediaUploadOutcome<T> {
    Created(T),
    Failed {
        cleanup_safe: bool,
        schema_unavailable: bool,
    },
}

impl<T> MediaUploadOutcome<T> {
    pub fn cleanup_safe(&self) -> bool {
        matches!(
            self,
            Self::Failed {
                cleanup_safe: true,
                ..
            }
        )
    }
    #[cfg(test)]
    fn is_success(&self) -> bool {
        matches!(self, Self::Created(_))
    }
}

trait MediaTransaction {
    fn next_id(&self) -> Result<i64, ()>;
    fn check_schema(&self) -> Result<(), ()>;
    fn insert(&self, id: i64, input: &MediaUpload) -> Result<(), ()>;
    fn read(&self, id: i64) -> Result<DbRow, ()>;
    fn commit(&self) -> Result<(), ()>;
    fn rollback(&self) -> Result<(), ()>;
}

fn run<T>(
    tx: &impl MediaTransaction,
    input: &MediaUpload,
    map: impl FnOnce(DbRow) -> Result<T, ()>,
) -> MediaUploadOutcome<T> {
    let failed = |cleanup_safe, schema_unavailable| MediaUploadOutcome::Failed {
        cleanup_safe,
        schema_unavailable,
    };
    let valid_access = match &input.access {
        MediaAccess::Public(url) => !url.is_empty(),
        MediaAccess::Private(scope) => {
            let prefix = format!("private/{}/", scope.as_str());
            input.key.starts_with(&prefix) && input.thumbnail_url.is_none()
        }
    };
    if input.user_id <= 0 || input.size <= 0 || input.key.is_empty() || !valid_access {
        return failed(true, false);
    }
    let id = match tx.next_id() {
        Ok(id) if id > 0 => id,
        _ => return failed(true, false),
    };
    if tx.check_schema().is_err() {
        return failed(true, true);
    }
    let row = match tx
        .insert(id, input)
        .and_then(|()| tx.read(id))
        .and_then(map)
    {
        Ok(row) => row,
        Err(()) => return failed(tx.rollback().is_ok(), false),
    };
    if tx.commit().is_err() {
        return failed(false, false);
    }
    MediaUploadOutcome::Created(row)
}

struct OracleMediaTransaction<'a>(&'a oracle::Connection);

impl MediaTransaction for OracleMediaTransaction<'_> {
    fn next_id(&self) -> Result<i64, ()> {
        self.0
            .query_row_as::<i64>("SELECT seq_media_id.NEXTVAL FROM dual", &[])
            .map_err(|_| ())
    }
    fn check_schema(&self) -> Result<(), ()> {
        let snapshot = readiness::collect_media_snapshot(self.0).map_err(|_| ())?;
        readiness::validate_feature_snapshot(&snapshot, "media").map_err(|_| ())
    }
    fn insert(&self, id: i64, input: &MediaUpload) -> Result<(), ()> {
        let optional_number = |v: Option<f64>| v.map(DbValue::F64).unwrap_or(DbValue::Null);
        let optional_text =
            |v: &Option<String>| DbValue::from_option_string(v.clone().filter(|s| !s.is_empty()));
        let public_url = match &input.access {
            MediaAccess::Public(url) => url.clone(),
            MediaAccess::Private(_) => super::private_read::content_url(id).ok_or(())?,
        };
        let mut binds = BindMap::from([
            ("media_id".into(), DbValue::I64(id)),
            ("owner_user_id".into(), DbValue::I64(input.user_id)),
            (
                "media_type".into(),
                DbValue::String(input.media_type.clone()),
            ),
            ("file_name".into(), DbValue::String(input.filename.clone())),
            ("storage_key".into(), DbValue::String(input.key.clone())),
            ("public_url".into(), DbValue::String(public_url)),
            ("file_size".into(), DbValue::I64(input.size)),
            ("mime_type".into(), DbValue::String(input.mime_type.clone())),
            ("width".into(), optional_number(input.width)),
            ("height".into(), optional_number(input.height)),
            ("duration".into(), optional_number(input.duration)),
            ("thumbnail_url".into(), optional_text(&input.thumbnail_url)),
            ("alt_text".into(), optional_text(&input.alt_text)),
            ("description".into(), optional_text(&input.description)),
        ]);
        let sql = match &input.access {
            MediaAccess::Public(_) => "INSERT INTO n_media_assets (media_id,owner_user_id,media_type,file_name,storage_key,public_url,file_size,mime_type,width,height,duration,thumbnail_url,alt_text,description,status) VALUES (:media_id,:owner_user_id,:media_type,:file_name,:storage_key,:public_url,:file_size,:mime_type,:width,:height,:duration,:thumbnail_url,:alt_text,:description,'ready')",
            MediaAccess::Private(scope) => {
                binds.insert("access_scope".into(), DbValue::String(scope.as_str().into()));
                "INSERT INTO n_media_assets (media_id,owner_user_id,media_type,file_name,storage_key,public_url,file_size,mime_type,width,height,duration,thumbnail_url,alt_text,description,status,access_scope) VALUES (:media_id,:owner_user_id,:media_type,:file_name,:storage_key,:public_url,:file_size,:mime_type,:width,:height,:duration,:thumbnail_url,:alt_text,:description,'ready',:access_scope)"
            }
        };
        match OracleTx::new(self.0).execute(sql, binds) {
            Ok(result) if result.rows_affected == 1 => Ok(()),
            _ => Err(()),
        }
    }
    fn read(&self, id: i64) -> Result<DbRow, ()> {
        let values = bind_values(BindMap::from([("media_id".into(), DbValue::I64(id))]));
        let refs = bind_refs(&values);
        let mut rows = self.0.query_named("SELECT media_id,media_type,file_name,public_url,file_size,mime_type,width,height,duration,thumbnail_url,alt_text,description,status,created_at FROM n_media_assets WHERE media_id=:media_id", &refs).map_err(|_| ())?;
        let row = rows.next().ok_or(())?.map_err(|_| ())?;
        let result = oracle_row_to_db_row(&row).map_err(|_| ())?;
        if rows.next().is_some() {
            return Err(());
        }
        Ok(result)
    }
    fn commit(&self) -> Result<(), ()> {
        OracleTx::new(self.0).commit().map_err(|_| ())
    }
    fn rollback(&self) -> Result<(), ()> {
        OracleTx::new(self.0).rollback().map_err(|_| ())
    }
}

pub fn execute<T>(
    connection: &oracle::Connection,
    input: &MediaUpload,
    map: impl FnOnce(DbRow) -> Result<T, ()>,
) -> MediaUploadOutcome<T> {
    run(&OracleMediaTransaction(connection), input, map)
}

#[cfg(test)]
impl MediaUpload {
    fn test_input() -> Self {
        Self {
            user_id: 1,
            size: 1,
            key: "posts/a".into(),
            access: MediaAccess::Public("/storage/posts/a".into()),
            filename: "a".into(),
            media_type: "image".into(),
            mime_type: "image/png".into(),
            width: None,
            height: None,
            duration: None,
            thumbnail_url: None,
            alt_text: None,
            description: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    struct Fake {
        fail: &'static str,
        calls: RefCell<Vec<&'static str>>,
    }

    impl MediaTransaction for Fake {
        fn next_id(&self) -> Result<i64, ()> {
            self.calls.borrow_mut().push("sequence");
            if self.fail == "sequence" {
                Err(())
            } else {
                Ok(12)
            }
        }
        fn check_schema(&self) -> Result<(), ()> {
            self.calls.borrow_mut().push("schema");
            if self.fail == "schema" {
                Err(())
            } else {
                Ok(())
            }
        }
        fn insert(&self, _: i64, _: &MediaUpload) -> Result<(), ()> {
            self.calls.borrow_mut().push("insert");
            if self.fail == "insert" || self.fail == "rollback" {
                Err(())
            } else {
                Ok(())
            }
        }
        fn read(&self, _: i64) -> Result<DbRow, ()> {
            self.calls.borrow_mut().push("read");
            if self.fail == "read" {
                Err(())
            } else {
                Ok(DbRow::new())
            }
        }
        fn commit(&self) -> Result<(), ()> {
            self.calls.borrow_mut().push("commit");
            if self.fail == "commit" {
                Err(())
            } else {
                Ok(())
            }
        }
        fn rollback(&self) -> Result<(), ()> {
            self.calls.borrow_mut().push("rollback");
            if self.fail == "rollback" {
                Err(())
            } else {
                Ok(())
            }
        }
    }

    #[test]
    fn transaction_cleanup_safety_and_order() {
        for (failure, cleanup, expected) in [
            ("sequence", true, vec!["sequence"]),
            ("schema", true, vec!["sequence", "schema"]),
            (
                "insert",
                true,
                vec!["sequence", "schema", "insert", "rollback"],
            ),
            (
                "read",
                true,
                vec!["sequence", "schema", "insert", "read", "rollback"],
            ),
            (
                "rollback",
                false,
                vec!["sequence", "schema", "insert", "rollback"],
            ),
            (
                "commit",
                false,
                vec!["sequence", "schema", "insert", "read", "commit"],
            ),
            (
                "",
                false,
                vec!["sequence", "schema", "insert", "read", "commit"],
            ),
        ] {
            let fake = Fake {
                fail: failure,
                calls: RefCell::new(Vec::new()),
            };
            let outcome = run(&fake, &MediaUpload::test_input(), Ok);
            assert_eq!(outcome.cleanup_safe(), cleanup, "{failure}");
            assert_eq!(outcome.is_success(), failure.is_empty(), "{failure}");
            assert_eq!(*fake.calls.borrow(), expected, "{failure}");
        }
    }

    #[test]
    fn failed_response_mapping_rolls_back_before_commit() {
        let fake = Fake {
            fail: "",
            calls: RefCell::new(Vec::new()),
        };
        let outcome = run(&fake, &MediaUpload::test_input(), |_| Err::<(), _>(()));
        assert!(outcome.cleanup_safe());
        assert_eq!(
            *fake.calls.borrow(),
            ["sequence", "schema", "insert", "read", "rollback"]
        );
    }
}
