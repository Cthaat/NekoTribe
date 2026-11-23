use super::{
    crypto::{counter_increases, restore_credential},
    decode_credential_id, decode_exact, encode, spec, CredentialView, Operation, Outcome,
    StoredProof,
};
use crate::{
    auth::{
        github_oauth::has_link,
        login_methods::{active_session, has_password},
        readiness,
        session_repository::profile_date,
        TokenClaims,
    },
    chat_message_send::write_one,
    db::{
        oracle::{BindMap, DbError},
        row::{row_value, DbRow},
        tx::{OracleTx, Transaction},
        value::DbValue,
    },
};
use webauthn_rs::prelude::{
    COSEKeyType, Credential, DiscoverableAuthentication, PublicKeyCredential, Webauthn,
};

const ISSUER: &str = "rust";

pub(crate) fn execute(
    connection: &oracle::Connection,
    operation: Operation,
) -> Result<Outcome, DbError> {
    if matches!(&operation, Operation::Ready) {
        return Ok(if readiness::passkey_ready(connection) {
            Outcome::Ready
        } else {
            Outcome::Unavailable
        });
    }
    let tx = OracleTx::new(connection);
    match operation {
        Operation::Owner(user) => {
            let rows = tx.query(&spec().sql.owner, user_bind(user))?;
            match rows.first() {
                Some(row) if number(row, "IS_ACTIVE")? == 1 && text(row, "STATUS")? == "active" => {
                    let username = text(row, "USERNAME")?;
                    let display_name = row_value(row, "DISPLAY_NAME")
                        .and_then(DbValue::as_str)
                        .filter(|name| !name.is_empty())
                        .unwrap_or(username);
                    let excluded = tx
                        .query(&spec().sql.credential_list, user_bind(user))?
                        .iter()
                        .map(|row| {
                            decode_credential_id(text(row, "CREDENTIAL_ID")?)
                                .ok_or(DbError::SchemaNotReady)
                        })
                        .collect::<Result<_, _>>()?;
                    Ok(Outcome::Owner {
                        username: username.into(),
                        display_name: display_name.into(),
                        excluded,
                    })
                }
                _ => Ok(Outcome::Invalid),
            }
        }
        Operation::List(user) => {
            let rows = tx.query(&spec().sql.credential_list, user_bind(user))?;
            Ok(Outcome::List(
                rows.iter().map(view).collect::<Result<_, _>>()?,
            ))
        }
        _ => finish_transaction(&tx, run_write(&tx, operation)),
    }
}

fn finish_transaction(
    tx: &impl Transaction,
    result: Result<Outcome, DbError>,
) -> Result<Outcome, DbError> {
    match result {
        Ok(
            outcome @ (Outcome::Begun
            | Outcome::Taken(_)
            | Outcome::Added(_)
            | Outcome::Used
            | Outcome::Removed),
        ) => {
            if let Err(error) = tx.commit() {
                let _ = tx.rollback();
                return Err(error);
            }
            Ok(outcome)
        }
        result => {
            tx.rollback()?;
            result
        }
    }
}

fn run_write(tx: &impl Transaction, operation: Operation) -> Result<Outcome, DbError> {
    let sql = &spec().sql;
    match operation {
        Operation::Begin { id, session, proof } => {
            if let Some(claims) = &session {
                if !active_session(tx, claims)? {
                    return Ok(Outcome::Invalid);
                }
            }
            tx.execute(&sql.challenge_prune, BindMap::new())?;
            let owner = session.map(|claims| (claims.user_id, claims.session_id));
            let mut binds = challenge_binds(id, owner);
            binds.insert("challenge".into(), DbValue::String(proof.challenge));
            binds.insert("engine_state".into(), DbValue::String(proof.engine_state));
            binds.insert("ttl_seconds".into(), DbValue::I64(spec().ttl_seconds));
            write_one(tx, &sql.challenge_insert, binds)?;
            Ok(Outcome::Begun)
        }
        Operation::Take { id, owner } => {
            let rows = tx.query(&sql.challenge_lock, challenge_binds(id.clone(), owner))?;
            let Some(row) = rows.first() else {
                return Ok(Outcome::Invalid);
            };
            // Nullable engine state allows other runtimes to use their own
            // representation. A Rust challenge is consumed even if unusable.
            let proof = StoredProof {
                challenge: text(row, "CHALLENGE")?.into(),
                engine_state: row_value(row, "ENGINE_STATE")
                    .and_then(DbValue::as_str)
                    .unwrap_or_default()
                    .into(),
            };
            write_one(
                tx,
                &sql.challenge_delete,
                BindMap::from([string("challenge_id", id)]),
            )?;
            Ok(Outcome::Taken(proof))
        }
        Operation::Add {
            session,
            credential,
            label,
        } => add(tx, session, credential, label),
        Operation::Use {
            id,
            user,
            engine,
            state,
            proof,
        } => authenticate(tx, id, user, engine, state, proof),
        Operation::Delete { id, session } => delete(tx, id, session),
        _ => Err(DbError::SchemaNotReady),
    }
}

fn challenge_binds(id: String, owner: Option<(u64, String)>) -> BindMap {
    let purpose = if owner.is_some() { "register" } else { "login" };
    let (user, session) = owner
        .map(|(user, session)| (DbValue::I64(user as i64), DbValue::String(session)))
        .unwrap_or((DbValue::Null, DbValue::Null));
    BindMap::from([
        string("challenge_id", id),
        string("issuer", ISSUER),
        string("purpose", purpose),
        ("owner_user_id".into(), user),
        ("owner_session_id".into(), session),
    ])
}

fn add(
    tx: &impl Transaction,
    session: TokenClaims,
    credential: Credential,
    label: String,
) -> Result<Outcome, DbError> {
    let sql = &spec().sql;
    let user = user_bind(session.user_id);
    if tx.query(&sql.lock_owner, user.clone())?.is_empty() || !active_session(tx, &session)? {
        return Ok(Outcome::Invalid);
    }
    let COSEKeyType::EC_EC2(key) = credential.cred.key else {
        return Err(DbError::SchemaNotReady);
    };
    let id = encode(&credential.cred_id);
    let mut binds = user.clone();
    binds.extend([
        string("credential_id", &id),
        string("public_x", encode(&key.x)),
        string("public_y", encode(&key.y)),
        integer("sign_count", i64::from(credential.counter)),
        integer("backup_eligible", i64::from(credential.backup_eligible)),
        integer("backed_up", i64::from(credential.backup_state)),
        string("label", label),
    ]);
    if let Err(error) = write_one(tx, &sql.credential_insert, binds) {
        return if matches!(&error, DbError::Oracle(e) if e.db_error().is_some_and(|e| e.code() == 1))
        {
            Ok(Outcome::Conflict)
        } else {
            Err(error)
        };
    }
    let rows = tx.query(
        &sql.credential_read,
        BindMap::from([string("credential_id", id)]),
    )?;
    let credential = rows.first().ok_or(DbError::SchemaNotReady)?;
    Ok(Outcome::Added(view(credential)?))
}

fn authenticate(
    tx: &impl Transaction,
    id: String,
    user: u64,
    engine: Webauthn,
    state: DiscoverableAuthentication,
    proof: PublicKeyCredential,
) -> Result<Outcome, DbError> {
    let sql = &spec().sql;
    let rows = tx.query(
        &sql.credential_read,
        BindMap::from([string("credential_id", &id)]),
    )?;
    let Some(row) = rows.first() else {
        return Ok(Outcome::Invalid);
    };
    if number(row, "USER_ID")? != user as i64 {
        return Ok(Outcome::Invalid);
    }
    let credential = read_credential(row)?;
    let Ok(result) = engine.finish_discoverable_authentication_v2(&proof, state, &credential)
    else {
        return Ok(Outcome::Invalid);
    };
    if !result.user_verified()
        || !counter_increases(credential.counter, result.counter())
        || credential.backup_eligible != result.backup_eligible()
        || (result.backup_state() && !result.backup_eligible())
    {
        return Ok(Outcome::Invalid);
    }
    let mut binds = user_bind(user);
    binds.extend([
        string("credential_id", id),
        integer("sign_count", i64::from(result.counter())),
        integer("backed_up", i64::from(result.backup_state())),
    ]);
    write_one(tx, &sql.credential_use, binds)?;
    Ok(Outcome::Used)
}

fn read_credential(row: &DbRow) -> Result<Credential, DbError> {
    let id = decode_credential_id(text(row, "CREDENTIAL_ID")?).ok_or(DbError::SchemaNotReady)?;
    let x = decode_exact(text(row, "PUBLIC_X")?, 32).ok_or(DbError::SchemaNotReady)?;
    let y = decode_exact(text(row, "PUBLIC_Y")?, 32).ok_or(DbError::SchemaNotReady)?;
    let counter = u32::try_from(number(row, "SIGN_COUNT")?).map_err(|_| DbError::SchemaNotReady)?;
    let backup_eligible = number(row, "BACKUP_ELIGIBLE")? == 1;
    let backup_state = number(row, "BACKED_UP")? == 1;
    Ok(restore_credential(
        id,
        x,
        y,
        counter,
        backup_eligible,
        backup_state,
    ))
}

fn delete(tx: &impl Transaction, id: String, session: TokenClaims) -> Result<Outcome, DbError> {
    let sql = &spec().sql;
    let mut user = user_bind(session.user_id);
    let owners = tx.query(&sql.lock_owner, user.clone())?;
    let Some(owner) = owners.first() else {
        return Ok(Outcome::Invalid);
    };
    if !active_session(tx, &session)? {
        return Ok(Outcome::Invalid);
    }
    let credentials = tx.query(&sql.credential_list, user.clone())?;
    if !credentials
        .iter()
        .any(|row| text(row, "CREDENTIAL_ID").is_ok_and(|stored| stored == id))
    {
        return Ok(Outcome::Missing);
    }
    if credentials.len() == 1 && !has_password(owner) && !has_link(tx, session.user_id)? {
        return Ok(Outcome::Conflict);
    }
    user.extend([string("credential_id", id)]);
    write_one(tx, &sql.credential_delete, user)?;
    Ok(Outcome::Removed)
}

fn view(row: &DbRow) -> Result<CredentialView, DbError> {
    Ok(CredentialView {
        credential_id: text(row, "CREDENTIAL_ID")?.into(),
        label: text(row, "LABEL")?.into(),
        created_at: profile_date(text(row, "CREATED_AT")?),
        last_used_at: row_value(row, "LAST_USED_AT")
            .and_then(DbValue::as_str)
            .map(profile_date),
    })
}

fn text<'a>(row: &'a DbRow, key: &str) -> Result<&'a str, DbError> {
    row_value(row, key)
        .and_then(DbValue::as_str)
        .ok_or(DbError::SchemaNotReady)
}

fn number(row: &DbRow, key: &str) -> Result<i64, DbError> {
    row_value(row, key)
        .and_then(DbValue::as_i64)
        .ok_or(DbError::SchemaNotReady)
}

fn string(key: &str, value: impl Into<String>) -> (String, DbValue) {
    (key.into(), DbValue::String(value.into()))
}

fn integer(key: &str, value: i64) -> (String, DbValue) {
    (key.into(), DbValue::I64(value))
}

fn user_bind(user: u64) -> BindMap {
    BindMap::from([integer("user_id", user as i64)])
}
