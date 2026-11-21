use crate::{
    auth::{
        session_repository::{nullable_text, row_number, row_text},
        sessions::NativeState,
    },
    chat_message_send::write_one,
    db::{
        oracle::{BindMap, DbError},
        tx::OracleTx,
        value::DbValue,
    },
    direct_history::query,
    group_membership::{DELETE, GROUP, MEMBER},
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

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Action {
    Approve,
    Reject,
    Remove,
    Role(String),
    Mute { hours: u32, reason: Option<String> },
    Unmute,
}

impl Action {
    fn permission_message(&self) -> &'static str {
        match self {
            Self::Approve | Self::Reject => "无权审批成员",
            Self::Remove => "无权移除成员",
            Self::Role(_) => "无权修改角色",
            Self::Mute { .. } => "无权禁言成员",
            Self::Unmute => "无权解除禁言",
        }
    }

    fn audit_action(&self) -> &'static str {
        match self {
            Self::Approve => "approve_member",
            Self::Reject => "reject_member",
            Self::Remove => "remove_member",
            Self::Role(_) => "change_role",
            Self::Mute { .. } => "mute_member",
            Self::Unmute => "unmute_member",
        }
    }
}

pub enum Outcome {
    Changed,
    Unchanged,
    Muted(String),
    GroupMissing,
    MemberMissing,
    Forbidden,
    NotPending,
}

const APPROVAL_TARGET: &str = "SELECT user_id,role,status FROM n_group_members WHERE group_id=:group_id AND member_id=:member_id FOR UPDATE";
const APPROVE: &str = "UPDATE n_group_members SET status='active' WHERE group_id=:group_id AND member_id=:member_id AND status='pending' AND role='member'";
const REJECT: &str = "DELETE FROM n_group_members WHERE group_id=:group_id AND member_id=:member_id AND status='pending' AND role='member'";
pub(crate) const AUDIT: &str = "INSERT INTO n_group_audit_logs (group_id,actor_id,target_user_id,action,details) VALUES (:group_id,:actor_id,:target_user_id,:action,:details)";
const ROLE: &str = "UPDATE n_group_members SET role=:role WHERE group_id=:group_id AND user_id=:user_id AND status IN ('active','muted') AND role<>'owner'";
const MUTE: &str = "UPDATE n_group_members SET status='muted',mute_until=SYSTIMESTAMP+NUMTODSINTERVAL(:hours,'HOUR'),ban_reason=:reason WHERE group_id=:group_id AND user_id=:user_id AND status IN ('active','muted') AND role<>'owner'";
const UNMUTE: &str = "UPDATE n_group_members SET status='active',mute_until=NULL,ban_reason=NULL WHERE group_id=:group_id AND user_id=:user_id AND status='muted' AND role<>'owner'";
const EXPIRY: &str = "SELECT TO_CHAR(SYS_EXTRACT_UTC(FROM_TZ(mute_until,TO_CHAR(SYSTIMESTAMP,'TZH:TZM'))),'YYYY-MM-DD\"T\"HH24:MI:SS.FF3\"Z\"') AS mute_until FROM n_group_members WHERE group_id=:group_id AND user_id=:user_id";

fn member_rank(role: &str) -> u8 {
    match role {
        "owner" => 4,
        "admin" => 3,
        "moderator" => 2,
        "member" => 1,
        _ => 0,
    }
}

pub(crate) fn execute(
    conn: &oracle::Connection,
    viewer: u64,
    group: u64,
    target: u64,
    action: Action,
) -> Result<Outcome, DbError> {
    let viewer = i64::try_from(viewer).map_err(|_| DbError::SchemaNotReady)?;
    let group = i64::try_from(group).map_err(|_| DbError::SchemaNotReady)?;
    let target = i64::try_from(target).map_err(|_| DbError::SchemaNotReady)?;
    let tx = OracleTx::new(conn);
    let result = (|| {
        let group_binds = BindMap::from([("group_id".into(), DbValue::I64(group))]);
        let groups = query(conn, GROUP, group_binds.clone())?;
        let Some(group_row) = groups.first() else {
            return Ok(Outcome::GroupMissing);
        };
        if row_number(group_row, "IS_ACTIVE") != 1 || row_number(group_row, "IS_DELETED") != 0 {
            return Ok(Outcome::GroupMissing);
        }
        let mut actor_binds = group_binds.clone();
        actor_binds.insert("user_id".into(), DbValue::I64(viewer));
        let actors = query(conn, MEMBER, actor_binds)?;
        let Some(actor) = actors.first() else {
            return Ok(Outcome::Forbidden);
        };
        let rank = member_rank(&row_text(actor, "ROLE"));
        if row_text(actor, "STATUS") != "active"
            || rank
                < if matches!(action, Action::Role(_)) {
                    3
                } else {
                    2
                }
        {
            return Ok(Outcome::Forbidden);
        }

        let approval = matches!(action, Action::Approve | Action::Reject);
        let mut binds = group_binds.clone();
        let key = if approval { "member_id" } else { "user_id" };
        binds.insert(key.into(), DbValue::I64(target));
        let members = query(
            conn,
            if approval { APPROVAL_TARGET } else { MEMBER },
            binds.clone(),
        )?;
        let Some(member) = members.first() else {
            return Ok(Outcome::MemberMissing);
        };
        let user = if approval {
            row_number(member, "USER_ID")
        } else {
            target
        };
        let role = row_text(member, "ROLE");
        let status = row_text(member, "STATUS");
        let target_rank = member_rank(&role);
        if user == viewer
            || user == row_number(group_row, "OWNER_ID")
            || target_rank == 0
            || target_rank >= rank
            || status == "banned"
        {
            return Ok(Outcome::Forbidden);
        }
        if approval && (role != "member" || status != "pending") {
            return Ok(Outcome::NotPending);
        }
        if matches!(
            action,
            Action::Role(_) | Action::Mute { .. } | Action::Unmute
        ) && status != "active"
            && status != "muted"
        {
            return Ok(Outcome::Forbidden);
        }
        let mut details = DbValue::Null;
        let lookup = binds.clone();
        let statement = match &action {
            Action::Approve => APPROVE,
            Action::Reject => REJECT,
            Action::Remove => DELETE,
            Action::Role(new) => {
                let new_rank = member_rank(new);
                if new_rank == 0 || new_rank >= rank {
                    return Ok(Outcome::Forbidden);
                }
                if new == &role {
                    return Ok(Outcome::Unchanged);
                }
                details = DbValue::String(json!({"old_role":role,"new_role":new}).to_string());
                binds.insert("role".into(), DbValue::String(new.clone()));
                ROLE
            }
            Action::Mute { hours, reason } => {
                details = DbValue::String(
                    json!({"duration_hours":hours, "reason":reason.as_deref().unwrap_or_default()})
                        .to_string(),
                );
                binds.insert("hours".into(), DbValue::I64(i64::from(*hours)));
                binds.insert("reason".into(), DbValue::from_option_string(reason.clone()));
                MUTE
            }
            Action::Unmute => {
                if status == "active" {
                    return Ok(Outcome::Unchanged);
                }
                UNMUTE
            }
        };
        write_one(&tx, statement, binds)?;
        let outcome = if matches!(action, Action::Mute { .. }) {
            let rows = query(conn, EXPIRY, lookup)?;
            let expiry = rows
                .first()
                .and_then(|row| nullable_text(row, "MUTE_UNTIL"))
                .filter(|value| !value.is_empty())
                .ok_or(DbError::SchemaNotReady)?;
            Outcome::Muted(expiry)
        } else {
            Outcome::Changed
        };
        let mut audit = group_binds;
        audit.extend([
            ("actor_id".into(), DbValue::I64(viewer)),
            ("target_user_id".into(), DbValue::I64(user)),
            (
                "action".into(),
                DbValue::String(action.audit_action().into()),
            ),
            ("details".into(), details),
        ]);
        write_one(&tx, AUDIT, audit)?;
        Ok(outcome)
    })();
    match result {
        Ok(outcome @ (Outcome::Changed | Outcome::Muted(_))) => match tx.commit() {
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

enum RequestKind {
    Approve(Body),
    Role(Body),
    Mute(Body),
    Ready(Action),
}

async fn body_value(body: Body, message: &str) -> Result<Value, ApiError> {
    let bytes = to_bytes(body, 1 << 20)
        .await
        .map_err(|_| ApiError::bad_request(message))?;
    let body: Value = serde_json::from_slice(&bytes).map_err(|_| ApiError::bad_request(message))?;
    if !body.is_object() {
        return Err(ApiError::bad_request(message));
    }
    Ok(body)
}

async fn action(request: RequestKind) -> Result<Action, ApiError> {
    const BAD_OBJECT: &str = "请求体必须是 JSON 对象";
    match request {
        RequestKind::Ready(action) => Ok(action),
        RequestKind::Approve(body) => {
            let body = body_value(body, "approved 参数错误").await?;
            match body.get("approved").and_then(Value::as_bool) {
                Some(true) => Ok(Action::Approve),
                Some(false) => Ok(Action::Reject),
                None => Err(ApiError::bad_request("approved 参数错误")),
            }
        }
        RequestKind::Role(body) => {
            let body = body_value(body, BAD_OBJECT).await?;
            match body.get("role").and_then(Value::as_str) {
                Some(value @ ("admin" | "moderator" | "member")) => Ok(Action::Role(value.into())),
                _ => Err(ApiError::bad_request("role 参数错误")),
            }
        }
        RequestKind::Mute(body) => {
            let body = body_value(body, BAD_OBJECT).await?;
            let hours = match body.get("duration_hours") {
                None => 24,
                Some(value) => value
                    .as_f64()
                    .filter(|v| (1.0..=8760.0).contains(v) && v.fract() == 0.0)
                    .map(|v| v as u32)
                    .ok_or_else(|| ApiError::bad_request("duration_hours 参数错误"))?,
            };
            let reason = match body.get("reason") {
                None | Some(Value::Null) => None,
                Some(value) => Some(
                    value
                        .as_str()
                        .filter(|s| s.len() <= 200)
                        .ok_or_else(|| ApiError::bad_request("reason 参数错误"))?
                        .to_owned(),
                ),
            };
            Ok(Action::Mute { hours, reason })
        }
    }
}

async fn route(
    state: NativeState,
    ids: (String, String),
    headers: HeaderMap,
    request: RequestKind,
) -> Response {
    let result = async {
        let (viewer, group) = crate::posts::bookmark::interaction_identity(&state, &ids.0, &headers).await?;
        let raw = ids.1;
        let target = raw.parse::<u64>().ok().filter(|id| {
            (1..=9_007_199_254_740_991).contains(id) && !raw.starts_with('0') && raw.bytes().all(|c| c.is_ascii_digit())
        }).ok_or_else(|| ApiError::bad_request("成员 ID 参数错误"))?;
        let action = action(request).await?;
        let expiry = match state.repository.manage_group_admission(viewer,group,target,action.clone()).await
            .map_err(|_| ApiError::server_error("服务器内部错误"))? {
            Outcome::Changed | Outcome::Unchanged => None,
            Outcome::Muted(expiry) => Some(expiry),
            Outcome::GroupMissing => return Err(ApiError::not_found("群组不存在")),
            Outcome::MemberMissing => return Err(ApiError::not_found("成员不存在")),
            Outcome::Forbidden => return Err(ApiError::unprocessable(action.permission_message())),
            Outcome::NotPending => return Err(ApiError::unprocessable("只能处理待审批的普通成员")),
        };
        let response = match action {
            Action::Approve => V2Response::ok_with_message(json!({"member_id":target,"status":"active"}),"member approved"),
            Action::Reject => V2Response::ok_with_message(json!({"member_id":target,"status":"rejected"}),"member rejected"),
            Action::Remove => V2Response::ok_with_message(Value::Null,"member removed"),
            Action::Role(role) => V2Response::ok_with_message(json!({"user_id":target,"role":role}),"role updated"),
            Action::Mute { .. } => V2Response::ok_with_message(
                json!({"user_id":target,"status":"muted","mute_until":expiry.ok_or_else(|| ApiError::server_error("服务器内部错误"))?}),"member muted"),
            Action::Unmute => V2Response::ok_with_message(json!({"user_id":target,"status":"active"}),"member unmuted"),
        };
        Ok(Json(response))
    }.await;
    let mut response = result.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}

pub(crate) async fn approve(
    State(state): State<NativeState>,
    Path(ids): Path<(String, String)>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    route(state, ids, headers, RequestKind::Approve(body)).await
}

pub(crate) async fn remove(
    State(state): State<NativeState>,
    Path(ids): Path<(String, String)>,
    headers: HeaderMap,
) -> Response {
    route(state, ids, headers, RequestKind::Ready(Action::Remove)).await
}

pub(crate) async fn role(
    State(state): State<NativeState>,
    Path(ids): Path<(String, String)>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    route(state, ids, headers, RequestKind::Role(body)).await
}

pub(crate) async fn mute(
    State(state): State<NativeState>,
    Path(ids): Path<(String, String)>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    route(state, ids, headers, RequestKind::Mute(body)).await
}

pub(crate) async fn unmute(
    State(state): State<NativeState>,
    Path(ids): Path<(String, String)>,
    headers: HeaderMap,
) -> Response {
    route(state, ids, headers, RequestKind::Ready(Action::Unmute)).await
}
