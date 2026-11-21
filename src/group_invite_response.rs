use crate::{
    auth::{session_repository::row_number, sessions::NativeState},
    chat_message_send::write_one,
    db::{
        oracle::{BindMap, DbError},
        tx::OracleTx,
        value::DbValue,
    },
    direct_history::query,
    direct_send::next_id,
    group_membership::{GROUP, INSERT, MEMBER},
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    body::{to_bytes, Body},
    extract::{Path, State},
    http::{header::CACHE_CONTROL, HeaderMap, HeaderValue},
    response::{IntoResponse, Response},
    Json,
};
use serde_json::{json, Value};

pub enum Outcome {
    Responded(Value),
    Missing,
    Invalid,
    AlreadyMember,
}

const LOOKUP: &str =
    "SELECT group_id FROM n_group_invites WHERE invite_id=:invite_id AND invitee_id=:viewer_id";
const LOCK: &str = "SELECT inviter_id FROM n_group_invites WHERE invite_id=:invite_id AND group_id=:group_id AND invitee_id=:viewer_id\n AND status='pending' AND (max_uses IS NULL OR NVL(used_count,0)<max_uses)\n AND (expires_at IS NULL OR expires_at>=SYSTIMESTAMP) FOR UPDATE";
const UPDATE: &str = "UPDATE n_group_invites SET status=:status, responded_at=SYSTIMESTAMP,\n used_count=CASE WHEN :status='accepted' THEN NVL(used_count,0)+1 ELSE used_count END\n WHERE invite_id=:invite_id AND group_id=:group_id AND invitee_id=:viewer_id\n AND status='pending' AND (max_uses IS NULL OR NVL(used_count,0)<max_uses)\n AND (expires_at IS NULL OR expires_at>=SYSTIMESTAMP)";

fn decision(raw: &[u8]) -> Result<bool, ApiError> {
    let bad = || ApiError::bad_request("accept 参数错误");
    let value: Value = serde_json::from_slice(raw).map_err(|_| bad())?;
    match (value.get("accept"), value.get("action")) {
        (Some(value), None) => value.as_bool().ok_or_else(bad),
        (None, Some(value)) => match value.as_str() {
            Some("accept") => Ok(true),
            Some("decline" | "reject") => Ok(false),
            _ => Err(bad()),
        },
        _ => Err(bad()),
    }
}

pub(crate) fn execute(
    conn: &oracle::Connection,
    viewer: u64,
    invite: u64,
    accept: bool,
) -> Result<Outcome, DbError> {
    let viewer = i64::try_from(viewer).map_err(|_| DbError::SchemaNotReady)?;
    let invite = i64::try_from(invite).map_err(|_| DbError::SchemaNotReady)?;
    let tx = OracleTx::new(conn);
    let out = (|| {
        let mut binds = BindMap::from([
            ("invite_id".into(), DbValue::I64(invite)),
            ("viewer_id".into(), DbValue::I64(viewer)),
        ]);
        let found = query(conn, LOOKUP, binds.clone())?;
        let Some(row) = found.first() else {
            return Ok(Outcome::Missing);
        };
        let group = row_number(row, "GROUP_ID");
        let rows = query(
            conn,
            GROUP,
            BindMap::from([("group_id".into(), DbValue::I64(group))]),
        )?;
        if !rows
            .first()
            .is_some_and(|r| row_number(r, "IS_ACTIVE") == 1 && row_number(r, "IS_DELETED") == 0)
        {
            return Ok(Outcome::Invalid);
        }
        binds.insert("group_id".into(), DbValue::I64(group));
        let locked = query(conn, LOCK, binds.clone())?;
        let Some(remaining) = locked.first() else {
            return Ok(Outcome::Invalid);
        };
        let mut member = BindMap::from([
            ("group_id".into(), DbValue::I64(group)),
            ("user_id".into(), DbValue::I64(viewer)),
        ]);
        if accept && !query(conn, MEMBER, member.clone())?.is_empty() {
            return Ok(Outcome::AlreadyMember);
        }
        let status = if accept { "accepted" } else { "rejected" };
        binds.insert("status".into(), DbValue::String(status.into()));
        match tx.execute(UPDATE, binds)?.rows_affected {
            0 => return Ok(Outcome::Invalid),
            1 => {}
            _ => return Err(DbError::SchemaNotReady),
        }
        if accept {
            let id = next_id(conn, "SELECT seq_group_member_id.NEXTVAL AS id FROM dual")?;
            member.extend([
                ("member_id".into(), DbValue::I64(id)),
                ("status".into(), DbValue::String("active".into())),
                (
                    "invited_by".into(),
                    DbValue::I64(row_number(remaining, "INVITER_ID")),
                ),
            ]);
            write_one(&tx, INSERT, member)?;
        }
        Ok(Outcome::Responded(
            json!({"invite_id":invite,"group_id":group,"status":status}),
        ))
    })();
    match out {
        Ok(success @ Outcome::Responded(_)) => match tx.commit() {
            Ok(()) => Ok(success),
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

pub(crate) async fn respond(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    let result = async {
        let (viewer, invite) =
            crate::posts::bookmark::interaction_identity(&state, &raw, &headers).await?;
        let bytes = to_bytes(body, 1 << 20)
            .await
            .map_err(|_| ApiError::bad_request("accept 参数错误"))?;
        let accept = decision(&bytes)?;
        match state
            .repository
            .respond_group_invite(viewer, invite, accept)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?
        {
            Outcome::Responded(response) => Ok(Json(V2Response::ok_with_message(
                response,
                if accept {
                    "invite accepted"
                } else {
                    "invite rejected"
                },
            ))),
            Outcome::Missing => Err(ApiError::not_found("邀请不存在")),
            Outcome::Invalid => Err(ApiError::unprocessable("邀请无效或已过期")),
            Outcome::AlreadyMember => Err(ApiError::unprocessable("您已经是群组成员")),
        }
    }
    .await;
    let mut response = result.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}
