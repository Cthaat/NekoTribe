use crate::{
    auth::{
        session_repository::{
            NotificationInput, OracleSessions, SessionExecutor, StoredNotification,
        },
        sessions::{NativeState, SessionStoreError},
    },
    db::{oracle::BindMap, row::DbRow, value::DbValue},
    httpx::errors::ApiError,
    posts::create_request::PostCreateInput,
};
use serde_json::Map;
use std::collections::HashSet;

#[derive(Clone, Debug)]
pub struct PostNoticeInput {
    pub recipient: u64,
    pub actor: u64,
    pub post_id: u64,
    pub kind: &'static str,
    pub title: String,
    pub message: String,
    pub metadata_json: String,
}

pub(crate) async fn actor_name<E: SessionExecutor>(
    executor: &E,
    actor: u64,
) -> Result<String, SessionStoreError> {
    let actor = i64::try_from(actor).map_err(|_| SessionStoreError)?;
    let rows = executor
        .query(
            "SELECT COALESCE(display_name,username) AS name FROM n_users WHERE user_id=:user_id",
            BindMap::from([("user_id".into(), DbValue::I64(actor))]),
        )
        .await?;
    Ok(rows
        .first()
        .and_then(|row| row.get("NAME"))
        .and_then(DbValue::as_str)
        .unwrap_or("有人")
        .to_owned())
}
pub(crate) async fn source_author<E: SessionExecutor>(
    executor: &E,
    post: u64,
) -> Result<Option<u64>, SessionStoreError> {
    let post = i64::try_from(post).map_err(|_| SessionStoreError)?;
    let rows = executor
        .query(
            "SELECT author_id FROM n_posts WHERE post_id=:post_id AND is_deleted=0",
            BindMap::from([("post_id".into(), DbValue::I64(post))]),
        )
        .await?;
    optional_user_id(rows.first(), "AUTHOR_ID")
}
pub(crate) async fn excerpt<E: SessionExecutor>(
    executor: &E,
    post: u64,
) -> Result<String, SessionStoreError> {
    let post = i64::try_from(post).map_err(|_| SessionStoreError)?;
    let rows = executor.query(
        "SELECT DBMS_LOB.SUBSTR(content,4000,1) AS content FROM n_posts WHERE post_id=:post_id AND is_deleted=0",
        BindMap::from([("post_id".into(), DbValue::I64(post))]),
    ).await?;
    Ok(crate::posts::like::excerpt_json(
        rows.first()
            .and_then(|row| row.get("CONTENT"))
            .and_then(DbValue::as_str),
    ))
}
pub(crate) async fn resolve_mention_recipient<E: SessionExecutor>(
    executor: &E,
    user: f64,
) -> Result<Option<u64>, SessionStoreError> {
    // Preserve the original JavaScript number: 7.5 must never resolve to user 7.
    let rows = executor
        .query(
            "SELECT user_id FROM n_users WHERE user_id=:user_id",
            BindMap::from([("user_id".into(), DbValue::F64(user))]),
        )
        .await?;
    optional_user_id(rows.first(), "USER_ID")
}
fn optional_user_id(row: Option<&DbRow>, key: &str) -> Result<Option<u64>, SessionStoreError> {
    match row.and_then(|row| row.get(key)) {
        None | Some(DbValue::Null) => Ok(None),
        Some(value) => {
            let id = value.as_i64().ok_or(SessionStoreError)?;
            Ok(u64::try_from(id).ok().filter(|id| *id > 0))
        }
    }
}
pub(crate) async fn store<E: SessionExecutor>(
    repository: &OracleSessions<E>,
    input: &PostNoticeInput,
) -> Result<Option<StoredNotification>, SessionStoreError> {
    repository
        .store_notification(NotificationInput {
            user_id: input.recipient,
            actor_id: Some(input.actor),
            kind: input.kind,
            title: &input.title,
            message: &input.message,
            resource_type: Some("post"),
            resource_id: Some(input.post_id),
            priority: "normal",
            metadata_json: Some(&input.metadata_json),
        })
        .await
}

pub(crate) async fn notify_created(
    state: &NativeState,
    actor: u64,
    post: u64,
    input: &PostCreateInput,
) -> Result<(), ApiError> {
    let actor_name = state
        .repository
        .post_create_actor_name(actor)
        .await
        .map_err(store_error)?;
    let action = match input.post_type() {
        "reply" => input.reply_to_post_id.map(|source| {
            (
                source,
                "comment",
                "回复了你的推文",
                "你的推文收到了一条新回复。",
                "reply_excerpt",
                "post_reply",
            )
        }),
        "repost" => input.repost_of_post_id.map(|source| {
            (
                source,
                "retweet",
                "转发了你的推文",
                "你的推文被转发了。",
                "retweet_excerpt",
                "post_repost",
            )
        }),
        "quote" => input.quoted_post_id.map(|source| {
            (
                source,
                "retweet",
                "引用了你的推文",
                "你的推文被引用了。",
                "quote_excerpt",
                "post_quote",
            )
        }),
        _ => None,
    };
    if let Some((source, kind, title, message, excerpt_key, event)) = action {
        if let Some(recipient) = state
            .repository
            .post_create_source_author(source)
            .await
            .map_err(store_error)?
        {
            let post_excerpt = state
                .repository
                .post_create_excerpt(source)
                .await
                .map_err(store_error)?;
            let action_excerpt = crate::posts::like::excerpt_json(Some(&input.content));
            // Keep excerpts as JSON fragments so a UTF-16 slice ending in a lone
            // surrogate is preserved through storage and notification serialization.
            let metadata_json = format!("{{\"source_post_id\":{source},\"target_post_id\":{source},\"action_post_id\":{post},\"post_excerpt\":{post_excerpt},\"{excerpt_key}\":{action_excerpt},\"event\":\"{event}\"}}");
            deliver(
                state,
                &PostNoticeInput {
                    recipient,
                    actor,
                    post_id: post,
                    kind,
                    title: format!("{actor_name} {title}"),
                    message: message.into(),
                    metadata_json,
                },
            )
            .await?;
        }
    }
    let mut seen = HashSet::new();
    for &user in &input.mention_user_ids {
        // SameValueZero treats positive and negative zero as the same value.
        let key = if user == 0.0 { 0 } else { user.to_bits() };
        if !seen.insert(key) {
            continue;
        }
        // Metadata is built before checking eligibility, even for skipped users.
        // This intentionally traverses all original mentions, beyond the 50 links.
        let post_excerpt = state
            .repository
            .post_create_excerpt(post)
            .await
            .map_err(store_error)?;
        if user <= 0.0 || user == actor as f64 {
            continue;
        }
        let Some(recipient) = state
            .repository
            .resolve_post_mention_recipient(user)
            .await
            .map_err(store_error)?
        else {
            continue;
        };
        let metadata_json = format!("{{\"target_post_id\":{post},\"post_excerpt\":{post_excerpt},\"event\":\"post_mention\"}}");
        deliver(
            state,
            &PostNoticeInput {
                recipient,
                actor,
                post_id: post,
                kind: "mention",
                title: format!("{actor_name} 提及了你"),
                message: "你在一条推文中被提及。".into(),
                metadata_json,
            },
        )
        .await?;
    }
    Ok(())
}

fn store_error(_: SessionStoreError) -> ApiError {
    ApiError::server_error("服务器内部错误")
}

async fn deliver(state: &NativeState, input: &PostNoticeInput) -> Result<(), ApiError> {
    let Some(stored) = state
        .repository
        .store_post_create_notification(input)
        .await
        .map_err(store_error)?
    else {
        return Ok(());
    };
    let Some(mut notification) = state
        .repository
        .read_notification(input.recipient, stored.id)
        .await
        .map_err(store_error)?
    else {
        return Ok(());
    };
    crate::notifications::hydrate_notification(state, input.recipient, &mut notification).await?;
    if stored.push_enabled {
        let data = Map::from_iter([
            ("notification".into(), notification),
            ("notification_type".into(), input.kind.into()),
        ]);
        let sent = match &state.notification_publisher {
            Some(publisher) => publisher
                .publish(input.recipient, "notification_created", &data)
                .await
                .is_ok(),
            None => false,
        };
        if !sent {
            eprintln!("notification delivery unavailable");
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        auth::{
            otp::SmtpConfig,
            sessions::{CorsPolicy, RefreshPolicy, SessionRepository, StoreFuture},
            storage_urls::StorageUrlPolicy,
            TokenClaims, TokenCodec,
        },
        notification_events::{EventError, NotificationPublisher, PublishFuture},
    };
    use serde_json::{json, Map, Value};
    use std::sync::{Arc, Mutex};

    struct Repository {
        calls: Mutex<Vec<String>>,
        notices: Mutex<Vec<PostNoticeInput>>,
        fail: String,
        author: Option<u64>,
        push: bool,
        skip_store: bool,
        missing: bool,
        excerpt: String,
    }
    impl Default for Repository {
        fn default() -> Self {
            Self {
                calls: Mutex::new(vec![]),
                notices: Mutex::new(vec![]),
                fail: String::new(),
                author: Some(7),
                push: true,
                skip_store: false,
                missing: false,
                excerpt: "\"source text\"".into(),
            }
        }
    }
    impl Repository {
        fn record(&self, call: String) -> Result<(), SessionStoreError> {
            self.calls.lock().unwrap().push(call.clone());
            if self.fail == call {
                Err(SessionStoreError)
            } else {
                Ok(())
            }
        }
    }
    impl SessionRepository for Repository {
        fn touch<'a>(&'a self, _: &'a TokenClaims) -> StoreFuture<'a, u64> {
            Box::pin(async { Ok(1) })
        }
        fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
            Box::pin(async { Ok(0) })
        }
        fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
            Box::pin(async { Ok(0) })
        }
        fn post_create_actor_name(&self, actor: u64) -> StoreFuture<'_, String> {
            Box::pin(async move {
                self.record(format!("actor:{actor}"))?;
                Ok("viewer".into())
            })
        }
        fn post_create_source_author(&self, post: u64) -> StoreFuture<'_, Option<u64>> {
            Box::pin(async move {
                self.record(format!("author:{post}"))?;
                Ok(self.author)
            })
        }
        fn post_create_excerpt(&self, post: u64) -> StoreFuture<'_, String> {
            Box::pin(async move {
                self.record(format!("excerpt:{post}"))?;
                Ok(self.excerpt.clone())
            })
        }
        fn resolve_post_mention_recipient(&self, user: f64) -> StoreFuture<'_, Option<u64>> {
            Box::pin(async move {
                self.record(format!("resolve:{user}"))?;
                Ok((user >= 1.0 && user.fract() == 0.0).then_some(user as u64))
            })
        }
        fn store_post_create_notification<'a>(
            &'a self,
            input: &'a PostNoticeInput,
        ) -> StoreFuture<'a, Option<StoredNotification>> {
            Box::pin(async move {
                self.record(format!("store:{}:{}", input.recipient, input.kind))?;
                if self.skip_store || input.recipient == input.actor {
                    return Ok(None);
                }
                let mut notices = self.notices.lock().unwrap();
                notices.push(input.clone());
                Ok(Some(StoredNotification {
                    id: notices.len() as u64,
                    push_enabled: self.push,
                }))
            })
        }
        fn read_notification<'a>(&'a self, user: u64, id: u64) -> StoreFuture<'a, Option<Value>> {
            Box::pin(async move {
                self.record(format!("lookup:{user}:{id}"))?;
                Ok((!self.missing).then(|| json!({"notification_id":id,"actor_id":42})))
            })
        }
        fn public_profile<'a>(&'a self, viewer: u64, user: u64) -> StoreFuture<'a, Option<Value>> {
            Box::pin(async move {
                self.record(format!("profile:{viewer}:{user}"))?;
                Ok(Some(json!({"user_id":user,"avatar_url":""})))
            })
        }
    }
    #[derive(Default)]
    struct Publisher {
        calls: Mutex<Vec<(u64, String)>>,
        fail: bool,
    }
    impl NotificationPublisher for Publisher {
        fn publish<'a>(
            &'a self,
            user: u64,
            kind: &'a str,
            data: &'a Map<String, Value>,
        ) -> PublishFuture<'a> {
            Box::pin(async move {
                assert_eq!(kind, "notification_created");
                assert_eq!(data["notification"]["actor"]["user_id"], 42);
                assert!(data["notification"].get("actor_id").is_none());
                self.calls
                    .lock()
                    .unwrap()
                    .push((user, data["notification_type"].as_str().unwrap().into()));
                if self.fail {
                    Err(EventError)
                } else {
                    Ok(())
                }
            })
        }
    }
    fn state(repository: Arc<Repository>, publisher: Option<Arc<Publisher>>) -> NativeState {
        let fixture: Value =
            serde_json::from_str(include_str!("../../contracts/scenarios/auth-tokens.json"))
                .unwrap();
        NativeState {
            codec: Arc::new(
                TokenCodec::new(
                    fixture["keys"]["access"].as_str().unwrap().as_bytes(),
                    fixture["keys"]["refresh"].as_str().unwrap().as_bytes(),
                )
                .unwrap(),
            ),
            repository,
            clock: Arc::new(|| 1_700_000_000),
            refresh_policy: RefreshPolicy::default(),
            storage_urls: StorageUrlPolicy::default(),
            otp_mailer: Arc::new(SmtpConfig::default()),
            cors: CorsPolicy::default(),
            notification_source: None,
            notification_publisher: publisher.map(|p| p as Arc<dyn NotificationPublisher>),
        }
    }
    fn input() -> PostCreateInput {
        PostCreateInput {
            content: " action\n text ".into(),
            visibility: "public".into(),
            media_ids: vec![],
            tag_names: vec![],
            mention_user_ids: vec![],
            reply_to_post_id: None,
            repost_of_post_id: None,
            quoted_post_id: None,
            location: String::new(),
        }
    }

    #[tokio::test]
    async fn action_types_metadata_and_publication_match_reference() {
        for (action, kind, title, message, field) in [
            (
                "reply",
                "comment",
                "viewer 回复了你的推文",
                "你的推文收到了一条新回复。",
                "reply_excerpt",
            ),
            (
                "repost",
                "retweet",
                "viewer 转发了你的推文",
                "你的推文被转发了。",
                "retweet_excerpt",
            ),
            (
                "quote",
                "retweet",
                "viewer 引用了你的推文",
                "你的推文被引用了。",
                "quote_excerpt",
            ),
        ] {
            let repo = Arc::new(Repository::default());
            let publisher = Arc::new(Publisher::default());
            let mut input = input();
            match action {
                "reply" => input.reply_to_post_id = Some(10),
                "repost" => input.repost_of_post_id = Some(10),
                _ => input.quoted_post_id = Some(10),
            }
            notify_created(
                &state(repo.clone(), Some(publisher.clone())),
                42,
                100,
                &input,
            )
            .await
            .unwrap();
            let notices = repo.notices.lock().unwrap();
            assert_eq!(notices.len(), 1);
            let notice = &notices[0];
            assert_eq!(
                (notice.recipient, notice.actor, notice.post_id, notice.kind),
                (7, 42, 100, kind)
            );
            assert_eq!((&*notice.title, &*notice.message), (title, message));
            assert_eq!(
                serde_json::from_str::<Value>(&notice.metadata_json).unwrap(),
                json!({"source_post_id":10,"target_post_id":10,"action_post_id":100,"post_excerpt":"source text",field:"action text","event":format!("post_{action}")})
            );
            assert_eq!(*publisher.calls.lock().unwrap(), vec![(7, kind.into())]);
            assert_eq!(
                *repo.calls.lock().unwrap(),
                [
                    "actor:42",
                    "author:10",
                    "excerpt:10",
                    &format!("store:7:{kind}"),
                    "lookup:7:1",
                    "profile:7:42"
                ]
            );
        }
    }

    #[tokio::test]
    async fn normal_posts_still_read_actor_and_missing_sources_skip_excerpt() {
        for has_source in [false, true] {
            let repo = Arc::new(Repository {
                author: None,
                ..Repository::default()
            });
            let mut input = input();
            input.reply_to_post_id = has_source.then_some(10);
            notify_created(&state(repo.clone(), None), 42, 100, &input)
                .await
                .unwrap();
            assert_eq!(
                *repo.calls.lock().unwrap(),
                if has_source {
                    vec!["actor:42", "author:10"]
                } else {
                    vec!["actor:42"]
                }
            );
        }
        let repo = Arc::new(Repository {
            fail: "actor:42".into(),
            ..Repository::default()
        });
        assert!(notify_created(&state(repo, None), 42, 100, &input())
            .await
            .is_err());
    }

    #[tokio::test]
    async fn mention_numbers_deduplicate_without_truncation_and_read_excerpt_before_filtering() {
        let repo = Arc::new(Repository::default());
        let publisher = Arc::new(Publisher::default());
        let mut input = input();
        input.mention_user_ids = vec![7.5, 7.0, 7.5, -1.0, 0.0, -0.0, 42.0];
        notify_created(
            &state(repo.clone(), Some(publisher.clone())),
            42,
            100,
            &input,
        )
        .await
        .unwrap();
        let notices = repo.notices.lock().unwrap();
        assert_eq!(notices.len(), 1);
        assert_eq!((notices[0].recipient, notices[0].kind), (7, "mention"));
        assert_eq!(notices[0].title, "viewer 提及了你");
        assert_eq!(notices[0].message, "你在一条推文中被提及。");
        assert_eq!(
            serde_json::from_str::<Value>(&notices[0].metadata_json).unwrap(),
            json!({"target_post_id":100,"post_excerpt":"source text","event":"post_mention"})
        );
        assert_eq!(
            *repo.calls.lock().unwrap(),
            [
                "actor:42",
                "excerpt:100",
                "resolve:7.5",
                "excerpt:100",
                "resolve:7",
                "store:7:mention",
                "lookup:7:1",
                "profile:7:42",
                "excerpt:100",
                "excerpt:100",
                "excerpt:100"
            ]
        );
        assert_eq!(
            *publisher.calls.lock().unwrap(),
            vec![(7, "mention".into())]
        );
    }

    #[tokio::test]
    async fn mentions_beyond_fifty_are_not_truncated() {
        let repo = Arc::new(Repository::default());
        let mut input = input();
        input.mention_user_ids = (1000..1060)
            .flat_map(|id| [f64::from(id), f64::from(id)])
            .collect();
        notify_created(&state(repo.clone(), None), 42, 100, &input)
            .await
            .unwrap();
        let notices = repo.notices.lock().unwrap();
        assert_eq!(
            notices.iter().map(|n| n.recipient).collect::<Vec<_>>(),
            (1000..1060).collect::<Vec<_>>()
        );
    }

    #[tokio::test]
    async fn excerpt_failures_precede_skipped_mention_eligibility() {
        for user in [0.0, -1.0, -7.5, 42.0] {
            let repo = Arc::new(Repository {
                fail: "excerpt:100".into(),
                ..Repository::default()
            });
            let mut input = input();
            input.mention_user_ids = vec![user, 7.0];
            assert!(notify_created(&state(repo.clone(), None), 42, 100, &input)
                .await
                .is_err());
            assert_eq!(*repo.calls.lock().unwrap(), ["actor:42", "excerpt:100"]);
        }
    }

    #[tokio::test]
    async fn database_failures_preserve_earlier_stored_and_published_notifications() {
        for (failure, stored, published) in [
            ("author:10", 0, 0),
            ("excerpt:10", 0, 0),
            ("store:7:comment", 0, 0),
            ("lookup:7:1", 1, 0),
            ("profile:7:42", 1, 0),
            ("excerpt:100", 1, 1),
            ("resolve:8", 1, 1),
            ("store:8:mention", 1, 1),
            ("lookup:8:2", 2, 1),
        ] {
            let repo = Arc::new(Repository {
                fail: failure.into(),
                ..Repository::default()
            });
            let publisher = Arc::new(Publisher::default());
            let mut input = input();
            input.reply_to_post_id = Some(10);
            input.mention_user_ids = vec![8.0, 9.0];
            assert!(
                notify_created(
                    &state(repo.clone(), Some(publisher.clone())),
                    42,
                    100,
                    &input
                )
                .await
                .is_err(),
                "{failure}"
            );
            assert_eq!(repo.notices.lock().unwrap().len(), stored, "{failure}");
            assert_eq!(
                publisher.calls.lock().unwrap().len(),
                published,
                "{failure}"
            );
            assert_eq!(repo.calls.lock().unwrap().last().unwrap(), failure);
        }
    }

    #[tokio::test]
    async fn publication_failures_and_preferences_do_not_fail_creation() {
        for mode in [
            "redis failure",
            "no publisher",
            "push disabled",
            "storage skipped",
            "notification missing",
        ] {
            let repo = Arc::new(Repository {
                push: mode != "push disabled",
                skip_store: mode == "storage skipped",
                missing: mode == "notification missing",
                ..Repository::default()
            });
            let publisher = Arc::new(Publisher {
                fail: mode == "redis failure",
                ..Publisher::default()
            });
            let mut input = input();
            input.repost_of_post_id = Some(10);
            input.mention_user_ids = vec![8.0];
            notify_created(
                &state(
                    repo.clone(),
                    (mode != "no publisher").then_some(publisher.clone()),
                ),
                42,
                100,
                &input,
            )
            .await
            .unwrap();
            assert_eq!(
                repo.notices.lock().unwrap().len(),
                if mode == "storage skipped" { 0 } else { 2 },
                "{mode}"
            );
            assert_eq!(
                publisher.calls.lock().unwrap().len(),
                if mode == "redis failure" { 2 } else { 0 },
                "{mode}"
            );
        }
    }

    #[tokio::test]
    async fn metadata_preserves_utf16_split_surrogates_and_empty_content_distinctions() {
        for (content, expected) in [
            (String::new(), "null".into()),
            (" \n \t ".into(), "\"\"".into()),
            (
                format!("{}😀", "x".repeat(159)),
                format!("\"{}\\ud83d...\"", "x".repeat(159)),
            ),
        ] {
            let repo = Arc::new(Repository {
                excerpt: "\"\\ud83d...\"".into(),
                ..Repository::default()
            });
            let mut input = input();
            input.content = content;
            input.quoted_post_id = Some(10);
            notify_created(&state(repo.clone(), None), 42, 100, &input)
                .await
                .unwrap();
            let notices = repo.notices.lock().unwrap();
            let metadata = &notices[0].metadata_json;
            assert!(
                metadata.contains(&format!("\"quote_excerpt\":{expected}")),
                "{metadata}"
            );
            assert!(metadata.contains("\"post_excerpt\":\"\\ud83d...\""));
            assert!(serde_json::value::RawValue::from_string(metadata.clone()).is_ok());
        }
    }
}
