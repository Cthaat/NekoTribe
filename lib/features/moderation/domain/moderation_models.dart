import '../../../core/utils/json_utils.dart';
import '../../posts/domain/post_models.dart';
import '../../users/domain/user_models.dart';

class V2ModerationStats {
  V2ModerationStats({
    required this.pending,
    required this.approved,
    required this.rejected,
    required this.flagged,
    required this.todayProcessed,
    required this.avgProcessMinutes,
    required this.openReports,
    required this.appealSuccessRate,
  });

  final int pending;
  final int approved;
  final int rejected;
  final int flagged;
  final int todayProcessed;
  final double avgProcessMinutes;
  final int openReports;
  final double appealSuccessRate;

  factory V2ModerationStats.fromJson(Map<String, dynamic> json) {
    return V2ModerationStats(
      pending: toInt(json['pending']) ?? 0,
      approved: toInt(json['approved']) ?? 0,
      rejected: toInt(json['rejected']) ?? 0,
      flagged: toInt(json['flagged']) ?? 0,
      todayProcessed: toInt(json['today_processed']) ?? 0,
      avgProcessMinutes: toDouble(json['avg_process_minutes']) ?? 0,
      openReports: toInt(json['open_reports']) ?? 0,
      appealSuccessRate: toDouble(json['appeal_success_rate']) ?? 0,
    );
  }
}

class V2ModerationReport {
  V2ModerationReport({
    required this.reportId,
    required this.targetType,
    required this.targetId,
    this.reporter,
    required this.reason,
    required this.description,
    this.evidenceUrl,
    required this.status,
    required this.priority,
    this.handledBy,
    required this.createdAt,
    required this.updatedAt,
    this.resolvedAt,
  });

  final int reportId;
  final String targetType;
  final int targetId;
  final V2PublicUser? reporter;
  final String reason;
  final String description;
  final String? evidenceUrl;
  final String status;
  final String priority;
  final V2PublicUser? handledBy;
  final String createdAt;
  final String updatedAt;
  final String? resolvedAt;

  factory V2ModerationReport.fromJson(Map<String, dynamic> json) {
    return V2ModerationReport(
      reportId: toInt(json['report_id']) ?? 0,
      targetType: toStr(json['target_type']),
      targetId: toInt(json['target_id']) ?? 0,
      reporter: json['reporter'] is Map<String, dynamic>
          ? V2PublicUser.fromJson(json['reporter'] as Map<String, dynamic>)
          : null,
      reason: toStr(json['reason']),
      description: toStr(json['description']),
      evidenceUrl: toStrOrNull(json['evidence_url']),
      status: toStr(json['status']),
      priority: toStr(json['priority'], defaultValue: 'normal'),
      handledBy: json['handled_by'] is Map<String, dynamic>
          ? V2PublicUser.fromJson(json['handled_by'] as Map<String, dynamic>)
          : null,
      createdAt: toStr(json['created_at']),
      updatedAt: toStr(json['updated_at']),
      resolvedAt: toStrOrNull(json['resolved_at']),
    );
  }
}

class V2ModerationContentItem {
  V2ModerationContentItem({
    required this.caseId,
    required this.postId,
    required this.content,
    required this.author,
    required this.media,
    required this.reportCount,
    required this.reportReasons,
    required this.reports,
    required this.status,
    required this.priority,
    this.assignedTo,
    required this.createdAt,
    required this.updatedAt,
    required this.reportedAt,
    required this.likesCount,
    required this.retweetsCount,
    required this.repliesCount,
  });

  final int caseId;
  final int postId;
  final String content;
  final V2PublicUser author;
  final List<V2MediaAsset> media;
  final int reportCount;
  final List<String> reportReasons;
  final List<V2ModerationReport> reports;
  final String status;
  final String priority;
  final V2PublicUser? assignedTo;
  final String createdAt;
  final String updatedAt;
  final String reportedAt;
  final int likesCount;
  final int retweetsCount;
  final int repliesCount;

  factory V2ModerationContentItem.fromJson(Map<String, dynamic> json) {
    return V2ModerationContentItem(
      caseId: toInt(json['case_id']) ?? 0,
      postId: toInt(json['post_id']) ?? 0,
      content: toStr(json['content']),
      author: V2PublicUser.fromJson(toMap(json['author'])),
      media: toList(json['media'], (e) => V2MediaAsset.fromJson(toMap(e))),
      reportCount: toInt(json['report_count']) ?? 0,
      reportReasons: toList(json['report_reasons'], (e) => toStr(e)),
      reports: toList(
        json['reports'],
        (e) => V2ModerationReport.fromJson(toMap(e)),
      ),
      status: toStr(json['status']),
      priority: toStr(json['priority'], defaultValue: 'normal'),
      assignedTo: json['assigned_to'] is Map<String, dynamic>
          ? V2PublicUser.fromJson(json['assigned_to'] as Map<String, dynamic>)
          : null,
      createdAt: toStr(json['created_at']),
      updatedAt: toStr(json['updated_at']),
      reportedAt: toStr(json['reported_at']),
      likesCount: toInt(json['likes_count']) ?? 0,
      retweetsCount: toInt(json['retweets_count']) ?? 0,
      repliesCount: toInt(json['replies_count']) ?? 0,
    );
  }
}

class V2ModerationUserItem {
  V2ModerationUserItem({
    required this.userId,
    required this.username,
    required this.displayName,
    required this.avatarUrl,
    required this.email,
    required this.status,
    required this.isActive,
    required this.isVerified,
    required this.followersCount,
    required this.postsCount,
    required this.likesCount,
    required this.reportCount,
    this.activeRestriction,
    this.restrictionUntil,
    required this.createdAt,
    required this.updatedAt,
  });

  final int userId;
  final String username;
  final String displayName;
  final String avatarUrl;
  final String email;
  final String status;
  final int isActive;
  final int isVerified;
  final int followersCount;
  final int postsCount;
  final int likesCount;
  final int reportCount;
  final String? activeRestriction;
  final String? restrictionUntil;
  final String createdAt;
  final String updatedAt;

  factory V2ModerationUserItem.fromJson(Map<String, dynamic> json) {
    return V2ModerationUserItem(
      userId: toInt(json['user_id']) ?? 0,
      username: toStr(json['username']),
      displayName: toStr(json['display_name']),
      avatarUrl: toStr(json['avatar_url']),
      email: toStr(json['email']),
      status: toStr(json['status']),
      isActive: toInt(json['is_active']) ?? 1,
      isVerified: toInt(json['is_verified']) ?? 0,
      followersCount: toInt(json['followers_count']) ?? 0,
      postsCount: toInt(json['posts_count']) ?? 0,
      likesCount: toInt(json['likes_count']) ?? 0,
      reportCount: toInt(json['report_count']) ?? 0,
      activeRestriction: toStrOrNull(json['active_restriction']),
      restrictionUntil: toStrOrNull(json['restriction_until']),
      createdAt: toStr(json['created_at']),
      updatedAt: toStr(json['updated_at']),
    );
  }
}

class V2ModerationSetting {
  V2ModerationSetting({
    required this.key,
    required this.value,
    required this.valueType,
    required this.label,
    required this.description,
    required this.updatedAt,
  });

  final String key;
  final String value;
  final String valueType;
  final String label;
  final String description;
  final String updatedAt;

  V2ModerationSetting copyWith({
    String? key,
    String? value,
    String? valueType,
    String? label,
    String? description,
    String? updatedAt,
  }) {
    return V2ModerationSetting(
      key: key ?? this.key,
      value: value ?? this.value,
      valueType: valueType ?? this.valueType,
      label: label ?? this.label,
      description: description ?? this.description,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory V2ModerationSetting.fromJson(Map<String, dynamic> json) {
    return V2ModerationSetting(
      key: toStr(json['key']),
      value: toStr(json['value']),
      valueType: toStr(json['value_type'], defaultValue: 'string'),
      label: toStr(json['label']),
      description: toStr(json['description']),
      updatedAt: toStr(json['updated_at']),
    );
  }
}

class V2ModerationAppeal {
  V2ModerationAppeal({
    required this.appealId,
    required this.statementId,
    required this.user,
    required this.appealMessage,
    required this.appealStatus,
    required this.adminResponse,
    required this.createdAt,
    required this.updatedAt,
  });

  final int appealId;
  final int statementId;
  final V2PublicUser user;
  final String appealMessage;
  final String appealStatus;
  final String adminResponse;
  final String createdAt;
  final String updatedAt;

  factory V2ModerationAppeal.fromJson(Map<String, dynamic> json) {
    return V2ModerationAppeal(
      appealId: toInt(json['appeal_id']) ?? 0,
      statementId: toInt(json['statement_id']) ?? 0,
      user: V2PublicUser.fromJson(toMap(json['user'])),
      appealMessage: toStr(json['appeal_message']),
      appealStatus: toStr(json['appeal_status']),
      adminResponse: toStr(json['admin_response']),
      createdAt: toStr(json['created_at']),
      updatedAt: toStr(json['updated_at']),
    );
  }
}
