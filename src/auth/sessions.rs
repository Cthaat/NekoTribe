use crate::{
    auth::{IssuedToken, TokenClaims, TokenCodec, TokenKind},
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    body::Body,
    extract::{OriginalUri, State},
    http::{HeaderMap, HeaderValue, Request, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{delete, get, patch, post},
    Json, Router,
};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{
    future::Future,
    pin::Pin,
    sync::{Arc, OnceLock},
};

#[derive(Debug, Clone, Copy, thiserror::Error)]
#[error("session store unavailable")]
pub struct SessionStoreError;
pub type StoreFuture<'a, T> =
    Pin<Box<dyn Future<Output = Result<T, SessionStoreError>> + Send + 'a>>;
pub trait SessionRepository: Send + Sync {
    fn ai_conversation(&self, _user:u64, _operation:crate::ai::conversation_store::AiOperation, _policy:crate::ai::conversation_store::ModerationPolicy) -> StoreFuture<'_, Result<serde_json::Value,crate::ai::conversation_store::Error>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn user_presence(&self, _user: u64) -> StoreFuture<'_, serde_json::Value> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn patch_user_settings<'a>(&'a self, _user: u64, _patch: &'a crate::users::settings_patch::SettingsPatch) -> StoreFuture<'a, crate::users::settings_read::SettingsRead> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn get_user_settings(&self, _user: u64) -> StoreFuture<'_, crate::users::settings_read::SettingsRead> {
        Box::pin(async { Err(SessionStoreError) })
    }
    // An error means the commit outcome may be unknown; callers must retain the object.
    fn create_media_atomic<'a>(
        &'a self,
        _input: &'a crate::media::upload_transaction::MediaUpload,
        _policy: &'a crate::auth::storage_urls::StorageUrlPolicy,
    ) -> StoreFuture<'a, crate::media::upload_transaction::MediaUploadOutcome<serde_json::Value>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn delete_media(&self, _user: u64, _id: f64) -> StoreFuture<'_, Option<crate::media::delete::MediaDelete>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn update_post_atomic<'a>(&'a self, _actor:u64, _id:u64, _input:&'a crate::posts::update_request::PostUpdateInput) -> StoreFuture<'a,crate::posts::update_transaction::PostUpdate> {
        Box::pin(async {Err(SessionStoreError)})
    }
    fn delete_post<'a>(&'a self, _user: u64, _id: u64) -> StoreFuture<'a, crate::posts::delete::PostDelete> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn create_post_atomic<'a>(
        &'a self, _actor: u64, _input: &'a crate::posts::create_request::PostCreateInput,
    ) -> StoreFuture<'a, crate::posts::create_transaction::PostCreation> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn post_create_actor_name(&self, _actor: u64) -> StoreFuture<'_, String> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn post_create_source_author(&self, _post: u64) -> StoreFuture<'_, Option<u64>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn post_create_excerpt(&self, _post: u64) -> StoreFuture<'_, String> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn resolve_post_mention_recipient(&self, _user: f64) -> StoreFuture<'_, Option<u64>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn store_post_create_notification<'a>(
        &'a self, _input: &'a crate::posts::create_notification::PostNoticeInput,
    ) -> StoreFuture<'a, Option<crate::auth::session_repository::StoredNotification>> {
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
    fn registration_otp<'a>(&'a self, _email: &'a str, _id: &'a str) -> StoreFuture<'a, bool> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn registration_exists<'a>(
        &'a self,
        _email: &'a str,
        _username: &'a str,
    ) -> StoreFuture<'a, bool> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn registration_next_id<'a>(&'a self) -> StoreFuture<'a, u64> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn registration_insert<'a>(
        &'a self,
        _record: &'a crate::auth::registration::RegistrationRecord,
    ) -> StoreFuture<'a, ()> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn otp_next_id<'a>(&'a self) -> StoreFuture<'a, u64> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn otp_insert<'a>(&'a self, _event: &'a crate::auth::otp::OtpEvent) -> StoreFuture<'a, ()> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn otp_lookup<'a>(
        &'a self,
        _account: &'a str,
        _kind: &'a str,
        _id: &'a str,
    ) -> StoreFuture<'a, Option<String>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn otp_mark<'a>(&'a self, _id: &'a str) -> StoreFuture<'a, ()> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn otp_verified_at<'a>(&'a self, _id: &'a str) -> StoreFuture<'a, Option<String>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn touch<'a>(&'a self, claims: &'a TokenClaims) -> StoreFuture<'a, u64>;
    fn revoke<'a>(&'a self, user_id: u64, id: &'a str) -> StoreFuture<'a, u64>;
    fn revoke_others<'a>(&'a self, user_id: u64, current: &'a str) -> StoreFuture<'a, u64>;
    fn list_sessions<'a>(
        &'a self,
        _user_id: u64,
        _page: crate::auth::session_list::SessionPage,
    ) -> StoreFuture<'a, (Vec<crate::auth::session_list::SessionItem>, u64)> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn list_notifications<'a>(
        &'a self,
        _user: u64,
        _query: &'a crate::notifications::NotificationQuery,
    ) -> StoreFuture<'a, (Vec<serde_json::Value>, u64)> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn revoke_current<'a>(
        &'a self,
        _user_id: u64,
        _session: &'a str,
        _credential: &'a SessionCredential,
    ) -> StoreFuture<'a, u64> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn rotate<'a>(&'a self, _rotation: &'a SessionRotation) -> StoreFuture<'a, u64> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn login_account<'a>(
        &'a self,
        _account: &'a str,
    ) -> StoreFuture<'a, Option<crate::auth::login::LoginAccount>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn login_two_factor<'a>(&'a self, _user: u64) -> StoreFuture<'a, bool> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn media_readiness<'a>(&'a self) -> StoreFuture<'a, ()> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn user_settings_readiness<'a>(&'a self) -> StoreFuture<'a, ()> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn two_factor_readiness<'a>(&'a self) -> StoreFuture<'a, ()> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn login_trusted_device<'a>(
        &'a self,
        _user: u64,
        _device: &'a crate::auth::login::LoginDevice,
    ) -> StoreFuture<'a, bool> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn login_challenge<'a>(
        &'a self,
        _challenge: &'a crate::auth::login::LoginChallenge,
    ) -> StoreFuture<'a, ()> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn login_insert_session<'a>(
        &'a self,
        _session: &'a crate::auth::login::LoginSession,
    ) -> StoreFuture<'a, ()> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn known_login_device<'a>(
        &'a self,
        _user: u64,
        _fingerprint: &'a str,
    ) -> StoreFuture<'a, bool> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn record_login_alert<'a>(
        &'a self,
        _session: &'a crate::auth::login::LoginSession,
    ) -> StoreFuture<'a, ()> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn update_self_profile<'a>(
        &'a self,
        _user: u64,
        _fields: &'a std::collections::BTreeMap<String, String>,
    ) -> StoreFuture<'a, ()> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn read_visible_post<'a>(
        &'a self,
        _viewer: Option<u64>,
        _id: u64,
    ) -> StoreFuture<'a, Option<serde_json::Value>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn set_post_bookmark<'a>(
        &'a self,
        _viewer: u64,
        _id: u64,
        _saved: bool,
    ) -> StoreFuture<'a, bool> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn remove_post_like<'a>(&'a self, _viewer: u64, _id: u64) -> StoreFuture<'a, Option<f64>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn add_post_like<'a>(
        &'a self,
        _viewer: u64,
        _id: u64,
    ) -> StoreFuture<'a, Option<crate::posts::like::PostLikeOutcome>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn prepare_post_like_notification<'a>(
        &'a self,
        _viewer: u64,
        _id: u64,
    ) -> StoreFuture<'a, Option<crate::posts::like::StoredLikeNotification>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn set_comment_like<'a>(&'a self,_viewer:u64,_id:u64,_liked:bool) -> StoreFuture<'a,Option<crate::posts::like::PostLikeOutcome>> {
        Box::pin(async {Err(SessionStoreError)})
    }
    fn prepare_comment_like_notification<'a>(&'a self,_viewer:u64,_id:u64) -> StoreFuture<'a,Option<crate::posts::like::StoredLikeNotification>> {
        Box::pin(async {Err(SessionStoreError)})
    }
    fn read_notification<'a>(
        &'a self,
        _user: u64,
        _id: u64,
    ) -> StoreFuture<'a, Option<serde_json::Value>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn list_post_comments<'a>(
        &'a self,
        _user: u64,
        _id: u64,
        _query: &'a crate::posts::comments::CommentListQuery,
    ) -> StoreFuture<'a, Option<(Vec<serde_json::Value>, u64)>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn delete_post_comment<'a>(
        &'a self, _user: u64, _id: u64,
    ) -> StoreFuture<'a, crate::posts::comment_delete::CommentDelete> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn create_post_comment<'a>(
        &'a self,
        _user: u64,
        _post: u64,
        _content: &'a str,
        _parent: Option<u64>,
    ) -> StoreFuture<'a, crate::posts::comment_create::CommentCreation> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn comment_notice_context<'a>(
        &'a self, _actor: u64, _post: u64, _comment: u64,
    ) -> StoreFuture<'a, crate::posts::comment_create::CommentNoticeContext> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn comment_parent_notice<'a>(
        &'a self, _parent: u64, _post_author: Option<u64>,
    ) -> StoreFuture<'a, crate::posts::comment_create::CommentParentNotice> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn store_comment_notification<'a>(
        &'a self, _input: &'a crate::posts::comment_create::CommentNoticeInput,
    ) -> StoreFuture<'a, Option<crate::posts::comment_create::StoredCommentNotification>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn set_notification_read<'a>(
        &'a self,
        _user: u64,
        _id: u64,
        _read: bool,
    ) -> StoreFuture<'a, Option<crate::notifications::NotificationReadResult>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn set_notification_deleted<'a>(
        &'a self,
        _user: u64,
        _id: u64,
        _restore: bool,
    ) -> StoreFuture<'a, Option<Option<String>>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn batch_set_notification_read<'a>(
        &'a self,
        _user: u64,
        _ids: &'a [u64],
        _read: bool,
    ) -> StoreFuture<'a, u64> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn list_visible_posts<'a>(
        &'a self,
        _viewer: Option<u64>,
        _query: &'a crate::posts::list::PostListQuery,
    ) -> StoreFuture<'a, (Vec<serde_json::Value>, u64)> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn list_tags<'a>(
        &'a self,
        _query: &'a crate::tags::TagListQuery,
    ) -> StoreFuture<'a, (Vec<serde_json::Value>, u64)> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn read_tag_analytics<'a>(
        &'a self,
        _viewer: u64,
        _name: &'a str,
    ) -> StoreFuture<'a, Option<serde_json::Value>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn read_post_author<'a>(
        &'a self,
        _viewer: Option<u64>,
        _id: u64,
    ) -> StoreFuture<'a, Option<serde_json::Value>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn read_post_media<'a>(&'a self, _id: u64) -> StoreFuture<'a, Vec<serde_json::Value>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn read_post_tags<'a>(&'a self, _id: u64) -> StoreFuture<'a, Vec<String>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn read_post_mentions<'a>(
        &'a self,
        _viewer: Option<u64>,
        _id: u64,
    ) -> StoreFuture<'a, Vec<serde_json::Value>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn increment_post_views<'a>(&'a self, _id: u64) -> StoreFuture<'a, ()> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn public_profile<'a>(
        &'a self,
        _viewer: u64,
        _target: u64,
    ) -> StoreFuture<'a, Option<serde_json::Value>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn login_profile<'a>(&'a self, _user: u64) -> StoreFuture<'a, Option<serde_json::Value>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn challenge_lookup<'a>(
        &'a self,
        _id: &'a str,
    ) -> StoreFuture<'a, Option<crate::auth::login::ChallengeRow>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn two_factor_secret<'a>(
        &'a self,
        _user: u64,
    ) -> StoreFuture<'a, Option<crate::auth::login::EncryptedSecret>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn recovery_codes<'a>(
        &'a self,
        _user: u64,
    ) -> StoreFuture<'a, Vec<crate::auth::login::RecoveryCode>> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn consume_recovery<'a>(&'a self, _id: u64) -> StoreFuture<'a, u64> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn consume_challenge<'a>(&'a self, _id: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Err(SessionStoreError) })
    }
    fn trust_challenge_device<'a>(
        &'a self,
        _row: &'a crate::auth::login::ChallengeRow,
        _expires_at: &'a str,
    ) -> StoreFuture<'a, ()> {
        Box::pin(async { Err(SessionStoreError) })
    }
}

pub enum SessionCredential {
    AccessJti(String),
    RefreshHash(String),
}

pub struct SessionRotation {
    pub user_id: u64,
    pub session_id: String,
    pub old_refresh_hash: String,
    pub refresh_hash: String,
    pub access_jti: String,
    pub access_expires_at: String,
    pub refresh_expires_at: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RefreshPolicy {
    pub access_seconds: u64,
    pub refresh_seconds: u64,
    pub cookie_secure: bool,
}
impl Default for RefreshPolicy {
    fn default() -> Self {
        Self {
            access_seconds: 900,
            refresh_seconds: 2_592_000,
            cookie_secure: false,
        }
    }
}
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CorsPolicy {
    pub origins: Vec<String>,
    pub localhost: bool,
}
#[derive(Clone)]
pub(crate) struct NativeState {
    pub(crate) codec: Arc<TokenCodec>,
    pub(crate) repository: Arc<dyn SessionRepository>,
    pub(crate) clock: Arc<dyn Fn() -> u64 + Send + Sync>,
    pub(crate) refresh_policy: RefreshPolicy,
    pub(crate) storage_urls: crate::auth::storage_urls::StorageUrlPolicy,
    pub(crate) otp_mailer: Arc<dyn crate::auth::otp::OtpMailer>,
    pub(crate) cors: CorsPolicy,
    pub(crate) notification_source: Option<Arc<dyn crate::notification_source::NotificationSource>>,
    pub(crate) notification_publisher:
        Option<Arc<dyn crate::notification_events::NotificationPublisher>>,
}
pub fn build_native_router(
    codec: TokenCodec,
    repository: Arc<dyn SessionRepository>,
    cors: CorsPolicy,
    clock: Arc<dyn Fn() -> u64 + Send + Sync>,
) -> Router {
    build_native_router_with_refresh(codec, repository, cors, clock, RefreshPolicy::default())
}
pub fn build_native_router_with_refresh(
    codec: TokenCodec,
    repository: Arc<dyn SessionRepository>,
    cors: CorsPolicy,
    clock: Arc<dyn Fn() -> u64 + Send + Sync>,
    refresh_policy: RefreshPolicy,
) -> Router {
    build_native_router_with_storage(
        codec,
        repository,
        cors,
        clock,
        refresh_policy,
        crate::auth::storage_urls::StorageUrlPolicy::default(),
    )
}
pub fn build_native_router_with_storage(
    codec: TokenCodec,
    repository: Arc<dyn SessionRepository>,
    cors: CorsPolicy,
    clock: Arc<dyn Fn() -> u64 + Send + Sync>,
    refresh_policy: RefreshPolicy,
    storage_urls: crate::auth::storage_urls::StorageUrlPolicy,
) -> Router {
    build_native_router_with_mail(
        codec,
        repository,
        cors,
        clock,
        refresh_policy,
        storage_urls,
        Arc::new(crate::auth::otp::SmtpConfig::default()),
    )
}
pub fn build_native_router_with_mail(
    codec: TokenCodec,
    repository: Arc<dyn SessionRepository>,
    cors: CorsPolicy,
    clock: Arc<dyn Fn() -> u64 + Send + Sync>,
    refresh_policy: RefreshPolicy,
    storage_urls: crate::auth::storage_urls::StorageUrlPolicy,
    otp_mailer: Arc<dyn crate::auth::otp::OtpMailer>,
) -> Router {
    build_native_router_with_realtime(
        codec,
        repository,
        cors,
        clock,
        refresh_policy,
        storage_urls,
        otp_mailer,
        None,
    )
}
pub fn build_native_router_with_realtime(
    codec: TokenCodec,
    repository: Arc<dyn SessionRepository>,
    cors: CorsPolicy,
    clock: Arc<dyn Fn() -> u64 + Send + Sync>,
    refresh_policy: RefreshPolicy,
    storage_urls: crate::auth::storage_urls::StorageUrlPolicy,
    otp_mailer: Arc<dyn crate::auth::otp::OtpMailer>,
    notification_source: Option<Arc<dyn crate::notification_source::NotificationSource>>,
) -> Router {
    build_native_router_with_realtime_and_publisher(
        codec,
        repository,
        cors,
        clock,
        refresh_policy,
        storage_urls,
        otp_mailer,
        notification_source,
        None,
    )
}
pub fn build_native_router_with_realtime_and_publisher(
    codec: TokenCodec,
    repository: Arc<dyn SessionRepository>,
    cors: CorsPolicy,
    clock: Arc<dyn Fn() -> u64 + Send + Sync>,
    refresh_policy: RefreshPolicy,
    storage_urls: crate::auth::storage_urls::StorageUrlPolicy,
    otp_mailer: Arc<dyn crate::auth::otp::OtpMailer>,
    notification_source: Option<Arc<dyn crate::notification_source::NotificationSource>>,
    notification_publisher: Option<Arc<dyn crate::notification_events::NotificationPublisher>>,
) -> Router {
    Router::new()
        .route("/api/v2/ai/conversations", post(crate::ai::conversation_http::create))
        .route("/api/v2/ai/conversations/{id}", get(crate::ai::conversation_http::read))
        .route("/api/v2/ai/conversations/{id}/messages", get(crate::ai::conversation_http::list).post(crate::ai::conversation_http::append))
        .route("/api/v2/ai/conversations/{id}/generate", post(crate::ai::conversation_http::generate))
        .route(
            "/api/health",
            get(|| async { Json(json!({"status":"ok","service":"nekotribe"})) }),
        )
        .route("/api/v2/auth/sessions/others", delete(revoke))
        .route("/api/v2/media/{id}", delete(crate::media::delete::remove))
        .route("/api/v2/media", post(crate::media::upload::upload))
        .route(
            "/api/v2/auth/sessions",
            get(crate::auth::session_list::list_sessions),
        )
        .route("/api/v2/auth/sessions/{id}", delete(revoke))
        .route("/api/v2/auth/tokens", post(crate::auth::login::login))
        .route(
            "/api/v2/auth/otp/verification",
            post(crate::auth::otp::verify_otp),
        )
        .route("/api/v2/auth/otp", post(crate::auth::otp::create_otp))
        .route(
            "/api/v2/auth/password-reset",
            post(crate::auth::password_reset::password_reset),
        )
        .route(
            "/api/v2/auth/registration",
            post(crate::auth::registration::register),
        )
        .route(
            "/api/v2/auth/two-factor/challenges",
            post(crate::auth::login::complete_challenge),
        )
        .route(
            "/api/v2/auth/two-factor/challenges/{id}",
            post(crate::auth::login::complete_challenge),
        )
        .route("/api/v2/auth/tokens/current", patch(refresh).delete(logout))
        .route(
            "/api/v2/posts/trending",
            get(crate::posts::list::list_posts),
        )
        .route("/api/v2/posts/{id}", get(crate::posts::detail::get_post).delete(crate::posts::delete::remove).patch(crate::posts::update::edit).put(crate::posts::update::edit))
        .route("/api/v2/posts/{id}/comments", get(crate::posts::comments::list_comments).post(crate::posts::comment_create::create))
        .route("/api/v2/comments/{id}", axum::routing::delete(crate::posts::comment_delete::remove))
        .route("/api/v2/comments/{id}/likes", post(crate::posts::comment_like::add).delete(crate::posts::comment_like::remove))
        .route(
            "/api/v2/posts/{id}/bookmarks",
            post(crate::posts::bookmark::save).delete(crate::posts::bookmark::remove),
        )
        .route(
            "/api/v2/posts/{id}/likes",
            post(crate::posts::like::add).delete(crate::posts::bookmark::remove_like),
        )
        .route("/api/v2/posts", get(crate::posts::list::list_posts).post(crate::posts::create::create))
        .route("/api/v2/notifications", get(crate::notifications::list))
        .route(
            "/api/v2/notifications/{id}",
            axum::routing::delete(crate::notifications::delete_notification),
        )
        .route(
            "/api/v2/notifications/{id}/restore-status",
            axum::routing::put(crate::notifications::restore_notification),
        )
        .route(
            "/api/v2/notifications/read-status",
            axum::routing::put(crate::notifications::set_batch_read),
        )
        .route(
            "/api/v2/notifications/{id}/read-status",
            axum::routing::put(crate::notifications::set_read),
        )
        .route("/_ws", get(crate::notification_websocket::upgrade))
        .route("/api/v2/tags", get(crate::tags::list_tags))
        .route("/api/v2/tags/trending", get(crate::tags::list_tags))
        .route(
            "/api/v2/tags/{name}/analytics",
            get(crate::tags::tag_analytics),
        )
        .route(
            "/api/v2/users/me/posts",
            get(crate::posts::list::list_posts),
        )
        .route(
            "/api/v2/users/me/bookmarks",
            get(crate::posts::list::list_posts),
        )
        .route(
            "/api/v2/users/me/likes",
            get(crate::posts::list::list_posts),
        )
        .route(
            "/api/v2/users/{id}/posts",
            get(crate::posts::list::scoped_posts),
        )
        .route(
            "/api/v2/tags/{name}/posts",
            get(crate::posts::list::scoped_posts),
        )
        .route(
            "/api/v2/posts/{id}/replies",
            get(crate::posts::list::scoped_posts),
        )
        .route(
            "/api/v2/posts/{id}/retweets",
            get(crate::posts::list::scoped_posts).post(crate::posts::create::retweet),
        )
        .route(
            "/api/v2/users/{id}",
            get(crate::users::public_profile::get_public),
        )
        .route(
            "/api/v2/users/me",
            get(crate::users::self_profile::get_me).patch(crate::users::self_profile::patch_me),
        )
        .route("/api/v2/users/me/settings", get(crate::users::settings_read::get).patch(crate::users::settings_patch::patch))
        .fallback(|| async { ApiError::route_not_found() })
        .layer(middleware::from_fn(crate::ai::conversation_http::private_headers))
        .layer(middleware::from_fn_with_state(
            cors.clone(),
            cors_middleware,
        ))
        .with_state(NativeState {
            codec: Arc::new(codec),
            repository,
            clock,
            refresh_policy,
            storage_urls,
            otp_mailer,
            cors,
            notification_source,
            notification_publisher,
        })
}

async fn logout(
    State(state): State<NativeState>,
    request: Request<Body>,
) -> Result<Response, ApiError> {
    let (parts, body) = request.into_parts();
    let headers = parts.headers;
    let refresh_cookie = named_cookie(&headers, "refresh_token");
    let refresh = match refresh_cookie.filter(|value| !value.is_empty()) {
        Some(value) => value.trim().to_owned(),
        None => {
            let bytes = axum::body::to_bytes(body, 1024 * 1024)
                .await
                .unwrap_or_default();
            body_refresh_token(&headers, &bytes).unwrap_or_default()
        }
    };
    let access = || {
        if let Some(cookie) =
            named_cookie(&headers, "access_token").filter(|value| !value.is_empty())
        {
            return cookie;
        }
        static BEARER: OnceLock<regex::Regex> = OnceLock::new();
        let value = headers
            .get("authorization")
            .and_then(|value| value.to_str().ok())
            .unwrap_or_default();
        BEARER
            .get_or_init(|| {
                regex::Regex::new(r"(?i)^Bearer\s+(\S+)$").expect("static bearer regex")
            })
            .captures(value)
            .and_then(|captures| captures.get(1))
            .map(|capture| capture.as_str().to_owned())
            .unwrap_or_default()
    };
    let now = (state.clock)();
    let verified = if !refresh.is_empty() {
        state
            .codec
            .verify_for_rotation(&refresh, now)
            .ok()
            .map(|claims| {
                (
                    claims,
                    SessionCredential::RefreshHash(hex::encode(Sha256::digest(refresh.as_bytes()))),
                )
            })
    } else {
        let token = access();
        state
            .codec
            .verify(&token, TokenKind::Access, now)
            .ok()
            .map(|claims| {
                let credential = SessionCredential::AccessJti(claims.jti.clone());
                (claims, credential)
            })
    };
    if let Some((claims, credential)) = verified {
        state
            .repository
            .revoke_current(claims.user_id, &claims.session_id, &credential)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    }
    let mut response = Json(V2Response::null("logout success")).into_response();
    for value in [
        "access_token=; Max-Age=0; Path=/",
        "refresh_token=; Max-Age=0; Path=/",
    ] {
        response
            .headers_mut()
            .append("set-cookie", HeaderValue::from_static(value));
    }
    Ok(response)
}

async fn refresh(
    State(state): State<NativeState>,
    request: Request<Body>,
) -> Result<Response, ApiError> {
    let (parts, body) = request.into_parts();
    let headers = parts.headers;
    let cookie = named_cookie(&headers, "refresh_token");
    // Nuxt decides whether to read JSON using the untrimmed Cookie value.
    let token = match cookie.filter(|v| !v.is_empty()) {
        Some(value) => value.trim().to_owned(),
        None => {
            // Ignore malformed or oversized bodies, just like a failed Nuxt body parse.
            let bytes = axum::body::to_bytes(body, 1024 * 1024)
                .await
                .unwrap_or_default();
            body_refresh_token(&headers, &bytes).unwrap_or_default()
        }
    };
    let unauthorized = || ApiError::unauthorized("未认证或 token 无效");
    if token.is_empty() {
        return Err(unauthorized());
    }
    let now = (state.clock)();
    let claims = state
        .codec
        .verify_for_rotation(&token, now)
        .map_err(|_| unauthorized())?;
    let policy = state.refresh_policy;
    let access_expiry = now
        .checked_add(policy.access_seconds)
        .ok_or_else(|| ApiError::server_error("服务器内部错误"))?;
    let refresh_expiry = now
        .checked_add(policy.refresh_seconds)
        .ok_or_else(|| ApiError::server_error("服务器内部错误"))?;
    let iso = |time: u64| {
        chrono::DateTime::from_timestamp(i64::try_from(time).ok()?, 0)
            .map(|t| t.to_rfc3339_opts(chrono::SecondsFormat::Millis, true))
    };
    let access_date = iso(access_expiry).ok_or_else(|| ApiError::server_error("服务器内部错误"))?;
    let refresh_date =
        iso(refresh_expiry).ok_or_else(|| ApiError::server_error("服务器内部错误"))?;
    let access_jti = uuid::Uuid::new_v4().to_string();
    let issue = |kind, expires_at, jti| IssuedToken {
        user_id: claims.user_id,
        user_name: claims.user_name.clone().unwrap_or_default(),
        session_id: claims.session_id.clone(),
        kind,
        issued_at: now,
        expires_at,
        jti,
    };
    let access = state
        .codec
        .sign(&issue(TokenKind::Access, access_expiry, access_jti.clone()))
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    let refresh = state
        .codec
        .sign(&issue(
            TokenKind::Refresh,
            refresh_expiry,
            uuid::Uuid::new_v4().to_string(),
        ))
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    let hash = |s: &str| hex::encode(Sha256::digest(s.as_bytes()));
    let rotation = SessionRotation {
        user_id: claims.user_id,
        session_id: claims.session_id.clone(),
        old_refresh_hash: hash(&token),
        refresh_hash: hash(&refresh),
        access_jti,
        access_expires_at: access_date.clone(),
        refresh_expires_at: refresh_date.clone(),
    };
    let count = state
        .repository
        .rotate(&rotation)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    if count != 1 {
        return Err(unauthorized());
    }
    let mut response = Json(V2Response::ok(json!({
        "session_id": claims.session_id, "access_token": access, "refresh_token": refresh,
        "access_token_expires_at": access_date, "refresh_token_expires_at": refresh_date,
    })))
    .into_response();
    for (name, value, max_age) in [
        ("access_token", &access, policy.access_seconds),
        ("refresh_token", &refresh, policy.refresh_seconds),
    ] {
        let secure = if policy.cookie_secure { "; Secure" } else { "" };
        let cookie =
            format!("{name}={value}; Max-Age={max_age}; Path=/; HttpOnly; SameSite=Lax{secure}");
        response.headers_mut().append(
            "set-cookie",
            HeaderValue::from_str(&cookie).map_err(|_| ApiError::server_error("服务器内部错误"))?,
        );
    }
    Ok(response)
}

fn body_refresh_token(headers: &HeaderMap, body: &[u8]) -> Option<String> {
    let content_type = headers
        .get("content-type")
        .and_then(|h| h.to_str().ok())
        .unwrap_or("");
    if content_type.starts_with("text/") {
        return None;
    }
    if content_type
        .split(';')
        .next()
        .unwrap_or("")
        .trim()
        .eq_ignore_ascii_case("application/x-www-form-urlencoded")
    {
        let mut url = reqwest::Url::parse("http://localhost/").ok()?;
        let text = std::str::from_utf8(body).ok()?;
        url.set_query(Some(text));
        let values: Vec<_> = url
            .query_pairs()
            .filter(|(k, _)| k == "refresh_token")
            .collect();
        return if values.len() == 1 {
            Some(values[0].1.trim().to_owned())
        } else {
            None
        };
    }
    serde_json::from_slice::<serde_json::Value>(body)
        .ok()
        .and_then(|v| {
            v.get("refresh_token")
                .and_then(|v| v.as_str())
                .map(str::trim)
                .map(str::to_owned)
        })
}

pub(crate) fn named_cookie(headers: &HeaderMap, target: &str) -> Option<String> {
    headers
        .get_all("cookie")
        .iter()
        .filter_map(|h| h.to_str().ok())
        .flat_map(|raw| raw.split(';'))
        .find_map(|cookie| {
            let (name, value) = cookie.trim_start().split_once('=')?;
            if name.trim() != target {
                return None;
            }
            let value = value.trim();
            let value = value
                .strip_prefix('"')
                .and_then(|v| v.strip_suffix('"'))
                .unwrap_or(value);
            Some(percent_decode(value).unwrap_or_else(|| value.to_owned()))
        })
}
async fn revoke(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let token = access_token(&headers);
    if token.is_empty() {
        return Err(ApiError::unauthorized("请先登录"));
    }
    let claims = state
        .codec
        .verify(&token, TokenKind::Access, (state.clock)())
        .map_err(|_| ApiError::unauthorized("Token无效或已过期"))?;
    if state.repository.touch(&claims).await.unwrap_or(0) != 1 {
        return Err(ApiError::unauthorized("Token无效或已过期"));
    }
    // OriginalUri preserves opaque encoding; Axum Path would percent-decode it.
    let id = uri
        .path()
        .strip_prefix("/api/v2/auth/sessions/")
        .unwrap_or_default();
    if id == "others" {
        let n = state
            .repository
            .revoke_others(claims.user_id, &claims.session_id)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?;
        return Ok(Json(V2Response::ok_with_message(
            json!({"revoked_count":n}),
            "other sessions revoked",
        ))
        .into_response());
    }
    let n = state
        .repository
        .revoke(claims.user_id, id)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?;
    if n == 0 {
        return Err(ApiError::not_found("会话不存在"));
    }
    let mut response = Json(V2Response::null("session revoked")).into_response();
    if id == claims.session_id {
        for value in [
            "access_token=; Max-Age=0; Path=/",
            "refresh_token=; Max-Age=0; Path=/",
        ] {
            response
                .headers_mut()
                .append("set-cookie", HeaderValue::from_static(value));
        }
    }
    Ok(response)
}
pub(crate) fn access_token(headers: &HeaderMap) -> String {
    // Repeated Cookie fields are ordered like one semicolon-joined value.
    // Select the first matching name across every field, including empty values,
    // before deciding whether Authorization is the fallback.
    let cookie = headers
        .get_all("cookie")
        .iter()
        .filter_map(|h| h.to_str().ok())
        .flat_map(|raw| raw.split(';'))
        .find_map(|cookie| {
            let (name, value) = cookie.trim().split_once('=')?;
            if name.trim() != "access_token" {
                return None;
            }
            let value = value.trim();
            Some(
                value
                    .strip_prefix('"')
                    .and_then(|v| v.strip_suffix('"'))
                    .unwrap_or(value),
            )
        });
    if let Some(value) = cookie.filter(|v| !v.is_empty()) {
        return percent_decode(value).unwrap_or_else(|| value.to_owned());
    }
    let header = headers
        .get("authorization")
        .and_then(|h| h.to_str().ok())
        .unwrap_or_default();
    static BEARER: OnceLock<regex::Regex> = OnceLock::new();
    BEARER
        .get_or_init(|| regex::Regex::new(r"(?i)^Bearer\s+").expect("static bearer regex"))
        .replace(header, "")
        .trim()
        .to_owned()
}
pub(crate) fn percent_decode(value: &str) -> Option<String> {
    let mut out = Vec::new();
    let b = value.as_bytes();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' {
            let pair = value.get(i + 1..i + 3)?;
            out.push(u8::from_str_radix(pair, 16).ok()?);
            i += 3
        } else {
            out.push(b[i]);
            i += 1
        }
    }
    String::from_utf8(out).ok()
}

pub const ALLOWED_HEADERS:&str="authorization,content-type,accept,origin,x-requested-with,x-request-id,x-client-platform,x-client-route,x-client-component,x-client-source,x-client-referer,x-device-fingerprint,x-device-info";
pub const ALLOWED_METHODS: &str = "GET,POST,PUT,PATCH,DELETE,OPTIONS";
fn normalize_origin(origin: &str) -> Option<String> {
    let url = reqwest::Url::parse(origin).ok()?;
    let serialized = url.origin().ascii_serialization();
    if matches!(url.scheme(), "http" | "https") && origin == serialized {
        Some(serialized)
    } else {
        None
    }
}
impl CorsPolicy {
    pub fn from_lookup(get: impl Fn(&str) -> Option<String>) -> Self {
        let mut policy = Self::default();
        for key in ["CORS_ALLOWED_ORIGINS", "NUXT_CORS_ALLOWED_ORIGINS"] {
            for raw in get(key).unwrap_or_default().split(',') {
                if let Some(origin) = normalize_origin(raw.trim()) {
                    if !policy.origins.contains(&origin) {
                        policy.origins.push(origin)
                    }
                }
            }
        }
        let local = get("NUXT_CORS_ALLOW_LOCALHOST_ORIGINS")
            .or_else(|| get("CORS_ALLOW_LOCALHOST_ORIGINS"));
        policy.localhost = local.as_deref() == Some("true")
            || (local.is_none() && get("NODE_ENV").as_deref() == Some("development"));
        policy
    }
    pub(crate) fn allows(&self, origin: &str) -> bool {
        if normalize_origin(origin).is_none() {
            return false;
        };
        if self.origins.iter().any(|o| o == origin) {
            return true;
        };
        if !self.localhost {
            return false;
        };
        let url = reqwest::Url::parse(origin).expect("normalized URL");
        let host = url.host_str().unwrap_or_default();
        host == "localhost"
            || host == "[::1]"
            || host == "::1"
            || host
                .parse::<std::net::Ipv4Addr>()
                .is_ok_and(|ip| ip.octets()[0] == 127)
    }
}
pub(crate) async fn cors_middleware(
    State(policy): State<CorsPolicy>,
    request: Request<Body>,
    next: Next,
) -> Response {
    let h = request.headers();
    let origin = h
        .get("origin")
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default();
    let mut allowed = policy.allows(origin);
    let preflight = request.method() == axum::http::Method::OPTIONS;
    if let Some(method) = h.get("access-control-request-method").filter(|_| preflight) {
        allowed &= method
            .to_str()
            .is_ok_and(|m| ALLOWED_METHODS.split(',').any(|v| v == m))
    }
    let mut requested = Vec::new();
    if let Some(headers) = h
        .get("access-control-request-headers")
        .filter(|_| preflight)
    {
        for name in headers.to_str().unwrap_or_default().split(',') {
            let name = name.trim().to_ascii_lowercase();
            allowed &= ALLOWED_HEADERS.split(',').any(|v| v == name);
            if !requested.contains(&name) {
                requested.push(name)
            }
        }
    }
    let cors = if allowed {
        let mut headers = HeaderMap::new();
        for (name, value) in [
            ("access-control-allow-origin", origin.to_owned()),
            ("access-control-allow-credentials", "true".into()),
            ("access-control-allow-methods", ALLOWED_METHODS.into()),
            (
                "access-control-allow-headers",
                if requested.is_empty() {
                    ALLOWED_HEADERS.into()
                } else {
                    requested.join(",")
                },
            ),
            (
                "access-control-expose-headers",
                "content-length,content-type".into(),
            ),
            ("access-control-max-age", "86400".into()),
        ] {
            if let Ok(value) = HeaderValue::from_str(&value) {
                headers.insert(axum::http::header::HeaderName::from_static(name), value);
            }
        }
        headers
    } else {
        HeaderMap::new()
    };
    let mut response = if preflight {
        if origin.is_empty() || allowed {
            StatusCode::NO_CONTENT.into_response()
        } else {
            ApiError::forbidden("Forbidden").into_response()
        }
    } else {
        next.run(request).await
    };
    response.headers_mut().extend(cors);
    merge_vary(response.headers_mut());
    response
}
fn merge_vary(headers: &mut HeaderMap) {
    let existing = headers
        .get_all("vary")
        .iter()
        .filter_map(|h| h.to_str().ok())
        .collect::<Vec<_>>()
        .join(",");
    let mut values: Vec<String> = existing
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .collect();
    if !values.iter().any(|v| v == "*") {
        for value in [
            "Origin",
            "Access-Control-Request-Method",
            "Access-Control-Request-Headers",
        ] {
            if !values.iter().any(|v| v.eq_ignore_ascii_case(value)) {
                values.push(value.to_owned())
            }
        }
    };
    if let Ok(v) = HeaderValue::from_str(&values.join(", ")) {
        headers.insert("vary", v);
    }
}
