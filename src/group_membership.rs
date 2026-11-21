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

pub enum Change {
    Join(String),
    Leave,
}
pub enum Outcome {
    Joined(Value),
    Left,
    MissingGroup,
    MissingMember,
    AlreadyMember,
    Owner,
    Banned,
    InvalidInvite,
    InviteOnly,
}

pub(crate) const GROUP:&str="SELECT owner_id, privacy, join_approval, is_active, is_deleted FROM n_groups WHERE group_id=:group_id FOR UPDATE";
pub(crate) const MEMBER:&str="SELECT role,status FROM n_group_members WHERE group_id=:group_id AND user_id=:user_id FOR UPDATE";
const INVITE:&str="SELECT invite_id,inviter_id FROM n_group_invites WHERE group_id=:group_id AND invite_code=:invite_code
AND status='pending' AND (invitee_id IS NULL OR invitee_id=:user_id)
AND (max_uses IS NULL OR used_count<max_uses) AND (expires_at IS NULL OR expires_at>=SYSTIMESTAMP)";
const CONSUME:&str="UPDATE n_group_invites SET used_count=used_count+1,
status=CASE WHEN max_uses IS NOT NULL AND used_count+1>=max_uses THEN 'accepted' ELSE status END,
responded_at=CASE WHEN max_uses IS NOT NULL AND used_count+1>=max_uses THEN SYSTIMESTAMP ELSE responded_at END
WHERE invite_id=:invite_id AND group_id=:group_id AND invite_code=:invite_code
AND status='pending' AND (invitee_id IS NULL OR invitee_id=:user_id)
AND (max_uses IS NULL OR used_count<max_uses) AND (expires_at IS NULL OR expires_at>=SYSTIMESTAMP)";
pub(crate) const INSERT: &str =
    "INSERT INTO n_group_members (member_id,group_id,user_id,role,status,invited_by)
VALUES (:member_id,:group_id,:user_id,'member',:status,:invited_by)";
pub(crate) const DELETE:&str="DELETE FROM n_group_members WHERE group_id=:group_id AND user_id=:user_id AND role<>'owner' AND status<>'banned'";

pub(crate) fn execute(
    conn: &oracle::Connection,
    user: u64,
    group: u64,
    change: Change,
) -> Result<Outcome, DbError> {
    let user = i64::try_from(user).map_err(|_| DbError::SchemaNotReady)?;
    let group = i64::try_from(group).map_err(|_| DbError::SchemaNotReady)?;
    let tx = OracleTx::new(conn);
    let operation = (|| {
        let group_binds = BindMap::from([("group_id".into(), DbValue::I64(group))]);
        let mut member_binds = group_binds.clone();
        member_binds.insert("user_id".into(), DbValue::I64(user));
        let groups = query(conn, GROUP, group_binds)?;
        let Some(row) = groups.first() else {
            return Ok(if matches!(change, Change::Leave) {
                Outcome::MissingMember
            } else {
                Outcome::MissingGroup
            });
        };
        if matches!(change, Change::Join(_))
            && (row_number(row, "IS_ACTIVE") != 1 || row_number(row, "IS_DELETED") != 0)
        {
            return Ok(Outcome::MissingGroup);
        }
        let members = query(conn, MEMBER, member_binds.clone())?;
        let Change::Join(code) = change else {
            let Some(member) = members.first() else {
                return Ok(Outcome::MissingMember);
            };
            if row_text(member, "ROLE") == "owner" || row_number(row, "OWNER_ID") == user {
                return Ok(Outcome::Owner);
            }
            if row_text(member, "STATUS") == "banned" {
                return Ok(Outcome::Banned);
            }
            write_one(&tx, DELETE, member_binds)?;
            return Ok(Outcome::Left);
        };
        if !members.is_empty() {
            return Ok(Outcome::AlreadyMember);
        }
        let privacy = row_text(row, "PRIVACY");
        let mut status = if privacy != "public" || row_number(row, "JOIN_APPROVAL") == 1 {
            "pending"
        } else {
            "active"
        };
        let mut inviter = DbValue::Null;
        if !code.is_empty() {
            let mut binds = member_binds.clone();
            binds.insert("invite_code".into(), DbValue::String(code));
            let invitations = query(conn, INVITE, binds.clone())?;
            let Some(invitation) = invitations.first() else {
                return Ok(Outcome::InvalidInvite);
            };
            binds.insert(
                "invite_id".into(),
                DbValue::I64(row_number(invitation, "INVITE_ID")),
            );
            match tx.execute(CONSUME, binds)?.rows_affected {
                0 => return Ok(Outcome::InvalidInvite),
                1 => {}
                _ => return Err(DbError::SchemaNotReady),
            }
            inviter = DbValue::I64(row_number(invitation, "INVITER_ID"));
            status = "active";
        } else if privacy == "secret" {
            return Ok(Outcome::InviteOnly);
        }
        let ids = query(
            conn,
            "SELECT seq_group_member_id.NEXTVAL AS id FROM dual",
            BindMap::new(),
        )?;
        let id = ids
            .first()
            .map(|row| row_number(row, "ID"))
            .filter(|id| (1..=9_007_199_254_740_991).contains(id))
            .ok_or(DbError::SchemaNotReady)?;
        member_binds.extend([
            ("member_id".into(), DbValue::I64(id)),
            ("status".into(), DbValue::String(status.into())),
            ("invited_by".into(), inviter),
        ]);
        write_one(&tx, INSERT, member_binds)?;
        Ok(Outcome::Joined(
            json!({"member_id":id,"group_id":group,"user_id":user,"role":"member","status":status}),
        ))
    })();
    match operation {
        Ok(result @ (Outcome::Left | Outcome::Joined(_))) => match tx.commit() {
            Ok(()) => Ok(result),
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

fn invite_body(raw: &[u8]) -> Result<String, ApiError> {
    let bad = || ApiError::bad_request("invite_code 参数错误");
    if raw.iter().all(u8::is_ascii_whitespace) {
        return Ok(String::new());
    }
    let body: Value = serde_json::from_slice(raw).map_err(|_| bad())?;
    let body = body.as_object().ok_or_else(bad)?;
    let Some(value) = body.get("invite_code").filter(|v| !v.is_null()) else {
        return Ok(String::new());
    };
    let code = value
        .as_str()
        .ok_or_else(bad)?
        .trim_matches(|c: char| (c.is_whitespace() && c != '\u{0085}') || c == '\u{feff}')
        .to_uppercase();
    if code.len() > 32 {
        return Err(bad());
    }
    Ok(code)
}

async fn route(
    state: NativeState,
    raw: String,
    headers: HeaderMap,
    body: Option<Body>,
) -> Response {
    let result = async {
        let (user, group) =
            crate::posts::bookmark::interaction_identity(&state, &raw, &headers).await?;
        let change = match body {
            Some(body) => {
                let body = to_bytes(body, 1 << 20)
                    .await
                    .map_err(|_| ApiError::bad_request("invite_code 参数错误"))?;
                Change::Join(invite_body(&body)?)
            }
            None => Change::Leave,
        };
        match state
            .repository
            .change_group_membership(user, group, change)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?
        {
            Outcome::Joined(member) => {
                let label = if member["status"] == "pending" {
                    "pending approval"
                } else {
                    "joined"
                };
                Ok(Json(V2Response::ok_with_message(member, label)))
            }
            Outcome::Left => Ok(Json(V2Response::ok_with_message(Value::Null, "left group"))),
            Outcome::MissingGroup => Err(ApiError::not_found("群组不存在")),
            Outcome::MissingMember => Err(ApiError::not_found("成员不存在")),
            Outcome::AlreadyMember => Err(ApiError::unprocessable("您已经是群组成员")),
            Outcome::Owner => Err(ApiError::unprocessable("群主不能退出群组")),
            Outcome::Banned => Err(ApiError::unprocessable("被封禁的成员不能退出群组")),
            Outcome::InvalidInvite => Err(ApiError::unprocessable("邀请码无效或已过期")),
            Outcome::InviteOnly => Err(ApiError::unprocessable("该群组仅限邀请加入")),
        }
    }
    .await;
    let mut response = result.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}

pub(crate) async fn join(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    route(state, raw, headers, Some(body)).await
}
pub(crate) async fn leave(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
) -> Response {
    route(state, raw, headers, None).await
}
