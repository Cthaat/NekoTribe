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
    direct_send::next_id,
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

pub struct Input {
    pub target: Option<i64>,
    pub max_uses: i64,
    pub hours: i64,
    pub message: Option<String>,
}

pub enum Outcome {
    Created {
        data: Value,
        push: Option<(u64, u64)>,
    },
    GroupMissing,
    TargetMissing,
    Forbidden,
    SelfInvite,
    AlreadyMember,
}

const INSERT: &str = "INSERT INTO n_group_invites (invite_id,group_id,inviter_id,invitee_id,invite_code,max_uses,message,expires_at)\nVALUES (:invite_id,:group_id,:inviter_id,:invitee_id,:invite_code,:max_uses,:message,SYSTIMESTAMP+NUMTODSINTERVAL(:expire_hours,'HOUR'))";
const EXPIRY: &str = "SELECT TO_CHAR(SYS_EXTRACT_UTC(FROM_TZ(expires_at,TO_CHAR(SYSTIMESTAMP,'TZH:TZM'))),'YYYY-MM-DD\"T\"HH24:MI:SS.FF3\"Z\"') AS expires_at FROM n_group_invites WHERE invite_id=:invite_id";
const TARGET: &str =
    "SELECT user_id FROM n_users WHERE user_id=:target AND is_active=1 AND status='active'";
const PREFERENCE: &str = "SELECT is_enabled FROM n_group_notification_preferences WHERE group_id=:group_id AND user_id=:user_id";
const NAMES: &str = "SELECT g.name,COALESCE(u.display_name,u.username) AS inviter_name FROM n_groups g JOIN n_users u ON u.user_id=:inviter_id WHERE g.group_id=:group_id";
const DELIVERY:&str="SELECT NVL(us.push_notification_enabled,1) AS push_enabled,NVL(np.is_enabled,1) AS type_enabled
FROM n_users u LEFT JOIN n_user_settings us ON us.user_id=u.user_id
LEFT JOIN n_notification_preferences np ON np.user_id=u.user_id AND np.notification_type='group_invite'
WHERE u.user_id=:user_id AND u.is_active=1";
const NOTICE:&str="INSERT INTO n_notifications
(notification_id,user_id,actor_id,type,title,message,resource_type,resource_id,priority,metadata_json)
VALUES (:notification_id,:user_id,:inviter_id,'group_invite',:title,:message,'group_invite',:invite_id,'normal',:metadata)";

fn number(key: &str, n: i64) -> (String, DbValue) {
    (key.into(), DbValue::I64(n))
}

fn parse(raw: &[u8]) -> Result<Input, ApiError> {
    let invalid = || ApiError::bad_request("请求体必须是 JSON 对象");
    let value: Value = serde_json::from_slice(raw).map_err(|_| invalid())?;
    let fields = value.as_object().ok_or_else(invalid)?;
    let integer = |key: &str, value: &Value, max: i64| {
        value
            .as_f64()
            .filter(|v| *v >= 1.0 && *v <= max as f64 && v.fract() == 0.0)
            .map(|v| v as i64)
            .ok_or_else(|| ApiError::bad_request(format!("{key} 参数错误")))
    };
    let target = fields
        .get("invitee_id")
        .filter(|v| !v.is_null())
        .map(|v| integer("invitee_id", v, 9_007_199_254_740_991))
        .transpose()?;
    let max_uses = fields
        .get("max_uses")
        .map(|v| integer("max_uses", v, 99_999))
        .transpose()?
        .unwrap_or(1);
    let hours = fields
        .get("expire_hours")
        .map(|v| integer("expire_hours", v, 8760))
        .transpose()?
        .unwrap_or(168);
    let message = fields
        .get("message")
        .filter(|v| !v.is_null())
        .map(|v| {
            v.as_str()
                .filter(|s| s.len() <= 200)
                .map(str::to_owned)
                .ok_or_else(|| ApiError::bad_request("message 参数错误"))
        })
        .transpose()?;
    Ok(Input {
        target,
        max_uses: if target.is_some() { 1 } else { max_uses },
        hours,
        message,
    })
}

fn notice(
    conn: &oracle::Connection,
    tx: &OracleTx<'_>,
    viewer: i64,
    group: i64,
    target: i64,
    invite: i64,
    message: Option<&str>,
) -> Result<Option<(u64, u64)>, DbError> {
    let target_binds = BindMap::from([number("user_id", target)]);
    let prefs = query(
        conn,
        PREFERENCE,
        BindMap::from([number("group_id", group), number("user_id", target)]),
    )?;
    if prefs
        .first()
        .is_some_and(|r| row_number(r, "IS_ENABLED") == 0)
    {
        return Ok(None);
    }
    let preferences = query(conn, DELIVERY, target_binds.clone())?;
    let Some(pref) = preferences
        .first()
        .filter(|r| row_number(r, "TYPE_ENABLED") != 0)
    else {
        return Ok(None);
    };
    let names = query(
        conn,
        NAMES,
        BindMap::from([number("group_id", group), number("inviter_id", viewer)]),
    )?;
    let names = names.first().ok_or(DbError::SchemaNotReady)?;
    let mut title = format!(
        "{} 邀请你加入 {}",
        row_text(names, "INVITER_NAME"),
        row_text(names, "NAME")
    );
    while title.len() > 200 {
        title.pop();
    }
    let id = next_id(conn, "SELECT seq_notification_id.NEXTVAL AS id FROM dual")?;
    let mut binds = target_binds;
    binds.extend([
        number("notification_id", id),
        number("inviter_id", viewer),
        number("invite_id", invite),
        ("title".into(), DbValue::String(title)),
        (
            "message".into(),
            DbValue::String(
                message
                    .filter(|text| !text.is_empty())
                    .unwrap_or("你收到了一条新的群组邀请。")
                    .into(),
            ),
        ),
        (
            "metadata".into(),
            DbValue::String(
                json!({"group_id":group,"invite_id":invite,"event":"group_invite_created"})
                    .to_string(),
            ),
        ),
    ]);
    write_one(tx, NOTICE, binds)?;
    Ok((row_number(pref, "PUSH_ENABLED") != 0).then_some((target as u64, id as u64)))
}

pub(crate) fn execute(
    conn: &oracle::Connection,
    viewer: u64,
    group: u64,
    input: Input,
) -> Result<Outcome, DbError> {
    let viewer = i64::try_from(viewer).map_err(|_| DbError::SchemaNotReady)?;
    let group = i64::try_from(group).map_err(|_| DbError::SchemaNotReady)?;
    let tx = OracleTx::new(conn);
    let outcome = (|| {
        let gb = BindMap::from([number("group_id", group)]);
        let groups = query(conn, GROUP, gb.clone())?;
        let Some(info) = groups.first() else {
            return Ok(Outcome::GroupMissing);
        };
        if row_number(info, "IS_ACTIVE") != 1 || row_number(info, "IS_DELETED") != 0 {
            return Ok(Outcome::GroupMissing);
        }
        let member = |id| {
            let mut binds = gb.clone();
            binds.insert("user_id".into(), DbValue::I64(id));
            query(conn, MEMBER, binds)
        };
        if !member(viewer)?.first().is_some_and(|r| {
            row_text(r, "STATUS") == "active"
                && matches!(
                    row_text(r, "ROLE").as_str(),
                    "owner" | "admin" | "moderator" | "member"
                )
        }) {
            return Ok(Outcome::Forbidden);
        }

        let code = if let Some(target) = input.target {
            if target == viewer {
                return Ok(Outcome::SelfInvite);
            }
            if query(conn, TARGET, BindMap::from([number("target", target)]))?.is_empty() {
                return Ok(Outcome::TargetMissing);
            }
            if !member(target)?.is_empty() {
                return Ok(Outcome::AlreadyMember);
            }
            None
        } else {
            let mut random = [0_u8; 16];
            getrandom::fill(&mut random).map_err(|_| DbError::SchemaNotReady)?;
            Some(hex::encode_upper(random))
        };
        let id = next_id(conn, "SELECT seq_group_invite_id.NEXTVAL AS id FROM dual")?;
        let mut binds = gb;
        binds.extend([
            number("invite_id", id),
            number("inviter_id", viewer),
            number("max_uses", input.max_uses),
            number("expire_hours", input.hours),
            (
                "invitee_id".into(),
                input.target.map(DbValue::I64).unwrap_or(DbValue::Null),
            ),
            (
                "invite_code".into(),
                DbValue::from_option_string(code.clone()),
            ),
            (
                "message".into(),
                DbValue::from_option_string(input.message.clone()),
            ),
        ]);
        write_one(&tx, INSERT, binds)?;
        let rows = query(conn, EXPIRY, BindMap::from([number("invite_id", id)]))?;
        let expires = rows
            .first()
            .and_then(|r| nullable_text(r, "EXPIRES_AT"))
            .filter(|s| !s.is_empty())
            .ok_or(DbError::SchemaNotReady)?;
        let push = match input.target {
            Some(target) => notice(
                conn,
                &tx,
                viewer,
                group,
                target,
                id,
                input.message.as_deref(),
            )?,
            None => None,
        };
        let url = code.as_ref().map(|code| format!("/groups/invite/{code}"));
        Ok(Outcome::Created {
            data: json!({"invite_id":id,"invite_code":code,"invite_url":url,"expires_at":expires}),
            push,
        })
    })();
    match outcome {
        Ok(created @ Outcome::Created { .. }) => match tx.commit() {
            Ok(()) => Ok(created),
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

async fn push_notice(state: &NativeState, target: u64, id: u64) {
    if let Some(publisher) = &state.notification_publisher {
        let result = async {
            let mut notice = state
                .repository
                .read_notification(target, id)
                .await
                .ok()??;
            crate::notifications::hydrate_notification(state, target, &mut notice)
                .await
                .ok()?;
            let event = json!({"notification":notice,"notification_type":"group_invite"});
            publisher
                .publish(target, "notification_created", event.as_object()?)
                .await
                .ok()
        }
        .await;
        if result.is_none() {
            eprintln!("group invitation realtime delivery unavailable");
        }
    }
}

pub(crate) async fn create(
    State(state): State<NativeState>,
    Path(id): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    let result = async {
        let (viewer, group) =
            crate::posts::bookmark::interaction_identity(&state, &id, &headers).await?;
        let body = to_bytes(body, 1 << 20)
            .await
            .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
        match state
            .repository
            .create_group_invite(viewer, group, parse(&body)?)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?
        {
            Outcome::Created { data, push } => {
                if let Some((target, id)) = push {
                    push_notice(&state, target, id).await;
                }
                Ok(Json(V2Response::ok_with_message(data, "invite created")))
            }
            Outcome::GroupMissing => Err(ApiError::not_found("群组不存在")),
            Outcome::TargetMissing => Err(ApiError::not_found("被邀请用户不存在")),
            Outcome::Forbidden => Err(ApiError::unprocessable("无权创建邀请")),
            Outcome::SelfInvite => Err(ApiError::unprocessable("不能邀请自己")),
            Outcome::AlreadyMember => Err(ApiError::unprocessable("被邀请用户已有群组成员记录")),
        }
    }
    .await;
    let mut response = result.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}
