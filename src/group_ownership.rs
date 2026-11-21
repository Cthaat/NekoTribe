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
    group_member_admission::AUDIT,
    group_membership::{GROUP, MEMBER},
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
    Transferred,
    MissingGroup,
    MissingMember,
    Forbidden,
    SelfTransfer,
    IneligibleMember,
}

const DEMOTE: &str = "UPDATE n_group_members SET role='admin' WHERE group_id=:group_id AND user_id=:user_id AND role='owner' AND status='active'";
const PROMOTE: &str = "UPDATE n_group_members SET role='owner' WHERE group_id=:group_id AND user_id=:user_id AND role<>'owner' AND status='active'";
const TRANSFER: &str = "UPDATE n_groups SET owner_id=:new_owner_id WHERE group_id=:group_id AND owner_id=:old_owner_id AND is_active=1 AND is_deleted=0";

pub(crate) fn execute(
    conn: &oracle::Connection,
    actor: u64,
    group: u64,
    target: u64,
) -> Result<Outcome, DbError> {
    let id = |n| i64::try_from(n).map_err(|_| DbError::SchemaNotReady);
    let (actor, group, target) = (id(actor)?, id(group)?, id(target)?);
    let tx = OracleTx::new(conn);
    let result = (|| {
        let gb = BindMap::from([("group_id".into(), DbValue::I64(group))]);
        let rows = query(conn, GROUP, gb.clone())?;
        let Some(group_row) = rows.first() else {
            return Ok(Outcome::MissingGroup);
        };
        if row_number(group_row, "IS_ACTIVE") != 1 || row_number(group_row, "IS_DELETED") != 0 {
            return Ok(Outcome::MissingGroup);
        }
        if row_number(group_row, "OWNER_ID") != actor {
            return Ok(Outcome::Forbidden);
        }
        let member = |user| {
            let mut binds = gb.clone();
            binds.insert("user_id".into(), DbValue::I64(user));
            binds
        };
        let old = member(actor);
        let new = member(target);
        let owners = query(conn, MEMBER, old.clone())?;
        if !owners.first().is_some_and(|row| {
            row_text(row, "ROLE") == "owner" && row_text(row, "STATUS") == "active"
        }) {
            return Ok(Outcome::Forbidden);
        }
        if actor == target {
            return Ok(Outcome::SelfTransfer);
        }
        let targets = query(conn, MEMBER, new.clone())?;
        let Some(successor) = targets.first() else {
            return Ok(Outcome::MissingMember);
        };
        if row_text(successor, "STATUS") != "active" || row_text(successor, "ROLE") == "owner" {
            return Ok(Outcome::IneligibleMember);
        }
        write_one(&tx, DEMOTE, old)?;
        write_one(&tx, PROMOTE, new)?;
        let mut transfer = gb.clone();
        transfer.extend([
            ("old_owner_id".into(), DbValue::I64(actor)),
            ("new_owner_id".into(), DbValue::I64(target)),
        ]);
        write_one(&tx, TRANSFER, transfer)?;
        let mut audit = gb;
        audit.extend([
            ("actor_id".into(), DbValue::I64(actor)),
            ("target_user_id".into(), DbValue::I64(target)),
            (
                "action".into(),
                DbValue::String("transfer_ownership".into()),
            ),
            (
                "details".into(),
                DbValue::String(json!({"from":actor,"to":target}).to_string()),
            ),
        ]);
        write_one(&tx, AUDIT, audit)?;
        Ok(Outcome::Transferred)
    })();
    match result {
        Ok(Outcome::Transferred) => match tx.commit() {
            Ok(()) => Ok(Outcome::Transferred),
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

pub(crate) async fn transfer(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    let result = async {
        let (actor, group) =
            crate::posts::bookmark::interaction_identity(&state, &raw, &headers).await?;
        let bad = || ApiError::bad_request("new_owner_id 参数错误");
        let bytes = to_bytes(body, 1 << 20).await.map_err(|_| bad())?;
        let input: Value = serde_json::from_slice(&bytes).map_err(|_| bad())?;
        let target = input
            .get("new_owner_id")
            .and_then(Value::as_f64)
            .filter(|id| (1.0..=9_007_199_254_740_991.0).contains(id) && id.fract() == 0.0)
            .map(|id| id as u64)
            .ok_or_else(bad)?;
        match state
            .repository
            .transfer_group_ownership(actor, group, target)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?
        {
            Outcome::Transferred => Ok(Json(V2Response::ok_with_message(
                json!({"group_id":group,"owner_id":target}),
                "ownership transferred",
            ))),
            Outcome::MissingGroup => Err(ApiError::not_found("群组不存在")),
            Outcome::MissingMember => Err(ApiError::not_found("成员不存在")),
            Outcome::Forbidden => Err(ApiError::unprocessable("只有群主可以转让群组")),
            Outcome::SelfTransfer => Err(ApiError::unprocessable("不能转让给自己")),
            Outcome::IneligibleMember => {
                Err(ApiError::unprocessable("目标用户不是可接任的活跃成员"))
            }
        }
    }
    .await;
    let mut response = result.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}
