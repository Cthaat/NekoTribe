use crate::{
    auth::{
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
    group_post_write::{
        author_visible, lock_group, notice_excerpt, notice_title, number, permission, Recipient, AUTHOR, MODERATE,
    },
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
        parent: Option<i64>,
        reply: Option<i64>,
    },
    Delete,
    Like(bool),
}
pub struct Request {
    pub group: u64,
    pub post: u64,
    pub comment: u64,
    pub action: Action,
}
pub enum Outcome {
    Saved(Value),
    MissingGroup,
    PublishForbidden,
    MissingPost,
    MissingComment,
    Forbidden(&'static str),
}

const MEMBER: &str =
    "SELECT fn_has_group_permission(:user_id,:group_id,'member') AS allowed FROM dual";
const COMMENT_AUTHOR: &str = "SELECT author_id FROM n_group_comments WHERE post_id=:post_id AND comment_id=:comment_id AND is_deleted=0";
const INSERT: &str = "INSERT INTO n_group_comments (comment_id,post_id,author_id,parent_comment_id,reply_to_user_id,content)
VALUES (:comment_id,:post_id,:user_id,:parent_comment_id,:reply_to_user_id,:content)";
const READ_CREATED: &str = "SELECT comment_id,post_id,author_id,parent_comment_id,reply_to_user_id,content,likes_count,created_at,updated_at,
0 AS is_liked_by_me,1 AS can_delete_by_me FROM n_group_comments
WHERE post_id=:post_id AND comment_id=:comment_id AND is_deleted=0";
const DELETE: &str = "UPDATE n_group_comments SET is_deleted=1,deleted_by=:user_id
WHERE post_id=:post_id AND comment_id=:comment_id AND is_deleted=0";
const LIKE: &str = "INSERT INTO n_group_comment_likes (comment_id,user_id)
SELECT :comment_id,:user_id FROM dual WHERE NOT EXISTS
(SELECT 1 FROM n_group_comment_likes WHERE comment_id=:comment_id AND user_id=:user_id)";
const UNLIKE: &str =
    "DELETE FROM n_group_comment_likes WHERE comment_id=:comment_id AND user_id=:user_id";

fn comment_author(
    conn: &oracle::Connection,
    post: i64,
    comment: i64,
) -> Result<Option<i64>, DbError> {
    let rows = query(
        conn,
        COMMENT_AUTHOR,
        BindMap::from([number("post_id", post), number("comment_id", comment)]),
    )?;
    Ok(rows.first().map(|row| row_number(row, "AUTHOR_ID")))
}


fn hidden_target(
    conn: &oracle::Connection,
    actor: i64,
    post_author: i64,
    comment_author: i64,
) -> Result<Option<Outcome>, DbError> {
    if !author_visible(conn, actor, post_author)? {
        return Ok(Some(Outcome::MissingPost));
    }
    if comment_author != post_author && !author_visible(conn, actor, comment_author)? {
        return Ok(Some(Outcome::MissingComment));
    }
    Ok(None)
}

pub(crate) fn execute(
    conn: &oracle::Connection,
    viewer: u64,
    input: Request,
    storage: &StorageUrlPolicy,
) -> Result<Outcome, DbError> {
    let id = |n| i64::try_from(n).map_err(|_| DbError::SchemaNotReady);
    let (actor, group, post, comment) = (
        id(viewer)?,
        id(input.group)?,
        id(input.post)?,
        id(input.comment)?,
    );
    let tx = OracleTx::new(conn);
    let result = (|| {
        if !lock_group(conn, group, actor)? {
            return Ok(Outcome::MissingGroup);
        }
        let posts = query(
            conn,
            AUTHOR,
            BindMap::from([number("group_id", group), number("post_id", post)]),
        )?;
        let Some(post_row) = posts.first() else {
            return Ok(Outcome::MissingPost);
        };
        let post_author = row_number(post_row, "AUTHOR_ID");
        if !matches!(&input.action, Action::Delete) && !author_visible(conn, actor, post_author)? {
            return Ok(Outcome::MissingPost);
        }
        if let Action::Create {
            content,
            parent,
            mut reply,
        } = input.action
        {
            if !permission(conn, MEMBER, group, actor)? {
                return Ok(Outcome::Forbidden("只有群组成员可以评论"));
            }
            let target = if let Some(parent_id) = parent {
                let Some(user) = comment_author(conn, post, parent_id)? else {
                    return Ok(Outcome::MissingComment);
                };
                if user != post_author && !author_visible(conn, actor, user)? {
                    return Ok(Outcome::MissingComment);
                }
                user
            } else {
                post_author
            };
            if reply.is_some_and(|user| user != target) {
                return Ok(Outcome::Forbidden("回复用户与目标不匹配"));
            }
            if parent.is_some() {
                reply = Some(target);
            }
            if !crate::moderation::publish_policy::allowed(actor, |sql, binds| {
                query(conn, sql, binds)
            })? {
                return Ok(Outcome::PublishForbidden);
            }
            let comment = next_id(conn, "SELECT seq_group_comment_id.NEXTVAL AS id FROM dual")?;
            if !(1..=9_007_199_254_740_991).contains(&comment) {
                return Err(DbError::SchemaNotReady);
            }
            let mut binds = BindMap::from([number("post_id", post), number("comment_id", comment)]);
            let read_binds = binds.clone();
            binds.extend([
                number("user_id", actor),
                (
                    "parent_comment_id".into(),
                    parent.map(DbValue::I64).unwrap_or(DbValue::Null),
                ),
                (
                    "reply_to_user_id".into(),
                    reply.map(DbValue::I64).unwrap_or(DbValue::Null),
                ),
                ("content".into(), DbValue::String(content)),
            ]);
            write_one(&tx, INSERT, binds)?;
            let rows = query(conn, READ_CREATED, read_binds)?;
            let row = rows.first().ok_or(DbError::SchemaNotReady)?;
            let mapped = group_content::hydrate_comment(conn, actor, row, storage);
            if let Some(missing) = hidden_target(conn, actor, post_author, target)? {
                return Ok(missing);
            }
            return Ok(Outcome::Saved(mapped?.ok_or(DbError::SchemaNotReady)?));
        }
        let Some(author) = comment_author(conn, post, comment)? else {
            return Ok(Outcome::MissingComment);
        };
        let mut binds = BindMap::from([number("comment_id", comment), number("user_id", actor)]);
        let data = match input.action {
            Action::Delete => {
                if author != actor && !permission(conn, MODERATE, group, actor)? {
                    return Ok(Outcome::Forbidden("无权删除评论"));
                }
                binds.insert("post_id".into(), DbValue::I64(post));
                write_one(&tx, DELETE, binds)?;
                Value::Null
            }
            Action::Like(liked) => {
                if author != post_author && !author_visible(conn, actor, author)? {
                    return Ok(Outcome::MissingComment);
                }
                tx.execute(if liked { LIKE } else { UNLIKE }, binds)?;
                let rows = query(
                    conn,
                    "SELECT likes_count FROM n_group_comments WHERE comment_id=:comment_id",
                    BindMap::from([number("comment_id", comment)]),
                )?;
                let row = rows.first().ok_or(DbError::SchemaNotReady)?;
                if let Some(missing) = hidden_target(conn, actor, post_author, author)? {
                    return Ok(missing);
                }
                json!({"comment_id":comment,"is_liked":liked,"likes_count":row_number(row,"LIKES_COUNT")})
            }
            Action::Create { .. } => return Err(DbError::SchemaNotReady),
        };
        Ok(Outcome::Saved(data))
    })();
    match result {
        Ok(saved @ Outcome::Saved(_)) => {
            if let Err(error) = tx.commit() {
                let _ = tx.rollback();
                return Err(error);
            }
            Ok(saved)
        }
        other => {
            tx.rollback()?;
            other
        }
    }
}

fn parse(raw: &[u8]) -> Result<Action, ApiError> {
    let bad = || ApiError::bad_request("请求体必须是 JSON 对象");
    let value: Value = serde_json::from_slice(raw).map_err(|_| bad())?;
    let body = value.as_object().ok_or_else(bad)?;
    let content = body
        .get("content")
        .and_then(Value::as_str)
        .map(crate::group_settings::trim)
        .filter(|s| !s.is_empty() && s.len() <= 1000)
        .ok_or_else(|| ApiError::bad_request("content 参数错误"))?;
    let optional = |key| match body.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_f64()
            .filter(|id| (1.0..=9_007_199_254_740_991.0).contains(id) && id.fract() == 0.0)
            .map(|id| Some(id as i64))
            .ok_or_else(|| ApiError::bad_request(format!("{key} 参数错误"))),
    };
    Ok(Action::Create {
        content: content.into(),
        parent: optional("parent_comment_id")?,
        reply: optional("reply_to_user_id")?,
    })
}

async fn route(
    state: NativeState,
    headers: HeaderMap,
    group: String,
    post: String,
    comment: Option<String>,
    body: Body,
    action: Option<Action>,
) -> Response {
    let result = async {
        let (actor, group) =
            crate::posts::bookmark::interaction_identity(&state, &group, &headers).await?;
        let post = group_content::parse_post_id(&post)?;
        let comment = comment
            .as_deref()
            .map(|raw| group_content::parse_content_id(raw, "comment_id"))
            .transpose()?
            .unwrap_or_default();
        let action = match action {
            Some(action) => action,
            None => {
                let bytes = to_bytes(body, 1 << 20)
                    .await
                    .map_err(|_| ApiError::bad_request("请求体必须是 JSON 对象"))?;
                parse(&bytes)?
            }
        };
        let message = match action {
            Action::Create { .. } => "group comment created",
            Action::Delete => "group comment deleted",
            Action::Like(_) => "success",
        };
        let value = match state
            .repository
            .write_group_comment(
                actor,
                Request {
                    group,
                    post,
                    comment,
                    action,
                },
                &state.storage_urls,
            )
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?
        {
            Outcome::Saved(value) => value,
            Outcome::MissingGroup => return Err(ApiError::not_found("群组不存在")),
            Outcome::MissingPost => return Err(ApiError::not_found("群组帖子不存在")),
            Outcome::MissingComment => return Err(ApiError::not_found("群组评论不存在")),
            Outcome::PublishForbidden => {
                return Err(ApiError::forbidden(
                    crate::moderation::publish_policy::message(),
                ))
            }
            Outcome::Forbidden(message) => return Err(ApiError::unprocessable(message)),
        };
        if comment == 0 && notify(&state, actor, group, post, &value).await.is_err() {
            eprintln!("group comment notification unavailable");
        }
        Ok::<_, ApiError>(Json(V2Response::ok_with_message(value, message)))
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
    Path((group, post)): Path<(String, String)>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    route(state, headers, group, post, None, body, None).await
}
pub(crate) async fn delete(
    State(state): State<NativeState>,
    Path((group, post, comment)): Path<(String, String, String)>,
    headers: HeaderMap,
) -> Response {
    route(
        state,
        headers,
        group,
        post,
        Some(comment),
        Body::empty(),
        Some(Action::Delete),
    )
    .await
}
pub(crate) async fn like(
    State(state): State<NativeState>,
    Path((group, post, comment)): Path<(String, String, String)>,
    headers: HeaderMap,
    method: Method,
) -> Response {
    route(
        state,
        headers,
        group,
        post,
        Some(comment),
        Body::empty(),
        Some(Action::Like(method == Method::POST)),
    )
    .await
}

const RECIPIENTS: &str = "WITH current_reply AS (
  SELECT c.comment_id,c.post_id,c.parent_comment_id,p.author_id AS post_author,g.group_id,g.name,g.privacy
  FROM n_group_comments c
  JOIN n_group_posts p ON p.post_id=c.post_id AND p.is_deleted=0
  JOIN n_users post_author ON post_author.user_id=p.author_id AND post_author.is_active=1
  JOIN n_groups g ON g.group_id=p.group_id AND g.is_active=1 AND g.is_deleted=0
  WHERE g.group_id=:group_id AND p.post_id=:post_id AND c.comment_id=:comment_id
    AND c.author_id=:actor_id AND c.is_deleted=0
), targets AS (
  SELECT post_author AS user_id FROM current_reply
  UNION
  SELECT parent.author_id AS user_id FROM current_reply r
  JOIN n_group_comments parent ON parent.comment_id=r.parent_comment_id
    AND parent.post_id=r.post_id AND parent.is_deleted=0
)
SELECT t.user_id,r.name AS group_name,COALESCE(u.display_name,u.username) AS actor_name
FROM targets t CROSS JOIN current_reply r
JOIN n_users u ON u.user_id=:actor_id AND u.is_active=1
JOIN n_users recipient ON recipient.user_id=t.user_id AND recipient.is_active=1
LEFT JOIN n_group_notification_preferences pref ON pref.group_id=r.group_id AND pref.user_id=t.user_id
WHERE t.user_id<>:actor_id AND NVL(pref.is_enabled,1)=1
  AND NOT EXISTS (SELECT 1 FROM n_user_blocks b
    WHERE (b.user_id=t.user_id AND b.target_user_id IN (:actor_id,r.post_author))
       OR (b.target_user_id=t.user_id AND b.user_id IN (:actor_id,r.post_author)))
  AND (r.privacy='public' OR EXISTS (SELECT 1 FROM n_group_members m
    WHERE m.group_id=r.group_id AND m.user_id=t.user_id AND m.status='active'))
ORDER BY t.user_id";

pub(crate) async fn recipients<E: SessionExecutor>(
    executor: &E,
    actor: u64,
    group: u64,
    post: u64,
    comment: u64,
) -> Result<Vec<Recipient>, SessionStoreError> {
    let id = |n| i64::try_from(n).map_err(|_| SessionStoreError);
    let rows = executor
        .query(
            RECIPIENTS,
            BindMap::from([
                number("actor_id", id(actor)?),
                number("group_id", id(group)?),
                number("post_id", id(post)?),
                number("comment_id", id(comment)?),
            ]),
        )
        .await?;
    rows.iter()
        .map(|row| {
            Ok(Recipient {
                id: u64::try_from(row_number(row, "USER_ID")).map_err(|_| SessionStoreError)?,
                group: row_text(row, "GROUP_NAME"),
                actor: row_text(row, "ACTOR_NAME"),
            })
        })
        .collect()
}

async fn notify(
    state: &NativeState,
    actor: u64,
    group: u64,
    post: u64,
    value: &Value,
) -> Result<(), SessionStoreError> {
    let comment = value["comment_id"].as_u64().ok_or(SessionStoreError)?;
    let message = notice_excerpt(value["content"].as_str().unwrap_or_default());
    for recipient in state
        .repository
        .group_comment_recipients(actor, group, post, comment)
        .await?
    {
        let input=PostNoticeInput{
            recipient:recipient.id,actor,resource_id:comment,kind:"group_comment",
            title:notice_title(format!("{} 评论了 {} 的帖子",recipient.actor,recipient.group)),message:message.clone(),
            metadata_json:json!({"group_id":group,"post_id":post,"comment_id":comment,"parent_comment_id":value["parent_comment_id"],"event":"group_comment_created"}).to_string()
        };
        if create_notification::deliver(state, &input).await.is_err() {
            eprintln!("group comment notification unavailable for recipient");
        }
    }
    Ok(())
}
