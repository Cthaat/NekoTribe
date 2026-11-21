use crate::{
    auth::{
        session_list::{session_pagination, SessionPage},
        session_repository::{
            nullable_text, profile_date, public_profile_json, row_number, row_text,
            PUBLIC_PROFILE_SQL,
        },
        sessions::NativeState,
        storage_urls::StorageUrlPolicy,
    },
    db::{
        oracle::{BindMap, DbError},
        row::DbRow,
        value::DbValue,
    },
    direct_history::query,
    httpx::errors::ApiError,
};
use axum::{
    extract::{OriginalUri, Path, State},
    http::{header::CACHE_CONTROL, HeaderMap, HeaderValue, Uri},
    response::{IntoResponse, Response},
    Json,
};
use serde_json::{json, Value};

pub struct Request {
    pub group: u64,
    pub post: u64,
    pub comment: u64,
    pub comments: bool,
    pub page: SessionPage,
    pub order: String,
}

pub enum Outcome {
    Found(Value, i64),
    MissingGroup,
    MissingPost,
    MissingUser,
}

const POSTS: &str = "WITH allowed_group AS (
  SELECT g.group_id
  FROM n_groups g
  WHERE g.group_id=:group_id AND g.is_active=1 AND g.is_deleted=0
    AND (g.privacy='public' OR EXISTS (SELECT 1 FROM n_group_members m
      WHERE m.group_id=g.group_id AND m.user_id=:viewer_id AND m.status='active'))
), ranked AS (
  SELECT p.post_id,p.group_id,p.author_id,p.content,p.media_urls,p.is_pinned,p.is_announcement,p.likes_count,p.comments_count,p.views_count,p.created_at,p.updated_at,
    CASE WHEN EXISTS (SELECT 1 FROM n_group_post_likes l
      WHERE l.post_id=p.post_id AND l.user_id=:viewer_id) THEN 1 ELSE 0 END AS is_liked_by_me,
    ROW_NUMBER() OVER (ORDER BY CASE WHEN p.is_pinned=1 THEN 2 WHEN p.is_announcement=1 THEN 1 ELSE 0 END DESC,
      p.created_at DESC,p.post_id DESC) AS rn
  FROM allowed_group g
  JOIN n_group_posts p ON p.group_id=g.group_id AND p.is_deleted=0
  JOIN n_users post_author ON post_author.user_id=p.author_id AND post_author.is_active=1
  WHERE (:post_id=0 OR p.post_id=:post_id)
    AND NOT EXISTS (SELECT 1 FROM n_user_blocks b
      WHERE (b.user_id=:viewer_id AND b.target_user_id=p.author_id)
         OR (b.target_user_id=:viewer_id AND b.user_id=p.author_id))
    AND (:post_type='all' OR :post_type='pinned' AND p.is_pinned=1
      OR :post_type='announcement' AND p.is_announcement=1)
)
SELECT (SELECT COUNT(*) FROM allowed_group) AS group_allowed,t.total,
  r.post_id,r.group_id,r.author_id,r.content,r.media_urls,r.is_pinned,r.is_announcement,r.likes_count,r.comments_count,r.views_count,r.created_at,r.updated_at,r.is_liked_by_me
FROM (SELECT COUNT(*) AS total FROM ranked) t
LEFT JOIN ranked r ON r.rn BETWEEN :start_row AND :end_row
ORDER BY r.rn";

const COMMENTS: &str = "WITH allowed_group AS (
  SELECT g.group_id
  FROM n_groups g
  WHERE g.group_id=:group_id AND g.is_active=1 AND g.is_deleted=0
    AND (g.privacy='public' OR EXISTS (SELECT 1 FROM n_group_members m
      WHERE m.group_id=g.group_id AND m.user_id=:viewer_id AND m.status='active'))
), allowed_post AS (
  SELECT p.post_id,p.group_id
  FROM allowed_group g
  JOIN n_group_posts p ON p.group_id=g.group_id AND p.is_deleted=0
  JOIN n_users post_author ON post_author.user_id=p.author_id AND post_author.is_active=1
  WHERE p.post_id=:post_id
    AND NOT EXISTS (SELECT 1 FROM n_user_blocks b
      WHERE (b.user_id=:viewer_id AND b.target_user_id=p.author_id)
         OR (b.target_user_id=:viewer_id AND b.user_id=p.author_id))
), ranked AS (
  SELECT c.comment_id,c.post_id,c.author_id,c.parent_comment_id,
    CASE WHEN EXISTS (SELECT 1 FROM n_users reply_author
      WHERE reply_author.user_id=c.reply_to_user_id AND reply_author.is_active=1
        AND NOT EXISTS (SELECT 1 FROM n_user_blocks b
          WHERE (b.user_id=:viewer_id AND b.target_user_id=reply_author.user_id)
             OR (b.target_user_id=:viewer_id AND b.user_id=reply_author.user_id)))
      THEN c.reply_to_user_id END AS reply_to_user_id,
    c.content,c.likes_count,c.created_at,c.updated_at,
    CASE WHEN EXISTS (SELECT 1 FROM n_group_comment_likes l
      WHERE l.comment_id=c.comment_id AND l.user_id=:viewer_id) THEN 1 ELSE 0 END AS is_liked_by_me,
    CASE WHEN c.author_id=:viewer_id OR EXISTS (SELECT 1 FROM n_group_members m
      WHERE m.group_id=p.group_id AND m.user_id=:viewer_id AND m.status='active'
        AND m.role IN ('owner','admin','moderator')) THEN 1 ELSE 0 END AS can_delete_by_me,
    ROW_NUMBER() OVER (ORDER BY
      CASE WHEN :comment_sort='popular' THEN c.likes_count END DESC,
      CASE WHEN :comment_sort='oldest' THEN c.created_at END ASC,
      CASE WHEN :comment_sort='oldest' THEN c.comment_id END ASC,
      c.created_at DESC,c.comment_id DESC) AS rn
  FROM allowed_post p
  JOIN n_group_comments c ON c.post_id=p.post_id AND c.is_deleted=0
  JOIN n_users comment_author ON comment_author.user_id=c.author_id AND comment_author.is_active=1
  WHERE (:target_comment_id=0 OR c.comment_id=:target_comment_id)
    AND NOT EXISTS (SELECT 1 FROM n_user_blocks b
      WHERE (b.user_id=:viewer_id AND b.target_user_id=c.author_id)
         OR (b.target_user_id=:viewer_id AND b.user_id=c.author_id))
)
SELECT (SELECT COUNT(*) FROM allowed_group) AS group_allowed,
  (SELECT COUNT(*) FROM allowed_post) AS post_allowed,t.total,
  r.comment_id,r.post_id,r.author_id,r.parent_comment_id,r.reply_to_user_id,r.content,r.likes_count,r.created_at,r.updated_at,r.is_liked_by_me,r.can_delete_by_me
FROM (SELECT COUNT(*) AS total FROM ranked) t
LEFT JOIN ranked r ON r.rn BETWEEN :start_row AND :end_row
ORDER BY r.rn";

pub(crate) fn user(
    conn: &oracle::Connection,
    viewer: i64,
    id: i64,
    storage: &StorageUrlPolicy,
) -> Result<Option<Value>, DbError> {
    let profiles = query(
        conn,
        PUBLIC_PROFILE_SQL,
        BindMap::from([
            ("viewer_id".into(), DbValue::I64(viewer)),
            ("user_id".into(), DbValue::I64(id)),
        ]),
    )?;
    profiles
        .first()
        .map(|row| {
            let mut profile = public_profile_json(row);
            profile["avatar_url"] = storage
                .normalize_avatar(profile["avatar_url"].as_str().unwrap_or_default())
                .map_err(|_| DbError::SchemaNotReady)?
                .into();
            Ok(profile)
        })
        .transpose()
}

pub(crate) fn hydrate_comment(
    conn: &oracle::Connection,
    viewer: i64,
    row: &DbRow,
    storage: &StorageUrlPolicy,
) -> Result<Option<Value>, DbError> {
    let Some(author) = user(conn, viewer, row_number(row, "AUTHOR_ID"), storage)? else {
        return Ok(None);
    };
    let reply = row_number(row, "REPLY_TO_USER_ID");
    let reply_to = if reply == 0 {
        Value::Null
    } else {
        let Some(profile) = user(conn, viewer, reply, storage)? else {
            return Ok(None);
        };
        profile
    };
    let date = |key| {
        nullable_text(row, key)
            .map(|value| profile_date(&value))
            .unwrap_or_default()
    };
    Ok(Some(json!({
      "comment_id":row_number(row,"COMMENT_ID"),"post_id":row_number(row,"POST_ID"),"author":author,
      "parent_comment_id":row.get("PARENT_COMMENT_ID").and_then(DbValue::as_i64),"reply_to_user":reply_to,
      "content":row_text(row,"CONTENT"),"likes_count":row_number(row,"LIKES_COUNT"),
      "is_liked_by_me":row_number(row,"IS_LIKED_BY_ME")==1,"can_delete_by_me":row_number(row,"CAN_DELETE_BY_ME")==1,
      "created_at":date("CREATED_AT"),"updated_at":date("UPDATED_AT")
    })))
}

pub(crate) fn execute(
    conn: &oracle::Connection,
    viewer: u64,
    request: Request,
    storage: &StorageUrlPolicy,
) -> Result<Outcome, DbError> {
    let id = |n| i64::try_from(n).map_err(|_| DbError::SchemaNotReady);
    let viewer = id(viewer)?;
    let mut binds = BindMap::from([
            ("viewer_id".into(), DbValue::I64(viewer)),
            ("group_id".into(), DbValue::I64(id(request.group)?)),
            ("post_id".into(), DbValue::I64(id(request.post)?)),
            ("start_row".into(), DbValue::F64(request.page.start)),
            ("end_row".into(), DbValue::F64(request.page.end)),
            (
                if request.comments {
                    "comment_sort"
                } else {
                    "post_type"
                }
                .into(),
                DbValue::String(request.order),
            ),
    ]);
    if request.comments {
        binds.insert("target_comment_id".into(), DbValue::I64(id(request.comment)?));
    }
    let rows = query(conn, if request.comments { COMMENTS } else { POSTS }, binds)?;
    let first = rows.first().ok_or(DbError::SchemaNotReady)?;
    if row_number(first, "GROUP_ALLOWED") != 1 {
        return Ok(Outcome::MissingGroup);
    }
    if request.comments && row_number(first, "POST_ALLOWED") != 1 {
        return Ok(Outcome::MissingPost);
    }
    let total = row_number(first, "TOTAL");
    let date = |row: &DbRow, key| {
        nullable_text(row, key)
            .map(|value| profile_date(&value))
            .unwrap_or_default()
    };
    let mut items = Vec::new();
    for row in &rows {
        let key = if request.comments {
            "COMMENT_ID"
        } else {
            "POST_ID"
        };
        if row.get(key).and_then(DbValue::as_i64).is_none() {
            continue;
        }
        if request.comments {
            let Some(comment) = hydrate_comment(conn, viewer, row, storage)? else {
                return Ok(Outcome::MissingUser);
            };
            items.push(comment);
            continue;
        }
        let Some(author) = user(conn, viewer, row_number(row, "AUTHOR_ID"), storage)? else {
            return Ok(Outcome::MissingUser);
        };
        let media = row_text(row, "MEDIA_URLS")
            .split(',')
            .map(crate::group_settings::trim)
            .filter(|value| !value.is_empty())
            .map(|value| {
                storage
                    .normalize_avatar(value)
                    .map_err(|_| DbError::SchemaNotReady)
            })
            .collect::<Result<Vec<_>, _>>()?;
        items.push(json!({
            "post_id": row_number(row,"POST_ID"), "author":author, "content":row_text(row,"CONTENT"),
            "likes_count":row_number(row,"LIKES_COUNT"),"is_liked_by_me":row_number(row,"IS_LIKED_BY_ME")==1,
            "created_at":date(row,"CREATED_AT"),"updated_at":date(row,"UPDATED_AT"),
            "group_id":row_number(row,"GROUP_ID"),"media_urls":media,
            "is_pinned":row_number(row,"IS_PINNED")==1,"is_announcement":row_number(row,"IS_ANNOUNCEMENT")==1,
            "comments_count":row_number(row,"COMMENTS_COUNT"),"views_count":row_number(row,"VIEWS_COUNT")
        }));
    }
    if !request.comments && request.post != 0 {
        return Ok(match items.pop() {
            Some(item) => Outcome::Found(item, total),
            None => Outcome::MissingPost,
        });
    }
    Ok(Outcome::Found(json!(items), total))
}

pub(crate) fn parse_post_id(value: &str) -> Result<u64, ApiError> {
    parse_content_id(value, "post_id")
}

pub(crate) fn parse_content_id(value: &str, field: &str) -> Result<u64, ApiError> {
    value
        .parse::<u64>()
        .ok()
        .filter(|id| {
            (1..=9_007_199_254_740_991).contains(id)
                && value.bytes().all(|b| b.is_ascii_digit())
                && !value.starts_with('0')
        })
        .ok_or_else(|| ApiError::bad_request(format!("{field} 参数错误")))
}

async fn route(
    state: NativeState,
    headers: HeaderMap,
    uri: Uri,
    group: String,
    post: Option<String>,
    comments: bool,
) -> Response {
    let result = async {
        let (viewer, group) = crate::posts::bookmark::interaction_identity(&state, &group, &headers).await?;
        let post = post.as_deref().map(parse_post_id).transpose()?.unwrap_or_default();
        let raw = uri.query().unwrap_or_default();
        let mut page = session_pagination(raw);
        let url = reqwest::Url::parse(&format!("http://localhost/?{raw}")).expect("fixed URL");
        let mut comment = 0;
        if comments {
            let mut ids = url.query_pairs().filter(|(key, _)| key == "comment_id");
            if let Some((_, value)) = ids.next() {
                if ids.next().is_some() {
                    return Err(ApiError::bad_request("comment_id 参数错误"));
                }
                comment = parse_content_id(&value, "comment_id")?;
                page = SessionPage { page: 1.0, page_size: 1.0, start: 1.0, end: 1.0 };
            }
        }
        let detail = post != 0 && !comments;
        if detail {
            page.start = 1.0;
            page.end = 1.0;
        }
        let order = if detail {
            "all".into()
        } else {
            let (key, default, allowed) = if comments {
                ("sort", "newest", ["newest", "oldest", "popular"])
            } else {
                ("type", "all", ["all", "pinned", "announcement"])
            };
            let mut pairs = url.query_pairs().filter(|(name, _)| name == key);
            match (pairs.next(), pairs.next()) {
                (Some((_, value)), None) if !value.is_empty() => {
                    if !allowed.contains(&value.as_ref()) {
                        return Err(ApiError::bad_request(format!("{key} 参数错误")));
                    }
                    value.into_owned()
                }
                _ => default.into(),
            }
        };
        let request = Request { group, post, comment, comments, page, order };
        let (data, total) = match state.repository.read_group_content(viewer, request, &state.storage_urls).await
            .map_err(|_| ApiError::server_error("服务器内部错误"))? {
            Outcome::Found(data, total) => (data, total),
            Outcome::MissingGroup => return Err(ApiError::not_found("群组不存在")),
            Outcome::MissingPost => return Err(ApiError::not_found("群组帖子不存在")),
            Outcome::MissingUser => return Err(ApiError::not_found("用户不存在")),
        };
        let meta = if detail { Value::Null } else {
            json!({"page":page.page,"page_size":page.page_size,"total":total,"has_next":page.end < total as f64})
        };
        Ok::<_, ApiError>(Json(json!({"code":200,"message":"success","data":data,"meta":meta})))
    }.await;
    let mut response = result.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}

pub(crate) async fn posts(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    Path(group): Path<String>,
    headers: HeaderMap,
) -> Response {
    route(state, headers, uri, group, None, false).await
}

pub(crate) async fn detail(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    Path((group, post)): Path<(String, String)>,
    headers: HeaderMap,
) -> Response {
    route(state, headers, uri, group, Some(post), false).await
}

pub(crate) async fn comments(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    Path((group, post)): Path<(String, String)>,
    headers: HeaderMap,
) -> Response {
    route(state, headers, uri, group, Some(post), true).await
}
