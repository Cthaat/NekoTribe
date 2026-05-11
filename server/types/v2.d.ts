type V2Nullable<T> = T | null;
type V2Primitive = string | number | boolean | null;
type V2Json =
  | V2Primitive
  | V2Json[]
  | { [key: string]: V2Json };

interface V2Meta {
  page?: number;
  page_size?: number;
  total?: number;
  has_next?: boolean;
  limit?: number;
}

interface V2Response<T> {
  code: number;
  message: string;
  data: T;
  meta: V2Meta | null;
}

interface V2AuthPayload {
  userId: number;
  userName?: string;
  sessionId?: string;
  jti?: string;
  type: 'access' | 'refresh';
  iat?: number;
  exp?: number;
}

interface V2Relationship {
  is_self: boolean;
  is_following: boolean;
  is_blocked: boolean;
  is_blocking: boolean;
  relation: string;
}

interface V2PublicUser {
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

interface V2SelfUser extends V2PublicUser {
  email: string;
  phone: string;
  birth_date: string | null;
  email_verified_at: string | null;
  is_active: number;
  status: string;
  created_at: string;
  updated_at: string;
}

type V2GroupRole = 'owner' | 'admin' | 'moderator' | 'member';

interface V2AuthOtpPayload {
  account: string;
  type: 'register' | 'password_reset' | 'change_email';
  channel: 'email' | 'sms';
}

interface V2AuthOtpData {
  account: string;
  verification_id: string;
  expires_at: string;
}

interface V2AuthOtpVerificationPayload {
  account: string;
  type: 'register' | 'password_reset' | 'change_email';
  verification_id: string;
  code: string;
}

interface V2AuthOtpVerificationData {
  account: string;
  verified: boolean;
  verified_at: string;
}

interface V2RegistrationPayload {
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

interface V2LoginPayload {
  account: string;
  password: string;
  remember_me?: boolean;
}

interface V2TokenData {
  session_id: string;
  access_token_expires_at: string;
  refresh_token_expires_at: string;
}

interface V2LoginData {
  user: V2SelfUser;
  tokens: V2TokenData;
}

interface V2PasswordResetPayload {
  email: string;
  verification_id: string;
  code: string;
  new_password: string;
}

interface V2SessionItem {
  session_id: string;
  device_info: string;
  ip_address: string;
  last_accessed_at: string;
  created_at: string;
  is_current: boolean;
}

interface V2UpdateUserPayload {
  display_name?: string;
  bio?: string;
  location?: string;
  website?: string;
  birth_date?: string | null;
  phone?: string;
}

interface V2ChangeEmailPayload {
  new_email: string;
  verification_id: string;
  code: string;
}

interface V2ChangeEmailData {
  email: string;
  email_verified_at: string;
}

interface V2AvatarData {
  avatar_url: string;
  avatar_media_id: number;
}

interface V2UserSettings {
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

interface V2UpdateSettingsPayload {
  two_factor_enabled?: boolean;
  login_alerts?: boolean;
  profile_visibility?: 'public' | 'private';
  show_online_status?: boolean;
  allow_dm_from_strangers?: boolean;
  push_notification_enabled?: boolean;
  email_notification_enabled?: boolean;
}

interface V2AccountStatement {
  statement_id: number;
  type: string;
  title: string;
  message: string;
  policy_code: string;
  status: string;
  created_at: string;
  updated_at: string;
}

interface V2UpdateStatementPayload {
  action:
    | 'mark_read'
    | 'mark_unread'
    | 'dismiss'
    | 'resolve';
}

interface V2StatementStatusData {
  statement_id: number;
  status: string;
  updated_at: string;
}

interface V2StatementAppealPayload {
  appeal_message: string;
}

interface V2StatementAppealData {
  statement_id: number;
  status: string;
  appeal_id: number;
  appeal_status: string;
}

interface V2MediaAsset {
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

interface V2PostStats {
  likes_count: number;
  comments_count: number;
  replies_count: number;
  retweets_count: number;
  views_count: number;
  engagement_score: number;
}

interface V2ViewerPostState {
  is_liked: boolean;
  is_bookmarked: boolean;
  can_delete: boolean;
}

interface V2Post {
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

type V2ModerationReportReason =
  | 'spam'
  | 'harassment'
  | 'hate'
  | 'violence'
  | 'adult'
  | 'misinformation'
  | 'copyright'
  | 'other';

type V2ModerationStatus =
  | 'pending'
  | 'approved'
  | 'rejected'
  | 'flagged'
  | 'removed'
  | 'restored';

type V2ModerationReportStatus =
  | 'pending'
  | 'in_review'
  | 'resolved'
  | 'dismissed';

type V2ModerationPriority =
  | 'low'
  | 'normal'
  | 'high'
  | 'urgent';

type V2ModerationTargetType = 'post' | 'comment' | 'user';

interface V2ModerationReport {
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

interface V2ModerationContentItem {
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

interface V2ModerationStats {
  pending: number;
  approved: number;
  rejected: number;
  flagged: number;
  today_processed: number;
  avg_process_minutes: number;
  open_reports: number;
  appeal_success_rate: number;
}

interface V2ModerationActionPayload {
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

interface V2ModerationUserItem {
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

interface V2ModerationUserActionPayload {
  action: 'ban' | 'unban' | 'mute' | 'unmute' | 'note';
  reason?: string;
  note?: string;
  duration_hours?: number;
}

interface V2ModerationSetting {
  key: string;
  value: string;
  value_type: 'boolean' | 'number' | 'string';
  label: string;
  description: string;
  updated_at: string;
}

interface V2ModerationSettingsPayload {
  settings: Array<{
    key: string;
    value: string;
  }>;
}

interface V2CreateReportPayload {
  target_type: V2ModerationTargetType;
  target_id: number;
  reason: V2ModerationReportReason;
  description?: string;
  evidence_url?: string;
  priority?: V2ModerationPriority;
}

interface V2CreatePostPayload {
  content?: string;
  visibility?:
    | 'public'
    | 'followers'
    | 'mentioned'
    | 'private';
  media_ids?: number[];
  tag_names?: string[];
  mention_user_ids?: number[];
  reply_to_post_id?: number | null;
  repost_of_post_id?: number | null;
  quoted_post_id?: number | null;
  location?: string;
}

interface V2RetweetPayload {
  content?: string;
  visibility?:
    | 'public'
    | 'followers'
    | 'mentioned'
    | 'private';
}

interface V2LikePostData {
  post_id: number;
  is_liked: boolean;
  likes_count: number;
}

interface V2BookmarkPostData {
  post_id: number;
  is_bookmarked: boolean;
}

interface V2CommentStats {
  likes_count: number;
  replies_count: number;
}

interface V2CommentViewerState {
  is_liked: boolean;
  can_delete: boolean;
}

interface V2Comment {
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

interface V2CreateCommentPayload {
  content: string;
  parent_comment_id?: number | null;
}

interface V2LikeCommentData {
  comment_id: number;
  is_liked: boolean;
  likes_count: number;
}

interface V2UserAnalytics {
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

interface V2PostAnalytics {
  post_id: number;
  views_count: number;
  likes_count: number;
  comments_count: number;
  replies_count: number;
  retweets_count: number;
  engagement_score: number;
  like_rate: number;
}

interface V2TagItem {
  tag_id: number;
  name: string;
  usage_count: number;
  trending_score: number;
  is_trending: number;
  updated_at: string;
}

interface V2TagAnalytics {
  name: string;
  total_posts: number;
  total_authors: number;
  total_views: number;
  total_likes: number;
  engagement_score: number;
}

interface V2RecommendationFeedbackPayload {
  resource_type: 'post' | 'user' | 'group' | 'tag';
  resource_id: number;
  action: string;
  reason?: string;
}

interface V2RecommendationFeedbackData {
  accepted: boolean;
}

interface V2Notification {
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

interface V2NotificationReadPayload {
  is_read: boolean;
}

interface V2NotificationBatchReadPayload {
  notification_ids?: number[];
  is_read: boolean;
}

interface V2NotificationReadData {
  notification_id: number;
  is_read: number;
  read_at: string | null;
}

interface V2NotificationBatchReadData {
  updated_count: number;
}

interface V2GroupMembership {
  is_member: boolean;
  role: string | null;
  status: string | null;
  joined_at: string | null;
}

interface V2Group {
  group_id: number;
  name: string;
  slug: string;
  description: string;
  avatar_url: string | null;
  cover_url: string | null;
  owner: V2PublicUser;
  privacy: string;
  privacy_desc: string;
  join_approval: boolean;
  post_permission: string;
  member_count: number;
  post_count: number;
  is_active: number;
  membership: V2GroupMembership;
  created_at: string;
  updated_at: string;
}

interface V2CreateGroupPayload {
  name: string;
  description?: string;
  avatar_url?: string | null;
  cover_url?: string | null;
  privacy?: 'public' | 'private' | 'secret';
  join_approval?: boolean;
  post_permission?: 'all' | 'admin_only' | 'moderator_up';
}

interface V2JoinGroupPayload {
  invite_code?: string;
}

interface V2GroupMember {
  member_id: number;
  user: V2PublicUser;
  role: string;
  role_desc: string;
  status: string;
  nickname: string | null;
  joined_at: string;
}

interface V2GroupMemberStatusData {
  member_id?: number;
  user_id?: number;
  status?: string;
  role?: string;
  mute_until?: string | null;
}

interface V2GroupPost {
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

interface V2CreateGroupPostPayload {
  content: string;
  media_urls?: string[];
}

interface V2GroupComment {
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

interface V2CreateGroupCommentPayload {
  content: string;
  parent_comment_id?: number | null;
  reply_to_user_id?: number | null;
}

interface V2CreateGroupInvitePayload {
  invitee_id?: number | null;
  max_uses?: number;
  expire_hours?: number;
  message?: string;
}

interface V2GroupInvite {
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

interface V2CreateGroupInviteData {
  invite_id: number;
  invite_code: string | null;
  invite_url: string | null;
  expires_at: string | null;
}

interface V2InviteCodeData {
  is_valid: boolean;
  group: V2Group;
  inviter: V2PublicUser;
  message: string | null;
}

interface V2InviteResponsePayload {
  accept: boolean;
}

interface V2InviteResponseData {
  invite_id: number;
  status: string;
  group_id: number;
}

interface V2GroupAuditLog {
  log_id: number;
  group_id: number;
  actor: V2PublicUser;
  target_user: V2PublicUser | null;
  target_post_id: number | null;
  target_comment_id: number | null;
  action: string;
  details: V2Json | null;
  ip_address: string | null;
  created_at: string;
}

type V2ChatChannelType =
  | 'text'
  | 'announcement'
  | 'voice'
  | 'video';

interface V2ChatGroup {
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

interface V2ChatChannelLastMessage {
  message_id: number;
  content: string;
  author_name: string;
  created_at: string;
}

interface V2ChatChannel {
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

interface V2ChatMember {
  user_id: number;
  username: string;
  display_name: string;
  avatar_url: string | null;
  role: V2GroupRole;
  status: string;
  online_status: 'online' | 'offline';
}

interface V2ChatReactionSummary {
  emoji: string;
  count: number;
  reacted_by_me: boolean;
}

interface V2ChatMessageReply {
  message_id: number;
  content: string;
  author_name: string;
}

interface V2ChatMessage {
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

interface V2CreateChatChannelPayload {
  name: string;
  type?: V2ChatChannelType;
  category?: string;
  is_private?: boolean;
}

interface V2UpdateChatChannelPayload {
  name?: string;
  category?: string;
  is_private?: boolean;
}

interface V2CreateChatMessagePayload {
  content?: string;
  reply_to_message_id?: number | null;
  media_ids?: number[];
}

interface V2UpdateChatMessagePayload {
  content: string;
}

interface V2ChatReactionPayload {
  emoji: string;
}

interface V2ChatMessagePinPayload {
  is_pinned: boolean;
}

interface V2ChatReadStatusData {
  channel_id: number;
  last_read_message_id: number | null;
  unread_count: number;
}

interface V2ChatChannelMuteData {
  channel_id: number;
  is_muted: boolean;
}

interface V2DirectLastMessage {
  message_id: number;
  content: string;
  author_name: string;
  created_at: string;
}

interface V2DirectConversation {
  conversation_id: number;
  participant: V2PublicUser;
  unread_count: number;
  last_message: V2DirectLastMessage | null;
  created_at: string;
  updated_at: string;
}

interface V2DirectMessage {
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

interface V2CreateDirectConversationPayload {
  target_user_id: number;
}

interface V2CreateDirectMessagePayload {
  content: string;
}
