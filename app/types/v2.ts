export type V2Nullable<T> = T | null;
export type V2Primitive = string | number | boolean | null;
export type V2Json =
  | V2Primitive
  | V2Json[]
  | { [key: string]: V2Json };

export interface V2ApiMeta {
  page?: number;
  page_size?: number;
  total?: number;
  has_next?: boolean;
  limit?: number;
}

export interface V2ApiResponse<T> {
  code: number;
  message: string;
  data: T;
  meta: V2ApiMeta | null;
}

export interface V2PagedResult<T> {
  items: T[];
  meta: V2ApiMeta | null;
}

export type V2AuthTokenType = 'access' | 'refresh';
export type V2AuthOtpType =
  | 'register'
  | 'password_reset'
  | 'change_email';
export type V2AuthOtpChannel = 'email' | 'sms';
export type V2ProfileVisibility = 'public' | 'private';
export type V2PostVisibility =
  | 'public'
  | 'followers'
  | 'mentioned'
  | 'private';
export type V2PostSort = 'newest' | 'oldest' | 'popular';
export type V2TimelineMode = 'home' | 'mentions';
export type V2NotificationTypeFilter =
  | 'all'
  | 'like'
  | 'retweet'
  | 'comment'
  | 'follow'
  | 'mention'
  | 'system';
export type V2GroupPrivacy =
  | 'public'
  | 'private'
  | 'secret';
export type V2GroupPostPermission =
  | 'all'
  | 'admin_only'
  | 'moderator_up';
export type V2GroupRole =
  | 'owner'
  | 'admin'
  | 'moderator'
  | 'member';
export type V2GroupPostListType =
  | 'all'
  | 'pinned'
  | 'announcement';
export type V2ChatChannelType =
  | 'text'
  | 'announcement'
  | 'voice'
  | 'video';

export interface V2Relationship {
  is_self: boolean;
  is_following: boolean;
  is_blocked: boolean;
  is_blocking: boolean;
  relation: string;
}

export interface V2PublicUser {
  user_id: number;
  username: string;
  display_name: string;
  avatar_url: string;
  bio: string;
  location: string;
  website: string;
  is_verified: number;
  followers_count: number;
  following_count: number;
  posts_count: number;
  likes_count: number;
  relationship: V2Relationship;
}

export interface V2SelfUser extends V2PublicUser {
  email: string;
  phone: string;
  birth_date: string | null;
  email_verified_at: string | null;
  is_active: number;
  status: string;
  created_at: string;
  updated_at: string;
}

export interface V2AuthOtpPayload {
  account: string;
  type: V2AuthOtpType;
  channel: V2AuthOtpChannel;
}

export interface V2AuthOtpData {
  account: string;
  verification_id: string;
  expires_at: string;
}

export interface V2AuthOtpVerificationPayload {
  account: string;
  type: V2AuthOtpType;
  verification_id: string;
  code: string;
}

export interface V2AuthOtpVerificationData {
  account: string;
  verified: boolean;
  verified_at: string;
}

export interface V2RegistrationPayload {
  email: string;
  username: string;
  password: string;
  confirm_password: string;
  display_name: string;
  bio?: string;
  location?: string;
  phone?: string;
  birth_date?: string;
  verification_id: string;
  agree_to_terms: boolean;
}

export interface V2LoginPayload {
  account: string;
  password: string;
  remember_me?: boolean;
}

export interface V2TokenData {
  session_id: string;
  access_token_expires_at: string;
  refresh_token_expires_at: string;
}

export interface V2LoginData {
  user: V2SelfUser;
  tokens: V2TokenData;
}

export interface V2PasswordResetPayload {
  email: string;
  verification_id: string;
  code: string;
  new_password: string;
}

export interface V2SessionItem {
  session_id: string;
  device_info: string;
  ip_address: string;
  last_accessed_at: string;
  created_at: string;
  is_current: boolean;
}

export interface V2UpdateUserPayload {
  display_name?: string;
  bio?: string;
  location?: string;
  website?: string;
  birth_date?: string | null;
  phone?: string;
}

export interface V2ChangeEmailPayload {
  new_email: string;
  verification_id: string;
  code: string;
}

export interface V2ChangeEmailData {
  email: string;
  email_verified_at: string;
}

export interface V2AvatarData {
  avatar_url: string;
  avatar_media_id: number;
}

export interface V2UserSettings {
  user_id: number;
  two_factor_enabled?: boolean;
  login_alerts: boolean;
  profile_visibility: string;
  show_online_status?: boolean;
  allow_dm_from_strangers?: boolean;
  push_notification_enabled?: boolean;
  email_notification_enabled?: boolean;
  updated_at: string;
}

export interface V2UpdateSettingsPayload {
  two_factor_enabled?: boolean;
  login_alerts?: boolean;
  profile_visibility?: V2ProfileVisibility;
  show_online_status?: boolean;
  allow_dm_from_strangers?: boolean;
  push_notification_enabled?: boolean;
  email_notification_enabled?: boolean;
}

export interface V2AccountStatement {
  statement_id: number;
  type: string;
  title: string;
  message: string;
  policy_code: string;
  status: string;
  created_at: string;
  updated_at: string;
}

export type V2AccountStatementAction =
  | 'mark_read'
  | 'mark_unread'
  | 'dismiss'
  | 'resolve';

export interface V2UpdateStatementPayload {
  action: V2AccountStatementAction;
}

export interface V2StatementStatusData {
  statement_id: number;
  status: string;
  updated_at: string;
}

export interface V2StatementAppealPayload {
  appeal_message: string;
}

export interface V2StatementAppealData {
  statement_id: number;
  status: string;
  appeal_id: number;
  appeal_status: string;
}

export interface V2MediaAsset {
  media_id: number;
  media_type: string;
  file_name: string;
  public_url: string;
  file_size: number;
  mime_type: string;
  width: number | null;
  height: number | null;
  duration: number | null;
  thumbnail_url: string | null;
  alt_text: string | null;
  status: string;
  created_at: string;
}

export interface V2PostStats {
  likes_count: number;
  comments_count: number;
  replies_count: number;
  retweets_count: number;
  views_count: number;
  engagement_score: number;
}

export interface V2ViewerPostState {
  is_liked: boolean;
  is_bookmarked: boolean;
  can_delete: boolean;
}

export interface V2Post {
  post_id: number;
  author: V2PublicUser;
  content: string;
  post_type: string;
  visibility: string;
  language: string;
  location: string;
  reply_to_post_id: number | null;
  repost_of_post_id: number | null;
  quoted_post_id: number | null;
  media: V2MediaAsset[];
  tags: string[];
  mentions: V2PublicUser[];
  stats: V2PostStats;
  viewer_state: V2ViewerPostState;
  created_at: string;
  updated_at: string;
}

export type V2ModerationReportReason =
  | 'spam'
  | 'harassment'
  | 'hate'
  | 'violence'
  | 'adult'
  | 'misinformation'
  | 'copyright'
  | 'other';

export type V2ModerationStatus =
  | 'pending'
  | 'approved'
  | 'rejected'
  | 'flagged'
  | 'removed'
  | 'restored';

export type V2ModerationReportStatus =
  | 'pending'
  | 'in_review'
  | 'resolved'
  | 'dismissed';

export type V2ModerationPriority =
  | 'low'
  | 'normal'
  | 'high'
  | 'urgent';

export type V2ModerationTargetType =
  | 'post'
  | 'comment'
  | 'user';

export interface V2ModerationReport {
  report_id: number;
  target_type: V2ModerationTargetType;
  target_id: number;
  reporter: V2PublicUser | null;
  reason: V2ModerationReportReason;
  description: string;
  evidence_url: string | null;
  status: V2ModerationReportStatus;
  priority: V2ModerationPriority;
  handled_by: V2PublicUser | null;
  created_at: string;
  updated_at: string;
  resolved_at: string | null;
}

export interface V2ModerationContentItem {
  case_id: number;
  post_id: number;
  content: string;
  author: V2PublicUser;
  media: V2MediaAsset[];
  report_count: number;
  report_reasons: V2ModerationReportReason[];
  reports: V2ModerationReport[];
  status: V2ModerationStatus;
  priority: V2ModerationPriority;
  assigned_to: V2PublicUser | null;
  created_at: string;
  updated_at: string;
  reported_at: string;
  likes_count: number;
  retweets_count: number;
  replies_count: number;
}

export interface V2ModerationStats {
  pending: number;
  approved: number;
  rejected: number;
  flagged: number;
  today_processed: number;
  avg_process_minutes: number;
  open_reports: number;
  appeal_success_rate: number;
}

export interface V2ModerationActionPayload {
  action:
    | 'approve'
    | 'reject'
    | 'flag'
    | 'remove'
    | 'restore'
    | 'claim'
    | 'release';
  note?: string;
  reason?: string;
  duration_hours?: number;
}

export interface V2ModerationUserItem {
  user_id: number;
  username: string;
  display_name: string;
  avatar_url: string;
  email: string;
  status: string;
  is_active: number;
  is_verified: number;
  followers_count: number;
  posts_count: number;
  likes_count: number;
  report_count: number;
  active_restriction: string | null;
  restriction_until: string | null;
  created_at: string;
  updated_at: string;
}

export interface V2ModerationUserActionPayload {
  action: 'ban' | 'unban' | 'mute' | 'unmute' | 'note';
  reason?: string;
  note?: string;
  duration_hours?: number;
}

export interface V2ModerationSetting {
  key: string;
  value: string;
  value_type: 'boolean' | 'number' | 'string';
  label: string;
  description: string;
  updated_at: string;
}

export interface V2ModerationAppeal {
  appeal_id: number;
  statement_id: number;
  user: V2PublicUser;
  appeal_message: string;
  appeal_status: 'pending' | 'approved' | 'rejected';
  admin_response: string;
  created_at: string;
  updated_at: string;
}

export interface V2ModerationAppealPayload {
  appeal_status: 'approved' | 'rejected';
  admin_response?: string;
}

export interface V2ModerationSettingsPayload {
  settings: Array<{
    key: string;
    value: string;
  }>;
}

export interface V2CreateReportPayload {
  target_type: V2ModerationTargetType;
  target_id: number;
  reason: V2ModerationReportReason;
  description?: string;
  evidence_url?: string;
  priority?: V2ModerationPriority;
}

export interface V2CreatePostPayload {
  content?: string;
  visibility?: V2PostVisibility;
  media_ids?: number[];
  tag_names?: string[];
  mention_user_ids?: number[];
  reply_to_post_id?: number | null;
  repost_of_post_id?: number | null;
  quoted_post_id?: number | null;
  location?: string;
}

export interface V2UpdatePostPayload {
  content?: string;
  visibility?: V2PostVisibility;
  language?: string;
  location?: string | null;
  media_ids?: number[];
  tag_names?: string[];
  mention_user_ids?: number[];
}

export interface V2RetweetPayload {
  content?: string;
  visibility?: V2PostVisibility;
}

export interface V2LikePostData {
  post_id: number;
  is_liked: boolean;
  likes_count: number;
}

export interface V2BookmarkPostData {
  post_id: number;
  is_bookmarked: boolean;
}

export interface V2PostAnalytics {
  post_id: number;
  views_count: number;
  likes_count: number;
  comments_count: number;
  replies_count: number;
  retweets_count: number;
  engagement_score: number;
  like_rate: number;
}

export interface V2CommentStats {
  likes_count: number;
  replies_count: number;
}

export interface V2CommentViewerState {
  is_liked: boolean;
  can_delete: boolean;
}

export interface V2Comment {
  comment_id: number;
  post_id: number;
  author: V2PublicUser;
  parent_comment_id: number | null;
  root_comment_id: number | null;
  content: string;
  stats: V2CommentStats;
  viewer_state: V2CommentViewerState;
  created_at: string;
  updated_at: string;
}

export interface V2CreateCommentPayload {
  content: string;
  parent_comment_id?: number | null;
}

export interface V2LikeCommentData {
  comment_id: number;
  is_liked: boolean;
  likes_count: number;
}

export interface V2UserAnalytics {
  user_id: number;
  total_posts: number;
  posts_this_week: number;
  posts_this_month: number;
  total_likes_received: number;
  avg_likes_per_post: number;
  total_likes_given: number;
  total_comments_made: number;
  engagement_score: number;
}

export interface V2Notification {
  notification_id: number;
  type: string;
  title: string;
  message: string;
  resource_type: string | null;
  resource_id: number | null;
  priority: string;
  is_read: number;
  read_at: string | null;
  deleted_at: string | null;
  actor: V2PublicUser | null;
  metadata: V2Json | null;
  created_at: string;
}

export interface V2NotificationReadPayload {
  is_read: boolean;
}

export interface V2NotificationBatchReadPayload {
  notification_ids?: number[];
  is_read: boolean;
}

export interface V2NotificationReadData {
  notification_id: number;
  is_read: number;
  read_at: string | null;
}

export interface V2NotificationBatchReadData {
  updated_count: number;
}

export interface V2GroupMembership {
  is_member: boolean;
  role: V2GroupRole | null;
  status: string | null;
  joined_at: string | null;
}

export interface V2Group {
  group_id: number;
  name: string;
  slug: string;
  description: string;
  avatar_url: string | null;
  cover_url: string | null;
  owner: V2PublicUser;
  privacy: V2GroupPrivacy;
  privacy_desc: string;
  join_approval: boolean;
  post_permission: V2GroupPostPermission;
  member_count: number;
  post_count: number;
  is_active: number;
  membership: V2GroupMembership;
  created_at: string;
  updated_at: string;
}

export interface V2CreateGroupPayload {
  name: string;
  description?: string;
  avatar_url?: string | null;
  cover_url?: string | null;
  privacy?: V2GroupPrivacy;
  join_approval?: boolean;
  post_permission?: V2GroupPostPermission;
}

export interface V2UpdateGroupPayload {
  name?: string;
  description?: string;
  avatar_url?: string | null;
  cover_url?: string | null;
  privacy?: V2GroupPrivacy;
  join_approval?: boolean;
  post_permission?: V2GroupPostPermission;
}

export interface V2JoinGroupPayload {
  invite_code?: string;
}

export interface V2JoinGroupData {
  member_id: number;
  group_id: number;
  user_id: number;
  role: V2GroupRole;
  status: string;
}

export interface V2GroupMember {
  member_id: number;
  user: V2PublicUser;
  role: V2GroupRole;
  role_desc: string;
  status: string;
  nickname: string | null;
  mute_until?: string | null;
  joined_at: string;
}

export interface V2GroupMemberStatusData {
  member_id?: number;
  user_id?: number;
  status?: string;
  role?: V2GroupRole;
  mute_until?: string | null;
}

export interface V2TransferGroupOwnershipData {
  group_id: number;
  owner_id: number;
}

export interface V2GroupPost {
  post_id: number;
  group_id: number;
  author: V2PublicUser;
  content: string;
  media_urls: string[];
  is_pinned: boolean;
  is_announcement: boolean;
  likes_count: number;
  comments_count: number;
  views_count: number;
  is_liked_by_me: boolean;
  created_at: string;
  updated_at: string;
}

export interface V2CreateGroupPostPayload {
  content: string;
  media_urls?: string[];
}

export interface V2GroupPostPinStatusData {
  post_id: number;
  is_pinned: boolean;
}

export interface V2GroupPostLikeData {
  post_id: number;
  is_liked: boolean;
  likes_count: number;
}

export interface V2GroupComment {
  comment_id: number;
  post_id: number;
  author: V2PublicUser;
  parent_comment_id: number | null;
  reply_to_user: V2PublicUser | null;
  content: string;
  likes_count: number;
  is_liked_by_me: boolean;
  created_at: string;
  updated_at: string;
}

export interface V2CreateGroupCommentPayload {
  content: string;
  parent_comment_id?: number | null;
  reply_to_user_id?: number | null;
}

export interface V2CreateGroupInvitePayload {
  invitee_id?: number | null;
  max_uses?: number;
  expire_hours?: number;
  message?: string;
}

export interface V2GroupInvite {
  invite_id: number;
  invite_code: string | null;
  status: string;
  max_uses: number | null;
  used_count: number;
  expires_at: string | null;
  inviter: V2PublicUser;
  invitee: V2PublicUser | null;
  is_valid: boolean;
}

export interface V2CreateGroupInviteData {
  invite_id: number;
  invite_code: string | null;
  invite_url: string | null;
  expires_at: string | null;
}

export interface V2InviteCodeData {
  is_valid: boolean;
  group: V2Group;
  inviter: V2PublicUser;
  message: string | null;
}

export interface V2InviteResponsePayload {
  accept: boolean;
}

export interface V2InviteResponseData {
  invite_id: number;
  status: string;
  group_id: number;
}

export interface V2PageQuery {
  [key: string]: V2Primitive | undefined;
  page?: number;
  page_size?: number;
}

export interface V2UserSearchQuery extends V2PageQuery {
  q?: string;
  verified?: boolean;
  sort?: 'popular' | 'newest' | 'oldest' | 'followers';
}

export interface V2PostListQuery extends V2PageQuery {
  sort?: V2PostSort;
  timeline?: V2TimelineMode;
  q?: string;
}

export interface V2NotificationListQuery
  extends V2PageQuery {
  type?: V2NotificationTypeFilter;
  unread_only?: boolean;
  show_deleted?: boolean;
}

export interface V2StatementListQuery extends V2PageQuery {
  status?: string;
  type?: string;
}

export interface V2SessionListQuery extends V2PageQuery {}

export interface V2GroupListQuery extends V2PageQuery {
  q?: string;
  privacy?: V2GroupPrivacy;
}

export interface V2PopularGroupsQuery {
  [key: string]: V2Primitive | undefined;
  limit?: number;
}

export interface V2GroupMemberListQuery
  extends V2PageQuery {}

export interface V2GroupPostListQuery extends V2PageQuery {
  type?: V2GroupPostListType;
}

export interface V2GroupInviteListQuery extends V2PageQuery {
  status?: string;
}

export interface V2ChatGroup {
  group_id: number;
  name: string;
  avatar_url: string | null;
  member_count: number;
  channel_count: number;
  unread_count: number;
  membership: V2GroupMembership & {
    can_manage: boolean;
  };
}

export interface V2ChatChannelLastMessage {
  message_id: number;
  content: string;
  author_name: string;
  created_at: string;
}

export interface V2ChatChannel {
  channel_id: number;
  group_id: number;
  name: string;
  type: V2ChatChannelType;
  category: string;
  position: number;
  is_private: boolean;
  is_muted_by_me: boolean;
  unread_count: number;
  last_message: V2ChatChannelLastMessage | null;
  created_at: string;
  updated_at: string;
  can_manage: boolean;
}

export interface V2ChatMember {
  user_id: number;
  username: string;
  display_name: string;
  avatar_url: string | null;
  role: V2GroupRole;
  status: string;
  online_status: 'online' | 'offline';
}

export interface V2ChatReactionSummary {
  emoji: string;
  count: number;
  reacted_by_me: boolean;
}

export interface V2ChatMessageReply {
  message_id: number;
  content: string;
  author_name: string;
}

export interface V2ChatMessage {
  message_id: number;
  channel_id: number;
  group_id: number;
  message_type: 'text' | 'system';
  content: string;
  author: V2PublicUser;
  reply_to: V2ChatMessageReply | null;
  media: V2MediaAsset[];
  reactions: V2ChatReactionSummary[];
  is_pinned: boolean;
  is_deleted: boolean;
  can_delete: boolean;
  can_pin: boolean;
  created_at: string;
  updated_at: string;
  edited_at: string | null;
  deleted_at: string | null;
}

export interface V2CreateChatChannelPayload {
  name: string;
  type?: V2ChatChannelType;
  category?: string;
  is_private?: boolean;
}

export interface V2UpdateChatChannelPayload {
  name?: string;
  category?: string;
  is_private?: boolean;
}

export interface V2CreateChatMessagePayload {
  content?: string;
  reply_to_message_id?: number | null;
  media_ids?: number[];
}

export interface V2UpdateChatMessagePayload {
  content: string;
}

export interface V2ChatReactionPayload {
  emoji: string;
}

export interface V2ChatMessagePinPayload {
  is_pinned: boolean;
}

export interface V2ChatReadStatusData {
  channel_id: number;
  last_read_message_id: number | null;
  unread_count: number;
}

export interface V2ChatChannelMuteData {
  channel_id: number;
  is_muted: boolean;
}

export interface V2DirectLastMessage {
  message_id: number;
  content: string;
  author_name: string;
  created_at: string;
}

export interface V2DirectConversation {
  conversation_id: number;
  participant: V2PublicUser;
  unread_count: number;
  last_message: V2DirectLastMessage | null;
  created_at: string;
  updated_at: string;
}

export interface V2DirectMessage {
  message_id: number;
  conversation_id: number;
  content: string;
  author: V2PublicUser;
  is_deleted: boolean;
  can_delete: boolean;
  created_at: string;
  updated_at: string;
  edited_at: string | null;
  deleted_at: string | null;
}

export interface V2CreateDirectConversationPayload {
  target_user_id: number;
}

export interface V2CreateDirectMessagePayload {
  content: string;
}

export interface V2FollowUserData {
  target_user_id: number;
  relationship: string;
  followers_count: number;
}

export interface V2SimpleRelationshipData {
  target_user_id: number;
  relationship: string;
}

export interface V2CurrentUserSummary {
  id: number;
  username: string;
  display_name: string;
  avatar_url: string;
  email: string;
  location: string;
  followers_count: number;
  following_count: number;
  likes_count: number;
  engagement_score: number;
}

export type V2CreateOtpRequest = V2AuthOtpPayload;
export type V2CreateOtpResponse =
  V2ApiResponse<V2AuthOtpData>;
export type V2VerifyOtpRequest =
  V2AuthOtpVerificationPayload;
export type V2VerifyOtpResponse =
  V2ApiResponse<V2AuthOtpVerificationData>;
export type V2RegisterRequest = V2RegistrationPayload;
export type V2RegisterResponse = V2ApiResponse<{
  user: V2SelfUser;
}>;
export type V2LoginRequest = V2LoginPayload;
export type V2LoginResponse = V2ApiResponse<V2LoginData>;
export type V2RefreshCurrentTokenResponse =
  V2ApiResponse<V2TokenData>;
export type V2LogoutCurrentResponse = V2ApiResponse<null>;
export type V2PasswordResetRequest = V2PasswordResetPayload;
export type V2PasswordResetResponse = V2ApiResponse<null>;
export type V2ListSessionsRequest = V2SessionListQuery;
export type V2ListSessionsResponse = V2ApiResponse<
  V2SessionItem[]
>;
export type V2RevokeSessionResponse = V2ApiResponse<null>;
export type V2RevokeOtherSessionsResponse = V2ApiResponse<{
  revoked_count: number;
}>;

export type V2GetMeResponse = V2ApiResponse<V2SelfUser>;
export type V2PatchMeRequest = V2UpdateUserPayload;
export type V2PatchMeResponse = V2ApiResponse<V2SelfUser>;
export type V2ChangeEmailRequest = V2ChangeEmailPayload;
export type V2ChangeEmailResponse =
  V2ApiResponse<V2ChangeEmailData>;
export type V2UpdateAvatarResponse =
  V2ApiResponse<V2AvatarData>;
export type V2SearchUsersRequest = V2UserSearchQuery;
export type V2SearchUsersResponse = V2ApiResponse<
  V2PublicUser[]
>;
export type V2GetUserByIdResponse =
  V2ApiResponse<V2PublicUser>;
export type V2GetUserAnalyticsResponse =
  V2ApiResponse<V2UserAnalytics>;
export type V2FollowUserResponse =
  V2ApiResponse<V2FollowUserData>;
export type V2UnfollowUserResponse =
  V2ApiResponse<V2FollowUserData>;
export type V2GetSettingsResponse =
  V2ApiResponse<V2UserSettings>;
export type V2PatchSettingsRequest =
  V2UpdateSettingsPayload;
export type V2PatchSettingsResponse =
  V2ApiResponse<V2UserSettings>;
export type V2ListAccountStatementsRequest =
  V2StatementListQuery;
export type V2ListAccountStatementsResponse = V2ApiResponse<
  V2AccountStatement[]
>;
export type V2PatchAccountStatementRequest =
  V2UpdateStatementPayload;
export type V2PatchAccountStatementResponse =
  V2ApiResponse<V2StatementStatusData>;
export type V2CreateStatementAppealRequest =
  V2StatementAppealPayload;
export type V2CreateStatementAppealResponse =
  V2ApiResponse<V2StatementAppealData>;

export type V2ListPostsRequest = V2PostListQuery;
export type V2ListPostsResponse = V2ApiResponse<V2Post[]>;
export type V2ListTrendingPostsRequest = V2PageQuery;
export type V2ListTrendingPostsResponse =
  V2ApiResponse<V2Post[]>;
export type V2ListUserPostsRequest = V2PageQuery & {
  sort?: V2PostSort;
};
export type V2ListUserPostsResponse =
  V2ApiResponse<V2Post[]>;
export type V2ListMyPostsRequest = V2PageQuery & {
  sort?: V2PostSort;
  q?: string;
};
export type V2ListMyPostsResponse = V2ApiResponse<V2Post[]>;
export type V2ListMyBookmarkedPostsRequest = V2PageQuery & {
  sort?: V2PostSort;
};
export type V2ListMyBookmarkedPostsResponse =
  V2ApiResponse<V2Post[]>;
export type V2CreatePostRequest = V2CreatePostPayload;
export type V2CreatePostResponse = V2ApiResponse<V2Post>;
export type V2UpdatePostRequest = V2UpdatePostPayload;
export type V2UpdatePostResponse = V2ApiResponse<V2Post>;
export type V2GetPostResponse = V2ApiResponse<V2Post>;
export type V2DeletePostResponse = V2ApiResponse<null>;
export type V2GetPostAnalyticsResponse =
  V2ApiResponse<V2PostAnalytics>;
export type V2CreateRetweetRequest = V2RetweetPayload;
export type V2CreateRetweetResponse = V2ApiResponse<V2Post>;
export type V2LikePostResponse =
  V2ApiResponse<V2LikePostData>;
export type V2BookmarkPostResponse =
  V2ApiResponse<V2BookmarkPostData>;
export type V2ListCommentsRequest = V2PageQuery & {
  sort?: V2PostSort;
};
export type V2ListCommentsResponse = V2ApiResponse<
  V2Comment[]
>;
export type V2CreateCommentRequest = V2CreateCommentPayload;
export type V2CreateCommentResponse =
  V2ApiResponse<V2Comment>;
export type V2DeleteCommentResponse = V2ApiResponse<null>;
export type V2LikeCommentResponse =
  V2ApiResponse<V2LikeCommentData>;
export type V2UploadMediaResponse =
  V2ApiResponse<V2MediaAsset>;

export type V2ListNotificationsRequest =
  V2NotificationListQuery;
export type V2ListNotificationsResponse = V2ApiResponse<
  V2Notification[]
>;
export type V2SetNotificationReadStatusRequest =
  V2NotificationReadPayload;
export type V2SetNotificationReadStatusResponse =
  V2ApiResponse<V2NotificationReadData>;
export type V2BatchSetNotificationReadStatusRequest =
  V2NotificationBatchReadPayload;
export type V2BatchSetNotificationReadStatusResponse =
  V2ApiResponse<V2NotificationBatchReadData>;
export type V2DeleteNotificationResponse =
  V2ApiResponse<null>;
export type V2RestoreNotificationResponse = V2ApiResponse<{
  notification_id: number;
  deleted_at: null;
}>;
export type V2ListGroupsRequest = V2GroupListQuery;
export type V2ListGroupsResponse = V2ApiResponse<
  V2Group[]
>;
export type V2PopularGroupsRequest = V2PopularGroupsQuery;
export type V2PopularGroupsResponse = V2ApiResponse<
  (V2Group & { activity_score: number })[]
>;
export type V2ListMyGroupsRequest = V2PageQuery;
export type V2ListMyGroupsResponse = V2ApiResponse<
  V2Group[]
>;
export type V2CreateGroupRequest = V2CreateGroupPayload;
export type V2CreateGroupResponse = V2ApiResponse<V2Group>;
export type V2GetGroupResponse = V2ApiResponse<V2Group>;
export type V2PatchGroupRequest = V2UpdateGroupPayload;
export type V2PatchGroupResponse = V2ApiResponse<V2Group>;
export type V2DeleteGroupResponse = V2ApiResponse<null>;
export type V2JoinGroupRequest = V2JoinGroupPayload;
export type V2JoinGroupResponse =
  V2ApiResponse<V2JoinGroupData>;
export type V2LeaveGroupResponse = V2ApiResponse<null>;
export type V2GroupMemberStatusResponse =
  V2ApiResponse<V2GroupMemberStatusData>;
export type V2TransferGroupOwnershipResponse =
  V2ApiResponse<V2TransferGroupOwnershipData>;
export type V2ListGroupMembersRequest =
  V2GroupMemberListQuery;
export type V2ListGroupMembersResponse = V2ApiResponse<
  V2GroupMember[]
>;
export type V2ListGroupPostsRequest =
  V2GroupPostListQuery;
export type V2ListGroupPostsResponse = V2ApiResponse<
  V2GroupPost[]
>;
export type V2CreateGroupPostRequest =
  V2CreateGroupPostPayload;
export type V2CreateGroupPostResponse =
  V2ApiResponse<V2GroupPost>;
export type V2CreateGroupInviteRequest =
  V2CreateGroupInvitePayload;
export type V2CreateGroupInviteResponse =
  V2ApiResponse<V2CreateGroupInviteData>;
export type V2ListGroupInvitesRequest =
  V2GroupInviteListQuery;
export type V2ListGroupInvitesResponse = V2ApiResponse<
  V2GroupInvite[]
>;
export type V2RespondGroupInviteRequest =
  V2InviteResponsePayload;
export type V2RespondGroupInviteResponse =
  V2ApiResponse<V2InviteResponseData>;
export type V2ListChatGroupsResponse = V2ApiResponse<
  V2ChatGroup[]
>;
export type V2ListChatChannelsResponse = V2ApiResponse<
  V2ChatChannel[]
>;
export type V2CreateChatChannelResponse =
  V2ApiResponse<V2ChatChannel>;
export type V2UpdateChatChannelResponse =
  V2ApiResponse<V2ChatChannel>;
export type V2ListChatMembersResponse = V2ApiResponse<
  V2ChatMember[]
>;
export type V2ListChatMessagesResponse = V2ApiResponse<
  V2ChatMessage[]
>;
export type V2CreateChatMessageResponse =
  V2ApiResponse<V2ChatMessage>;
export type V2UpdateChatMessageResponse =
  V2ApiResponse<V2ChatMessage>;
export type V2DeleteChatMessageResponse = V2ApiResponse<null>;
export type V2ChatReactionResponse =
  V2ApiResponse<V2ChatMessage>;
export type V2ChatMessagePinResponse =
  V2ApiResponse<V2ChatMessage>;
export type V2ChatReadStatusResponse =
  V2ApiResponse<V2ChatReadStatusData>;
export type V2ChatChannelMuteResponse =
  V2ApiResponse<V2ChatChannelMuteData>;
export type V2ListDirectConversationsResponse = V2ApiResponse<
  V2DirectConversation[]
>;
export type V2CreateDirectConversationResponse =
  V2ApiResponse<V2DirectConversation>;
export type V2ListDirectMessagesResponse = V2ApiResponse<
  V2DirectMessage[]
>;
export type V2CreateDirectMessageResponse =
  V2ApiResponse<V2DirectMessage>;
