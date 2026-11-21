use axum::{body::Body, http::Request};
use http_body_util::BodyExt;
use nekotribe_backend::{
    auth::{
        session_list::SessionPage,
        sessions::{build_native_router, CorsPolicy, SessionRepository, StoreFuture},
        IssuedToken, TokenClaims, TokenCodec, TokenKind,
    },
    direct_history::DirectHistory,
};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

#[tokio::test]
async fn direct_send_only_publishes_a_committed_result() {
    use nekotribe_backend::{
        auth::{
            otp::SmtpConfig,
            sessions::{
                build_native_router_with_realtime_and_publisher, RefreshPolicy, SessionStoreError,
            },
            storage_urls::StorageUrlPolicy,
        },
        direct_send::DirectSend,
        notification_events::{EventError, NotificationPublisher, PublishFuture},
    };
    use std::sync::atomic::{AtomicBool, Ordering};

    struct SendRepository {
        allowed: bool,
        committed: Arc<AtomicBool>,
    }
    impl SessionRepository for SendRepository {
        fn touch<'a>(&'a self, _: &'a TokenClaims) -> StoreFuture<'a, u64> {
            Box::pin(async { Ok(1) })
        }
        fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
            Box::pin(async { Ok(0) })
        }
        fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
            Box::pin(async { Ok(0) })
        }
        fn send_direct_message<'a>(
            &'a self,
            user: u64,
            id: u64,
            content: &'a str,
            _: &'a StorageUrlPolicy,
        ) -> StoreFuture<'a, DirectSend> {
            Box::pin(async move {
                assert_eq!((user, id, content), (42, 7, "hello"));
                if !self.allowed {
                    return Err(SessionStoreError);
                }
                self.committed.store(true, Ordering::SeqCst);
                Ok(DirectSend::Created {
                    recipient: 9,
                    message: json!({"message_id":12,"conversation_id":7}),
                    push_notice: None,
                })
            })
        }
    }
    struct Publisher {
        committed: Arc<AtomicBool>,
        called: AtomicBool,
    }
    impl NotificationPublisher for Publisher {
        fn publish<'a>(
            &'a self,
            _: u64,
            _: &'a str,
            _: &'a serde_json::Map<String, Value>,
        ) -> PublishFuture<'a> {
            Box::pin(async { panic!("no inbox notification expected") })
        }
        fn publish_direct<'a>(
            &'a self,
            sender: u64,
            recipient: u64,
            message: &'a Value,
        ) -> PublishFuture<'a> {
            Box::pin(async move {
                assert!(self.committed.load(Ordering::SeqCst));
                assert_eq!((sender, recipient), (42, 9));
                assert_eq!(message["message_id"], 12);
                self.called.store(true, Ordering::SeqCst);
                Err(EventError)
            })
        }
    }
    for (allowed, status) in [(false, 500), (true, 200)] {
        let codec = TokenCodec::new(b"fixture-access-key", b"fixture-refresh-key").unwrap();
        let token = codec
            .sign(&IssuedToken {
                user_id: 42,
                user_name: "fixture".into(),
                session_id: "fixture-session".into(),
                kind: TokenKind::Access,
                issued_at: 100,
                expires_at: 300,
                jti: "fixture-jti".into(),
            })
            .unwrap();
        let committed = Arc::new(AtomicBool::new(false));
        let publisher = Arc::new(Publisher {
            committed: committed.clone(),
            called: AtomicBool::new(false),
        });
        let app = build_native_router_with_realtime_and_publisher(
            codec,
            Arc::new(SendRepository { allowed, committed }),
            CorsPolicy::default(),
            Arc::new(|| 150),
            RefreshPolicy::default(),
            StorageUrlPolicy::default(),
            Arc::new(SmtpConfig::default()),
            None,
            Some(publisher.clone()),
        );
        let response = app
            .oneshot(
                Request::post("/api/v2/chat/direct-conversations/7/messages")
                    .header("authorization", format!("Bearer {token}"))
                    .header("content-type", "application/json")
                    .body(Body::from(r#"{"content":" hello "}"#))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), status);
        assert_eq!(publisher.called.load(Ordering::SeqCst), allowed);
    }
}

#[derive(Default)]
struct Repository {
    page: Mutex<Option<SessionPage>>,
    expected_ids: Vec<u64>,
    allowed: bool,
    muted: bool,
}

impl SessionRepository for Repository {
    fn send_direct_message<'a>(
        &'a self,
        _: u64,
        _: u64,
        _: &'a str,
        _: &'a nekotribe_backend::auth::storage_urls::StorageUrlPolicy,
    ) -> StoreFuture<'a, nekotribe_backend::direct_send::DirectSend> {
        Box::pin(async move {
            assert!(self.muted);
            Ok(nekotribe_backend::direct_send::DirectSend::PublishForbidden)
        })
    }

    fn change_group_membership(
        &self,
        user: u64,
        group: u64,
        change: nekotribe_backend::group_membership::Change,
    ) -> StoreFuture<'_, nekotribe_backend::group_membership::Outcome> {
        use nekotribe_backend::group_membership::{Change, Outcome};
        Box::pin(async move {
            assert_eq!((user, group), (42, 7));
            Ok(match change {
                Change::Join(code) => {
                    assert_eq!(code, "AB12");
                    Outcome::Joined(
                        json!({"member_id":8,"group_id":7,"user_id":42,"role":"member","status":"active"}),
                    )
                }
                Change::Leave => Outcome::Banned,
            })
        })
    }
    fn list_groups<'a>(
        &'a self,
        viewer: u64,
        request: nekotribe_backend::group_list::Request,
        _: &'a nekotribe_backend::auth::storage_urls::StorageUrlPolicy,
    ) -> StoreFuture<'a, nekotribe_backend::group_list::Outcome> {
        use nekotribe_backend::group_list::{Mode, Outcome};
        Box::pin(async move {
            assert_eq!(viewer, 42);
            Ok(match request.mode {
                Mode::Discover => {
                    assert_eq!(
                        (
                            request.search.as_str(),
                            request.privacy.as_str(),
                            request.category.as_str(),
                            request.page.start
                        ),
                        ("neko", "public", "tech", 3.0)
                    );
                    Outcome::Found(vec![json!({"group_id":7})], 9)
                }
                Mode::Popular => {
                    assert_eq!(request.limit, 50.0);
                    Outcome::Found(vec![json!({"group_id":7,"activity_score":4.2})], 0)
                }
                Mode::Mine => Outcome::Found(vec![], 0),
            })
        })
    }
    fn group_detail<'a>(
        &'a self,
        viewer: u64,
        key: nekotribe_backend::group_detail::GroupLookup,
        _: &'a nekotribe_backend::auth::storage_urls::StorageUrlPolicy,
    ) -> StoreFuture<'a, nekotribe_backend::group_detail::GroupDetail> {
        use nekotribe_backend::group_detail::{GroupDetail, GroupLookup};
        Box::pin(async move {
            assert_eq!(viewer, 42);
            let found = match key {
                GroupLookup::Id(id) => id == 7,
                GroupLookup::Slug(slug) => slug == "neko",
            };
            Ok(if found {
                GroupDetail::Found(json!({"group_id":7,"slug":"neko","tags":["chat"]}))
            } else {
                GroupDetail::Missing
            })
        })
    }
    fn respond_group_invite(
        &self,
        viewer:u64,
        invite:u64,
        accept:bool,
    ) -> StoreFuture<'_,nekotribe_backend::group_invite_response::Outcome> {
        use nekotribe_backend::group_invite_response::Outcome;
        Box::pin(async move {
            assert_eq!(viewer,42);
            Ok(match invite {
                7=>Outcome::Responded(json!({"invite_id":7,"group_id":9,"status":if accept {"accepted"}else{"rejected"}})),
                8=>Outcome::Missing,
                _=>Outcome::Invalid,
            })
        })
    }
    fn create_group_invite(
        &self,
        viewer:u64,
        group:u64,
        input:nekotribe_backend::group_invite_create::Input,
    ) -> StoreFuture<'_,nekotribe_backend::group_invite_create::Outcome> {
        use nekotribe_backend::group_invite_create::Outcome;
        Box::pin(async move {
            assert_eq!((viewer,group),(42,7));
            assert_eq!((input.max_uses,input.hours),(1,168));
            Ok(match input.target {
                Some(42)=>Outcome::SelfInvite,
                Some(8)=>Outcome::TargetMissing,
                _=>Outcome::Created{data:json!({"invite_id":12}),push:None}
            })
        })
    }
    fn read_group_invites<'a>(
        &'a self,
        viewer: u64,
        request: nekotribe_backend::group_invite_reads::Request,
        _: &'a nekotribe_backend::auth::storage_urls::StorageUrlPolicy,
    ) -> StoreFuture<'a, nekotribe_backend::group_invite_reads::Outcome> {
        use nekotribe_backend::group_invite_reads::{Outcome, Request};
        Box::pin(async move {
            assert_eq!(viewer,42);
            Ok(match request {
                Request::List(7, page, status) if page.page == 2.0 && status == "pending" => Outcome::List(vec![],1),
                Request::List(_,_,_) => Outcome::Forbidden,
                Request::Inbox(_, 12) => Outcome::List(vec![json!({"invite_id":12})], 1),
                Request::Inbox(page, _) => Outcome::List(vec![], if page.page==2.0 {1} else {0}),
                Request::Preview(code) if code == "ABC" => Outcome::Preview(json!({"is_valid":true})),
                Request::Preview(_) => Outcome::CodeInvalid,
            })
        })
    }
    fn patch_group_settings<'a>(
        &'a self,
        viewer: u64,
        group: u64,
        _: nekotribe_backend::group_settings::Patch,
        _: &'a nekotribe_backend::auth::storage_urls::StorageUrlPolicy,
    ) -> StoreFuture<'a, nekotribe_backend::group_settings::Outcome> {
        use nekotribe_backend::{group_detail::GroupDetail, group_settings::Outcome};
        Box::pin(async move {
            assert_eq!(viewer, 42);
            Ok(if group == 7 {
                Outcome::Detail(GroupDetail::Found(json!({"group_id":7,"name":"Cat","tags":[]})))
            } else { Outcome::Forbidden })
        })
    }
    fn group_administration<'a>(
        &'a self,
        viewer: u64,
        group: u64,
        operation: nekotribe_backend::group_admin::Operation,
        _: &'a nekotribe_backend::auth::storage_urls::StorageUrlPolicy,
    ) -> StoreFuture<'a, nekotribe_backend::group_admin::Outcome> {
        use nekotribe_backend::group_admin::{Operation, Outcome};
        Box::pin(async move {
            assert_eq!(viewer, 42);
            if group != 7 {
                return Ok(Outcome::MissingGroup);
            }
            Ok(match operation {
                Operation::ReadPreference => Outcome::Preference(json!({"is_enabled":true})),
                Operation::WritePreference(value) => Outcome::Preference(json!({"is_enabled":value})),
                Operation::Audit(page) => {
                    let logs = if page.start == 1.0 {
                        vec![json!({"log_id":2,"actor_id":20,"actor":null})]
                    } else {
                        vec![]
                    };
                    Outcome::Audit(logs, 2)
                }
            })
        })
    }
    fn write_group_comment<'a>(
        &'a self,
        actor: u64,
        input: nekotribe_backend::group_comment_write::Request,
        _: &'a nekotribe_backend::auth::storage_urls::StorageUrlPolicy,
    ) -> StoreFuture<'a, nekotribe_backend::group_comment_write::Outcome> {
        use nekotribe_backend::group_comment_write::{Action, Outcome};
        Box::pin(async move {
            assert_eq!(actor, 42);
            if self.muted { return Ok(Outcome::PublishForbidden); }
            if input.group != 7 || input.post != 5 {
                return Ok(Outcome::MissingPost);
            }
            if input.comment != 0 && input.comment != 6 {
                return Ok(Outcome::MissingComment);
            }
            Ok(Outcome::Saved(match input.action {
                Action::Create { content, parent, reply } => {
                    assert_eq!(parent, Some(4));
                    assert_eq!(reply, None);
                    json!({"comment_id":6,"post_id":5,"content":content,"parent_comment_id":4})
                }
                Action::Delete => Value::Null,
                Action::Like(liked) => json!({"comment_id":6,"is_liked":liked,"likes_count":3}),
            }))
        })
    }
    fn write_group_post<'a>(
        &'a self,
        actor: u64,
        input: nekotribe_backend::group_post_write::Request,
        _: &'a nekotribe_backend::auth::storage_urls::StorageUrlPolicy,
    ) -> StoreFuture<'a, nekotribe_backend::group_post_write::Outcome> {
        use nekotribe_backend::group_post_write::{Action, Outcome};
        Box::pin(async move {
            assert_eq!(actor, 42);
            if self.muted { return Ok(Outcome::PublishForbidden); }
            if input.group != 7 {
                return Ok(Outcome::MissingGroup);
            }
            if input.post != 0 && input.post != 5 {
                return Ok(Outcome::MissingPost);
            }
            Ok(Outcome::Saved(match input.action {
                Action::Create { content, media, announcement } => {
                    assert_eq!(media, "/storage/a.png");
                    json!({"group_id":7,"post_id":5,"content":content,"is_announcement":announcement})
                }
                Action::Pin(pin) => json!({"post_id":5,"is_pinned":pin}),
                Action::Delete { .. } => Value::Null,
                Action::Like(liked) => json!({"post_id":5,"is_liked":liked,"likes_count":3}),
            }))
        })
    }
    fn read_group_content<'a>(
        &'a self,
        viewer: u64,
        request: nekotribe_backend::group_content::Request,
        _: &'a nekotribe_backend::auth::storage_urls::StorageUrlPolicy,
    ) -> StoreFuture<'a, nekotribe_backend::group_content::Outcome> {
        use nekotribe_backend::group_content::Outcome;
        Box::pin(async move {
            assert_eq!(viewer, 42);
            Ok(match (request.group, request.post, request.comments) {
                (7, 0, false) | (7, 5, true) => Outcome::Found(json!([]), 12),
                (7, 5, false) => {
                    assert_eq!((request.page.start, request.page.end), (1.0, 1.0));
                    Outcome::Found(json!({"post_id":5,"group_id":7}), 1)
                }
                (7, _, _) => Outcome::MissingPost,
                _ => Outcome::MissingGroup,
            })
        })
    }
    fn create_group<'a>(
        &'a self,
        actor: u64,
        _: nekotribe_backend::group_settings::Patch,
        _: &'a nekotribe_backend::auth::storage_urls::StorageUrlPolicy,
    ) -> StoreFuture<'a, Option<Value>> {
        Box::pin(async move {
            assert_eq!(actor, 42);
            Ok(Some(json!({"group_id":7,"name":"Cat","tags":["Rust"]})))
        })
    }
    fn dissolve_group(
        &self,
        actor: u64,
        group: u64,
    ) -> StoreFuture<'_, nekotribe_backend::group_dissolution::Outcome> {
        use nekotribe_backend::group_dissolution::Outcome;
        Box::pin(async move {
            assert_eq!(actor, 42);
            Ok(match group {
                7 => Outcome::Dissolved,
                8 => Outcome::Forbidden,
                _ => Outcome::MissingGroup,
            })
        })
    }
    fn transfer_group_ownership(
        &self,
        actor: u64,
        group: u64,
        target: u64,
    ) -> StoreFuture<'_, nekotribe_backend::group_ownership::Outcome> {
        use nekotribe_backend::group_ownership::Outcome;
        Box::pin(async move {
            assert_eq!((actor, group), (42, 7));
            Ok(match target {
                9 => Outcome::Transferred,
                42 => Outcome::SelfTransfer,
                _ => Outcome::MissingMember,
            })
        })
    }
    fn manage_group_admission(
        &self,
        viewer: u64,
        group: u64,
        target: u64,
        action: nekotribe_backend::group_member_admission::Action,
    ) -> StoreFuture<'_, nekotribe_backend::group_member_admission::Outcome> {
        use nekotribe_backend::group_member_admission::{Action, Outcome};
        Box::pin(async move {
            assert_eq!((viewer, group), (42, 7));
            Ok(match (action, target) {
                (Action::Approve | Action::Reject, 12) | (Action::Remove, 9) => Outcome::Changed,
                (Action::Remove, 10) => Outcome::Forbidden,
                (Action::Role(value), 9) if value == "moderator" => Outcome::Changed,
                (Action::Mute { hours: 24, reason: None }, 9) => Outcome::Muted("2026-11-17T12:00:00.000Z".into()),
                (Action::Unmute, 9) => Outcome::Unchanged,
                (Action::Unmute, 10) => Outcome::Forbidden,
                _ => Outcome::MemberMissing,
            })
        })
    }
    fn list_group_members<'a>(
        &'a self,
        viewer: u64,
        group: u64,
        request: nekotribe_backend::group_member_list::Request,
        _: &'a nekotribe_backend::auth::storage_urls::StorageUrlPolicy,
    ) -> StoreFuture<'a, nekotribe_backend::group_member_list::Outcome> {
        use nekotribe_backend::group_member_list::Outcome;
        Box::pin(async move {
            assert_eq!(viewer, 42);
            Ok(match group {
                7 => {
                    assert_eq!(request.role, "member");
                    assert_eq!(request.status, "pending");
                    assert_eq!(request.page.start, 3.0);
                    Outcome::Found(vec![json!({"member_id":12,"status":"pending"})], 6)
                }
                8 => Outcome::Found(vec![], 3),
                9 => Outcome::Forbidden,
                _ => Outcome::Missing,
            })
        })
    }
    fn list_chat_members<'a>(
        &'a self,
        user: u64,
        group: u64,
        _: &'a nekotribe_backend::auth::storage_urls::StorageUrlPolicy,
    ) -> StoreFuture<'a, Option<Vec<Value>>> {
        Box::pin(async move {
            assert_eq!(user, 42);
            Ok((group == 7)
                .then(|| vec![json!({"user_id":9,"online_status":"hidden","last_seen_at":null})]))
        })
    }
    fn mutate_chat_message<'a>(
        &'a self,
        user: u64,
        id: u64,
        change: nekotribe_backend::chat_message_mutation::Change,
        _: &'a nekotribe_backend::auth::storage_urls::StorageUrlPolicy,
    ) -> StoreFuture<'a, nekotribe_backend::chat_message_mutation::Outcome> {
        use nekotribe_backend::chat_message_mutation::{Change, Outcome};
        Box::pin(async move {
            assert_eq!(user, 42);
            if self.muted { return Ok(Outcome::PublishForbidden); }
            Ok(match id {
                8 => Outcome::Changed {
                    channel: 7,
                    message: match change {
                        Change::Edit(content) => json!({"message_id":8,"content":content}),
                        Change::Pin(pinned) => json!({"message_id":8,"is_pinned":pinned}),
                        Change::Delete => Value::Null,
                        Change::Reaction { emoji, add } => {
                            json!({"message_id":8,"reactions":[{"emoji":emoji,"count":7,"reacted_by_me":add}]})
                        }
                    },
                },
                9 => Outcome::Forbidden,
                _ => Outcome::Missing,
            })
        })
    }
    fn send_chat_message<'a>(
        &'a self,
        user: u64,
        channel: u64,
        input: nekotribe_backend::chat_message_send::Input,
        _: &'a nekotribe_backend::auth::storage_urls::StorageUrlPolicy,
    ) -> StoreFuture<'a, nekotribe_backend::chat_message_send::Outcome> {
        use nekotribe_backend::chat_message_send::Outcome;
        Box::pin(async move {
            if self.muted { return Ok(Outcome::PublishForbidden); }
            assert_eq!(
                (
                    user,
                    input.content.as_str(),
                    input.reply,
                    input.media.as_slice()
                ),
                (42, "hello", Some(9), &[77][..])
            );
            Ok(if channel == 7 {
                Outcome::Created(json!({"message_id":8,"channel_id":7,"can_delete":true}))
            } else {
                Outcome::Forbidden
            })
        })
    }
    fn list_chat_messages<'a>(
        &'a self,
        user: u64,
        channel: u64,
        page: SessionPage,
        search: &'a str,
        _: &'a nekotribe_backend::auth::storage_urls::StorageUrlPolicy,
    ) -> StoreFuture<'a, nekotribe_backend::chat_message_history::History> {
        Box::pin(async move {
            assert_eq!(user, 42);
            if channel != 7 {
                return Ok(None);
            }
            assert_eq!((page.page, page.page_size, search), (2.0, 3.0, "hello"));
            Ok(Some((
                vec![json!({"message_id":8,"channel_id":7,"media":[],"reactions":[]})],
                10,
            )))
        })
    }
    fn set_chat_channel_status(
        &self,
        user: u64,
        channel: u64,
        operation: nekotribe_backend::chat_channel_status::Operation,
    ) -> StoreFuture<'_, nekotribe_backend::chat_channel_status::Outcome> {
        use nekotribe_backend::chat_channel_status::{Operation, Outcome};
        Box::pin(async move {
            assert_eq!(user, 42);
            if channel != 7 {
                return Ok(Outcome::Forbidden);
            }
            Ok(match operation {
                Operation::Read(Some(9)) => Outcome::InvalidMessage,
                Operation::Read(_) => Outcome::Updated(
                    json!({"channel_id":7,"last_read_message_id":12,"unread_count":2}),
                ),
                Operation::Mute(is_muted) => {
                    Outcome::Updated(json!({"channel_id":7,"is_muted":is_muted}))
                }
            })
        })
    }
    fn write_chat_channel(
        &self,
        user: u64,
        id: u64,
        change: nekotribe_backend::chat_channel_write::Change,
    ) -> StoreFuture<'_, Option<Value>> {
        use nekotribe_backend::chat_channel_write::Change;
        Box::pin(async move {
            assert_eq!(user, 42);
            if id != 7 {
                return Ok(None);
            }
            let value = match change {
                Change::Create {
                    name,
                    kind,
                    category,
                    private,
                } => {
                    assert_eq!(
                        (name.as_str(), kind.as_str(), category.as_str(), private),
                        ("技术交流", "text", "文字频道", false)
                    );
                    json!({"channel_id":8})
                }
                Change::Update {
                    name,
                    category,
                    private,
                } => {
                    assert_eq!((name, category, private), (None, None, Some(true)));
                    json!({"channel_id":7,"is_private":true})
                }
                Change::Delete => Value::Null,
            };
            Ok(Some(value))
        })
    }
    fn list_chat_groups(&self, user: u64, page: SessionPage) -> StoreFuture<'_, (Vec<Value>, u64)> {
        Box::pin(async move {
            assert_eq!(user, 42);
            assert_eq!((page.start, page.end), (3.0, 4.0));
            Ok((
                vec![json!({"group_id":7,"channel_count":0,"membership":{"status":"muted"}})],
                5,
            ))
        })
    }
    fn list_direct_conversations<'a>(
        &'a self,
        user: u64,
        _conversation_id: u64,
        page: SessionPage,
        _: &'a nekotribe_backend::auth::storage_urls::StorageUrlPolicy,
    ) -> StoreFuture<'a, (Vec<Value>, u64)> {
        Box::pin(async move {
            assert_eq!(user, 42);
            *self.page.lock().unwrap() = Some(page);
            Ok((vec![json!({"conversation_id":7,"unread_count":2})], 6))
        })
    }
    fn create_direct_conversation<'a>(
        &'a self,
        user: u64,
        target: u64,
        _: &'a nekotribe_backend::auth::storage_urls::StorageUrlPolicy,
    ) -> StoreFuture<'a, nekotribe_backend::direct_conversations::ConversationCreation> {
        use nekotribe_backend::{
            direct_conversations::ConversationCreation, direct_send::RecipientDenial,
        };
        Box::pin(async move {
            assert_eq!(user, 42);
            Ok(match target {
                9 => ConversationCreation::Ready(json!({"conversation_id":7})),
                8 => ConversationCreation::Deleted,
                _ => ConversationCreation::Denied(RecipientDenial::Blocked),
            })
        })
    }
    fn touch<'a>(&'a self, claims: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async move { Ok(u64::from(claims.user_id == 42)) })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn list_direct_history(
        &self,
        user: u64,
        conversation: u64,
        page: SessionPage,
    ) -> StoreFuture<'_, DirectHistory> {
        Box::pin(async move {
            assert_eq!((user, conversation), (42, 7));
            *self.page.lock().unwrap() = Some(page);
            if !self.allowed {
                return Ok(None);
            }
            let data = self
                .expected_ids
                .iter()
                .map(|id| json!({"message_id":id,"author":{"avatar_url":""}}))
                .collect();
            Ok(Some((data, 4)))
        })
    }
}

#[tokio::test]
async fn muted_account_has_the_shared_error_on_group_and_chat_writes() {
    let vectors: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/moderation-publish-policy.json"
    ))
    .unwrap();
    let codec = TokenCodec::new(b"fixture-access-key", b"fixture-refresh-key").unwrap();
    let token = codec
        .sign(&IssuedToken {
            user_id: 42,
            user_name: "fixture".into(),
            session_id: "fixture-session".into(),
            kind: TokenKind::Access,
            issued_at: 100,
            expires_at: 300,
            jti: "fixture-jti".into(),
        })
        .unwrap();
    let app = build_native_router(
        codec,
        Arc::new(Repository {
            muted: true,
            ..Repository::default()
        }),
        CorsPolicy::default(),
        Arc::new(|| 150),
    );
    let mut tested = 0;
    for case in vectors["cases"].as_array().unwrap() {
        let Some(path) = case["path"].as_str() else {
            continue;
        };
        if !(path.starts_with("/api/v2/chat/") || path.starts_with("/api/v2/groups/")) {
            continue;
        }
        let path = path
            .replace("{id}", "7")
            .replace("{conversation_id}", "7")
            .replace("{channel_id}", "7")
            .replace("{post_id}", "5")
            .replace("{message_id}", "8");
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(case["method"].as_str().unwrap())
                    .uri(&path)
                    .header("authorization", format!("Bearer {token}"))
                    .header("content-type", "application/json")
                    .body(Body::from(case["body"].to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(Some(u64::from(response.status().as_u16())), case["status"].as_u64(), "{path}");
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        let result: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(result["code"], 40301, "{path}");
        assert_eq!(result["message"], case["message"], "{path}");
        tested += 1;
    }
    assert_eq!(tested, 5);
}

#[tokio::test]
async fn native_chat_channel_write_and_status_routes() {
    let codec = TokenCodec::new(b"fixture-access-key", b"fixture-refresh-key").unwrap();
    let token = codec
        .sign(&IssuedToken {
            user_id: 42,
            user_name: "fixture".into(),
            session_id: "fixture-session".into(),
            kind: TokenKind::Access,
            issued_at: 100,
            expires_at: 300,
            jti: "fixture-jti".into(),
        })
        .unwrap();
    let app = build_native_router(
        codec,
        Arc::new(Repository {
            page: Mutex::new(None),
            expected_ids: vec![],
            allowed: true,
            muted: false,
        }),
        CorsPolicy::default(),
        Arc::new(|| 150),
    );
    for (method, path, body, status, message) in [
        (
            "POST",
            "/groups/7/channels",
            r#"{"name":" 技术交流 "}"#,
            200,
            "chat channel created",
        ),
        (
            "PATCH",
            "/channels/7",
            r#"{"is_private":true}"#,
            200,
            "chat channel updated",
        ),
        ("DELETE", "/channels/7", "", 200, "chat channel deleted"),
        ("DELETE", "/channels/9", "", 403, ""),
        ("POST", "/groups/7/channels", r#"{"name":"x"} {}"#, 400, ""),
        ("PATCH", "/channels/9007199254740992", "{}", 400, ""),
        (
            "GET",
            "/channels/7/messages?page=2&page_size=3&q=+Hello+",
            "",
            200,
            "success",
        ),
        ("GET", "/channels/9/messages", "", 403, ""),
        ("GET", "/groups/7/members", "", 200, "success"),
        ("GET", "/groups/9/members", "", 403, ""),
        (
            "PATCH",
            "/messages/8",
            r#"{"content":" edited "}"#,
            200,
            "chat message updated",
        ),
        ("DELETE", "/messages/8", "", 200, "chat message deleted"),
        ("DELETE", "/messages/10", "", 404, ""),
        (
            "POST",
            "/messages/8/reactions",
            r#"{"emoji":" 👍 "}"#,
            200,
            "chat reaction created",
        ),
        (
            "DELETE",
            "/messages/8/reactions",
            r#"{"emoji":"👍"}"#,
            200,
            "chat reaction deleted",
        ),
        (
            "POST",
            "/messages/9/reactions",
            r#"{"emoji":"👍"}"#,
            403,
            "",
        ),
        ("POST", "/messages/8/reactions", r#"{"emoji":5}"#, 400, ""),
        (
            "PUT",
            "/messages/8/pin-status",
            r#"{"is_pinned":true}"#,
            200,
            "chat message pin status updated",
        ),
        ("PUT", "/messages/9/pin-status", "{}", 403, ""),
        (
            "POST",
            "/channels/7/messages",
            r#"{"content":" hello ","reply_to_message_id":9,"media_ids":[77]}"#,
            200,
            "chat message created",
        ),
        (
            "POST",
            "/channels/9/messages",
            r#"{"content":" hello ","reply_to_message_id":9,"media_ids":[77]}"#,
            403,
            "",
        ),
        (
            "POST",
            "/channels/7/messages",
            r#"{"media_ids":[77,77]}"#,
            400,
            "",
        ),
        (
            "PUT",
            "/channels/7/read-status",
            "",
            200,
            "chat read status updated",
        ),
        (
            "PUT",
            "/channels/7/read-status",
            r#"{"last_read_message_id":9}"#,
            400,
            "",
        ),
        (
            "PUT",
            "/channels/7/mute-status",
            r#"{"is_muted":false}"#,
            200,
            "chat channel mute status updated",
        ),
        (
            "PUT",
            "/channels/9/mute-status",
            r#"{"is_muted":true}"#,
            403,
            "",
        ),
    ] {
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(method)
                    .uri(format!("/api/v2/chat{path}"))
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), status, "{method} {path}");
        assert_eq!(response.headers()["cache-control"], "private, no-store");
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        let value: Value = serde_json::from_slice(&bytes).unwrap();
        if !message.is_empty() {
            assert_eq!(value["message"], message);
        }
        if method == "DELETE" && status == 200 && !path.ends_with("/reactions") {
            assert_eq!(value.get("data"), Some(&Value::Null));
        }
        if path == "/messages/8" && method == "PATCH" {
            assert_eq!(value["data"]["content"], "edited");
        }
        if path == "/messages/8/pin-status" {
            assert_eq!(value["data"]["is_pinned"], true);
        }
        if path == "/messages/8/reactions" && status == 200 {
            assert_eq!(value["data"]["reactions"][0]["emoji"], "👍");
            assert_eq!(
                value["data"]["reactions"][0]["reacted_by_me"],
                method == "POST"
            );
        }
        if path == "/groups/7/members" {
            assert_eq!(value["data"][0]["online_status"], "hidden");
            assert!(value["data"][0]["last_seen_at"].is_null());
        }
        if path.ends_with("/read-status") && status == 200 {
            assert_eq!(value["data"]["last_read_message_id"], 12);
            assert_eq!(value["data"]["unread_count"], 2);
        }
        if path.ends_with("/mute-status") && status == 200 {
            assert_eq!(value["data"]["is_muted"], false);
        }
        if path.contains("/messages?") && status == 200 {
            assert_eq!(value["meta"]["has_next"], true);
            assert_eq!(value["data"][0]["message_id"], 8);
        }
    }
}

#[tokio::test]
async fn native_group_read_routes_use_viewer_and_filters() {
    let codec = TokenCodec::new(b"fixture-access-key", b"fixture-refresh-key").unwrap();
    let token = codec
        .sign(&IssuedToken {
            user_id: 42,
            user_name: "fixture".into(),
            session_id: "fixture-session".into(),
            kind: TokenKind::Access,
            issued_at: 100,
            expires_at: 300,
            jti: "fixture-jti".into(),
        })
        .unwrap();
    let app = build_native_router(
        codec,
        Arc::new(Repository::default()),
        CorsPolicy::default(),
        Arc::new(|| 150),
    );
    for (key, status) in [
        ("7", 200),
        ("by-slug/neko", 200),
        ("by-slug/missing", 404),
        ("9007199254740992", 400),
    ] {
        let response = app
            .clone()
            .oneshot(
                Request::get(format!("/api/v2/groups/{key}"))
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), status, "{key}");
        assert_eq!(response.headers()["cache-control"], "private, no-store");
        if status == 200 {
            let bytes = response.into_body().collect().await.unwrap().to_bytes();
            let value: Value = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(value["data"]["tags"], json!(["chat"]));
        }
    }
    for (path, status) in [
        (
            "/api/v2/groups?q=+NEKO+&privacy=public&category=tech&page=2&page_size=2",
            200,
        ),
        ("/api/v2/groups/popular?limit=80", 200),
        ("/api/v2/users/me/groups", 200),
        ("/api/v2/users/me/groups?category=invalid", 400),
        ("/api/v2/groups/7/members?role=member&status=pending&page=2&page_size=2", 200),
        ("/api/v2/groups/8/members?page=4", 200),
        ("/api/v2/groups/9/members", 403),
        ("/api/v2/groups/10/members", 404),
        ("/api/v2/groups/7/members?status=pending&status=active", 400),
        ("/api/v2/groups/7/members?role=invalid", 400),
        ("/api/v2/groups/9007199254740992/members", 400),
    ] {
        let response = app
            .clone()
            .oneshot(
                Request::get(path)
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), status, "{path}");
        assert_eq!(response.headers()["cache-control"], "private, no-store");
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        let value: Value = serde_json::from_slice(&bytes).unwrap();
        if path.contains("popular") {
            assert_eq!(value["data"][0]["activity_score"], 4.2);
        } else if path.contains("page=2") {
            assert_eq!(value["meta"]["has_next"], true);
        } else if status == 200 {
            assert_eq!(value["data"], json!([]));
        }
    }
}

#[tokio::test]
async fn native_group_membership_routes_enforce_scope() {
    let codec = TokenCodec::new(b"fixture-access-key", b"fixture-refresh-key").unwrap();
    let token = codec
        .sign(&IssuedToken {
            user_id: 42,
            user_name: "fixture".into(),
            session_id: "fixture-session".into(),
            kind: TokenKind::Access,
            issued_at: 100,
            expires_at: 300,
            jti: "fixture-jti".into(),
        })
        .unwrap();
    let app = build_native_router(
        codec,
        Arc::new(Repository::default()),
        CorsPolicy::default(),
        Arc::new(|| 150),
    );
    for (body, status) in [
        (r#"{"name":"Cat","tags":["Rust"]}"#, 200),
        (r#"{"name":" "}"#, 400),
        (r#"{"name":"Cat","join_approval":1}"#, 400),
    ] {
        let response = app
            .clone()
            .oneshot(
                Request::post("/api/v2/groups")
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), status);
        assert_eq!(response.headers()["cache-control"], "private, no-store");
        if status == 200 {
            let bytes = response.into_body().collect().await.unwrap().to_bytes();
            let value: Value = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(value["data"]["group_id"], 7);
            assert_eq!(value["message"], "group created");
        }
    }
    for (path, status, expected_total) in [
        ("7/posts?page=3&page_size=5", 200, json!(12)),
        ("7/posts/5?page=10", 200, Value::Null),
        ("7/posts/5/comments", 200, json!(12)),
        ("8/posts", 404, Value::Null),
        ("7/posts/6/comments", 404, Value::Null),
        ("7/posts/9007199254740992", 400, Value::Null),
        ("7/posts?type=unknown", 400, Value::Null),
        ("7/posts/5/comments?sort=unknown", 400, Value::Null),
    ] {
        let response = app
            .clone()
            .oneshot(
                Request::get(format!("/api/v2/groups/{path}"))
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), status, "{path}");
        assert_eq!(response.headers()["cache-control"], "private, no-store");
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        let result: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(result["meta"]["total"], expected_total);
    }
    for (method, path, body, status, field, expected) in [
        ("POST", "7/posts", r#"{"content":" Cat ","media_urls":[" /storage/a.png "]}"#, 200, "content", json!("Cat")),
        ("POST", "7/posts", r#"{"content":" Cat ","media_urls":["/storage/a.png"],"is_announcement":true}"#, 200, "is_announcement", json!(true)),
        ("POST", "7/posts", r#"{"content":5}"#, 400, "", Value::Null),
        ("PUT", "7/posts/5/pin-status", r#"{"is_pinned":true}"#, 200, "is_pinned", json!(true)),
        ("PUT", "7/posts/5/pin-status", r#"{"is_pinned":1}"#, 400, "", Value::Null),
        ("DELETE", "7/posts/5", "", 200, "", Value::Null),
        ("POST", "7/posts/5/likes", "", 200, "is_liked", json!(true)),
        ("DELETE", "7/posts/5/likes", "", 200, "is_liked", json!(false)),
        ("POST", "7/posts/6/likes", "", 404, "", Value::Null),
    ] {
        let res = app.clone().oneshot(Request::builder()
            .method(method).uri(format!("/api/v2/groups/{path}"))
            .header("authorization",format!("Bearer {token}"))
            .body(Body::from(body)).unwrap()).await.unwrap();
        assert_eq!(res.status(), status, "{method} {path}");
        assert_eq!(res.headers()["cache-control"],"private, no-store");
        let bytes = res.into_body().collect().await.unwrap().to_bytes();
        let value: Value = serde_json::from_slice(&bytes).unwrap();
        if field.is_empty() {
            assert_eq!(value["data"], expected);
        } else {
            assert_eq!(value["data"][field], expected);
        }
    }
    for (method, path, body, status, field, expected) in [
        ("POST", "7/posts/5/comments", r#"{"content":" Cat ","parent_comment_id":4}"#, 200, "content", json!("Cat")),
        ("POST", "7/posts/5/comments", r#"{"content":"Cat","parent_comment_id":"4"}"#, 400, "", Value::Null),
        ("DELETE", "7/posts/5/comments/6", "", 200, "", Value::Null),
        ("POST", "7/posts/5/comments/6/likes", "", 200, "is_liked", json!(true)),
        ("DELETE", "7/posts/5/comments/6/likes", "", 200, "is_liked", json!(false)),
        ("POST", "7/posts/5/comments/9/likes", "", 404, "", Value::Null),
        ("DELETE", "7/posts/5/comments/0", "", 400, "", Value::Null),
    ] {
        let res = app.clone().oneshot(Request::builder()
            .method(method).uri(format!("/api/v2/groups/{path}"))
            .header("authorization",format!("Bearer {token}"))
            .body(Body::from(body)).unwrap()).await.unwrap();
        assert_eq!(res.status(), status, "{method} {path}");
        assert_eq!(res.headers()["cache-control"],"private, no-store");
        let bytes = res.into_body().collect().await.unwrap().to_bytes();
        let value: Value = serde_json::from_slice(&bytes).unwrap();
        if field.is_empty() {
            assert_eq!(value["data"], expected);
        } else {
            assert_eq!(value["data"][field], expected);
        }
    }
    for (method, path, body, status, data) in [
        ("GET", "7/notification-preference", "", 200, json!({"is_enabled":true})),
        ("PUT", "7/notification-preference", r#"{"is_enabled":false}"#, 200, json!({"is_enabled":false})),
        ("PUT", "7/notification-preference", r#"{"is_enabled":0}"#, 200, json!({"is_enabled":false})),
        ("PUT", "7/notification-preference", "[]", 400, Value::Null),
        ("GET", "7/audit-logs", "", 200, json!([{"log_id":2,"actor_id":20,"actor":null}])),
        ("GET", "7/audit-logs?page=2", "", 200, json!([])),
        ("GET", "8/audit-logs", "", 404, Value::Null),
    ] {
        let res = app.clone().oneshot(Request::builder()
            .method(method).uri(format!("/api/v2/groups/{path}"))
            .header("authorization",format!("Bearer {token}"))
            .body(Body::from(body)).unwrap()).await.unwrap();
        assert_eq!(res.status(), status, "{method} {path}");
        assert_eq!(res.headers()["cache-control"],"private, no-store");
        let bytes = res.into_body().collect().await.unwrap().to_bytes();
        let value: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(value["data"], data);
        if path.contains("audit-logs") && status == 200 {
            assert_eq!(value["meta"]["total"], 2);
        }
    }
    let inbox=app.clone().oneshot(Request::get("/api/v2/users/me/group-invites?page=2")
        .header("authorization",format!("Bearer {token}"))
        .body(Body::empty()).unwrap()).await.unwrap();
    assert_eq!(inbox.status(),200);
    assert_eq!(inbox.headers()["cache-control"],"private, no-store");
    let bytes=inbox.into_body().collect().await.unwrap().to_bytes();
    let page:Value=serde_json::from_slice(&bytes).unwrap();
    assert_eq!(page["meta"]["total"],1);
    for (query, status) in [("invite_id=12", 200), ("invite_id=012", 400), ("invite_id=12&invite_id=12", 400)] {
        let reply = app.clone().oneshot(
            Request::get(format!("/api/v2/users/me/group-invites?{query}"))
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty()).unwrap()
        ).await.unwrap();
        assert_eq!(reply.status(), status, "{query}");
        if status == 200 {
            let bytes = reply.into_body().collect().await.unwrap().to_bytes();
            let value: Value = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(value["data"], json!([{"invite_id":12}]));
        }
    }
    for (invite,body,status,fragment) in [
        (7,r#"{"accept":true}"#,200,"accepted"),
        (7,r#"{"action":"decline"}"#,200,"rejected"),
        (7,r#"{"accept":true,"action":"accept"}"#,400,"40001"),
        (8,r#"{"accept":false}"#,404,"40401"),
        (9,r#"{"accept":true}"#,422,"42201"),
    ] {
        let response=app.clone().oneshot(Request::post(format!("/api/v2/groups/invites/{invite}/responses"))
            .header("authorization",format!("Bearer {token}"))
            .body(Body::from(body)).unwrap()).await.unwrap();
        assert_eq!(response.status(),status,"{invite} {body}");
        assert_eq!(response.headers()["cache-control"],"private, no-store");
        let bytes=response.into_body().collect().await.unwrap().to_bytes();
        assert!(String::from_utf8_lossy(&bytes).contains(fragment));
    }
    for (body,status) in [
        ("{}",200),(r#"{"invitee_id":9,"max_uses":8}"#,200),
        (r#"{"invitee_id":42}"#,422),(r#"{"invitee_id":8}"#,404),
        (r#"{"expire_hours":0}"#,400),
    ] {
        let response=app.clone().oneshot(Request::post("/api/v2/groups/7/invites")
            .header("authorization",format!("Bearer {token}"))
            .body(Body::from(body)).unwrap()).await.unwrap();
        assert_eq!(response.status(),status,"{body}");
        assert_eq!(response.headers()["cache-control"],"private, no-store");
    }
    for (path, status) in [
        ("7/invites?page=2&status=pending",200),("8/invites",422),
        ("7/invites?status=pending&status=accepted",400),
        ("invite-codes/%20aBc%20",200),("invite-codes/bad-code",400),
        ("invite-codes/EXPIRED",422),
    ] {
        let response=app.clone().oneshot(Request::get(format!("/api/v2/groups/{path}"))
            .header("authorization",format!("Bearer {token}"))
            .body(Body::empty()).unwrap()).await.unwrap();
        assert_eq!(response.status(),status,"{path}");
        assert_eq!(response.headers()["cache-control"],"private, no-store");
    }
    for (group, body, status) in [(7,r#"{"tags":[]}"#,200),(7,r#"{"tags":null}"#,400),(8,"{}",422)] {
        let response=app.clone().oneshot(Request::patch(format!("/api/v2/groups/{group}"))
            .header("authorization",format!("Bearer {token}"))
            .body(Body::from(body)).unwrap()).await.unwrap();
        assert_eq!(response.status(),status);
        assert_eq!(response.headers()["cache-control"],"private, no-store");
    }
    for (body, status) in [
        (r#"{"new_owner_id":9}"#, 200),
        (r#"{"new_owner_id":42}"#, 422),
        (r#"{"new_owner_id":99}"#, 404),
        (r#"{"new_owner_id":"9"}"#, 400),
    ] {
        let response = app.clone().oneshot(
            Request::put("/api/v2/groups/7/ownership")
                .header("authorization", format!("Bearer {token}"))
                .body(Body::from(body)).unwrap()
        ).await.unwrap();
        assert_eq!(response.status(), status);
        assert_eq!(response.headers()["cache-control"], "private, no-store");
        if status == 200 {
            let bytes = response.into_body().collect().await.unwrap().to_bytes();
            let value: Value = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(value["data"], json!({"group_id":7,"owner_id":9}));
        }
    }
    for (group, status) in [("7", 200), ("8", 422), ("9", 404), ("0", 400)] {
        let response = app
            .clone()
            .oneshot(
                Request::delete(format!("/api/v2/groups/{group}"))
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), status);
        assert_eq!(response.headers()["cache-control"], "private, no-store");
        if status == 200 {
            let bytes = response.into_body().collect().await.unwrap().to_bytes();
            let value: Value = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(value, json!({"code":200,"message":"group deleted","data":null,"meta":null}));
        }
    }
    for (method, body, status) in [
        ("POST", r#"{"invite_code":" ab12 "}"#, 200),
        ("POST", r#"{"invite_code":3}"#, 400),
        ("DELETE", "", 422),
    ] {
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(method)
                    .uri("/api/v2/groups/7/members/current")
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), status);
        assert_eq!(response.headers()["cache-control"], "private, no-store");
    }
    for (method, path, body, status, expected) in [
        ("PUT", "12/approval-status", r#"{"approved":true}"#, 200, "member approved"),
        ("PUT", "12/approval-status", r#"{"approved":false}"#, 200, "member rejected"),
        ("PUT", "12/approval-status", r#"{"approved":"false"}"#, 400, "40001"),
        ("PUT", "9/approval-status", r#"{"approved":true}"#, 404, "40401"),
        ("DELETE", "9", "", 200, "member removed"),
        ("DELETE", "10", "", 422, "42201"),
        ("DELETE", "9007199254740992", "", 400, "40001"),
        ("PATCH", "9/role", r#"{"role":"moderator"}"#, 200, "role updated"),
        ("PATCH", "9/roles", r#"{"role":"moderator"}"#, 200, "role updated"),
        ("PATCH", "9/roles", r#"{"role":"owner"}"#, 400, "40001"),
        ("PUT", "9/mute-status", "{}", 200, "2026-11-17T12:00:00.000Z"),
        ("PUT", "9/mute-status", r#"{"duration_hours":8761}"#, 400, "40001"),
        ("PUT", "9/mute-status", r#"{"duration_hours":null}"#, 400, "40001"),
        ("DELETE", "9/mute-status", "", 200, "member unmuted"),
        ("DELETE", "10/mute-status", "", 422, "42201"),
    ] {
        let response = app.clone().oneshot(
            Request::builder().method(method)
                .uri(format!("/api/v2/groups/7/members/{path}"))
                .header("authorization", format!("Bearer {token}"))
                .body(Body::from(body)).unwrap()
        ).await.unwrap();
        assert_eq!(response.status(), status, "{method} {path}");
        assert_eq!(response.headers()["cache-control"], "private, no-store");
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        assert!(String::from_utf8_lossy(&bytes).contains(expected), "{method} {path}");
    }
}

#[tokio::test]
async fn native_conversation_routes_enforce_scope_and_return_conflicts() {
    let codec = TokenCodec::new(b"fixture-access-key", b"fixture-refresh-key").unwrap();
    let token = codec
        .sign(&IssuedToken {
            user_id: 42,
            user_name: "fixture".into(),
            session_id: "fixture-session".into(),
            kind: TokenKind::Access,
            issued_at: 100,
            expires_at: 300,
            jti: "fixture-jti".into(),
        })
        .unwrap();
    let repository = Arc::new(Repository::default());
    let app = build_native_router(
        codec,
        repository.clone(),
        CorsPolicy::default(),
        Arc::new(|| 150),
    );
    let uri = "/api/v2/chat/direct-conversations";
    let group_response = app
        .clone()
        .oneshot(
            Request::get("/api/v2/chat/groups?page=2&page_size=2&user_id=9")
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(group_response.status().as_u16(), 200);
    assert_eq!(
        group_response.headers()["cache-control"],
        "private, no-store"
    );
    let group_body: Value = serde_json::from_slice(
        &group_response
            .into_body()
            .collect()
            .await
            .unwrap()
            .to_bytes(),
    )
    .unwrap();
    assert_eq!(group_body["data"][0]["channel_count"], 0);
    assert_eq!(group_body["data"][0]["membership"]["status"], "muted");
    assert_eq!(group_body["meta"]["has_next"], true);
    for (method, path, target, authenticated, status, code) in [
        ("GET", uri.to_owned(), 0, false, 401, 40101),
        (
            "GET",
            format!("{uri}?page=2&page_size=2&user_id=9"),
            0,
            true,
            200,
            200,
        ),
        ("POST", uri.to_owned(), 42, true, 400, 40001),
        ("POST", uri.to_owned(), 9, true, 200, 200),
        ("POST", uri.to_owned(), 8, true, 409, 40901),
        ("POST", uri.to_owned(), 7, true, 403, 40301),
    ] {
        let mut req = Request::builder()
            .method(method)
            .uri(path)
            .header("content-type", "application/json");
        if authenticated {
            req = req.header("authorization", format!("Bearer {token}"));
        }
        let response = app
            .clone()
            .oneshot(
                req.body(Body::from(json!({"target_user_id":target}).to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), status);
        assert_eq!(response.headers()["cache-control"], "private, no-store");
        let body: Value =
            serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes())
                .unwrap();
        assert_eq!(body["code"], code);
        if status == 200 && method == "GET" {
            assert_eq!(body["data"][0]["unread_count"], 2);
            assert_eq!(body["meta"]["has_next"], true);
            assert_eq!(repository.page.lock().unwrap().unwrap().start, 3.0);
        }
    }
}

#[tokio::test]
async fn shared_direct_history_http_cases() {
    let vectors: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/direct-message-history.json"
    ))
    .unwrap();
    let codec = TokenCodec::new(b"fixture-access-key", b"fixture-refresh-key").unwrap();
    let token = codec
        .sign(&IssuedToken {
            user_id: 42,
            user_name: "fixture".into(),
            session_id: "fixture-session".into(),
            kind: TokenKind::Access,
            issued_at: 100,
            expires_at: 300,
            jti: "fixture-jti".into(),
        })
        .unwrap();
    for case in vectors["cases"].as_array().unwrap() {
        let ids: Vec<u64> =
            serde_json::from_value(case.get("orderedMessageIds").cloned().unwrap_or(json!([])))
                .unwrap();
        let repository = Arc::new(Repository {
            expected_ids: ids.clone(),
            allowed: case["participant"] == true,
            ..Repository::default()
        });
        let app = build_native_router(
            TokenCodec::new(b"fixture-access-key", b"fixture-refresh-key").unwrap(),
            repository.clone(),
            CorsPolicy::default(),
            Arc::new(|| 150),
        );
        let id = case["conversationId"].as_str().unwrap();
        let page = case["page"].as_u64().unwrap_or(1);
        let size = case["pageSize"].as_u64().unwrap_or(20);
        let mut req = Request::builder().uri(format!("/api/v2/chat/direct-conversations/{id}/messages?page={page}&page_size={size}&user_id=9"));
        if case["authenticated"] == true {
            req = req.header("authorization", format!("Bearer {token}"));
        }
        let response = app.oneshot(req.body(Body::empty()).unwrap()).await.unwrap();
        assert_eq!(
            u64::from(response.status().as_u16()),
            case["status"].as_u64().unwrap(),
            "{}",
            case["id"]
        );
        assert_eq!(response.headers()["cache-control"], "private, no-store");
        let payload: Value =
            serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes())
                .unwrap();
        if case["status"] == 200 {
            let listed: Vec<u64> = payload["data"]
                .as_array()
                .unwrap()
                .iter()
                .map(|item| item["message_id"].as_u64().unwrap())
                .collect();
            assert_eq!(listed, ids);
            assert_eq!(payload["meta"]["has_next"], page * size < 4);
            let recorded = repository.page.lock().unwrap().unwrap();
            assert_eq!(
                (recorded.page, recorded.page_size),
                (page as f64, size as f64)
            );
        } else {
            assert!(payload["data"].is_null());
            assert_eq!(
                repository.page.lock().unwrap().is_some(),
                case["status"] == 403
            );
        }
    }
}
