use crate::{
    auth::{
        sessions::{
            SessionCredential, SessionRepository, SessionRotation, SessionStoreError, StoreFuture,
        },
        TokenClaims,
    },
    db::{oracle::BindMap, pool::OraclePool, row::DbRow, value::DbValue},
};

pub const TOUCH_SQL:&str="UPDATE n_auth_sessions SET last_accessed_at = CURRENT_TIMESTAMP WHERE user_id = :user_id AND session_id = :session_id AND access_jti = :access_jti AND revoked_at IS NULL AND access_token_expires_at > CURRENT_TIMESTAMP";
pub const REVOKE_SQL:&str="UPDATE n_auth_sessions SET revoked_at = CURRENT_TIMESTAMP WHERE user_id = :user_id AND session_id = :session_id AND revoked_at IS NULL";
pub const REVOKE_OTHERS_SQL:&str="UPDATE n_auth_sessions SET revoked_at = CURRENT_TIMESTAMP WHERE user_id = :user_id AND session_id <> :session_id AND revoked_at IS NULL";
pub const LOGOUT_ACCESS_SQL: &str = "UPDATE n_auth_sessions SET revoked_at = CURRENT_TIMESTAMP WHERE session_id = :session_id AND user_id = :user_id AND revoked_at IS NULL AND access_jti = :access_jti";
pub const LOGOUT_REFRESH_SQL: &str = "UPDATE n_auth_sessions SET revoked_at = CURRENT_TIMESTAMP WHERE session_id = :session_id AND user_id = :user_id AND revoked_at IS NULL AND refresh_token_hash = :refresh_token_hash";
pub const PREFLIGHT_SQL:&str="SELECT user_id, session_id, access_jti, access_token_expires_at, refresh_token_hash, refresh_token_expires_at, last_refresh_at, revoked_at, last_accessed_at FROM n_auth_sessions WHERE 1 = 0";
pub const ROTATE_SQL: &str = "UPDATE n_auth_sessions SET access_jti = :access_jti, refresh_token_hash = :refresh_token_hash, access_token_expires_at = CAST(TO_TIMESTAMP_TZ(:access_expires_at, 'YYYY-MM-DD\"T\"HH24:MI:SS.FF3TZH:TZM') AT LOCAL AS TIMESTAMP), refresh_token_expires_at = CAST(TO_TIMESTAMP_TZ(:refresh_expires_at, 'YYYY-MM-DD\"T\"HH24:MI:SS.FF3TZH:TZM') AT LOCAL AS TIMESTAMP), last_refresh_at = CURRENT_TIMESTAMP, last_accessed_at = CURRENT_TIMESTAMP WHERE session_id = :session_id AND user_id = :user_id AND refresh_token_hash = :old_refresh_hash AND revoked_at IS NULL AND refresh_token_expires_at > CURRENT_TIMESTAMP";
pub const RESET_CLAIM_SQL: &str = "UPDATE n_auth_otp_events SET verified_at = CURRENT_TIMESTAMP, expires_at = CURRENT_TIMESTAMP, verification_code_hash = '!consumed!' WHERE account = :account AND otp_type = 'password_reset' AND verification_id = :verification_id AND verification_code_hash = :code_hash AND expires_at > CURRENT_TIMESTAMP";
pub const RESET_PASSWORD_SQL: &str =
    "UPDATE n_users SET password_hash = :password_hash WHERE email = :email";
pub const RESET_REVOKE_SQL: &str = "UPDATE n_auth_sessions SET revoked_at = CURRENT_TIMESTAMP WHERE user_id IN (SELECT user_id FROM n_users WHERE email = :email) AND revoked_at IS NULL";

fn profile_update_sql(mask: usize) -> &'static str {
    static QUERIES: std::sync::OnceLock<Vec<String>> = std::sync::OnceLock::new();
    &QUERIES.get_or_init(|| (0..64).map(|bits| {
        let clauses = crate::users::self_profile::PROFILE_KEYS.iter().enumerate().filter_map(|(i, key)| {
            if bits & (1 << i) == 0 { return None; }
            Some(if *key == "birth_date" { "birth_date = CASE WHEN :birth_date IS NULL THEN NULL ELSE TO_DATE(:birth_date, 'YYYY-MM-DD') END".to_owned() } else { format!("{key} = :{key}") })
        }).collect::<Vec<_>>().join(", ");
        format!("UPDATE n_users SET {clauses} WHERE user_id = :user_id")
    }).collect())[mask]
}
pub const PUBLIC_PROFILE_SQL: &str = "SELECT u.user_id,u.username,u.avatar_url,u.display_name,u.bio,u.location,u.website,u.is_verified,u.followers_count,u.following_count,u.posts_count,u.likes_count,CASE WHEN NVL(us.show_online_status,1)=0 THEN 'hidden' WHEN EXISTS (SELECT 1 FROM n_auth_sessions s WHERE s.user_id=u.user_id AND s.revoked_at IS NULL AND s.last_accessed_at >= CURRENT_TIMESTAMP - NUMTODSINTERVAL(90,'SECOND')) THEN 'online' ELSE 'offline' END AS online_status,CASE WHEN NVL(us.show_online_status,1)=0 THEN NULL ELSE (SELECT MAX(s.last_accessed_at) FROM n_auth_sessions s WHERE s.user_id=u.user_id AND s.revoked_at IS NULL) END AS last_seen_at,fn_get_user_relationship(:viewer_id,u.user_id) AS relation FROM v_user_profile_public u LEFT JOIN n_user_settings us ON us.user_id=u.user_id WHERE u.user_id=:user_id AND u.is_active=1";
pub const POST_DETAIL_SQL: &str = "SELECT v.post_id,v.author_id,DBMS_LOB.SUBSTR(v.content,4000,1) AS content,v.post_type,v.visibility,v.language,v.location,v.reply_to_post_id,v.repost_of_post_id,v.quoted_post_id,v.likes_count,v.comments_count,v.replies_count,v.retweets_count,v.views_count,v.engagement_score,CASE WHEN EXISTS (SELECT 1 FROM n_post_likes pl WHERE pl.post_id=v.post_id AND pl.user_id=:viewer_id) THEN 1 ELSE 0 END AS is_liked,CASE WHEN EXISTS (SELECT 1 FROM n_post_bookmarks pb WHERE pb.post_id=v.post_id AND pb.user_id=:viewer_id) THEN 1 ELSE 0 END AS is_bookmarked,v.created_at,v.updated_at FROM v_post_feed_item v WHERE fn_can_view_post(:viewer_id,v.post_id)=1 AND v.post_id=:post_id";
pub const POST_MEDIA_SQL: &str = "SELECT ma.media_id,ma.media_type,ma.file_name,ma.public_url,ma.file_size,ma.mime_type,ma.width,ma.height,ma.duration,ma.thumbnail_url,ma.alt_text,ma.description,ma.status,ma.created_at FROM n_post_media pm JOIN n_media_assets ma ON ma.media_id=pm.media_id WHERE pm.post_id=:post_id ORDER BY pm.sort_order";
pub const POST_TAGS_SQL: &str = "SELECT t.name FROM n_post_tags pt JOIN n_tags t ON t.tag_id=pt.tag_id WHERE pt.post_id=:post_id ORDER BY t.name";
pub const POST_MENTIONS_SQL: &str = "SELECT u.user_id,u.username,u.avatar_url,u.display_name,u.bio,u.location,u.website,u.is_verified,u.followers_count,u.following_count,u.posts_count,u.likes_count,fn_get_user_relationship(:viewer_id,u.user_id) AS relation FROM n_post_mentions pm JOIN v_user_profile_public u ON u.user_id=pm.mentioned_user_id WHERE pm.post_id=:post_id ORDER BY u.username";
pub const POST_VIEWS_SQL: &str = "UPDATE n_post_stats SET views_count=views_count+1,updated_at=CURRENT_TIMESTAMP WHERE post_id=:post_id";

fn post_list_sql(query: &crate::posts::list::PostListQuery) -> (&'static str, &'static str) {
    static QUERIES: std::sync::OnceLock<Vec<(String, String)>> = std::sync::OnceLock::new();
    let sql = QUERIES.get_or_init(|| {
        let columns = POST_DETAIL_SQL.split(" FROM v_post_feed_item v WHERE ").next().expect("fixed SQL");
        let mut variants = Vec::new();
        for mode in 0..8 {
          for timeline in 0..3 {
            for search in 0..2 {
                for sort in 0..3 {
                    let mut filter = " WHERE fn_can_view_post(:viewer_id,v.post_id)=1".to_owned();
                    if mode == 1 { filter.push_str(" AND v.author_id=:viewer_id"); }
                    if mode == 2 { filter.push_str(" AND EXISTS (SELECT 1 FROM n_post_bookmarks b WHERE b.post_id=v.post_id AND b.user_id=:viewer_id)"); }
                    if mode == 3 { filter.push_str(" AND EXISTS (SELECT 1 FROM n_post_likes l WHERE l.post_id=v.post_id AND l.user_id=:viewer_id)"); }
                    if mode == 4 { filter.push_str(" AND v.author_id=:author_id"); }
                    if mode == 5 { filter.push_str(" AND EXISTS (SELECT 1 FROM n_post_tags pt JOIN n_tags t ON t.tag_id=pt.tag_id WHERE pt.post_id=v.post_id AND t.name_lower=LOWER(:tag_name))"); }
                    if mode == 6 { filter.push_str(" AND v.reply_to_post_id=:target_post_id"); }
                    if mode == 7 { filter.push_str(" AND v.repost_of_post_id=:target_post_id"); }
                    if timeline == 1 { filter.push_str(" AND EXISTS (SELECT 1 FROM n_user_follows f WHERE f.follower_id=:viewer_id AND f.following_id=v.author_id AND f.status='active')"); }
                    if timeline == 2 { filter.push_str(" AND EXISTS (SELECT 1 FROM n_post_mentions pm WHERE pm.post_id=v.post_id AND pm.mentioned_user_id=:viewer_id)"); }
                    if search == 1 { filter.push_str(" AND (LOWER(DBMS_LOB.SUBSTR(v.content,4000,1)) LIKE :q OR LOWER(NVL(v.location,'')) LIKE :q OR EXISTS (SELECT 1 FROM n_post_tags pt JOIN n_tags t ON t.tag_id=pt.tag_id WHERE pt.post_id=v.post_id AND t.name_lower LIKE :tag_q))"); }
                    let order = if mode == 3 && sort != 2 {
                        if sort == 1 { "(SELECT MAX(l.created_at) FROM n_post_likes l WHERE l.post_id=v.post_id AND l.user_id=:viewer_id) ASC" }
                        else { "(SELECT MAX(l.created_at) FROM n_post_likes l WHERE l.post_id=v.post_id AND l.user_id=:viewer_id) DESC" }
                    } else { match sort { 1 => "v.created_at ASC", 2 => "v.engagement_score DESC,v.created_at DESC", _ => "v.created_at DESC" } };
                    variants.push((format!("SELECT COUNT(*) AS total FROM v_post_feed_item v{filter}"), format!("SELECT * FROM ({columns},ROW_NUMBER() OVER (ORDER BY {order}) AS rn FROM v_post_feed_item v{filter}) WHERE rn BETWEEN :start_row AND :end_row")));
                }
            }
          }
        }
        variants
    });
    let timeline = match query.timeline.as_str() {
        "following" => 1,
        "mentions" => 2,
        _ => 0,
    };
    let search = usize::from(!query.search.is_empty());
    let sort = match query.sort.as_str() {
        "oldest" => 1,
        "popular" => 2,
        _ => 0,
    };
    let mode = match query.mode.as_str() {
        "me" => 1,
        "bookmarks" => 2,
        "likes" => 3,
        "user" => 4,
        "tag" => 5,
        "replies" => 6,
        "retweets" => 7,
        _ => 0,
    };
    let (count, page) = &sql[mode * 18 + timeline * 6 + search * 3 + sort];
    (count, page)
}
pub trait SessionExecutor: Send + Sync {
    fn create_post_atomic<'a>(
        &'a self,
        _actor: u64,
        _input: &'a crate::posts::create_request::PostCreateInput,
    ) -> StoreFuture<'a, crate::posts::create_transaction::PostCreation> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn reset_password_atomic<'a>(
        &'a self,
        _email: &'a str,
        _id: &'a str,
        _otp_hash: &'a str,
        _new_hash: &'a str,
    ) -> StoreFuture<'a, u64> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn execute(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, u64>;
    fn preflight(&self, sql: &'static str) -> StoreFuture<'_, ()>;
    fn query(&self, _sql: &'static str, _binds: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn media_readiness_snapshot(&self) -> StoreFuture<'_, serde_json::Value> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn readiness_snapshot(&self) -> StoreFuture<'_, serde_json::Value> {
        Box::pin(async { Err(SessionStoreError) })
    }
}
pub struct OracleSessions<E> {
    pub executor: E,
}
pub struct NotificationInput<'a> {
    pub user_id: u64,
    pub actor_id: Option<u64>,
    pub kind: &'a str,
    pub title: &'a str,
    pub message: &'a str,
    pub resource_type: Option<&'a str>,
    pub resource_id: Option<u64>,
    pub priority: &'a str,
    pub metadata_json: Option<&'a str>,
}
#[derive(Debug, PartialEq, Eq)]
pub struct StoredNotification {
    pub id: u64,
    pub push_enabled: bool,
}

fn map_notification_row(row: &DbRow) -> serde_json::Value {
    let actor = if row
        .get("ACTOR_ID")
        .is_none_or(|v| matches!(v, DbValue::Null))
    {
        serde_json::Value::Null
    } else {
        serde_json::json!(row_number(row, "ACTOR_ID"))
    };
    let mut raw_metadata = None;
    let metadata = nullable_text(row, "METADATA_JSON")
        .map(|s| match serde_json::from_str(&s) {
            Ok(value) => value,
            Err(_) if serde_json::value::RawValue::from_string(s.clone()).is_ok() => {
                raw_metadata = Some(s);
                serde_json::Value::Null
            }
            Err(_) => serde_json::Value::String(s),
        })
        .unwrap_or(serde_json::Value::Null);
    let mut result = serde_json::json!({"notification_id":row_number(row,"NOTIFICATION_ID"),"actor_id":actor,"type":row_text(row,"TYPE"),"title":row_text(row,"TITLE"),"message":row_text(row,"MESSAGE"),"resource_type":nullable_text(row,"RESOURCE_TYPE"),"resource_id":nullable_number(row,"RESOURCE_ID"),"priority":row_text(row,"PRIORITY"),"is_read":row_number(row,"IS_READ"),"read_at":nullable_text(row,"READ_AT").map(|s|profile_date(&s)),"deleted_at":nullable_text(row,"DELETED_AT").map(|s|profile_date(&s)),"metadata":metadata,"created_at":nullable_text(row,"CREATED_AT").map(|s|profile_date(&s)).unwrap_or_default()});
    if let Some(raw) = raw_metadata {
        result[crate::notification_events::RAW_METADATA_KEY] = serde_json::Value::String(raw);
    }
    result
}
impl<E: SessionExecutor> OracleSessions<E> {
    pub async fn preflight(&self) -> Result<(), SessionStoreError> {
        self.executor.preflight(PREFLIGHT_SQL).await
    }

    async fn comment_notification_excerpt(&self, id: i64) -> Result<String, SessionStoreError> {
        let rows=self.executor.query(
            "SELECT user_id,post_id,DBMS_LOB.SUBSTR(content,4000,1) AS content FROM n_comments WHERE comment_id=:comment_id AND is_deleted=0",
            BindMap::from([("comment_id".into(),DbValue::I64(id))]),
        ).await?;
        Ok(crate::posts::like::excerpt_json(rows.first().and_then(|row|nullable_text(row,"CONTENT")).as_deref()))
    }

    /// Read only a notification owned by the requested recipient.
    pub async fn notification_by_id(
        &self,
        user: u64,
        id: u64,
    ) -> Result<Option<serde_json::Value>, SessionStoreError> {
        let user = i64::try_from(user).map_err(|_| SessionStoreError)?;
        let id = i64::try_from(id).map_err(|_| SessionStoreError)?;
        let rows = self.executor.query(
            "SELECT notification_id,actor_id,type,title,message,resource_type,resource_id,priority,is_read,read_at,deleted_at,DBMS_LOB.SUBSTR(metadata_json,4000,1) AS metadata_json,created_at FROM n_notifications WHERE user_id=:user_id AND notification_id=:notification_id",
            BindMap::from([("user_id".into(), DbValue::I64(user)), ("notification_id".into(), DbValue::I64(id))]),
        ).await?;
        Ok(rows.first().map(map_notification_row))
    }
    pub async fn store_notification(
        &self,
        n: NotificationInput<'_>,
    ) -> Result<Option<StoredNotification>, SessionStoreError> {
        if n.user_id == 0 || n.actor_id == Some(n.user_id) {
            return Ok(None);
        }
        let user = i64::try_from(n.user_id).map_err(|_| SessionStoreError)?;
        let actor = n
            .actor_id
            .map(i64::try_from)
            .transpose()
            .map_err(|_| SessionStoreError)?;
        let resource = n
            .resource_id
            .map(i64::try_from)
            .transpose()
            .map_err(|_| SessionStoreError)?;
        let mut binds = BindMap::from([("user_id".into(), DbValue::I64(user))]);
        binds.insert("notification_type".into(), DbValue::String(n.kind.into()));
        let rows = self.executor.query("SELECT NVL(us.push_notification_enabled,1) AS push_notification_enabled,NVL(np.is_enabled,1) AS type_enabled FROM n_users u LEFT JOIN n_user_settings us ON us.user_id=u.user_id LEFT JOIN n_notification_preferences np ON np.user_id=u.user_id AND np.notification_type=:notification_type WHERE u.user_id=:user_id AND u.is_active=1",binds).await?;
        let Some(row) = rows.first() else {
            return Ok(None);
        };
        if row_number(row, "TYPE_ENABLED") == 0 {
            return Ok(None);
        }
        let push_enabled = row_number(row, "PUSH_NOTIFICATION_ENABLED") != 0;
        let rows = self
            .executor
            .query(
                "SELECT seq_notification_id.NEXTVAL AS id FROM dual",
                BindMap::new(),
            )
            .await?;
        let id = row_id(rows.first().ok_or(SessionStoreError)?, "ID")?;
        let id_bind = i64::try_from(id).map_err(|_| SessionStoreError)?;
        let binds = BindMap::from([
            ("notification_id".into(), DbValue::I64(id_bind)),
            ("user_id".into(), DbValue::I64(user)),
            (
                "actor_id".into(),
                actor.map(DbValue::I64).unwrap_or(DbValue::Null),
            ),
            ("type".into(), DbValue::String(n.kind.into())),
            ("title".into(), DbValue::String(n.title.into())),
            ("message".into(), DbValue::String(n.message.into())),
            (
                "resource_type".into(),
                n.resource_type
                    .map(|v| DbValue::String(v.into()))
                    .unwrap_or(DbValue::Null),
            ),
            (
                "resource_id".into(),
                resource.map(DbValue::I64).unwrap_or(DbValue::Null),
            ),
            ("priority".into(), DbValue::String(n.priority.into())),
            (
                "metadata_json".into(),
                n.metadata_json
                    .map(|v| DbValue::String(v.into()))
                    .unwrap_or(DbValue::Null),
            ),
        ]);
        self.executor.execute("INSERT INTO n_notifications (notification_id,user_id,actor_id,type,title,message,resource_type,resource_id,priority,metadata_json) VALUES (:notification_id,:user_id,:actor_id,:type,:title,:message,:resource_type,:resource_id,:priority,:metadata_json)",binds).await?;
        Ok(Some(StoredNotification { id, push_enabled }))
    }
}
impl<E: SessionExecutor> SessionRepository for OracleSessions<E> {
    fn delete_post<'a>(&'a self, user:u64, id:u64) -> StoreFuture<'a,crate::posts::delete::PostDelete> {
        Box::pin(crate::posts::delete::remove_from_store(&self.executor,user,id))
    }
    fn create_post_atomic<'a>(
        &'a self,
        actor: u64,
        input: &'a crate::posts::create_request::PostCreateInput,
    ) -> StoreFuture<'a, crate::posts::create_transaction::PostCreation> {
        self.executor.create_post_atomic(actor, input)
    }
    fn post_create_actor_name(&self, actor: u64) -> StoreFuture<'_, String> {
        Box::pin(crate::posts::create_notification::actor_name(&self.executor, actor))
    }
    fn post_create_source_author(&self, post: u64) -> StoreFuture<'_, Option<u64>> {
        Box::pin(crate::posts::create_notification::source_author(&self.executor, post))
    }
    fn post_create_excerpt(&self, post: u64) -> StoreFuture<'_, String> {
        Box::pin(crate::posts::create_notification::excerpt(&self.executor, post))
    }
    fn resolve_post_mention_recipient(&self, user: f64) -> StoreFuture<'_, Option<u64>> {
        Box::pin(crate::posts::create_notification::resolve_mention_recipient(&self.executor, user))
    }
    fn store_post_create_notification<'a>(
        &'a self,
        input: &'a crate::posts::create_notification::PostNoticeInput,
    ) -> StoreFuture<'a, Option<StoredNotification>> {
        Box::pin(crate::posts::create_notification::store(self, input))
    }
    fn set_comment_like<'a>(&'a self,viewer:u64,id:u64,liked:bool)->StoreFuture<'a,Option<crate::posts::like::PostLikeOutcome>> {
        Box::pin(async move {
            let id=i64::try_from(id).map_err(|_|SessionStoreError)?;
            let viewer=i64::try_from(viewer).map_err(|_|SessionStoreError)?;
            let read=BindMap::from([("comment_id".into(),DbValue::I64(id)),("viewer_id".into(),DbValue::I64(viewer))]);
            const VISIBLE:&str="SELECT c.comment_id FROM n_comments c JOIN n_posts p ON p.post_id=c.post_id WHERE c.comment_id=:comment_id AND c.is_deleted=0 AND p.is_deleted=0 AND fn_can_view_post(:viewer_id,c.post_id)=1";
            const COUNT:&str="SELECT NVL(s.likes_count,0) AS likes_count FROM n_comments c JOIN n_posts p ON p.post_id=c.post_id LEFT JOIN n_comment_stats s ON s.comment_id=c.comment_id WHERE c.comment_id=:comment_id AND c.is_deleted=0 AND p.is_deleted=0 AND fn_can_view_post(:viewer_id,c.post_id)=1";
            const INSERT:&str="INSERT INTO n_comment_likes (comment_id,user_id) SELECT :comment_id,:user_id FROM dual WHERE EXISTS (SELECT 1 FROM n_comments c JOIN n_posts p ON p.post_id=c.post_id WHERE c.comment_id=:comment_id AND c.is_deleted=0 AND p.is_deleted=0 AND fn_can_view_post(:user_id,c.post_id)=1) AND NOT EXISTS (SELECT 1 FROM n_comment_likes WHERE comment_id=:comment_id AND user_id=:user_id)";
            const DELETE:&str="DELETE FROM n_comment_likes WHERE comment_id=:comment_id AND user_id=:user_id AND EXISTS (SELECT 1 FROM n_comments c JOIN n_posts p ON p.post_id=c.post_id WHERE c.comment_id=:comment_id AND c.is_deleted=0 AND p.is_deleted=0 AND fn_can_view_post(:user_id,c.post_id)=1)";
            if self.executor.query(VISIBLE,read.clone()).await?.is_empty(){return Ok(None)}
            let changed=self.executor.execute(if liked{INSERT}else{DELETE},BindMap::from([("comment_id".into(),DbValue::I64(id)),("user_id".into(),DbValue::I64(viewer))])).await?;
            if changed==0&&self.executor.query(VISIBLE,read.clone()).await?.is_empty(){return Ok(None)}
            let rows=self.executor.query(COUNT,read).await?;let Some(row)=rows.first() else{return Ok(None)};
            Ok(Some(crate::posts::like::PostLikeOutcome{count:row_float(row,"LIKES_COUNT"),inserted:liked&&changed>0}))
        })
    }
    fn prepare_comment_like_notification<'a>(&'a self,viewer:u64,id:u64)->StoreFuture<'a,Option<crate::posts::like::StoredLikeNotification>> {
        Box::pin(async move {
            let comment=i64::try_from(id).map_err(|_|SessionStoreError)?;
            let actor=i64::try_from(viewer).map_err(|_|SessionStoreError)?;
            let rows=self.executor.query("SELECT user_id,post_id,DBMS_LOB.SUBSTR(content,4000,1) AS content FROM n_comments WHERE comment_id=:comment_id AND is_deleted=0",BindMap::from([("comment_id".into(),DbValue::I64(comment))])).await?;
            let Some(row)=rows.first() else{return Ok(None)};
            let author=row_number(row,"USER_ID");let post=row_number(row,"POST_ID");
            if author<=0||post<=0||author==actor{return Ok(None)}
            let comment_excerpt=crate::posts::like::excerpt_json(nullable_text(row,"CONTENT").as_deref());
            let names=self.executor.query("SELECT COALESCE(display_name,username) AS name FROM n_users WHERE user_id=:user_id",BindMap::from([("user_id".into(),DbValue::I64(actor))])).await?;
            let name=names.first().and_then(|r|nullable_text(r,"NAME")).unwrap_or_else(||"有人".into());
            let posts=self.executor.query("SELECT DBMS_LOB.SUBSTR(content,4000,1) AS content FROM n_posts WHERE post_id=:post_id AND is_deleted=0",BindMap::from([("post_id".into(),DbValue::I64(post))])).await?;
            let post_excerpt=crate::posts::like::excerpt_json(posts.first().and_then(|r|nullable_text(r,"CONTENT")).as_deref());
            let metadata=format!("{{\"post_id\":{post},\"target_post_id\":{post},\"comment_id\":{id},\"comment_excerpt\":{comment_excerpt},\"post_excerpt\":{post_excerpt},\"event\":\"comment_like\"}}");
            let title=format!("{name} 赞了你的评论");
            let stored=self.store_notification(NotificationInput{user_id:author as u64,actor_id:Some(viewer),kind:"like",title:&title,message:"你的评论收到了一次点赞。",resource_type:Some("comment"),resource_id:Some(id),priority:"normal",metadata_json:Some(&metadata)}).await?;
            Ok(stored.map(|n|crate::posts::like::StoredLikeNotification{recipient:author as u64,id:n.id,push_enabled:n.push_enabled}))
        })
    }
    fn delete_post_comment<'a>(
        &'a self, user: u64, id: u64,
    ) -> StoreFuture<'a, crate::posts::comment_delete::CommentDelete> {
        Box::pin(async move {
            use crate::posts::comment_delete::CommentDelete;
            let user=i64::try_from(user).map_err(|_|SessionStoreError)?;
            let id=i64::try_from(id).map_err(|_|SessionStoreError)?;
            const READ:&str="SELECT c.user_id FROM n_comments c JOIN n_posts p ON p.post_id=c.post_id WHERE c.comment_id=:comment_id AND c.is_deleted=0 AND p.is_deleted=0 AND fn_can_view_post(:viewer_id,c.post_id)=1";
            let rows=self.executor.query(READ,BindMap::from([("comment_id".into(),DbValue::I64(id)),("viewer_id".into(),DbValue::I64(user))])).await?;
            let Some(row)=rows.first() else {return Ok(CommentDelete::Missing)};
            if row_number(row,"USER_ID")!=user{return Ok(CommentDelete::NotOwner)}
            const UPDATE:&str="UPDATE n_comments c SET is_deleted=1 WHERE c.comment_id=:comment_id AND c.user_id=:user_id AND c.is_deleted=0 AND fn_can_view_post(:user_id,c.post_id)=1 AND EXISTS (SELECT 1 FROM n_posts p WHERE p.post_id=c.post_id AND p.is_deleted=0)";
            let changed=self.executor.execute(UPDATE,BindMap::from([("comment_id".into(),DbValue::I64(id)),("user_id".into(),DbValue::I64(user))])).await?;
            Ok(if changed==0 {CommentDelete::Missing}else{CommentDelete::Deleted})
        })
    }
    fn comment_notice_context<'a>(
        &'a self, actor: u64, post: u64, comment: u64,
    ) -> StoreFuture<'a, crate::posts::comment_create::CommentNoticeContext> {
        Box::pin(async move {
            use crate::posts::comment_create::CommentNoticeContext;
            let actor=i64::try_from(actor).map_err(|_|SessionStoreError)?;
            let post=i64::try_from(post).map_err(|_|SessionStoreError)?;
            let comment=i64::try_from(comment).map_err(|_|SessionStoreError)?;
            let names=self.executor.query("SELECT COALESCE(display_name,username) AS name FROM n_users WHERE user_id=:user_id",BindMap::from([("user_id".into(),DbValue::I64(actor))])).await?;
            let actor_name=names.first().and_then(|r|nullable_text(r,"NAME")).unwrap_or_else(||"有人".into());
            let post_bind=BindMap::from([("post_id".into(),DbValue::I64(post))]);
            let authors=self.executor.query("SELECT author_id FROM n_posts WHERE post_id=:post_id AND is_deleted=0",post_bind.clone()).await?;
            let post_author=authors.first().and_then(|r|u64::try_from(row_number(r,"AUTHOR_ID")).ok()).filter(|id|*id>0);
            let comment_excerpt=self.comment_notification_excerpt(comment).await?;
            let posts=self.executor.query("SELECT DBMS_LOB.SUBSTR(content,4000,1) AS content FROM n_posts WHERE post_id=:post_id AND is_deleted=0",post_bind).await?;
            let post_excerpt=crate::posts::like::excerpt_json(posts.first().and_then(|r|nullable_text(r,"CONTENT")).as_deref());
            Ok(CommentNoticeContext{actor_name,post_author,comment_excerpt,post_excerpt})
        })
    }
    fn comment_parent_notice<'a>(
        &'a self, parent: u64, post_author: Option<u64>,
    ) -> StoreFuture<'a, crate::posts::comment_create::CommentParentNotice> {
        Box::pin(async move {
            use crate::posts::comment_create::CommentParentNotice;
            let parent=i64::try_from(parent).map_err(|_|SessionStoreError)?;
            let rows=self.executor.query("SELECT user_id FROM n_comments WHERE comment_id=:comment_id AND is_deleted=0",BindMap::from([("comment_id".into(),DbValue::I64(parent))])).await?;
            let author=rows.first().and_then(|r|u64::try_from(row_number(r,"USER_ID")).ok()).filter(|id|*id>0);
            let excerpt=if author.is_some()&&author!=post_author {self.comment_notification_excerpt(parent).await?} else {"null".into()};
            Ok(CommentParentNotice{author,excerpt})
        })
    }
    fn store_comment_notification<'a>(
        &'a self, input: &'a crate::posts::comment_create::CommentNoticeInput,
    ) -> StoreFuture<'a, Option<crate::posts::comment_create::StoredCommentNotification>> {
        Box::pin(async move {
            let result=self.store_notification(NotificationInput{user_id:input.recipient,actor_id:Some(input.actor),kind:"comment",title:&input.title,message:&input.message,resource_type:Some("comment"),resource_id:Some(input.comment_id),priority:"normal",metadata_json:Some(&input.metadata_json)}).await?;
            Ok(result.map(|stored|crate::posts::comment_create::StoredCommentNotification{recipient:input.recipient,id:stored.id,push_enabled:stored.push_enabled}))
        })
    }
    fn create_post_comment<'a>(
        &'a self,
        user: u64,
        post: u64,
        content: &'a str,
        parent: Option<u64>,
    ) -> StoreFuture<'a, crate::posts::comment_create::CommentCreation> {
        Box::pin(async move {
            use crate::posts::comment_create::CommentCreation;
            let user = i64::try_from(user).map_err(|_| SessionStoreError)?;
            let post = i64::try_from(post).map_err(|_| SessionStoreError)?;
            let parent = parent.map(i64::try_from).transpose().map_err(|_| SessionStoreError)?;
            let visible = BindMap::from([("viewer_id".into(),DbValue::I64(user)),("post_id".into(),DbValue::I64(post))]);
            const CHECK: &str = "SELECT p.post_id FROM n_posts p WHERE p.post_id=:post_id AND p.is_deleted=0 AND fn_can_view_post(:viewer_id,p.post_id)=1";
            if self.executor.query(CHECK,visible.clone()).await?.is_empty() { return Ok(CommentCreation::PostUnavailable); }
            let ids=self.executor.query("SELECT seq_comment_id.NEXTVAL AS id FROM dual",BindMap::new()).await?;
            let id=i64::try_from(row_id(ids.first().ok_or(SessionStoreError)?,"ID")?).map_err(|_|SessionStoreError)?;
            let mut root=id;
            if let Some(parent)=parent {
                let rows=self.executor.query("SELECT NVL(root_comment_id, comment_id) AS root_comment_id FROM n_comments WHERE comment_id=:comment_id AND post_id=:post_id AND is_deleted=0",BindMap::from([("comment_id".into(),DbValue::I64(parent)),("post_id".into(),DbValue::I64(post))])).await?;
                let Some(row)=rows.first() else {return Ok(CommentCreation::ParentUnavailable)};
                root=i64::try_from(row_id(row,"ROOT_COMMENT_ID")?).map_err(|_|SessionStoreError)?;
            }
            let binds=BindMap::from([
                ("comment_id".into(),DbValue::I64(id)),("post_id".into(),DbValue::I64(post)),("user_id".into(),DbValue::I64(user)),
                ("parent_comment_id".into(),parent.map(DbValue::I64).unwrap_or(DbValue::Null)),("root_comment_id".into(),DbValue::I64(root)),("content".into(),DbValue::String(content.into())),
            ]);
            const INSERT:&str="INSERT INTO n_comments (comment_id,post_id,user_id,parent_comment_id,root_comment_id,content) SELECT :comment_id,:post_id,:user_id,:parent_comment_id,:root_comment_id,:content FROM dual WHERE fn_can_view_post(:user_id,:post_id)=1 AND EXISTS (SELECT 1 FROM n_posts p WHERE p.post_id=:post_id AND p.is_deleted=0) AND (:parent_comment_id IS NULL OR EXISTS (SELECT 1 FROM n_comments parent WHERE parent.comment_id=:parent_comment_id AND parent.post_id=:post_id AND parent.is_deleted=0))";
            if self.executor.execute(INSERT,binds).await?==0 {
                if self.executor.query(CHECK,visible.clone()).await?.is_empty() {return Ok(CommentCreation::PostUnavailable)}
                return Ok(if parent.is_some() {CommentCreation::ParentUnavailable}else{CommentCreation::PostUnavailable});
            }
            let mut read=visible;read.insert("comment_id".into(),DbValue::I64(id));
            let rows=self.executor.query("SELECT c.comment_id,c.post_id,c.user_id,c.parent_comment_id,c.root_comment_id,DBMS_LOB.SUBSTR(c.content,4000,1) AS content,c.created_at,c.updated_at,c.likes_count,c.replies_count,0 AS is_liked FROM v_post_comment_list_item c WHERE c.comment_id=:comment_id AND c.post_id=:post_id AND c.user_id=:viewer_id AND fn_can_view_post(:viewer_id,c.post_id)=1",read).await?;
            match rows.first() {Some(row)=>Ok(CommentCreation::Created(map_post_comment(row)?)),None=>Ok(CommentCreation::CommentUnavailable)}
        })
    }
    fn list_post_comments<'a>(
        &'a self,
        user: u64,
        id: u64,
        query: &'a crate::posts::comments::CommentListQuery,
    ) -> StoreFuture<'a, Option<(Vec<serde_json::Value>, u64)>> {
        Box::pin(async move {
            let user = i64::try_from(user).map_err(|_| SessionStoreError)?;
            let id = i64::try_from(id).map_err(|_| SessionStoreError)?;
            let binds = BindMap::from([
                ("viewer_id".into(), DbValue::I64(user)),
                ("post_id".into(), DbValue::I64(id)),
            ]);
            const VISIBLE: &str = "SELECT p.post_id FROM n_posts p WHERE p.post_id=:post_id AND p.is_deleted=0 AND fn_can_view_post(:viewer_id,p.post_id)=1";
            const COUNT: &str = "SELECT COUNT(*) AS total FROM v_post_comment_list_item c WHERE c.post_id=:post_id AND fn_can_view_post(:viewer_id,c.post_id)=1";
            macro_rules! comment_sql { ($order:literal) => { concat!(
                "SELECT comment_id,post_id,user_id,parent_comment_id,root_comment_id,content,created_at,updated_at,likes_count,replies_count,is_liked FROM (",
                "SELECT c.comment_id,c.post_id,c.user_id,c.parent_comment_id,c.root_comment_id,DBMS_LOB.SUBSTR(c.content,4000,1) AS content,c.created_at,c.updated_at,c.likes_count,c.replies_count,",
                "CASE WHEN EXISTS (SELECT 1 FROM n_comment_likes cl WHERE cl.comment_id=c.comment_id AND cl.user_id=:viewer_id) THEN 1 ELSE 0 END AS is_liked,",
                "ROW_NUMBER() OVER (ORDER BY ", $order, ") AS rn FROM v_post_comment_list_item c WHERE c.post_id=:post_id AND fn_can_view_post(:viewer_id,c.post_id)=1) WHERE rn BETWEEN :start_row AND :end_row"
            ) }; }
            let list = match query.sort.as_str() {
                "oldest" => comment_sql!("c.created_at ASC"),
                "popular" => comment_sql!("c.likes_count DESC, c.created_at DESC"),
                _ => comment_sql!("c.created_at DESC"),
            };
            if self.executor.query(VISIBLE, binds.clone()).await?.is_empty() {
                return Ok(None);
            }
            let count = self.executor.query(COUNT, binds.clone()).await?;
            let total = u64::try_from(row_number(count.first().ok_or(SessionStoreError)?, "TOTAL"))
                .map_err(|_| SessionStoreError)?;
            let mut page_binds = binds;
            page_binds.insert("start_row".into(), DbValue::F64(query.page.start));
            page_binds.insert("end_row".into(), DbValue::F64(query.page.end));
            let rows = self.executor.query(list, page_binds).await?;
            let mut comments = Vec::with_capacity(rows.len());
            for row in &rows {
                comments.push(map_post_comment(row)?);
            }
            Ok(Some((comments,total)))
        })
    }
    fn set_notification_deleted<'a>(
        &'a self,
        user: u64,
        id: u64,
        restore: bool,
    ) -> StoreFuture<'a, Option<Option<String>>> {
        Box::pin(async move {
            let user = i64::try_from(user).map_err(|_| SessionStoreError)?;
            let id = i64::try_from(id).map_err(|_| SessionStoreError)?;
            let binds = BindMap::from([
                ("user_id".into(), DbValue::I64(user)),
                ("notification_id".into(), DbValue::I64(id)),
            ]);
            let sql = if restore {
                "UPDATE n_notifications SET deleted_at=NULL WHERE notification_id=:notification_id AND user_id=:user_id"
            } else {
                "UPDATE n_notifications SET deleted_at=CURRENT_TIMESTAMP WHERE notification_id=:notification_id AND user_id=:user_id AND deleted_at IS NULL"
            };
            if self.executor.execute(sql, binds.clone()).await? == 0 {
                return Ok(None);
            }
            if restore {
                return Ok(Some(None));
            }
            let rows = self.executor.query(
                "SELECT deleted_at FROM n_notifications WHERE notification_id=:notification_id AND user_id=:user_id",
                binds,
            ).await?;
            Ok(Some(rows.first().and_then(|row| {
                nullable_text(row, "DELETED_AT").map(|s| profile_date(&s))
            })))
        })
    }
    fn batch_set_notification_read<'a>(
        &'a self,
        user: u64,
        ids: &'a [u64],
        read: bool,
    ) -> StoreFuture<'a, u64> {
        Box::pin(async move {
            let user = i64::try_from(user).map_err(|_| SessionStoreError)?;
            let flag = i64::from(read);
            if ids.is_empty() {
                return self.executor.execute(
                    "UPDATE n_notifications SET is_read=:is_read,read_at=CASE WHEN :is_read=1 THEN CURRENT_TIMESTAMP ELSE NULL END WHERE user_id=:user_id AND deleted_at IS NULL",
                    BindMap::from([("user_id".into(), DbValue::I64(user)), ("is_read".into(), DbValue::I64(flag))]),
                ).await;
            }
            let mut total = 0_u64;
            for &id in ids {
                let id = i64::try_from(id).map_err(|_| SessionStoreError)?;
                let count = self.executor.execute(
                    "UPDATE n_notifications SET is_read=:is_read,read_at=CASE WHEN :is_read=1 THEN CURRENT_TIMESTAMP ELSE NULL END WHERE user_id=:user_id AND notification_id=:notification_id",
                    BindMap::from([("user_id".into(), DbValue::I64(user)), ("is_read".into(), DbValue::I64(flag)), ("notification_id".into(), DbValue::I64(id))]),
                ).await?;
                total = total.checked_add(count).ok_or(SessionStoreError)?;
            }
            Ok(total)
        })
    }
    fn set_notification_read<'a>(
        &'a self,
        user: u64,
        id: u64,
        read: bool,
    ) -> StoreFuture<'a, Option<crate::notifications::NotificationReadResult>> {
        Box::pin(async move {
            let user = i64::try_from(user).map_err(|_| SessionStoreError)?;
            let id_i64 = i64::try_from(id).map_err(|_| SessionStoreError)?;
            let binds = BindMap::from([
                ("user_id".into(), DbValue::I64(user)),
                ("notification_id".into(), DbValue::I64(id_i64)),
                ("is_read".into(), DbValue::I64(i64::from(read))),
            ]);
            let changed=self.executor.execute("UPDATE n_notifications SET is_read=:is_read,read_at=CASE WHEN :is_read=1 THEN CURRENT_TIMESTAMP ELSE NULL END WHERE notification_id=:notification_id AND user_id=:user_id",binds).await?;
            if changed == 0 {
                return Ok(None);
            }
            let rows=self.executor.query("SELECT notification_id,is_read,read_at FROM n_notifications WHERE notification_id=:notification_id AND user_id=:user_id",BindMap::from([("user_id".into(),DbValue::I64(user)),("notification_id".into(),DbValue::I64(id_i64))])).await?;
            let Some(row) = rows.first() else {
                return Ok(None);
            };
            let result = crate::notifications::NotificationReadResult {
                notification_id: row_id(row, "NOTIFICATION_ID")?,
                is_read: u8::try_from(row_number(row, "IS_READ")).map_err(|_| SessionStoreError)?,
                read_at: nullable_text(row, "READ_AT").map(|s| profile_date(&s)),
            };
            Ok(Some(result))
        })
    }
    fn read_notification<'a>(
        &'a self,
        user: u64,
        id: u64,
    ) -> StoreFuture<'a, Option<serde_json::Value>> {
        Box::pin(async move { self.notification_by_id(user, id).await })
    }
    fn add_post_like<'a>(
        &'a self,
        viewer: u64,
        id: u64,
    ) -> StoreFuture<'a, Option<crate::posts::like::PostLikeOutcome>> {
        Box::pin(async move {
            const VISIBLE:&str="SELECT p.post_id FROM n_posts p WHERE p.post_id=:post_id AND p.is_deleted=0 AND fn_can_view_post(:user_id,p.post_id)=1";
            const INSERT:&str="INSERT INTO n_post_likes (post_id,user_id) SELECT :post_id,:user_id FROM dual WHERE fn_can_view_post(:user_id,:post_id)=1 AND NOT EXISTS (SELECT 1 FROM n_post_likes WHERE post_id=:post_id AND user_id=:user_id)";
            const COUNT: &str = "SELECT likes_count FROM n_post_stats WHERE post_id=:post_id";
            let binds = BindMap::from([
                (
                    "post_id".into(),
                    DbValue::I64(i64::try_from(id).map_err(|_| SessionStoreError)?),
                ),
                (
                    "user_id".into(),
                    DbValue::I64(i64::try_from(viewer).map_err(|_| SessionStoreError)?),
                ),
            ]);
            if self
                .executor
                .query(VISIBLE, binds.clone())
                .await?
                .is_empty()
            {
                return Ok(None);
            }
            let changed = self.executor.execute(INSERT, binds.clone()).await?;
            if changed == 0 && self.executor.query(VISIBLE, binds).await?.is_empty() {
                return Ok(None);
            }
            let rows = self
                .executor
                .query(
                    COUNT,
                    BindMap::from([("post_id".into(), DbValue::I64(id as i64))]),
                )
                .await?;
            Ok(Some(crate::posts::like::PostLikeOutcome {
                count: rows
                    .first()
                    .map(|r| row_float(r, "LIKES_COUNT"))
                    .unwrap_or(0.0),
                inserted: changed > 0,
            }))
        })
    }
    fn prepare_post_like_notification<'a>(
        &'a self,
        viewer: u64,
        id: u64,
    ) -> StoreFuture<'a, Option<crate::posts::like::StoredLikeNotification>> {
        Box::pin(async move {
            let post = i64::try_from(id).map_err(|_| SessionStoreError)?;
            let actor = i64::try_from(viewer).map_err(|_| SessionStoreError)?;
            let post_bind = BindMap::from([("post_id".into(), DbValue::I64(post))]);
            let rows = self
                .executor
                .query(
                    "SELECT author_id FROM n_posts WHERE post_id=:post_id AND is_deleted=0",
                    post_bind.clone(),
                )
                .await?;
            let Some(author) = rows
                .first()
                .and_then(|r| r.get("AUTHOR_ID"))
                .and_then(DbValue::as_i64)
                .filter(|v| *v > 0)
            else {
                return Ok(None);
            };
            if author == actor {
                return Ok(None);
            }
            let rows=self.executor.query("SELECT COALESCE(display_name,username) AS name FROM n_users WHERE user_id=:user_id",BindMap::from([("user_id".into(),DbValue::I64(actor))])).await?;
            let name = rows
                .first()
                .and_then(|r| nullable_text(r, "NAME"))
                .filter(|v| !v.is_empty())
                .unwrap_or_else(|| "有人".into());
            let rows=self.executor.query("SELECT DBMS_LOB.SUBSTR(content,4000,1) AS content FROM n_posts WHERE post_id=:post_id AND is_deleted=0",post_bind).await?;
            let excerpt = crate::posts::like::excerpt_json(
                rows.first()
                    .and_then(|r| nullable_text(r, "CONTENT"))
                    .as_deref(),
            );
            let metadata = format!(
                "{{\"target_post_id\":{id},\"post_excerpt\":{excerpt},\"event\":\"post_like\"}}"
            );
            let title = format!("{name} 赞了你的推文");
            let stored = self
                .store_notification(NotificationInput {
                    user_id: author as u64,
                    actor_id: Some(viewer),
                    kind: "like",
                    title: &title,
                    message: "你的推文收到了一次点赞。",
                    resource_type: Some("post"),
                    resource_id: Some(id),
                    priority: "normal",
                    metadata_json: Some(&metadata),
                })
                .await?;
            Ok(stored.map(|n| crate::posts::like::StoredLikeNotification {
                recipient: author as u64,
                id: n.id,
                push_enabled: n.push_enabled,
            }))
        })
    }
    fn list_notifications<'a>(
        &'a self,
        user: u64,
        query: &'a crate::notifications::NotificationQuery,
    ) -> StoreFuture<'a, (Vec<serde_json::Value>, u64)> {
        Box::pin(async move {
            static SQL: std::sync::OnceLock<Vec<(String, String)>> = std::sync::OnceLock::new();
            let filtered = !query.kind.is_empty() && query.kind != "all";
            let index = usize::from(query.show_deleted) * 4
                + usize::from(query.unread_only) * 2
                + usize::from(filtered);
            let variants=SQL.get_or_init(|| (0..8).map(|i| {
                let mut filter=if i&4!=0 {"user_id=:user_id AND deleted_at IS NOT NULL".to_owned()} else {"user_id=:user_id AND deleted_at IS NULL".to_owned()};
                if i&2!=0 {filter.push_str(" AND is_read=0");}
                if i&1!=0 {filter.push_str(" AND type=:type");}
                (format!("SELECT COUNT(*) AS total FROM n_notifications WHERE {filter}"),format!("SELECT notification_id,actor_id,type,title,message,resource_type,resource_id,priority,is_read,read_at,deleted_at,metadata_json,created_at FROM (SELECT notification_id,actor_id,type,title,message,resource_type,resource_id,priority,is_read,read_at,deleted_at,DBMS_LOB.SUBSTR(metadata_json,4000,1) AS metadata_json,created_at,ROW_NUMBER() OVER (ORDER BY created_at DESC) AS rn FROM n_notifications WHERE {filter}) WHERE rn BETWEEN :start_row AND :end_row"))
            }).collect());
            let (count_sql, page_sql) = &variants[index];
            let mut binds = user_bind(user);
            if filtered {
                binds.insert("type".into(), DbValue::String(query.kind.clone()));
            }
            let rows = self.executor.query(count_sql, binds.clone()).await?;
            let total = u64::try_from(row_number(rows.first().ok_or(SessionStoreError)?, "TOTAL"))
                .map_err(|_| SessionStoreError)?;
            binds.insert("start_row".into(), DbValue::F64(query.page.start));
            binds.insert("end_row".into(), DbValue::F64(query.page.end));
            let rows = self.executor.query(page_sql, binds).await?;
            let items = rows.iter().map(map_notification_row).collect();
            Ok((items, total))
        })
    }
    fn remove_post_like<'a>(&'a self, viewer: u64, id: u64) -> StoreFuture<'a, Option<f64>> {
        Box::pin(async move {
            const VISIBLE: &str = "SELECT p.post_id FROM n_posts p WHERE p.post_id=:post_id AND p.is_deleted=0 AND fn_can_view_post(:user_id,p.post_id)=1";
            const DELETE: &str = "DELETE FROM n_post_likes WHERE post_id=:post_id AND user_id=:user_id AND fn_can_view_post(:user_id,:post_id)=1";
            const COUNT: &str = "SELECT likes_count FROM n_post_stats WHERE post_id=:post_id";
            let binds = BindMap::from([
                ("post_id".into(), DbValue::I64(id as i64)),
                ("user_id".into(), DbValue::I64(viewer as i64)),
            ]);
            if self
                .executor
                .query(VISIBLE, binds.clone())
                .await?
                .is_empty()
            {
                return Ok(None);
            }
            let changed = self.executor.execute(DELETE, binds.clone()).await?;
            if changed == 0 && self.executor.query(VISIBLE, binds).await?.is_empty() {
                return Ok(None);
            }
            let rows = self
                .executor
                .query(
                    COUNT,
                    BindMap::from([("post_id".into(), DbValue::I64(id as i64))]),
                )
                .await?;
            Ok(Some(
                rows.first()
                    .map(|r| row_float(r, "LIKES_COUNT"))
                    .unwrap_or(0.0),
            ))
        })
    }
    fn set_post_bookmark<'a>(&'a self, viewer: u64, id: u64, saved: bool) -> StoreFuture<'a, bool> {
        Box::pin(async move {
            const VISIBLE: &str = "SELECT p.post_id FROM n_posts p WHERE p.post_id=:post_id AND p.is_deleted=0 AND fn_can_view_post(:user_id,p.post_id)=1";
            const INSERT: &str = "INSERT INTO n_post_bookmarks (post_id,user_id) SELECT :post_id,:user_id FROM dual WHERE fn_can_view_post(:user_id,:post_id)=1 AND NOT EXISTS (SELECT 1 FROM n_post_bookmarks WHERE post_id=:post_id AND user_id=:user_id)";
            const DELETE: &str = "DELETE FROM n_post_bookmarks WHERE post_id=:post_id AND user_id=:user_id AND fn_can_view_post(:user_id,:post_id)=1";
            let binds = BindMap::from([
                ("post_id".into(), DbValue::I64(id as i64)),
                ("user_id".into(), DbValue::I64(viewer as i64)),
            ]);
            if self
                .executor
                .query(VISIBLE, binds.clone())
                .await?
                .is_empty()
            {
                return Ok(false);
            }
            let changed = self
                .executor
                .execute(if saved { INSERT } else { DELETE }, binds.clone())
                .await?;
            if changed == 0 {
                return Ok(!self.executor.query(VISIBLE, binds).await?.is_empty());
            }
            Ok(true)
        })
    }
    fn read_tag_analytics<'a>(
        &'a self,
        viewer: u64,
        name: &'a str,
    ) -> StoreFuture<'a, Option<serde_json::Value>> {
        Box::pin(async move {
            const SQL:&str="SELECT t.name,COUNT(DISTINCT p.post_id) AS total_posts,COUNT(DISTINCT p.author_id) AS total_authors,NVL(SUM(ps.views_count),0) AS total_views,NVL(SUM(ps.likes_count),0) AS total_likes,NVL(ROUND(AVG(ps.engagement_score),2),0) AS avg_engagement_score FROM n_tags t LEFT JOIN n_post_tags pt ON pt.tag_id=t.tag_id LEFT JOIN n_posts p ON p.post_id=pt.post_id AND p.is_deleted=0 AND fn_can_view_post(:viewer_id,p.post_id)=1 LEFT JOIN n_post_stats ps ON ps.post_id=p.post_id WHERE t.name_lower=LOWER(:name) GROUP BY t.tag_id,t.name";
            let binds = BindMap::from([
                ("viewer_id".into(), DbValue::I64(viewer as i64)),
                ("name".into(), DbValue::String(name.to_owned())),
            ]);
            let rows = self.executor.query(SQL, binds).await?;
            Ok(rows.first().map(|r|serde_json::json!({"name":row_text(r,"NAME"),"total_posts":row_float(r,"TOTAL_POSTS"),"total_authors":row_float(r,"TOTAL_AUTHORS"),"total_views":row_float(r,"TOTAL_VIEWS"),"total_likes":row_float(r,"TOTAL_LIKES"),"engagement_score":row_float(r,"AVG_ENGAGEMENT_SCORE")})))
        })
    }
    fn list_tags<'a>(
        &'a self,
        query: &'a crate::tags::TagListQuery,
    ) -> StoreFuture<'a, (Vec<serde_json::Value>, u64)> {
        Box::pin(async move {
            const NORMAL_COUNT: &str =
                "SELECT COUNT(*) AS total FROM n_tags WHERE (:q IS NULL OR name_lower LIKE :q)";
            const TRENDING_COUNT: &str = "SELECT COUNT(*) AS total FROM n_tags WHERE is_trending=1";
            const NORMAL_LIST:&str="SELECT * FROM (SELECT tag_id,name,usage_count,trending_score,is_trending,updated_at,ROW_NUMBER() OVER (ORDER BY trending_score DESC,usage_count DESC,updated_at DESC) AS rn FROM n_tags WHERE (:q IS NULL OR name_lower LIKE :q)) WHERE rn BETWEEN :start_row AND :end_row";
            const TRENDING_LIST:&str="SELECT * FROM (SELECT tag_id,name,usage_count,trending_score,is_trending,updated_at,ROW_NUMBER() OVER (ORDER BY trending_score DESC,usage_count DESC,updated_at DESC) AS rn FROM n_tags WHERE is_trending=1) WHERE rn BETWEEN :start_row AND :end_row";
            let mut binds = BindMap::new();
            if !query.trending {
                binds.insert(
                    "q".into(),
                    query
                        .q
                        .clone()
                        .map(DbValue::String)
                        .unwrap_or(DbValue::Null),
                );
            }
            let count = self
                .executor
                .query(
                    if query.trending {
                        TRENDING_COUNT
                    } else {
                        NORMAL_COUNT
                    },
                    binds.clone(),
                )
                .await?;
            let total = u64::try_from(
                count
                    .first()
                    .map(|row| row_number(row, "TOTAL"))
                    .ok_or(SessionStoreError)?,
            )
            .map_err(|_| SessionStoreError)?;
            binds.insert("start_row".into(), DbValue::F64(query.page.start));
            binds.insert("end_row".into(), DbValue::F64(query.page.end));
            let rows = self
                .executor
                .query(
                    if query.trending {
                        TRENDING_LIST
                    } else {
                        NORMAL_LIST
                    },
                    binds,
                )
                .await?;
            let items=rows.iter().map(|row|serde_json::json!({"tag_id":row_number(row,"TAG_ID"),"name":row_text(row,"NAME"),"usage_count":row_float(row,"USAGE_COUNT"),"trending_score":row_float(row,"TRENDING_SCORE"),"is_trending":row_number(row,"IS_TRENDING"),"updated_at":nullable_text(row,"UPDATED_AT").map(|s|profile_date(&s)).unwrap_or_default()})).collect();
            Ok((items, total))
        })
    }
    fn list_visible_posts<'a>(
        &'a self,
        viewer: Option<u64>,
        query: &'a crate::posts::list::PostListQuery,
    ) -> StoreFuture<'a, (Vec<serde_json::Value>, u64)> {
        Box::pin(async move {
            let (count_sql, rows_sql) = post_list_sql(query);
            let mut binds = BindMap::from([(
                "viewer_id".into(),
                viewer
                    .map(|v| DbValue::I64(v as i64))
                    .unwrap_or(DbValue::Null),
            )]);
            match query.mode.as_str() {
                "user" => {
                    binds.insert(
                        "author_id".into(),
                        DbValue::I64(query.target_id.ok_or(SessionStoreError)? as i64),
                    );
                }
                "tag" => {
                    binds.insert(
                        "tag_name".into(),
                        DbValue::String(query.tag_name.clone().ok_or(SessionStoreError)?),
                    );
                }
                "replies" | "retweets" => {
                    binds.insert(
                        "target_post_id".into(),
                        DbValue::I64(query.target_id.ok_or(SessionStoreError)? as i64),
                    );
                }
                _ => {}
            }
            if !query.search.is_empty() {
                binds.insert("q".into(), DbValue::String(format!("%{}%", query.search)));
                binds.insert(
                    "tag_q".into(),
                    DbValue::String(format!("%{}%", query.tag_search)),
                );
            }
            let counts = self.executor.query(count_sql, binds.clone()).await?;
            let total = counts
                .first()
                .map(|row| row_number(row, "TOTAL"))
                .ok_or(SessionStoreError)?;
            let total = u64::try_from(total).map_err(|_| SessionStoreError)?;
            binds.insert("start_row".into(), DbValue::F64(query.page.start));
            binds.insert("end_row".into(), DbValue::F64(query.page.end));
            let rows = self.executor.query(rows_sql, binds).await?;
            Ok((
                rows.iter().map(|row| post_json(row, viewer)).collect(),
                total,
            ))
        })
    }
    fn reset_password_atomic<'a>(
        &'a self,
        email: &'a str,
        id: &'a str,
        otp_hash: &'a str,
        new_hash: &'a str,
    ) -> StoreFuture<'a, u64> {
        self.executor
            .reset_password_atomic(email, id, otp_hash, new_hash)
    }
    fn registration_otp<'a>(&'a self, email: &'a str, id: &'a str) -> StoreFuture<'a, bool> {
        Box::pin(async move {
            let b = BindMap::from([
                ("account".into(), DbValue::String(email.into())),
                ("verification_id".into(), DbValue::String(id.into())),
            ]);
            let rows=self.executor.query("SELECT verified_at FROM n_auth_otp_events WHERE account = :account AND otp_type = 'register' AND verification_id = :verification_id AND expires_at > CURRENT_TIMESTAMP AND verified_at IS NOT NULL",b).await?;
            Ok(!rows.is_empty())
        })
    }
    fn registration_exists<'a>(
        &'a self,
        email: &'a str,
        username: &'a str,
    ) -> StoreFuture<'a, bool> {
        Box::pin(async move {
            let b = BindMap::from([
                ("email".into(), DbValue::String(email.into())),
                ("username".into(), DbValue::String(username.into())),
            ]);
            let rows=self.executor.query("SELECT COUNT(*) AS total FROM n_users WHERE email = :email OR username = :username",b).await?;
            Ok(rows
                .first()
                .map(|r| row_number(r, "TOTAL"))
                .unwrap_or_default()
                > 0)
        })
    }
    fn registration_next_id<'a>(&'a self) -> StoreFuture<'a, u64> {
        Box::pin(async move {
            let rows = self
                .executor
                .query("SELECT seq_user_id.NEXTVAL AS id FROM dual", BindMap::new())
                .await?;
            row_id(rows.first().ok_or(SessionStoreError)?, "ID")
        })
    }
    fn registration_insert<'a>(
        &'a self,
        r: &'a crate::auth::registration::RegistrationRecord,
    ) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            let nullable = |s: &str| {
                if s.is_empty() {
                    DbValue::Null
                } else {
                    DbValue::String(s.into())
                }
            };
            let b = BindMap::from([
                ("user_id".into(), DbValue::I64(r.user_id as i64)),
                ("email".into(), DbValue::String(r.email.clone())),
                ("username".into(), DbValue::String(r.username.clone())),
                (
                    "password_hash".into(),
                    DbValue::String(r.password_hash.clone()),
                ),
                (
                    "display_name".into(),
                    DbValue::String(r.display_name.clone()),
                ),
                ("bio".into(), nullable(&r.bio)),
                ("location".into(), nullable(&r.location)),
                ("phone".into(), nullable(&r.phone)),
                ("birth_date".into(), nullable(&r.birth_date)),
            ]);
            self.executor.execute("INSERT INTO n_users (user_id,email,username,password_hash,display_name,bio,location,phone,birth_date,email_verified_at,status) VALUES (:user_id,:email,:username,:password_hash,:display_name,:bio,:location,:phone,CASE WHEN :birth_date IS NULL THEN NULL ELSE TO_DATE(:birth_date, 'YYYY-MM-DD') END,CURRENT_TIMESTAMP,'active')",b).await?;
            Ok(())
        })
    }
    fn otp_next_id<'a>(&'a self) -> StoreFuture<'a, u64> {
        Box::pin(async move {
            let rows = self
                .executor
                .query(
                    "SELECT seq_otp_event_id.NEXTVAL AS id FROM dual",
                    BindMap::new(),
                )
                .await?;
            row_id(rows.first().ok_or(SessionStoreError)?, "ID")
        })
    }
    fn otp_insert<'a>(&'a self, event: &'a crate::auth::otp::OtpEvent) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            let binds = BindMap::from([
                ("otp_event_id".into(), DbValue::I64(event.sequence as i64)),
                ("account".into(), DbValue::String(event.account.clone())),
                ("otp_type".into(), DbValue::String(event.kind.clone())),
                (
                    "send_channel".into(),
                    DbValue::String(event.channel.clone()),
                ),
                (
                    "verification_code_hash".into(),
                    DbValue::String(event.hash.clone()),
                ),
                ("verification_id".into(), DbValue::String(event.id.clone())),
                (
                    "expires_at".into(),
                    DbValue::String(oracle_time(&event.expires)),
                ),
            ]);
            self.executor.execute("INSERT INTO n_auth_otp_events (otp_event_id,account,otp_type,send_channel,verification_code_hash,verification_id,expires_at) VALUES (:otp_event_id,:account,:otp_type,:send_channel,:verification_code_hash,:verification_id,CAST(TO_TIMESTAMP_TZ(:expires_at, 'YYYY-MM-DD\"T\"HH24:MI:SS.FF3TZH:TZM') AT LOCAL AS TIMESTAMP))",binds).await?;
            Ok(())
        })
    }
    fn otp_lookup<'a>(
        &'a self,
        account: &'a str,
        kind: &'a str,
        id: &'a str,
    ) -> StoreFuture<'a, Option<String>> {
        Box::pin(async move {
            let binds = BindMap::from([
                ("account".into(), DbValue::String(account.into())),
                ("otp_type".into(), DbValue::String(kind.into())),
                ("verification_id".into(), DbValue::String(id.into())),
            ]);
            let rows=self.executor.query("SELECT verification_code_hash FROM n_auth_otp_events WHERE account = :account AND otp_type = :otp_type AND verification_id = :verification_id AND expires_at > CURRENT_TIMESTAMP ORDER BY created_at DESC FETCH FIRST 1 ROWS ONLY",binds).await?;
            Ok(rows.first().map(|r| row_text(r, "VERIFICATION_CODE_HASH")))
        })
    }
    fn otp_mark<'a>(&'a self, id: &'a str) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            self.executor.execute("UPDATE n_auth_otp_events SET verified_at = CURRENT_TIMESTAMP WHERE verification_id = :verification_id",BindMap::from([("verification_id".into(),DbValue::String(id.into()))])).await?;
            Ok(())
        })
    }
    fn otp_verified_at<'a>(&'a self, id: &'a str) -> StoreFuture<'a, Option<String>> {
        Box::pin(async move {
            let rows=self.executor.query("SELECT verified_at FROM n_auth_otp_events WHERE verification_id = :verification_id",BindMap::from([("verification_id".into(),DbValue::String(id.into()))])).await?;
            Ok(rows
                .first()
                .map(|r| row_text(r, "VERIFIED_AT"))
                .filter(|v| !v.is_empty())
                .map(|v| profile_date(&v)))
        })
    }
    fn list_sessions<'a>(
        &'a self,
        user: u64,
        page: crate::auth::session_list::SessionPage,
    ) -> StoreFuture<'a, (Vec<crate::auth::session_list::SessionItem>, u64)> {
        Box::pin(async move {
            let count = self.executor.query("SELECT COUNT(*) AS total FROM n_auth_sessions WHERE user_id = :user_id AND revoked_at IS NULL", user_bind(user)).await?;
            let total = u64::try_from(
                count
                    .first()
                    .map(|r| row_number(r, "TOTAL"))
                    .unwrap_or_default(),
            )
            .map_err(|_| SessionStoreError)?;
            let binds = BindMap::from([
                ("user_id".into(), DbValue::I64(user as i64)),
                ("start_row".into(), DbValue::F64(page.start)),
                ("end_row".into(), DbValue::F64(page.end)),
            ]);
            let rows=self.executor.query("SELECT session_id, device_info, ip_address, last_accessed_at, created_at FROM (SELECT session_id, device_info, ip_address, last_accessed_at, created_at, ROW_NUMBER() OVER (ORDER BY last_accessed_at DESC) AS rn FROM n_auth_sessions WHERE user_id = :user_id AND revoked_at IS NULL) WHERE rn BETWEEN :start_row AND :end_row",binds).await?;
            Ok((
                rows.iter()
                    .map(|row| crate::auth::session_list::SessionItem {
                        session_id: row_text(row, "SESSION_ID"),
                        device_info: row_text(row, "DEVICE_INFO"),
                        ip_address: row_text(row, "IP_ADDRESS"),
                        last_accessed_at: profile_date(&row_text(row, "LAST_ACCESSED_AT")),
                        created_at: profile_date(&row_text(row, "CREATED_AT")),
                        is_current: false,
                    })
                    .collect(),
                total,
            ))
        })
    }
    fn media_readiness<'a>(&'a self) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            let snapshot = self.executor.media_readiness_snapshot().await?;
            crate::auth::readiness::validate_feature_snapshot(&snapshot, "media")
        })
    }
    fn two_factor_readiness<'a>(&'a self) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            let snapshot = self.executor.readiness_snapshot().await?;
            crate::auth::readiness::validate_snapshot(&snapshot)
        })
    }
    fn login_account<'a>(
        &'a self,
        account: &'a str,
    ) -> StoreFuture<'a, Option<crate::auth::login::LoginAccount>> {
        Box::pin(async move {
            let rows = self.executor.query("SELECT user_id, username, password_hash, status, is_active FROM n_users WHERE email = :account OR username = :account FETCH FIRST 1 ROWS ONLY", BindMap::from([("account".into(), DbValue::String(account.into()))])).await?;
            rows.first()
                .map(|r| {
                    Ok(crate::auth::login::LoginAccount {
                        user_id: row_id(r, "USER_ID")?,
                        username: row_text(r, "USERNAME"),
                        password_hash: row_text(r, "PASSWORD_HASH"),
                        status: row_text(r, "STATUS"),
                        active: row_number(r, "IS_ACTIVE") == 1,
                    })
                })
                .transpose()
        })
    }
    fn login_two_factor<'a>(&'a self, user: u64) -> StoreFuture<'a, bool> {
        Box::pin(async move {
            let rows = self.executor.query("SELECT NVL(us.two_factor_enabled, 0) AS two_factor_enabled, tf.enabled_at FROM n_users u LEFT JOIN n_user_settings us ON us.user_id = u.user_id LEFT JOIN n_user_two_factor_secrets tf ON tf.user_id = u.user_id WHERE u.user_id = :user_id", user_bind(user)).await?;
            Ok(rows.first().is_some_and(|r| {
                row_number(r, "TWO_FACTOR_ENABLED") != 0
                    && r.get("ENABLED_AT")
                        .is_some_and(|v| !matches!(v, DbValue::Null))
            }))
        })
    }
    fn login_trusted_device<'a>(
        &'a self,
        user: u64,
        device: &'a crate::auth::login::LoginDevice,
    ) -> StoreFuture<'a, bool> {
        Box::pin(async move {
            let fingerprint: String = device.fingerprint.chars().take(200).collect();
            if fingerprint.is_empty() || fingerprint == "unknown" {
                return Ok(false);
            }
            let mut binds = user_bind(user);
            binds.insert("device_fingerprint".into(), DbValue::String(fingerprint));
            let rows = self.executor.query("SELECT trusted_device_id FROM n_user_two_factor_trusted_devices WHERE user_id = :user_id AND device_fingerprint = :device_fingerprint AND expires_at > CURRENT_TIMESTAMP AND revoked_at IS NULL FETCH FIRST 1 ROWS ONLY", binds).await?;
            let Some(row) = rows.first() else {
                return Ok(false);
            };
            let id = row_id(row, "TRUSTED_DEVICE_ID")?;
            let mut binds = device_bind(device, true);
            binds.remove("device_fingerprint");
            binds.insert("trusted_device_id".into(), DbValue::I64(id as i64));
            self.executor.execute("UPDATE n_user_two_factor_trusted_devices SET last_used_at = CURRENT_TIMESTAMP, device_info = :device_info, ip_address = :ip_address, user_agent = :user_agent WHERE trusted_device_id = :trusted_device_id", binds).await?;
            Ok(true)
        })
    }
    fn login_challenge<'a>(
        &'a self,
        c: &'a crate::auth::login::LoginChallenge,
    ) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            let mut b = device_bind(&c.device, true);
            b.extend(user_bind(c.user_id));
            b.insert("challenge_id".into(), DbValue::String(c.id.clone()));
            b.insert("remember_me".into(), DbValue::I64(i64::from(c.remember)));
            b.insert(
                "expires_at".into(),
                DbValue::String(oracle_time(&c.expires_at)),
            );
            self.executor.execute("INSERT INTO n_auth_two_factor_challenges (challenge_id,user_id,remember_me,device_info,device_fingerprint,ip_address,user_agent,expires_at) VALUES (:challenge_id,:user_id,:remember_me,:device_info,:device_fingerprint,:ip_address,:user_agent,CAST(TO_TIMESTAMP_TZ(:expires_at, 'YYYY-MM-DD\"T\"HH24:MI:SS.FF3TZH:TZM') AT LOCAL AS TIMESTAMP))", b).await?;
            Ok(())
        })
    }
    fn login_insert_session<'a>(
        &'a self,
        s: &'a crate::auth::login::LoginSession,
    ) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            let mut b = device_bind(&s.device, false);
            b.extend(user_bind(s.user_id));
            b.insert("session_id".into(), DbValue::String(s.id.clone()));
            b.insert("access_jti".into(), DbValue::String(s.access_jti.clone()));
            b.insert(
                "refresh_token_hash".into(),
                DbValue::String(s.refresh_hash.clone()),
            );
            b.insert(
                "access_token_expires_at".into(),
                DbValue::String(oracle_time(&s.access_expires_at)),
            );
            b.insert(
                "refresh_token_expires_at".into(),
                DbValue::String(oracle_time(&s.refresh_expires_at)),
            );
            self.executor.execute("INSERT INTO n_auth_sessions (session_id,user_id,access_jti,refresh_token_hash,device_info,device_fingerprint,ip_address,user_agent,access_token_expires_at,refresh_token_expires_at) VALUES (:session_id,:user_id,:access_jti,:refresh_token_hash,:device_info,:device_fingerprint,:ip_address,:user_agent,CAST(TO_TIMESTAMP_TZ(:access_token_expires_at, 'YYYY-MM-DD\"T\"HH24:MI:SS.FF3TZH:TZM') AT LOCAL AS TIMESTAMP),CAST(TO_TIMESTAMP_TZ(:refresh_token_expires_at, 'YYYY-MM-DD\"T\"HH24:MI:SS.FF3TZH:TZM') AT LOCAL AS TIMESTAMP))", b).await?;
            self.executor
                .execute(
                    "UPDATE n_users SET last_login_at = CURRENT_TIMESTAMP WHERE user_id = :user_id",
                    user_bind(s.user_id),
                )
                .await?;
            Ok(())
        })
    }
    fn known_login_device<'a>(&'a self, user: u64, fingerprint: &'a str) -> StoreFuture<'a, bool> {
        Box::pin(async move {
            let mut b = user_bind(user);
            b.insert(
                "device_fingerprint".into(),
                DbValue::String(fingerprint.into()),
            );
            let rows=self.executor.query("SELECT COUNT(*) AS total FROM n_auth_sessions WHERE user_id=:user_id AND device_fingerprint=:device_fingerprint",b).await?;
            let row = rows.first().ok_or(SessionStoreError)?;
            Ok(row_number(row, "TOTAL") > 0)
        })
    }
    fn record_login_alert<'a>(
        &'a self,
        session: &'a crate::auth::login::LoginSession,
    ) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            let rows=self.executor.query("SELECT NVL(us.login_alerts,1) AS login_alerts,NVL(us.email_notification_enabled,1) AS email_notification_enabled FROM n_users u LEFT JOIN n_user_settings us ON us.user_id=u.user_id WHERE u.user_id=:user_id",user_bind(session.user_id)).await?;
            if rows
                .first()
                .is_some_and(|r| row_number(r, "LOGIN_ALERTS") == 0)
            {
                return Ok(());
            }
            let device = &session.device;
            let metadata=serde_json::json!({"session_id":session.id,"device_info":device.info,"device_fingerprint":device.fingerprint,"ip_address":device.ip,"user_agent":device.user_agent}).to_string();
            let message = format!(
                "你的账号刚刚通过新设备登录：{}",
                if device.info.is_empty() {
                    "unknown"
                } else {
                    &device.info
                }
            );
            self.store_notification(NotificationInput {
                user_id: session.user_id,
                actor_id: None,
                kind: "login_alert",
                title: "新设备登录提醒",
                message: &message,
                resource_type: Some("auth_session"),
                resource_id: None,
                priority: "high",
                metadata_json: Some(&metadata),
            })
            .await?;
            Ok(())
        })
    }
    fn update_self_profile<'a>(
        &'a self,
        user: u64,
        fields: &'a std::collections::BTreeMap<String, String>,
    ) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            let mut mask = 0usize;
            let mut binds = user_bind(user);
            for (index, key) in crate::users::self_profile::PROFILE_KEYS.iter().enumerate() {
                if let Some(value) = fields.get(*key) {
                    mask |= 1 << index;
                    binds.insert(
                        (*key).into(),
                        if value.is_empty() {
                            DbValue::Null
                        } else {
                            DbValue::String(value.clone())
                        },
                    );
                }
            }
            if mask == 0 {
                return Ok(());
            }
            self.executor
                .execute(profile_update_sql(mask), binds)
                .await?;
            Ok(())
        })
    }
    fn read_visible_post<'a>(
        &'a self,
        viewer: Option<u64>,
        id: u64,
    ) -> StoreFuture<'a, Option<serde_json::Value>> {
        Box::pin(async move {
            let rows = self
                .executor
                .query(POST_DETAIL_SQL, post_binds(viewer, id))
                .await?;
            Ok(rows.first().map(|row| post_json(row, viewer)))
        })
    }
    fn read_post_author<'a>(
        &'a self,
        viewer: Option<u64>,
        id: u64,
    ) -> StoreFuture<'a, Option<serde_json::Value>> {
        Box::pin(async move {
            let mut binds = user_bind(id);
            binds.insert(
                "viewer_id".into(),
                viewer
                    .map(|v| DbValue::I64(v as i64))
                    .unwrap_or(DbValue::Null),
            );
            let rows = self.executor.query(PUBLIC_PROFILE_SQL, binds).await?;
            Ok(rows.first().map(public_profile_json))
        })
    }
    fn read_post_media<'a>(&'a self, id: u64) -> StoreFuture<'a, Vec<serde_json::Value>> {
        Box::pin(async move {
            Ok(self
                .executor
                .query(POST_MEDIA_SQL, post_id_bind(id))
                .await?
                .iter()
                .map(media_json)
                .collect())
        })
    }
    fn read_post_tags<'a>(&'a self, id: u64) -> StoreFuture<'a, Vec<String>> {
        Box::pin(async move {
            Ok(self
                .executor
                .query(POST_TAGS_SQL, post_id_bind(id))
                .await?
                .iter()
                .map(|row| row_text(row, "NAME"))
                .collect())
        })
    }
    fn read_post_mentions<'a>(
        &'a self,
        viewer: Option<u64>,
        id: u64,
    ) -> StoreFuture<'a, Vec<serde_json::Value>> {
        Box::pin(async move {
            Ok(self
                .executor
                .query(POST_MENTIONS_SQL, post_binds(viewer, id))
                .await?
                .iter()
                .map(public_profile_json)
                .collect())
        })
    }
    fn increment_post_views<'a>(&'a self, id: u64) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            self.executor
                .execute(POST_VIEWS_SQL, post_id_bind(id))
                .await?;
            Ok(())
        })
    }
    fn public_profile<'a>(
        &'a self,
        viewer: u64,
        target: u64,
    ) -> StoreFuture<'a, Option<serde_json::Value>> {
        Box::pin(async move {
            let binds = BindMap::from([
                ("viewer_id".into(), DbValue::I64(viewer as i64)),
                ("user_id".into(), DbValue::I64(target as i64)),
            ]);
            let rows = self.executor.query(PUBLIC_PROFILE_SQL, binds).await?;
            Ok(rows.first().map(public_profile_json))
        })
    }
    fn login_profile<'a>(&'a self, user: u64) -> StoreFuture<'a, Option<serde_json::Value>> {
        Box::pin(async move {
            let mut b = user_bind(user);
            b.insert("viewer_id".into(), DbValue::I64(user as i64));
            let rows = self.executor.query("SELECT user_id,email,username,avatar_url,display_name,bio,location,website,phone,TO_CHAR(birth_date,'YYYY-MM-DD') AS birth_date,email_verified_at,is_verified,is_active,status,followers_count,following_count,posts_count,likes_count,bookmarks_count,comments_count,'online' AS online_status,(SELECT MAX(s.last_accessed_at) FROM n_auth_sessions s WHERE s.user_id=u.user_id AND s.revoked_at IS NULL) AS last_seen_at,created_at,updated_at,fn_get_user_relationship(:viewer_id,u.user_id) AS relation FROM v_user_profile_self u WHERE u.user_id=:user_id", b).await?;
            Ok(rows.first().map(profile_json))
        })
    }
    fn challenge_lookup<'a>(
        &'a self,
        id: &'a str,
    ) -> StoreFuture<'a, Option<crate::auth::login::ChallengeRow>> {
        Box::pin(async move {
            let b = BindMap::from([("challenge_id".into(), DbValue::String(id.into()))]);
            let rows=self.executor.query("SELECT c.challenge_id,c.user_id,c.remember_me,c.device_info,c.device_fingerprint,c.ip_address,c.user_agent,u.username FROM n_auth_two_factor_challenges c JOIN n_users u ON u.user_id=c.user_id WHERE c.challenge_id=:challenge_id AND c.expires_at>CURRENT_TIMESTAMP AND c.consumed_at IS NULL AND u.is_active=1 AND u.status='active'",b).await?;
            rows.first()
                .map(|r| {
                    Ok(crate::auth::login::ChallengeRow {
                        user_id: row_id(r, "USER_ID")?,
                        username: row_text(r, "USERNAME"),
                        remember: row_number(r, "REMEMBER_ME") != 0,
                        device: crate::auth::login::LoginDevice {
                            fingerprint: row_text(r, "DEVICE_FINGERPRINT"),
                            info: row_text(r, "DEVICE_INFO"),
                            ip: row_text(r, "IP_ADDRESS"),
                            user_agent: row_text(r, "USER_AGENT"),
                        },
                    })
                })
                .transpose()
        })
    }
    fn two_factor_secret<'a>(
        &'a self,
        user: u64,
    ) -> StoreFuture<'a, Option<crate::auth::login::EncryptedSecret>> {
        Box::pin(async move {
            let rows=self.executor.query("SELECT secret_encrypted,secret_iv,secret_auth_tag,enabled_at FROM n_user_two_factor_secrets WHERE user_id=:user_id",user_bind(user)).await?;
            Ok(rows.first().map(|r| crate::auth::login::EncryptedSecret {
                encrypted: row_text(r, "SECRET_ENCRYPTED"),
                iv: row_text(r, "SECRET_IV"),
                tag: row_text(r, "SECRET_AUTH_TAG"),
                enabled: r
                    .get("ENABLED_AT")
                    .is_some_and(|v| !matches!(v, DbValue::Null)),
            }))
        })
    }
    fn recovery_codes<'a>(
        &'a self,
        user: u64,
    ) -> StoreFuture<'a, Vec<crate::auth::login::RecoveryCode>> {
        Box::pin(async move {
            self.executor.query("SELECT recovery_code_id,code_hash FROM n_user_two_factor_recovery_codes WHERE user_id=:user_id AND used_at IS NULL ORDER BY created_at ASC",user_bind(user)).await?.iter().map(|r|Ok(crate::auth::login::RecoveryCode{id:row_id(r,"RECOVERY_CODE_ID")?,hash:row_text(r,"CODE_HASH")})).collect()
        })
    }
    fn consume_recovery<'a>(&'a self, id: u64) -> StoreFuture<'a, u64> {
        self.executor.execute("UPDATE n_user_two_factor_recovery_codes SET used_at=CURRENT_TIMESTAMP WHERE recovery_code_id=:recovery_code_id AND used_at IS NULL",BindMap::from([("recovery_code_id".into(),DbValue::I64(id as i64))]))
    }
    fn consume_challenge<'a>(&'a self, id: &'a str) -> StoreFuture<'a, u64> {
        self.executor.execute("UPDATE n_auth_two_factor_challenges SET consumed_at=CURRENT_TIMESTAMP WHERE challenge_id=:challenge_id AND consumed_at IS NULL AND expires_at>CURRENT_TIMESTAMP",BindMap::from([("challenge_id".into(),DbValue::String(id.into()))]))
    }
    fn trust_challenge_device<'a>(
        &'a self,
        row: &'a crate::auth::login::ChallengeRow,
        expires_at: &'a str,
    ) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            let fingerprint: String = row.device.fingerprint.chars().take(200).collect();
            if fingerprint.is_empty() || fingerprint == "unknown" {
                return Ok(());
            }
            let idrows = self
                .executor
                .query(
                    "SELECT seq_2fa_trusted_device_id.NEXTVAL AS id FROM dual",
                    BindMap::new(),
                )
                .await?;
            let id = row_id(idrows.first().ok_or(SessionStoreError)?, "ID")?;
            let mut b = device_bind(&row.device, true);
            b.extend(user_bind(row.user_id));
            b.insert("trusted_device_id".into(), DbValue::I64(id as i64));
            b.insert(
                "expires_at".into(),
                DbValue::String(oracle_time(expires_at)),
            );
            self.executor.execute("MERGE INTO n_user_two_factor_trusted_devices target USING (SELECT :user_id AS user_id,:device_fingerprint AS device_fingerprint FROM dual) src ON (target.user_id=src.user_id AND target.device_fingerprint=src.device_fingerprint) WHEN MATCHED THEN UPDATE SET device_info=:device_info,ip_address=:ip_address,user_agent=:user_agent,expires_at=CAST(TO_TIMESTAMP_TZ(:expires_at,'YYYY-MM-DD\"T\"HH24:MI:SS.FF3TZH:TZM') AT LOCAL AS TIMESTAMP),revoked_at=NULL,last_used_at=CURRENT_TIMESTAMP WHEN NOT MATCHED THEN INSERT (trusted_device_id,user_id,device_fingerprint,device_info,ip_address,user_agent,expires_at) VALUES (:trusted_device_id,:user_id,:device_fingerprint,:device_info,:ip_address,:user_agent,CAST(TO_TIMESTAMP_TZ(:expires_at,'YYYY-MM-DD\"T\"HH24:MI:SS.FF3TZH:TZM') AT LOCAL AS TIMESTAMP))",b).await?;
            Ok(())
        })
    }
    fn touch<'a>(&'a self, claims: &'a TokenClaims) -> StoreFuture<'a, u64> {
        let mut binds = session_binds(claims.user_id, &claims.session_id);
        binds.insert("access_jti".into(), DbValue::String(claims.jti.clone()));
        self.executor.execute(TOUCH_SQL, binds)
    }
    fn revoke<'a>(&'a self, user_id: u64, id: &'a str) -> StoreFuture<'a, u64> {
        self.executor
            .execute(REVOKE_SQL, session_binds(user_id, id))
    }
    fn revoke_others<'a>(&'a self, user_id: u64, current: &'a str) -> StoreFuture<'a, u64> {
        self.executor
            .execute(REVOKE_OTHERS_SQL, session_binds(user_id, current))
    }
    fn revoke_current<'a>(
        &'a self,
        user_id: u64,
        session: &'a str,
        credential: &'a SessionCredential,
    ) -> StoreFuture<'a, u64> {
        let mut binds = session_binds(user_id, session);
        let sql = match credential {
            SessionCredential::AccessJti(jti) => {
                binds.insert("access_jti".into(), DbValue::String(jti.clone()));
                LOGOUT_ACCESS_SQL
            }
            SessionCredential::RefreshHash(hash) => {
                binds.insert("refresh_token_hash".into(), DbValue::String(hash.clone()));
                LOGOUT_REFRESH_SQL
            }
        };
        self.executor.execute(sql, binds)
    }
    fn rotate<'a>(&'a self, rotation: &'a SessionRotation) -> StoreFuture<'a, u64> {
        let mut binds = session_binds(rotation.user_id, &rotation.session_id);
        for (key, value) in [
            ("access_jti", &rotation.access_jti),
            ("refresh_token_hash", &rotation.refresh_hash),
            ("old_refresh_hash", &rotation.old_refresh_hash),
        ] {
            binds.insert(key.into(), DbValue::String(value.clone()));
        }
        for (key, value) in [
            ("access_expires_at", &rotation.access_expires_at),
            ("refresh_expires_at", &rotation.refresh_expires_at),
        ] {
            binds.insert(
                key.into(),
                DbValue::String(value.trim_end_matches('Z').to_owned() + "+00:00"),
            );
        }
        self.executor.execute(ROTATE_SQL, binds)
    }
}
fn session_binds(user: u64, id: &str) -> BindMap {
    BindMap::from([
        ("user_id".into(), DbValue::I64(user as i64)),
        ("session_id".into(), DbValue::String(id.into())),
    ])
}
impl SessionExecutor for OraclePool {
    fn create_post_atomic<'a>(
        &'a self,
        actor: u64,
        input: &'a crate::posts::create_request::PostCreateInput,
    ) -> StoreFuture<'a, crate::posts::create_transaction::PostCreation> {
        let input = input.clone();
        Box::pin(async move {
            self.run_blocking(move |connection| {
                crate::posts::create_transaction::execute(connection, actor, &input)
            })
            .await
            .map_err(|_| SessionStoreError)
        })
    }
    fn reset_password_atomic<'a>(
        &'a self,
        email: &'a str,
        id: &'a str,
        otp_hash: &'a str,
        new_hash: &'a str,
    ) -> StoreFuture<'a, u64> {
        let (email, id, otp_hash, new_hash) = (
            email.to_owned(),
            id.to_owned(),
            otp_hash.to_owned(),
            new_hash.to_owned(),
        );
        Box::pin(async move {
            self.run_blocking(move |connection| {
                crate::auth::password_reset_transaction::execute(
                    connection, &email, &id, &otp_hash, &new_hash,
                )
            })
            .await
            .map_err(|_| SessionStoreError)
        })
    }
    fn media_readiness_snapshot(&self) -> StoreFuture<'_, serde_json::Value> {
        Box::pin(async move {
            self.run_blocking(crate::auth::readiness::collect_media_snapshot)
                .await
                .map_err(|_| SessionStoreError)
        })
    }
    fn readiness_snapshot(&self) -> StoreFuture<'_, serde_json::Value> {
        Box::pin(async move {
            self.run_blocking(crate::auth::readiness::collect_snapshot)
                .await
                .map_err(|_| SessionStoreError)
        })
    }
    fn query(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, Vec<DbRow>> {
        Box::pin(async move {
            self.query_rows(sql, binds)
                .await
                .map_err(|_| SessionStoreError)
        })
    }
    fn execute(&self, sql: &'static str, binds: BindMap) -> StoreFuture<'_, u64> {
        Box::pin(async move {
            OraclePool::execute(self, sql, binds)
                .await
                .map(|r| r.rows_affected)
                .map_err(|_| SessionStoreError)
        })
    }
    fn preflight(&self, sql: &'static str) -> StoreFuture<'_, ()> {
        Box::pin(async move {
            self.query_rows(sql, BindMap::new())
                .await
                .map(|_| ())
                .map_err(|_| SessionStoreError)
        })
    }
}

fn user_bind(user: u64) -> BindMap {
    BindMap::from([("user_id".into(), DbValue::I64(user as i64))])
}
fn row_number(row: &DbRow, key: &str) -> i64 {
    row.get(key).and_then(DbValue::as_i64).unwrap_or_default()
}
fn row_id(row: &DbRow, key: &str) -> Result<u64, SessionStoreError> {
    u64::try_from(row_number(row, key))
        .ok()
        .filter(|n| *n > 0 && *n <= 9_007_199_254_740_991)
        .ok_or(SessionStoreError)
}
fn row_text(row: &DbRow, key: &str) -> String {
    row.get(key)
        .and_then(DbValue::as_str)
        .unwrap_or_default()
        .to_owned()
}
fn map_post_comment(row: &DbRow) -> Result<serde_json::Value, SessionStoreError> {
    let date = |key| nullable_text(row,key).map(|s|profile_date(&s)).unwrap_or_default();
    Ok(serde_json::json!({
        "comment_id":row_id(row,"COMMENT_ID")?, "post_id":row_id(row,"POST_ID")?, "author_id":row_id(row,"USER_ID")?,
        "parent_comment_id":row.get("PARENT_COMMENT_ID").and_then(DbValue::as_i64),
        "root_comment_id":row.get("ROOT_COMMENT_ID").and_then(DbValue::as_i64),
        "content":row_text(row,"CONTENT"), "stats":{"likes_count":row_number(row,"LIKES_COUNT"),"replies_count":row_number(row,"REPLIES_COUNT")},
        "is_liked":row_number(row,"IS_LIKED")==1, "created_at":date("CREATED_AT"), "updated_at":date("UPDATED_AT")
    }))
}
fn oracle_time(value: &str) -> String {
    value.trim_end_matches('Z').to_owned() + "+00:00"
}
fn device_bind(device: &crate::auth::login::LoginDevice, truncate: bool) -> BindMap {
    let text = |value: &str| {
        if truncate {
            value.chars().take(200).collect()
        } else {
            value.to_owned()
        }
    };
    BindMap::from([
        (
            "device_fingerprint".into(),
            DbValue::String(text(&device.fingerprint)),
        ),
        ("device_info".into(), DbValue::String(text(&device.info))),
        ("ip_address".into(), DbValue::String(device.ip.clone())),
        (
            "user_agent".into(),
            DbValue::String(device.user_agent.clone()),
        ),
    ])
}
fn profile_json(r: &DbRow) -> serde_json::Value {
    let relation = row_text(r, "RELATION");
    let avatar = row_text(r, "AVATAR_URL");
    let avatar = avatar.trim();
    let optional = |key| r.get(key).and_then(DbValue::as_str).map(str::to_owned);
    serde_json::json!({"user_id":row_number(r,"USER_ID"),"username":row_text(r,"USERNAME"),"display_name":row_text(r,"DISPLAY_NAME"),"avatar_url":if avatar.is_empty() || avatar=="/default-avatar.png" || avatar=="default-avatar.png" {"/storage/default-avatar.png"} else {avatar},"bio":row_text(r,"BIO"),"location":row_text(r,"LOCATION"),"website":row_text(r,"WEBSITE"),"is_verified":row_number(r,"IS_VERIFIED"),"followers_count":row_number(r,"FOLLOWERS_COUNT"),"following_count":row_number(r,"FOLLOWING_COUNT"),"posts_count":row_number(r,"POSTS_COUNT"),"likes_count":row_number(r,"LIKES_COUNT"),"relationship":{"is_self":relation=="self","is_following":relation=="following" || relation=="mutual_follow","is_blocked":relation=="blocked_by","is_blocking":relation=="blocking","relation":if relation.is_empty(){"none"}else{&relation}},"online_status":"online","last_seen_at":optional("LAST_SEEN_AT").map(|s|profile_date(&s)),"email":row_text(r,"EMAIL"),"phone":row_text(r,"PHONE"),"birth_date":optional("BIRTH_DATE"),"email_verified_at":optional("EMAIL_VERIFIED_AT").map(|s|profile_date(&s)),"is_active":row_number(r,"IS_ACTIVE"),"status":row_text(r,"STATUS"),"created_at":optional("CREATED_AT").map(|s|profile_date(&s)).unwrap_or_default(),"updated_at":optional("UPDATED_AT").map(|s|profile_date(&s)).unwrap_or_default()})
}

fn post_id_bind(id: u64) -> BindMap {
    BindMap::from([("post_id".into(), DbValue::I64(id as i64))])
}
fn post_binds(viewer: Option<u64>, id: u64) -> BindMap {
    let mut binds = post_id_bind(id);
    binds.insert(
        "viewer_id".into(),
        viewer
            .map(|v| DbValue::I64(v as i64))
            .unwrap_or(DbValue::Null),
    );
    binds
}
fn row_float(row: &DbRow, key: &str) -> f64 {
    match row.get(key) {
        Some(DbValue::F64(v)) => *v,
        Some(DbValue::I64(v)) => *v as f64,
        Some(v) => v
            .as_str()
            .and_then(|v| v.parse::<f64>().ok())
            .filter(|v| v.is_finite())
            .unwrap_or(0.0),
        None => 0.0,
    }
}
fn nullable_number(row: &DbRow, key: &str) -> serde_json::Value {
    if row.get(key).is_none_or(|v| matches!(v, DbValue::Null)) {
        serde_json::Value::Null
    } else {
        serde_json::json!(row_float(row, key))
    }
}
fn nullable_text(row: &DbRow, key: &str) -> Option<String> {
    row.get(key)
        .and_then(DbValue::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}
fn post_json(row: &DbRow, viewer: Option<u64>) -> serde_json::Value {
    let author = row_number(row, "AUTHOR_ID");
    let date = |key| {
        nullable_text(row, key)
            .map(|x| profile_date(&x))
            .unwrap_or_default()
    };
    serde_json::json!({"post_id":row_number(row,"POST_ID"),"author":{"user_id":author},"content":row_text(row,"CONTENT"),"post_type":row_text(row,"POST_TYPE"),"visibility":row_text(row,"VISIBILITY"),"language":row_text(row,"LANGUAGE"),"location":row_text(row,"LOCATION"),"reply_to_post_id":nullable_number(row,"REPLY_TO_POST_ID"),"repost_of_post_id":nullable_number(row,"REPOST_OF_POST_ID"),"quoted_post_id":nullable_number(row,"QUOTED_POST_ID"),"media":[],"tags":[],"mentions":[],"stats":{"likes_count":row_float(row,"LIKES_COUNT"),"comments_count":row_float(row,"COMMENTS_COUNT"),"replies_count":row_float(row,"REPLIES_COUNT"),"retweets_count":row_float(row,"RETWEETS_COUNT"),"views_count":row_float(row,"VIEWS_COUNT"),"engagement_score":row_float(row,"ENGAGEMENT_SCORE")},"viewer_state":{"is_liked":row_number(row,"IS_LIKED")==1,"is_bookmarked":row_number(row,"IS_BOOKMARKED")==1,"can_delete":viewer.is_some_and(|v|v as i64==author)},"created_at":date("CREATED_AT"),"updated_at":date("UPDATED_AT")})
}
fn media_json(row: &DbRow) -> serde_json::Value {
    serde_json::json!({"media_id":row_number(row,"MEDIA_ID"),"media_type":row_text(row,"MEDIA_TYPE"),"file_name":row_text(row,"FILE_NAME"),"public_url":row_text(row,"PUBLIC_URL"),"file_size":row_number(row,"FILE_SIZE"),"mime_type":row_text(row,"MIME_TYPE"),"width":nullable_number(row,"WIDTH"),"height":nullable_number(row,"HEIGHT"),"duration":nullable_number(row,"DURATION"),"thumbnail_url":nullable_text(row,"THUMBNAIL_URL"),"alt_text":nullable_text(row,"ALT_TEXT"),"description":nullable_text(row,"DESCRIPTION"),"status":row_text(row,"STATUS"),"created_at":nullable_text(row,"CREATED_AT").map(|x|profile_date(&x)).unwrap_or_default()})
}
fn public_profile_json(row: &DbRow) -> serde_json::Value {
    let mut value = profile_json(row);
    let object = value.as_object_mut().expect("profile is an object");
    for key in [
        "email",
        "phone",
        "birth_date",
        "email_verified_at",
        "is_active",
        "status",
        "created_at",
        "updated_at",
    ] {
        object.remove(key);
    }
    let status = row_text(row, "ONLINE_STATUS");
    let status = if status == "online" || status == "hidden" {
        status.as_str()
    } else {
        "offline"
    };
    object.insert("online_status".into(), status.into());
    if status == "hidden" {
        object.insert("last_seen_at".into(), serde_json::Value::Null);
    }
    value
}
fn profile_date(text: &str) -> String {
    use chrono::{SecondsFormat, TimeZone};
    if let Ok(date) = chrono::DateTime::parse_from_rfc3339(text) {
        return date
            .with_timezone(&chrono::Utc)
            .to_rfc3339_opts(SecondsFormat::Millis, true);
    }
    if let Ok(date) = chrono::DateTime::parse_from_str(text, "%Y-%m-%d %H:%M:%S%.f %:z") {
        return date
            .with_timezone(&chrono::Utc)
            .to_rfc3339_opts(SecondsFormat::Millis, true);
    }
    if let Ok(date) = chrono::NaiveDateTime::parse_from_str(text, "%Y-%m-%d %H:%M:%S%.f") {
        if let Some(local) = chrono::Local.from_local_datetime(&date).earliest() {
            return local
                .with_timezone(&chrono::Utc)
                .to_rfc3339_opts(SecondsFormat::Millis, true);
        }
    }
    text.to_owned()
}

#[cfg(test)]
mod profile_tests {
    use super::*;
    #[test]
    fn self_profile_mapping_matches_shared_fixture() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../contracts/scenarios/user-self-profile.json"
        ))
        .unwrap();
        let mut row = DbRow::new();
        for (key, value) in [
            ("USERNAME", "selfuser"),
            ("EMAIL", "self@example.test"),
            ("DISPLAY_NAME", "New User"),
            ("STATUS", "active"),
            ("RELATION", "self"),
            ("EMAIL_VERIFIED_AT", "2026-01-02T03:04:05.000Z"),
            ("CREATED_AT", "2026-01-02T03:04:05.000Z"),
            ("UPDATED_AT", "2026-01-02T03:04:05.000Z"),
        ] {
            row.insert(key.into(), DbValue::String(value.into()));
        }
        row.insert("USER_ID".into(), DbValue::I64(42));
        row.insert("IS_ACTIVE".into(), DbValue::I64(1));
        assert_eq!(profile_json(&row), fixture["profile"]);
    }
    #[test]
    fn oracle_timestamp_and_whitespace_avatar_map_like_default_nuxt_shape() {
        use chrono::TimeZone;
        let text = oracle::sql_type::Timestamp::new(2017, 8, 9, 11, 22, 33, 500_000_000)
            .unwrap()
            .to_string();
        let expected = chrono::Local
            .with_ymd_and_hms(2017, 8, 9, 11, 22, 33)
            .earliest()
            .unwrap()
            .with_timezone(&chrono::Utc)
            .format("%Y-%m-%dT%H:%M:%S.500Z")
            .to_string();
        let row = DbRow::from([
            (
                "AVATAR_URL".into(),
                DbValue::String(" /default-avatar.png ".into()),
            ),
            ("CREATED_AT".into(), DbValue::String(text)),
        ]);
        let profile = profile_json(&row);
        assert_eq!(profile["avatar_url"], "/storage/default-avatar.png");
        assert_eq!(profile["created_at"], expected);
        assert_eq!(
            profile_date("2017-08-09 11:22:33.500 -08:00"),
            "2017-08-09T19:22:33.500Z"
        );
    }
    #[test]
    fn public_profile_never_exposes_private_fields_or_hidden_activity() {
        let row = DbRow::from([
            ("USER_ID".into(), DbValue::I64(7)),
            (
                "EMAIL".into(),
                DbValue::String("private@example.test".into()),
            ),
            ("PHONE".into(), DbValue::String("secret".into())),
            ("ONLINE_STATUS".into(), DbValue::String("hidden".into())),
            (
                "LAST_SEEN_AT".into(),
                DbValue::String("2026-01-02T03:04:05Z".into()),
            ),
            ("RELATION".into(), DbValue::String("following".into())),
        ]);
        let value = public_profile_json(&row);
        assert_eq!(value["online_status"], "hidden");
        assert!(value["last_seen_at"].is_null());
        assert_eq!(value["relationship"]["is_following"], true);
        for key in [
            "email",
            "phone",
            "birth_date",
            "email_verified_at",
            "status",
            "is_active",
            "created_at",
            "updated_at",
        ] {
            assert!(value.get(key).is_none());
        }
    }
}
