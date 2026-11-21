use crate::{
    auth::{
        session_repository::{row_number, row_text},
        sessions::NativeState,
    },
    chat_message_send::write_one,
    db::{
        oracle::{BindMap, DbError},
        tx::OracleTx,
        value::DbValue,
    },
    direct_history::query,
    group_membership::{GROUP, MEMBER},
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    extract::{Path, State},
    http::{header::CACHE_CONTROL, HeaderMap, HeaderValue},
    response::{IntoResponse, Response},
    Json,
};

pub enum Outcome {
    Dissolved,
    MissingGroup,
    Forbidden,
}

const DISSOLVE: &str = "UPDATE n_groups SET is_deleted=1,is_active=0 WHERE group_id=:group_id AND owner_id=:actor_id AND is_deleted=0";
const AUDIT: &str = "INSERT INTO n_group_audit_logs (group_id,actor_id,action) VALUES (:group_id,:actor_id,'delete_group')";

pub(crate) fn execute(
    conn: &oracle::Connection,
    actor: u64,
    group: u64,
) -> Result<Outcome, DbError> {
    let id = |n| i64::try_from(n).map_err(|_| DbError::SchemaNotReady);
    let (actor, group) = (id(actor)?, id(group)?);
    let tx = OracleTx::new(conn);
    let result = (|| {
        let mut binds = BindMap::from([("group_id".into(), DbValue::I64(group))]);
        let rows = query(conn, GROUP, binds.clone())?;
        let Some(group_row) = rows.first() else {
            return Ok(Outcome::MissingGroup);
        };
        if row_number(group_row, "IS_DELETED") != 0 {
            return Ok(Outcome::MissingGroup);
        }
        if row_number(group_row, "OWNER_ID") != actor {
            return Ok(Outcome::Forbidden);
        }
        let mut member = binds.clone();
        member.insert("user_id".into(), DbValue::I64(actor));
        let owners = query(conn, MEMBER, member)?;
        if !owners.first().is_some_and(|row| {
            row_text(row, "ROLE") == "owner" && row_text(row, "STATUS") == "active"
        }) {
            return Ok(Outcome::Forbidden);
        }
        binds.insert("actor_id".into(), DbValue::I64(actor));
        write_one(&tx, DISSOLVE, binds.clone())?;
        write_one(&tx, AUDIT, binds)?;
        tx.commit()?;
        Ok(Outcome::Dissolved)
    })();
    if !matches!(result, Ok(Outcome::Dissolved)) {
        tx.rollback()?;
    }
    result
}

pub(crate) async fn delete(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
) -> Response {
    let result = async {
        let (actor, group) =
            crate::posts::bookmark::interaction_identity(&state, &raw, &headers).await?;
        match state
            .repository
            .dissolve_group(actor, group)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?
        {
            Outcome::Dissolved => Ok(Json(V2Response::null("group deleted"))),
            Outcome::MissingGroup => Err(ApiError::not_found("群组不存在")),
            Outcome::Forbidden => Err(ApiError::unprocessable("只有群主可以解散群组")),
        }
    }
    .await;
    let mut response = result.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}
