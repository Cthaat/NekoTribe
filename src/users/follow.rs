use crate::{
    auth::{session_list::session_pagination, sessions::NativeState},
    db::{
        oracle::{BindMap, DbError},
        tx::OracleTx,
        value::DbValue,
    },
    httpx::errors::ApiError,
    users::visibility::{lock_user_pair, statement, success, viewer},
};
use axum::{
    body::Body,
    extract::{Path, State},
    http::{Method, Request},
    response::Response,
};
use serde_json::{json, Map, Value};

pub enum FollowOutcome {
    Missing,
    Blocked,
    Applied { count: i64, inserted: bool },
}

pub(crate) fn write_transaction(
    connection: &oracle::Connection,
    actor: u64,
    target: u64,
    remove: bool,
) -> Result<FollowOutcome, DbError> {
    let (actor, target) = (actor as i64, target as i64);
    let tx = OracleTx::new(connection);
    let result = (|| {
        if !lock_user_pair(connection, actor, target)? {
            return Ok(if remove {
                FollowOutcome::Applied {
                    count: 0,
                    inserted: false,
                }
            } else {
                FollowOutcome::Missing
            });
        }
        let target_bind: [(&str, &dyn oracle::sql_type::ToSql); 1] = [("target_id", &target)];
        if !remove {
            if connection
                .query_named(statement("activeTarget"), &target_bind)?
                .next()
                .transpose()?
                .is_none()
            {
                return Ok(FollowOutcome::Missing);
            }
            let blocked = connection.query_row_as_named::<i64>(
                statement("blocked"),
                &[("actor_id", &actor), ("target_id", &target)],
            )?;
            if blocked > 0 {
                return Ok(FollowOutcome::Blocked);
            }
        }
        let count = tx
            .execute(
                statement(if remove { "unfollow" } else { "follow" }),
                BindMap::from([
                    ("actor_id".into(), DbValue::I64(actor)),
                    ("target_id".into(), DbValue::I64(target)),
                ]),
            )?
            .rows_affected;
        if count > 1 {
            return Err(DbError::SchemaNotReady);
        }
        let followers = connection
            .query_named(statement("followCount"), &target_bind)?
            .next()
            .transpose()?
            .map(|row| row.get::<_, Option<i64>>(0))
            .transpose()?
            .flatten()
            .unwrap_or_default();
        Ok(FollowOutcome::Applied {
            count: followers,
            inserted: !remove && count == 1,
        })
    })();
    if matches!(result, Ok(FollowOutcome::Applied { .. })) {
        if let Err(error) = tx.commit() {
            let _ = tx.rollback();
            return Err(error);
        }
    } else {
        tx.rollback()?;
    }
    result
}

fn server_error() -> ApiError {
    ApiError::server_error("服务器内部错误")
}

pub(crate) async fn handle(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    request: Request<Body>,
) -> Result<Response, ApiError> {
    let (parts, _) = request.into_parts();
    let actor = viewer(&state, &parts.headers).await?;
    let target = raw
        .parse::<u64>()
        .ok()
        .filter(|id| {
            !raw.starts_with('0')
                && raw.bytes().all(|b| b.is_ascii_digit())
                && *id <= 9_007_199_254_740_991
        })
        .ok_or_else(|| ApiError::bad_request("id 参数错误"))?;
    if parts.method == Method::GET {
        let kind = match parts.uri.path().rsplit('/').next() {
            Some("following") => "following",
            Some("mutual-following") => "mutual-following",
            _ => "followers",
        };
        let page = session_pagination(parts.uri.query().unwrap_or_default());
        let (mut items, total) = state
            .repository
            .list_user_follows(actor, target, kind, page)
            .await
            .map_err(|_| server_error())?;
        for user in &mut items {
            user["avatar_url"] = state
                .storage_urls
                .normalize_avatar(user["avatar_url"].as_str().unwrap_or_default())
                .map_err(|_| server_error())?
                .into();
        }
        return Ok(success(
            json!({"code":200,"message":"success","data":items,"meta":{
                "page":page.page,"page_size":page.page_size,"total":total,"has_next":page.end < total as f64
            }}),
        ));
    }
    let remove = parts.method == Method::DELETE;
    if !remove && actor == target {
        return Err(ApiError::unprocessable("不能关注自己"));
    }
    let outcome = state
        .repository
        .write_user_follow(actor, target, remove)
        .await
        .map_err(|_| server_error())?;
    let (count, inserted) = match outcome {
        FollowOutcome::Blocked => return Err(ApiError::forbidden("无法关注该用户")),
        FollowOutcome::Missing => return Err(ApiError::not_found("用户不存在")),
        FollowOutcome::Applied { count, inserted } => (count, inserted),
    };
    if inserted
        && deliver_follow_notification(&state, actor, target)
            .await
            .is_err()
    {
        eprintln!("follow notification unavailable");
    }
    Ok(success(json!({"code":200,"message":"success","data":{
        "target_user_id":target,"relationship":if remove { "none" } else { "following" },"followers_count":count
    },"meta":null})))
}

async fn deliver_follow_notification(
    state: &NativeState,
    actor: u64,
    target: u64,
) -> Result<(), ApiError> {
    let stored = state
        .repository
        .prepare_follow_notification(actor, target)
        .await
        .map_err(|_| server_error())?;
    let Some(id) = stored else { return Ok(()) };
    let Some(publisher) = &state.notification_publisher else {
        return Ok(());
    };
    let Some(mut item) = state
        .repository
        .read_notification(target, id)
        .await
        .map_err(|_| server_error())?
    else {
        return Ok(());
    };
    crate::notifications::hydrate_notification(state, target, &mut item).await?;
    publisher
        .publish(
            target,
            "notification_created",
            &Map::from_iter([
                ("notification".into(), item),
                ("notification_type".into(), Value::String("follow".into())),
            ]),
        )
        .await
        .map_err(|_| server_error())
}
