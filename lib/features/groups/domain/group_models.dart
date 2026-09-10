import '../../../core/utils/json_utils.dart';
import '../../users/domain/user_models.dart';

class V2GroupMembership {
  V2GroupMembership({
    required this.isMember,
    this.role,
    this.status,
    this.joinedAt,
  });

  final bool isMember;
  final String? role;
  final String? status;
  final String? joinedAt;

  factory V2GroupMembership.fromJson(Map<String, dynamic> json) {
    return V2GroupMembership(
      isMember: toBool(json['is_member']),
      role: toStrOrNull(json['role']),
      status: toStrOrNull(json['status']),
      joinedAt: toStrOrNull(json['joined_at']),
    );
  }

  static V2GroupMembership empty() => V2GroupMembership(isMember: false);
}

class V2Group {
  V2Group({
    required this.groupId,
    required this.name,
    required this.slug,
    required this.description,
    this.avatarUrl,
    this.coverUrl,
    this.category,
    required this.tags,
    required this.owner,
    required this.privacy,
    required this.privacyDesc,
    required this.joinApproval,
    required this.postPermission,
    required this.memberCount,
    required this.postCount,
    required this.isActive,
    required this.membership,
    required this.createdAt,
    required this.updatedAt,
  });

  final int groupId;
  final String name;
  final String slug;
  final String description;
  final String? avatarUrl;
  final String? coverUrl;
  final String? category;
  final List<String> tags;
  final V2PublicUser owner;
  final String privacy;
  final String privacyDesc;
  final bool joinApproval;
  final String postPermission;
  final int memberCount;
  final int postCount;
  final int isActive;
  final V2GroupMembership membership;
  final String createdAt;
  final String updatedAt;

  factory V2Group.fromJson(Map<String, dynamic> json) {
    return V2Group(
      groupId: toInt(json['group_id']) ?? 0,
      name: toStr(json['name']),
      slug: toStr(json['slug']),
      description: toStr(json['description']),
      avatarUrl: toStrOrNull(json['avatar_url']),
      coverUrl: toStrOrNull(json['cover_url']),
      category: toStrOrNull(json['category']),
      tags: toList(json['tags'], (e) => toStr(e)),
      owner: V2PublicUser.fromJson(toMap(json['owner'])),
      privacy: toStr(json['privacy'], defaultValue: 'public'),
      privacyDesc: toStr(json['privacy_desc']),
      joinApproval: toBool(json['join_approval']),
      postPermission: toStr(json['post_permission'], defaultValue: 'all'),
      memberCount: toInt(json['member_count']) ?? 0,
      postCount: toInt(json['post_count']) ?? 0,
      isActive: toInt(json['is_active']) ?? 1,
      membership: json['membership'] is Map<String, dynamic>
          ? V2GroupMembership.fromJson(
              json['membership'] as Map<String, dynamic>,
            )
          : V2GroupMembership.empty(),
      createdAt: toStr(json['created_at']),
      updatedAt: toStr(json['updated_at']),
    );
  }
}

class V2GroupMember {
  V2GroupMember({
    required this.memberId,
    required this.user,
    required this.role,
    required this.roleDesc,
    required this.status,
    this.nickname,
    this.muteUntil,
    required this.joinedAt,
  });

  final int memberId;
  final V2PublicUser user;
  final String role;
  final String roleDesc;
  final String status;
  final String? nickname;
  final String? muteUntil;
  final String joinedAt;

  factory V2GroupMember.fromJson(Map<String, dynamic> json) {
    return V2GroupMember(
      memberId: toInt(json['member_id']) ?? 0,
      user: V2PublicUser.fromJson(toMap(json['user'])),
      role: toStr(json['role'], defaultValue: 'member'),
      roleDesc: toStr(json['role_desc']),
      status: toStr(json['status'], defaultValue: 'active'),
      nickname: toStrOrNull(json['nickname']),
      muteUntil: toStrOrNull(json['mute_until']),
      joinedAt: toStr(json['joined_at']),
    );
  }
}

class V2GroupMemberStatus {
  V2GroupMemberStatus({
    this.memberId,
    this.userId,
    this.status,
    this.role,
    this.muteUntil,
  });

  final int? memberId;
  final int? userId;
  final String? status;
  final String? role;
  final String? muteUntil;

  factory V2GroupMemberStatus.fromJson(Map<String, dynamic> json) {
    return V2GroupMemberStatus(
      memberId: toInt(json['member_id']),
      userId: toInt(json['user_id']),
      status: toStrOrNull(json['status']),
      role: toStrOrNull(json['role']),
      muteUntil: toStrOrNull(json['mute_until']),
    );
  }
}

class V2GroupNotificationPreference {
  V2GroupNotificationPreference({
    required this.userId,
    required this.groupId,
    required this.isEnabled,
    required this.updatedAt,
  });

  final int userId;
  final int groupId;
  final bool isEnabled;
  final String updatedAt;

  factory V2GroupNotificationPreference.fromJson(Map<String, dynamic> json) {
    return V2GroupNotificationPreference(
      userId: toInt(json['user_id']) ?? 0,
      groupId: toInt(json['group_id']) ?? 0,
      isEnabled: toBool(json['is_enabled']),
      updatedAt: toStr(json['updated_at']),
    );
  }
}

class V2GroupInvite {
  V2GroupInvite({
    required this.inviteId,
    this.inviteCode,
    required this.status,
    this.message,
    this.maxUses,
    required this.usedCount,
    this.expiresAt,
    required this.createdAt,
    this.group,
    required this.inviter,
    this.invitee,
    required this.isValid,
  });

  final int inviteId;
  final String? inviteCode;
  final String status;
  final String? message;
  final int? maxUses;
  final int usedCount;
  final String? expiresAt;
  final String createdAt;
  final Map<String, dynamic>? group;
  final V2PublicUser inviter;
  final V2PublicUser? invitee;
  final bool isValid;

  factory V2GroupInvite.fromJson(Map<String, dynamic> json) {
    return V2GroupInvite(
      inviteId: toInt(json['invite_id']) ?? 0,
      inviteCode: toStrOrNull(json['invite_code']),
      status: toStr(json['status']),
      message: toStrOrNull(json['message']),
      maxUses: toInt(json['max_uses']),
      usedCount: toInt(json['used_count']) ?? 0,
      expiresAt: toStrOrNull(json['expires_at']),
      createdAt: toStr(json['created_at']),
      group: json['group'] is Map<String, dynamic>
          ? json['group'] as Map<String, dynamic>
          : null,
      inviter: V2PublicUser.fromJson(toMap(json['inviter'])),
      invitee: json['invitee'] is Map<String, dynamic>
          ? V2PublicUser.fromJson(json['invitee'] as Map<String, dynamic>)
          : null,
      isValid: toBool(json['is_valid']),
    );
  }
}

class V2GroupPost {
  V2GroupPost({
    required this.postId,
    required this.groupId,
    required this.author,
    required this.content,
    required this.mediaUrls,
    required this.isPinned,
    required this.isAnnouncement,
    required this.likesCount,
    required this.commentsCount,
    required this.viewsCount,
    required this.isLikedByMe,
    required this.createdAt,
    required this.updatedAt,
  });

  final int postId;
  final int groupId;
  final V2PublicUser author;
  final String content;
  final List<String> mediaUrls;
  final bool isPinned;
  final bool isAnnouncement;
  final int likesCount;
  final int commentsCount;
  final int viewsCount;
  final bool isLikedByMe;
  final String createdAt;
  final String updatedAt;

  factory V2GroupPost.fromJson(Map<String, dynamic> json) {
    return V2GroupPost(
      postId: toInt(json['post_id']) ?? 0,
      groupId: toInt(json['group_id']) ?? 0,
      author: V2PublicUser.fromJson(toMap(json['author'])),
      content: toStr(json['content']),
      mediaUrls: toList(json['media_urls'], (e) => toStr(e)),
      isPinned: toBool(json['is_pinned']),
      isAnnouncement: toBool(json['is_announcement']),
      likesCount: toInt(json['likes_count']) ?? 0,
      commentsCount: toInt(json['comments_count']) ?? 0,
      viewsCount: toInt(json['views_count']) ?? 0,
      isLikedByMe: toBool(json['is_liked_by_me']),
      createdAt: toStr(json['created_at']),
      updatedAt: toStr(json['updated_at']),
    );
  }

  V2GroupPost copyWith({
    bool? isPinned,
    bool? isAnnouncement,
    int? likesCount,
    int? commentsCount,
    int? viewsCount,
    bool? isLikedByMe,
  }) {
    return V2GroupPost(
      postId: postId,
      groupId: groupId,
      author: author,
      content: content,
      mediaUrls: mediaUrls,
      isPinned: isPinned ?? this.isPinned,
      isAnnouncement: isAnnouncement ?? this.isAnnouncement,
      likesCount: likesCount ?? this.likesCount,
      commentsCount: commentsCount ?? this.commentsCount,
      viewsCount: viewsCount ?? this.viewsCount,
      isLikedByMe: isLikedByMe ?? this.isLikedByMe,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}

class V2GroupComment {
  V2GroupComment({
    required this.commentId,
    required this.postId,
    required this.author,
    this.parentCommentId,
    this.replyToUser,
    required this.content,
    required this.likesCount,
    required this.isLikedByMe,
    required this.canDeleteByMe,
    required this.createdAt,
    required this.updatedAt,
  });

  final int commentId;
  final int postId;
  final V2PublicUser author;
  final int? parentCommentId;
  final V2PublicUser? replyToUser;
  final String content;
  final int likesCount;
  final bool isLikedByMe;
  final bool canDeleteByMe;
  final String createdAt;
  final String updatedAt;

  factory V2GroupComment.fromJson(Map<String, dynamic> json) {
    return V2GroupComment(
      commentId: toInt(json['comment_id']) ?? 0,
      postId: toInt(json['post_id']) ?? 0,
      author: V2PublicUser.fromJson(toMap(json['author'])),
      parentCommentId: toInt(json['parent_comment_id']),
      replyToUser: json['reply_to_user'] is Map<String, dynamic>
          ? V2PublicUser.fromJson(json['reply_to_user'] as Map<String, dynamic>)
          : null,
      content: toStr(json['content']),
      likesCount: toInt(json['likes_count']) ?? 0,
      isLikedByMe: toBool(json['is_liked_by_me']),
      canDeleteByMe: toBool(json['can_delete_by_me']),
      createdAt: toStr(json['created_at']),
      updatedAt: toStr(json['updated_at']),
    );
  }

  V2GroupComment copyWith({
    int? likesCount,
    bool? isLikedByMe,
  }) {
    return V2GroupComment(
      commentId: commentId,
      postId: postId,
      author: author,
      parentCommentId: parentCommentId,
      replyToUser: replyToUser,
      content: content,
      likesCount: likesCount ?? this.likesCount,
      isLikedByMe: isLikedByMe ?? this.isLikedByMe,
      canDeleteByMe: canDeleteByMe,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}
