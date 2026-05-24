import '../../../core/utils/json_utils.dart';

class V2Relationship {
  V2Relationship({
    required this.isSelf,
    required this.isFollowing,
    required this.isBlocked,
    required this.isBlocking,
    required this.relation,
  });

  final bool isSelf;
  final bool isFollowing;
  final bool isBlocked;
  final bool isBlocking;
  final String relation;

  factory V2Relationship.fromJson(Map<String, dynamic> json) {
    return V2Relationship(
      isSelf: toBool(json['is_self']),
      isFollowing: toBool(json['is_following']),
      isBlocked: toBool(json['is_blocked']),
      isBlocking: toBool(json['is_blocking']),
      relation: toStr(json['relation'], defaultValue: 'stranger'),
    );
  }

  factory V2Relationship.fromFollowJson(Map<String, dynamic> json) {
    final relation = toStrOrNull(json['relationship']);
    final isFollowing = toBool(json['is_following']) || relation == 'following';
    return V2Relationship(
      isSelf: false,
      isFollowing: isFollowing,
      isBlocked: false,
      isBlocking: false,
      relation: relation ?? (isFollowing ? 'following' : 'stranger'),
    );
  }

  static V2Relationship empty() => V2Relationship(
    isSelf: false,
    isFollowing: false,
    isBlocked: false,
    isBlocking: false,
    relation: 'stranger',
  );
}

class V2PublicUser {
  V2PublicUser({
    required this.userId,
    required this.username,
    required this.displayName,
    required this.avatarUrl,
    required this.bio,
    required this.location,
    required this.website,
    required this.isVerified,
    required this.followersCount,
    required this.followingCount,
    required this.postsCount,
    required this.likesCount,
    required this.relationship,
    required this.onlineStatus,
    this.lastSeenAt,
  });

  final int userId;
  final String username;
  final String displayName;
  final String avatarUrl;
  final String bio;
  final String location;
  final String website;
  final int isVerified;
  final int followersCount;
  final int followingCount;
  final int postsCount;
  final int likesCount;
  final V2Relationship relationship;
  final String onlineStatus;
  final String? lastSeenAt;

  bool get verified => isVerified == 1;

  factory V2PublicUser.fromJson(Map<String, dynamic> json) {
    return V2PublicUser(
      userId: toInt(json['user_id']) ?? 0,
      username: toStr(json['username']),
      displayName: toStr(json['display_name']),
      avatarUrl: toStr(json['avatar_url']),
      bio: toStr(json['bio']),
      location: toStr(json['location']),
      website: toStr(json['website']),
      isVerified: toInt(json['is_verified']) ?? 0,
      followersCount: toInt(json['followers_count']) ?? 0,
      followingCount: toInt(json['following_count']) ?? 0,
      postsCount: toInt(json['posts_count']) ?? 0,
      likesCount: toInt(json['likes_count']) ?? 0,
      relationship: json['relationship'] is Map<String, dynamic>
          ? V2Relationship.fromJson(
              json['relationship'] as Map<String, dynamic>,
            )
          : V2Relationship.empty(),
      onlineStatus: toStr(json['online_status'], defaultValue: 'offline'),
      lastSeenAt: toStrOrNull(json['last_seen_at']),
    );
  }
}

class V2SelfUser extends V2PublicUser {
  V2SelfUser({
    required super.userId,
    required super.username,
    required super.displayName,
    required super.avatarUrl,
    required super.bio,
    required super.location,
    required super.website,
    required super.isVerified,
    required super.followersCount,
    required super.followingCount,
    required super.postsCount,
    required super.likesCount,
    required super.relationship,
    required super.onlineStatus,
    super.lastSeenAt,
    required this.email,
    required this.phone,
    required this.birthDate,
    required this.emailVerifiedAt,
    required this.isActive,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  final String email;
  final String phone;
  final String? birthDate;
  final String? emailVerifiedAt;
  final int isActive;
  final String status;
  final String createdAt;
  final String updatedAt;

  factory V2SelfUser.fromJson(Map<String, dynamic> json) {
    final base = V2PublicUser.fromJson(json);
    return V2SelfUser(
      userId: base.userId,
      username: base.username,
      displayName: base.displayName,
      avatarUrl: base.avatarUrl,
      bio: base.bio,
      location: base.location,
      website: base.website,
      isVerified: base.isVerified,
      followersCount: base.followersCount,
      followingCount: base.followingCount,
      postsCount: base.postsCount,
      likesCount: base.likesCount,
      relationship: base.relationship,
      onlineStatus: base.onlineStatus,
      lastSeenAt: base.lastSeenAt,
      email: toStr(json['email']),
      phone: toStr(json['phone']),
      birthDate: toStrOrNull(json['birth_date']),
      emailVerifiedAt: toStrOrNull(json['email_verified_at']),
      isActive: toInt(json['is_active']) ?? 1,
      status: toStr(json['status'], defaultValue: 'active'),
      createdAt: toStr(json['created_at']),
      updatedAt: toStr(json['updated_at']),
    );
  }
}

class V2UserSettings {
  V2UserSettings({
    required this.userId,
    this.twoFactorEnabled,
    required this.loginAlerts,
    required this.profileVisibility,
    this.showOnlineStatus,
    this.allowDmFromStrangers,
    this.pushNotificationEnabled,
    this.emailNotificationEnabled,
    this.aiSentimentEnabled,
    this.aiSentimentModelId,
    this.aiSentimentReturnProbabilities,
    this.aiSentimentIncludeMetadata,
    this.aiSentimentTopK,
    required this.updatedAt,
  });

  final int userId;
  final bool? twoFactorEnabled;
  final bool loginAlerts;
  final String profileVisibility;
  final bool? showOnlineStatus;
  final bool? allowDmFromStrangers;
  final bool? pushNotificationEnabled;
  final bool? emailNotificationEnabled;
  final bool? aiSentimentEnabled;
  final String? aiSentimentModelId;
  final bool? aiSentimentReturnProbabilities;
  final bool? aiSentimentIncludeMetadata;
  final int? aiSentimentTopK;
  final String updatedAt;

  factory V2UserSettings.fromJson(Map<String, dynamic> json) {
    return V2UserSettings(
      userId: toInt(json['user_id']) ?? 0,
      twoFactorEnabled: json['two_factor_enabled'] == null
          ? null
          : toBool(json['two_factor_enabled']),
      loginAlerts: toBool(json['login_alerts']),
      profileVisibility: toStr(
        json['profile_visibility'],
        defaultValue: 'public',
      ),
      showOnlineStatus: json['show_online_status'] == null
          ? null
          : toBool(json['show_online_status']),
      allowDmFromStrangers: json['allow_dm_from_strangers'] == null
          ? null
          : toBool(json['allow_dm_from_strangers']),
      pushNotificationEnabled: json['push_notification_enabled'] == null
          ? null
          : toBool(json['push_notification_enabled']),
      emailNotificationEnabled: json['email_notification_enabled'] == null
          ? null
          : toBool(json['email_notification_enabled']),
      aiSentimentEnabled: json['ai_sentiment_enabled'] == null
          ? null
          : toBool(json['ai_sentiment_enabled']),
      aiSentimentModelId: toStrOrNull(json['ai_sentiment_model_id']),
      aiSentimentReturnProbabilities:
          json['ai_sentiment_return_probabilities'] == null
          ? null
          : toBool(json['ai_sentiment_return_probabilities']),
      aiSentimentIncludeMetadata: json['ai_sentiment_include_metadata'] == null
          ? null
          : toBool(json['ai_sentiment_include_metadata']),
      aiSentimentTopK: toInt(json['ai_sentiment_top_k']),
      updatedAt: toStr(json['updated_at']),
    );
  }
}

class V2SessionItem {
  V2SessionItem({
    required this.sessionId,
    required this.deviceInfo,
    required this.ipAddress,
    required this.lastAccessedAt,
    required this.createdAt,
    required this.isCurrent,
  });

  final String sessionId;
  final String deviceInfo;
  final String ipAddress;
  final String lastAccessedAt;
  final String createdAt;
  final bool isCurrent;

  factory V2SessionItem.fromJson(Map<String, dynamic> json) {
    return V2SessionItem(
      sessionId: toStr(json['session_id']),
      deviceInfo: toStr(json['device_info']),
      ipAddress: toStr(json['ip_address']),
      lastAccessedAt: toStr(json['last_accessed_at']),
      createdAt: toStr(json['created_at']),
      isCurrent: toBool(json['is_current']),
    );
  }
}

class V2AccountStatement {
  V2AccountStatement({
    required this.statementId,
    required this.type,
    required this.title,
    required this.message,
    required this.policyCode,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  final int statementId;
  final String type;
  final String title;
  final String message;
  final String policyCode;
  final String status;
  final String createdAt;
  final String updatedAt;

  factory V2AccountStatement.fromJson(Map<String, dynamic> json) {
    return V2AccountStatement(
      statementId: toInt(json['statement_id']) ?? 0,
      type: toStr(json['type']),
      title: toStr(json['title']),
      message: toStr(json['message']),
      policyCode: toStr(json['policy_code']),
      status: toStr(json['status']),
      createdAt: toStr(json['created_at']),
      updatedAt: toStr(json['updated_at']),
    );
  }
}
