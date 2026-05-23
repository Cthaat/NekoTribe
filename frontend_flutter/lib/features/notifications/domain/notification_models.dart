import '../../../core/utils/json_utils.dart';
import '../../users/domain/user_models.dart';

class V2Notification {
  V2Notification({
    required this.notificationId,
    required this.type,
    required this.title,
    required this.message,
    this.resourceType,
    this.resourceId,
    required this.priority,
    required this.isRead,
    this.readAt,
    this.deletedAt,
    this.actor,
    this.metadata,
    required this.createdAt,
  });

  final int notificationId;
  final String type;
  final String title;
  final String message;
  final String? resourceType;
  final int? resourceId;
  final String priority;
  final int isRead;
  final String? readAt;
  final String? deletedAt;
  final V2PublicUser? actor;
  final dynamic metadata;
  final String createdAt;

  bool get readFlag => isRead == 1;
  bool get isDeleted => deletedAt != null && deletedAt!.isNotEmpty;

  factory V2Notification.fromJson(Map<String, dynamic> json) {
    return V2Notification(
      notificationId: toInt(json['notification_id']) ?? 0,
      type: toStr(json['type']),
      title: toStr(json['title']),
      message: toStr(json['message']),
      resourceType: toStrOrNull(json['resource_type']),
      resourceId: toInt(json['resource_id']),
      priority: toStr(json['priority'], defaultValue: 'normal'),
      isRead: toInt(json['is_read']) ?? 0,
      readAt: toStrOrNull(json['read_at']),
      deletedAt: toStrOrNull(json['deleted_at']),
      actor: json['actor'] is Map<String, dynamic>
          ? V2PublicUser.fromJson(json['actor'] as Map<String, dynamic>)
          : null,
      metadata: json['metadata'],
      createdAt: toStr(json['created_at']),
    );
  }

  V2Notification copyWith({
    int? isRead,
    String? readAt,
    String? deletedAt,
  }) {
    return V2Notification(
      notificationId: notificationId,
      type: type,
      title: title,
      message: message,
      resourceType: resourceType,
      resourceId: resourceId,
      priority: priority,
      isRead: isRead ?? this.isRead,
      readAt: readAt ?? this.readAt,
      deletedAt: deletedAt ?? this.deletedAt,
      actor: actor,
      metadata: metadata,
      createdAt: createdAt,
    );
  }
}
