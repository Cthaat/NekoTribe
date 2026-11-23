use super::{spec, Flow, Identity, Link, Operation, Outcome};
use crate::{
    auth::{
        login_methods::{active_session, has_password, missing_table},
        passkey::active_owner_sql,
        readiness,
        session_repository::profile_date,
        TokenClaims,
    },
    chat_message_send::write_one,
    db::{
        oracle::{BindMap, DbError},
        row::DbRow,
        tx::{OracleTx, Transaction},
        value::DbValue,
    },
};

pub(crate) fn execute(
    connection: &oracle::Connection,
    operation: Operation,
) -> Result<Outcome, DbError> {
    if matches!(operation, Operation::Ready) {
        return Ok(if readiness::github_oauth_ready(connection) {
            Outcome::Ready
        } else {
            Outcome::Unavailable
        });
    }
    let tx = OracleTx::new(connection);
    if let Operation::Read(user) = operation {
        let rows = tx.query(&spec().sql.link_for_user, user_bind(user))?;
        return Ok(Outcome::Link(rows.first().map(link).transpose()?));
    }
    run(&tx, operation)
}

pub(super) fn run(tx: &impl Transaction, operation: Operation) -> Result<Outcome, DbError> {
    match write(tx, operation) {
        Ok((result, true)) => {
            if let Err(error) = tx.commit() {
                let _ = tx.rollback();
                return Err(error);
            }
            Ok(result)
        }
        Ok((result, false)) => {
            tx.rollback()?;
            Ok(result)
        }
        Err(error) => {
            tx.rollback()?;
            Err(error)
        }
    }
}

fn write(tx: &impl Transaction, operation: Operation) -> Result<(Outcome, bool), DbError> {
    let sql = &spec().sql;
    match operation {
        Operation::Begin { flow, session } => {
            tx.execute(&sql.prune, BindMap::new())?;
            if let Some(claims) = &session {
                if !active_session(tx, claims)? {
                    return Ok((Outcome::Invalid, false));
                }
            }
            begin(tx, flow, session.as_ref())
        }
        Operation::Claim { state_hash } => {
            let rows = tx.query(
                &sql.callback_lock,
                BindMap::from([string("state_hash", state_hash)]),
            )?;
            let Some(row) = rows.first() else {
                return Ok((Outcome::Invalid, false));
            };
            let flow_id = text(row, "FLOW_ID")?.to_owned();
            let pkce_verifier = text(row, "PKCE_VERIFIER")?.to_owned();
            write_one(
                tx,
                &sql.callback_claim,
                BindMap::from([string("flow_id", &flow_id)]),
            )?;
            Ok((
                Outcome::Claimed {
                    flow_id,
                    pkce_verifier,
                },
                true,
            ))
        }
        Operation::Record { flow_id, identity } => {
            let (status, github_user_id, github_login) = match identity {
                Some(Identity { id, login }) => ("verified", Some(id), Some(login)),
                None => ("failed", None, None),
            };
            let binds = BindMap::from([
                string("flow_id", flow_id),
                string("status", status),
                (
                    "github_user_id".into(),
                    DbValue::from_option_string(github_user_id),
                ),
                (
                    "github_login".into(),
                    DbValue::from_option_string(github_login),
                ),
            ]);
            match tx.execute(&sql.callback_finish, binds)? {
                0 => Ok((Outcome::Invalid, false)),
                1 => Ok((Outcome::Recorded, true)),
                _ => Err(DbError::SchemaNotReady),
            }
        }
        Operation::Complete {
            flow_id,
            flow_key_hash,
            session,
        } => complete(tx, flow_id, flow_key_hash, session),
        Operation::Remove(session) => remove(tx, session),
        _ => Err(DbError::SchemaNotReady),
    }
}

fn begin(
    tx: &impl Transaction,
    flow: Flow,
    claims: Option<&TokenClaims>,
) -> Result<(Outcome, bool), DbError> {
    let mut binds = flow_binds(flow.id, claims);
    binds.extend([
        string("state_hash", flow.state_hash),
        string("flow_key_hash", flow.flow_key_hash),
        string("pkce_verifier", flow.pkce_verifier),
        ("ttl_seconds".into(), DbValue::I64(spec().ttl_seconds)),
    ]);
    write_one(tx, &spec().sql.begin, binds)?;
    Ok((Outcome::Begun, true))
}

fn complete(
    tx: &impl Transaction,
    flow_id: String,
    flow_key_hash: String,
    claims: Option<TokenClaims>,
) -> Result<(Outcome, bool), DbError> {
    if let Some(claims) = &claims {
        if tx
            .query(active_owner_sql(), user_bind(claims.user_id))?
            .is_empty()
            || !active_session(tx, claims)?
        {
            return Ok((Outcome::Invalid, false));
        }
    }
    let sql = &spec().sql;
    let mut binds = flow_binds(flow_id.clone(), claims.as_ref());
    binds.extend([string("flow_key_hash", flow_key_hash)]);
    let rows = tx.query(&sql.complete_lock, binds)?;
    let Some(row) = rows.first() else {
        return Ok((Outcome::Invalid, false));
    };
    let status = text(row, "STATUS")?;
    if matches!(status, "pending" | "checking") {
        return Ok((Outcome::Pending, false));
    }
    write_one(
        tx,
        &sql.complete_consume,
        BindMap::from([string("flow_id", flow_id)]),
    )?;
    if status != "verified" {
        return Ok((Outcome::Invalid, true));
    }
    let identity = Identity {
        id: text(row, "GITHUB_USER_ID")?.into(),
        login: text(row, "GITHUB_LOGIN")?.into(),
    };
    let result = match claims {
        Some(claims) => bind_identity(tx, claims.user_id, identity)?,
        None => login_user(tx, &identity.id)?,
    };
    Ok((result, true))
}

fn login_user(tx: &impl Transaction, id: &str) -> Result<Outcome, DbError> {
    let rows = tx.query(
        &spec().sql.link_for_github,
        BindMap::from([string("github_user_id", id)]),
    )?;
    let Some(row) = rows.first() else {
        return Ok(Outcome::Invalid);
    };
    row.get("USER_ID")
        .and_then(DbValue::as_i64)
        .and_then(|id| u64::try_from(id).ok())
        .filter(|id| *id > 0)
        .map(Outcome::Login)
        .ok_or(DbError::SchemaNotReady)
}

fn bind_identity(tx: &impl Transaction, user: u64, identity: Identity) -> Result<Outcome, DbError> {
    let sql = &spec().sql;
    let mut binds = user_bind(user);
    let existing = tx.query(&sql.link_for_user, binds.clone())?;
    if let Some(row) = existing.first() {
        let existing = link(row)?;
        return Ok(if existing.github_user_id == identity.id {
            Outcome::Linked(existing)
        } else {
            Outcome::Conflict
        });
    }
    binds.extend([
        string("github_user_id", identity.id),
        string("github_login", identity.login),
    ]);
    if let Err(error) = write_one(tx, &sql.link_create, binds) {
        return if matches!(&error, DbError::Oracle(err) if err.db_error().is_some_and(|detail| detail.code() == 1))
        {
            Ok(Outcome::Conflict)
        } else {
            Err(error)
        };
    }
    let rows = tx.query(&sql.link_for_user, user_bind(user))?;
    Ok(Outcome::Linked(link(
        rows.first().ok_or(DbError::SchemaNotReady)?,
    )?))
}

fn remove(tx: &impl Transaction, session: TokenClaims) -> Result<(Outcome, bool), DbError> {
    let sql = &spec().sql;
    let user = user_bind(session.user_id);
    let owners = tx.query(active_owner_sql(), user.clone())?;
    let Some(owner) = owners.first() else {
        return Ok((Outcome::Invalid, false));
    };
    if !active_session(tx, &session)? {
        return Ok((Outcome::Invalid, false));
    }
    if tx.query(&sql.link_for_user, user.clone())?.is_empty() {
        return Ok((Outcome::Missing, false));
    }
    if !has_password(owner) && !has_passkey(tx, session.user_id)? {
        return Ok((Outcome::Conflict, false));
    }
    write_one(tx, &sql.link_remove, user)?;
    Ok((Outcome::Removed, true))
}

fn has_passkey(tx: &impl Transaction, user: u64) -> Result<bool, DbError> {
    match tx.query(&spec().sql.passkey_count, user_bind(user)) {
        Ok(rows) => rows
            .first()
            .and_then(|row| row.get("TOTAL"))
            .and_then(DbValue::as_i64)
            .filter(|total| *total >= 0)
            .map(|total| total > 0)
            .ok_or(DbError::SchemaNotReady),
        Err(error) if missing_table(&error) => Ok(false),
        Err(error) => Err(error),
    }
}

pub(in crate::auth) fn has_link(tx: &impl Transaction, user: u64) -> Result<bool, DbError> {
    match tx.query(&spec().sql.link_for_user, user_bind(user)) {
        Ok(rows) => Ok(!rows.is_empty()),
        Err(error) if missing_table(&error) => Ok(false),
        Err(error) => Err(error),
    }
}

fn flow_binds(id: String, claims: Option<&TokenClaims>) -> BindMap {
    let (purpose, owner_user_id, owner_session_id) = match claims {
        Some(claims) => (
            "link",
            DbValue::I64(claims.user_id as i64),
            DbValue::String(claims.session_id.clone()),
        ),
        None => ("login", DbValue::Null, DbValue::Null),
    };
    BindMap::from([
        string("flow_id", id),
        string("purpose", purpose),
        ("owner_user_id".into(), owner_user_id),
        ("owner_session_id".into(), owner_session_id),
    ])
}

fn link(row: &DbRow) -> Result<Link, DbError> {
    Ok(Link {
        github_user_id: text(row, "GITHUB_USER_ID")?.into(),
        github_login: text(row, "GITHUB_LOGIN")?.into(),
        linked_at: profile_date(text(row, "LINKED_AT")?),
    })
}

fn text<'a>(row: &'a DbRow, name: &str) -> Result<&'a str, DbError> {
    row.get(name)
        .and_then(DbValue::as_str)
        .ok_or(DbError::SchemaNotReady)
}

fn string(key: &str, value: impl Into<String>) -> (String, DbValue) {
    (key.into(), DbValue::String(value.into()))
}

fn user_bind(user: u64) -> BindMap {
    BindMap::from([("user_id".into(), DbValue::I64(user as i64))])
}
