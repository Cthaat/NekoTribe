use crate::{
    auth::{
        session_list::SessionPage,
        session_repository::{row_number, row_text, SessionExecutor},
        sessions::{NativeState, SessionStoreError},
        storage_urls::StorageUrlPolicy,
    },
    chat_message_send::write_one,
    db::{
        oracle::{BindMap, DbError},
        tx::OracleTx,
        value::DbValue,
    },
    direct_history::query,
    direct_send::next_id,
    group_content,
    httpx::{errors::ApiError, response::V2Response},
    posts::create_notification::{self, PostNoticeInput},
};
use axum::{
    body::{to_bytes, Body},
    extract::{Path, State},
    http::{header::CACHE_CONTROL, HeaderMap, HeaderValue, Method},
    response::{IntoResponse, Response},
    Json,
};
use serde_json::{json, Value};

pub enum Action {
    Create {
        content: String,
        media: String,
        announcement: bool,
    },
    Delete {
        reason: String,
    },
    Pin(bool),
    Like(bool),
}

pub struct Request {
    pub group: u64,
    pub post: u64,
    pub action: Action,
}

pub enum Outcome {
    Saved(Value),
    MissingGroup,
    MissingMedia,
    InvalidMedia,
    PublishForbidden,
    MissingPost,
    Forbidden(&'static str),
}

pub(crate) const LOCK: &str = "SELECT group_id FROM n_groups WHERE group_id=:group_id AND is_active=1 AND is_deleted=0 FOR UPDATE";
const VIEW: &str = "SELECT fn_can_view_group(:user_id,:group_id) AS allowed FROM dual";
const POST: &str = "SELECT fn_can_post_in_group(:user_id,:group_id) AS allowed FROM dual";
pub(crate) const MODERATE: &str =
    "SELECT fn_has_group_permission(:user_id,:group_id,'moderator') AS allowed FROM dual";
const AUTHOR_VISIBLE: &str = "SELECT 1 AS visible FROM n_users u
WHERE u.user_id=:author_id AND u.is_active=1
  AND NOT EXISTS (SELECT 1 FROM n_user_blocks b
    WHERE (b.user_id=:viewer_id AND b.target_user_id=u.user_id)
       OR (b.target_user_id=:viewer_id AND b.user_id=u.user_id))";

pub(crate) const AUTHOR: &str = "SELECT author_id FROM n_group_posts WHERE group_id=:group_id AND post_id=:post_id AND is_deleted=0";
const INSERT: &str =
    "INSERT INTO n_group_posts (post_id,group_id,author_id,content,media_urls,is_announcement)
VALUES (:post_id,:group_id,:user_id,:content,:media_urls,:is_announcement)";
const DELETE: &str =
    "UPDATE n_group_posts SET is_deleted=1,deleted_by=:user_id,delete_reason=:reason
WHERE group_id=:group_id AND post_id=:post_id AND is_deleted=0";
const PIN: &str = "UPDATE n_group_posts SET is_pinned=:is_pinned
WHERE group_id=:group_id AND post_id=:post_id AND is_deleted=0";
const LIKE: &str = "INSERT INTO n_group_post_likes (post_id,user_id)
SELECT :post_id,:user_id FROM dual WHERE NOT EXISTS
(SELECT 1 FROM n_group_post_likes WHERE post_id=:post_id AND user_id=:user_id)";
const UNLIKE: &str = "DELETE FROM n_group_post_likes WHERE post_id=:post_id AND user_id=:user_id";

pub(crate) fn number(key: &str, value: i64) -> (String, DbValue) {
    (key.into(), DbValue::I64(value))
}

fn text(key: &str, value: String) -> (String, DbValue) {
    (
        key.into(),
        if value.is_empty() {
            DbValue::Null
        } else {
            DbValue::String(value)
        },
    )
}

pub(crate) fn permission(
    conn: &oracle::Connection,
    sql: &str,
    group: i64,
    actor: i64,
) -> Result<bool, DbError> {
    let rows = query(
        conn,
        sql,
        BindMap::from([number("group_id", group), number("user_id", actor)]),
    )?;
    let row = rows.first().ok_or(DbError::SchemaNotReady)?;
    Ok(row_number(row, "ALLOWED") == 1)
}

pub(crate) fn author_visible(conn: &oracle::Connection, viewer: i64, author: i64) -> Result<bool, DbError> {
    let rows = query(
        conn,
        AUTHOR_VISIBLE,
        BindMap::from([number("viewer_id", viewer), number("author_id", author)]),
    )?;
    Ok(!rows.is_empty())
}

pub(crate) fn lock_group(
    conn: &oracle::Connection,
    group: i64,
    actor: i64,
) -> Result<bool, DbError> {
    let rows = query(conn, LOCK, BindMap::from([number("group_id", group)]))?;
    Ok(!rows.is_empty() && permission(conn, VIEW, group, actor)?)
}

pub(crate) fn execute(
    conn: &oracle::Connection,
    viewer: u64,
    request: Request,
    storage: &StorageUrlPolicy,
) -> Result<Outcome, DbError> {
    let id = |value| i64::try_from(value).map_err(|_| DbError::SchemaNotReady);
    let (actor, group, post) = (id(viewer)?, id(request.group)?, id(request.post)?);
    let tx = OracleTx::new(conn);
    let result = (|| {
        if !lock_group(conn, group, actor)? {
            return Ok(Outcome::MissingGroup);
        }
        if let Action::Create {
            content,
            media,
            announcement,
        } = request.action
        {
            if !permission(conn, POST, group, actor)? {
                return Ok(Outcome::Forbidden("无权发帖"));
            }
            if announcement && !permission(conn, MODERATE, group, actor)? {
                return Ok(Outcome::Forbidden("无权发布公告"));
            }
            if !crate::moderation::publish_policy::allowed(actor, |sql, binds| {
                query(conn, sql, binds)
            })? {
                return Ok(Outcome::PublishForbidden);
            }
            let mut urls: Vec<_> = media.split(',').map(str::to_owned).collect();
            if !crate::group_settings::lock_group_media_urls(&tx, &mut urls, storage)? {
                return Ok(Outcome::MissingMedia);
            }
            let media = urls.join(",");
            if media.len() > 2000 || urls.iter().any(|url| url.contains(',')) {
                return Ok(Outcome::InvalidMedia);
            }
            let post = next_id(conn, "SELECT seq_group_post_id.NEXTVAL AS id FROM dual")?;
            if !(1..=9_007_199_254_740_991).contains(&post) {
                return Err(DbError::SchemaNotReady);
            }
            write_one(
                &tx,
                INSERT,
                BindMap::from([
                    number("post_id", post),
                    number("group_id", group),
                    number("user_id", actor),
                    text("content", content),
                    text("media_urls", media),
                    number("is_announcement", i64::from(announcement)),
                ]),
            )?;
            let detail = group_content::execute(
                conn,
                viewer,
                group_content::Request {
                    group: request.group,
                    post: post as u64,
                    comment: 0,
                    comments: false,
                    page: SessionPage {
                        page: 1.0,
                        page_size: 1.0,
                        start: 1.0,
                        end: 1.0,
                    },
                    order: "all".into(),
                },
                storage,
            )?;
            let group_content::Outcome::Found(detail, _) = detail else {
                return Err(DbError::SchemaNotReady);
            };
            return Ok(Outcome::Saved(detail));
        }

        let scoped = BindMap::from([number("group_id", group), number("post_id", post)]);
        let authors = query(conn, AUTHOR, scoped.clone())?;
        let Some(row) = authors.first() else {
            return Ok(Outcome::MissingPost);
        };
        let author = row_number(row, "AUTHOR_ID");
        let check_visibility = matches!(&request.action, Action::Pin(true) | Action::Like(_));
        if check_visibility && !author_visible(conn, actor, author)? {
            return Ok(Outcome::MissingPost);
        }
        let denied = match request.action {
            Action::Pin(_) => Some("无权置顶帖子"),
            Action::Delete { .. } if row_number(row, "AUTHOR_ID") != actor => Some("无权删除帖子"),
            _ => None,
        };
        if let Some(message) = denied {
            if !permission(conn, MODERATE, group, actor)? {
                return Ok(Outcome::Forbidden(message));
            }
        }
        let mut binds = scoped;
        let data = match request.action {
            Action::Delete { reason } => {
                binds.extend([number("user_id", actor), text("reason", reason)]);
                write_one(&tx, DELETE, binds)?;
                Value::Null
            }
            Action::Pin(pin) => {
                binds.insert("is_pinned".into(), DbValue::I64(i64::from(pin)));
                write_one(&tx, PIN, binds)?;
                json!({"post_id":post,"is_pinned":pin})
            }
            Action::Like(liked) => {
                tx.execute(
                    if liked { LIKE } else { UNLIKE },
                    BindMap::from([number("post_id", post), number("user_id", actor)]),
                )?;
                let counts = query(
                    conn,
                    "SELECT likes_count FROM n_group_posts WHERE post_id=:post_id",
                    BindMap::from([number("post_id", post)]),
                )?;
                let count = counts.first().ok_or(DbError::SchemaNotReady)?;
                json!({"post_id":post,"is_liked":liked,"likes_count":row_number(count,"LIKES_COUNT")})
            }
            Action::Create { .. } => return Err(DbError::SchemaNotReady),
        };
        if check_visibility && !author_visible(conn, actor, author)? {
            return Ok(Outcome::MissingPost);
        }
        Ok(Outcome::Saved(data))
    })();
    match result {
        Ok(value @ Outcome::Saved(_)) => {
            if let Err(error) = tx.commit() {
                let _ = tx.rollback();
                return Err(error);
            }
            Ok(value)
        }
        other => {
            tx.rollback()?;
            other
        }
    }
}

#[derive(Clone, Copy)]
enum Operation {
    Create,
    Delete,
    Pin,
    Like(bool),
}

fn parse(operation: Operation, raw: &[u8]) -> Result<Action, ApiError> {
    let error = |key| ApiError::bad_request(format!("{key} 参数错误"));
    if matches!(operation, Operation::Delete)
        && raw
            .iter()
            .all(|&b| matches!(b, b' ' | b'\t' | b'\r' | b'\n'))
    {
        return Ok(Action::Delete {
            reason: String::new(),
        });
    }
    let bad_body = || ApiError::bad_request("请求体必须是 JSON 对象");
    let value: Value = serde_json::from_slice(raw).map_err(|_| bad_body())?;
    let body = value.as_object().ok_or_else(bad_body)?;
    match operation {
        Operation::Create => {
            let content = body
                .get("content")
                .and_then(Value::as_str)
                .map(crate::group_settings::trim)
                .filter(|s| !s.is_empty() && s.len() <= 4000)
                .ok_or_else(|| error("content"))?;
            let announcement = match body.get("is_announcement") {
                None => false,
                Some(value) => value.as_bool().ok_or_else(|| error("is_announcement"))?,
            };
            let mut media = Vec::new();
            if let Some(urls) = body.get("media_urls") {
                for value in urls.as_array().ok_or_else(|| error("media_urls"))? {
                    let url = value
                        .as_str()
                        .filter(|s| !s.contains(','))
                        .ok_or_else(|| error("media_urls"))?;
                    let url = crate::group_settings::trim(url);
                    if !url.is_empty() {
                        media.push(url);
                    }
                }
            }
            let media = media.join(",");
            if media.len() > 2000 {
                return Err(error("media_urls"));
            }
            Ok(Action::Create {
                content: content.into(),
                media,
                announcement,
            })
        }
        Operation::Delete => {
            let reason = match body.get("reason") {
                None | Some(Value::Null) => "",
                Some(value) => value
                    .as_str()
                    .filter(|s| s.len() <= 200)
                    .ok_or_else(|| error("reason"))?,
            };
            Ok(Action::Delete {
                reason: reason.into(),
            })
        }
        Operation::Pin => Ok(Action::Pin(
            body.get("is_pinned")
                .and_then(Value::as_bool)
                .ok_or_else(|| error("is_pinned"))?,
        )),
        Operation::Like(liked) => Ok(Action::Like(liked)),
    }
}

async fn route(
    state: NativeState,
    headers: HeaderMap,
    group: String,
    post: Option<String>,
    operation: Operation,
    body: Body,
) -> Response {
    let result = async {
        let (actor, group) =
            crate::posts::bookmark::interaction_identity(&state, &group, &headers).await?;
        let post = post
            .as_deref()
            .map(group_content::parse_post_id)
            .transpose()?
            .unwrap_or_default();
        let action = if let Operation::Like(liked) = operation {
            Action::Like(liked)
        } else {
            let bytes = to_bytes(body, 1 << 20)
                .await
                .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
            parse(operation, &bytes)?
        };
        let outcome = state
            .repository
            .write_group_post(
                actor,
                Request {
                    group,
                    post,
                    action,
                },
                &state.storage_urls,
            )
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?;
        let data = match outcome {
            Outcome::Saved(value) => value,
            Outcome::MissingGroup => return Err(ApiError::not_found("群组不存在")),
            Outcome::MissingMedia => return Err(ApiError::bad_request("群组附件不存在或已删除")),
            Outcome::InvalidMedia => return Err(ApiError::bad_request("media_urls 参数错误")),
            Outcome::MissingPost => return Err(ApiError::not_found("群组帖子不存在")),
            Outcome::PublishForbidden => {
                return Err(ApiError::forbidden(
                    crate::moderation::publish_policy::message(),
                ))
            }
            Outcome::Forbidden(message) => return Err(ApiError::unprocessable(message)),
        };
        let message = match operation {
            Operation::Create => {
                if notify(&state, actor, group, &data).await.is_err() {
                    eprintln!("group post notification unavailable");
                }
                "group post created"
            }
            Operation::Delete => "group post deleted",
            Operation::Pin => "pin status updated",
            Operation::Like(_) => "success",
        };
        Ok::<_, ApiError>(Json(V2Response::ok_with_message(data, message)))
    }
    .await;
    let mut response = result.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}

pub(crate) async fn create(
    State(state): State<NativeState>,
    Path(group): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    route(state, headers, group, None, Operation::Create, body).await
}
pub(crate) async fn delete(
    State(state): State<NativeState>,
    Path((group, post)): Path<(String, String)>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    route(state, headers, group, Some(post), Operation::Delete, body).await
}
pub(crate) async fn pin(
    State(state): State<NativeState>,
    Path((group, post)): Path<(String, String)>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    route(state, headers, group, Some(post), Operation::Pin, body).await
}
pub(crate) async fn like(
    State(state): State<NativeState>,
    Path((group, post)): Path<(String, String)>,
    headers: HeaderMap,
    method: Method,
) -> Response {
    route(
        state,
        headers,
        group,
        Some(post),
        Operation::Like(method == Method::POST),
        Body::empty(),
    )
    .await
}

pub struct Recipient {
    pub(crate) id: u64,
    pub(crate) group: String,
    pub(crate) actor: String,
}

const RECIPIENTS: &str = "SELECT m.user_id,g.name,COALESCE(u.display_name,u.username) AS actor_name
FROM n_group_members m
JOIN n_groups g ON g.group_id=m.group_id AND g.is_active=1 AND g.is_deleted=0
JOIN n_group_posts p ON p.group_id=g.group_id AND p.post_id=:post_id AND p.is_deleted=0 AND p.author_id=:actor_id
JOIN n_users u ON u.user_id=:actor_id AND u.is_active=1
JOIN n_users recipient ON recipient.user_id=m.user_id AND recipient.is_active=1
LEFT JOIN n_group_notification_preferences pref ON pref.group_id=g.group_id AND pref.user_id=m.user_id
WHERE g.group_id=:group_id AND m.status='active' AND m.user_id<>:actor_id AND NVL(pref.is_enabled,1)=1
  AND NOT EXISTS (SELECT 1 FROM n_user_blocks b
    WHERE (b.user_id=m.user_id AND b.target_user_id=:actor_id)
       OR (b.target_user_id=m.user_id AND b.user_id=:actor_id))
ORDER BY m.user_id";

pub(crate) async fn recipients<E: SessionExecutor>(
    executor: &E,
    actor: u64,
    group: u64,
    post: u64,
) -> Result<Vec<Recipient>, SessionStoreError> {
    let id = |n| i64::try_from(n).map_err(|_| SessionStoreError);
    let rows = executor
        .query(
            RECIPIENTS,
            BindMap::from([
                number("actor_id", id(actor)?),
                number("group_id", id(group)?),
                number("post_id", id(post)?),
            ]),
        )
        .await?;
    rows.iter()
        .map(|row| {
            Ok(Recipient {
                id: u64::try_from(row_number(row, "USER_ID")).map_err(|_| SessionStoreError)?,
                group: row_text(row, "NAME"),
                actor: row_text(row, "ACTOR_NAME"),
            })
        })
        .collect()
}

async fn notify(
    state: &NativeState,
    actor: u64,
    group: u64,
    data: &Value,
) -> Result<(), SessionStoreError> {
    let post = data["post_id"].as_u64().ok_or(SessionStoreError)?;
    let message = notice_excerpt(data["content"].as_str().unwrap_or_default());
    for recipient in state
        .repository
        .group_post_recipients(actor, group, post)
        .await?
    {
        let title = notice_title(format!(
            "{} 在 {} 发布了新帖子",
            recipient.actor, recipient.group
        ));
        let input = PostNoticeInput {
            recipient: recipient.id,
            actor,
            resource_id: post,
            kind: "group_post",
            title,
            message: message.clone(),
            metadata_json: json!({"group_id":group,"post_id":post,"event":"group_post_created"})
                .to_string(),
        };
        if create_notification::deliver(state, &input).await.is_err() {
            eprintln!("group post notification unavailable for recipient");
        }
    }
    Ok(())
}

pub(crate) fn notice_excerpt(content: &str) -> String {
    let mut units: Vec<_> = content.encode_utf16().take(120).collect();
    if units
        .last()
        .is_some_and(|unit| (0xd800..=0xdbff).contains(unit))
    {
        units.pop();
    }
    String::from_utf16_lossy(&units)
}

pub(crate) fn notice_title(mut title: String) -> String {
    while title.len() > 200 {
        title.pop();
    }
    title
}
