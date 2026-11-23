import 'dart:convert';

import '../../../core/utils/json_utils.dart';
import '../../posts/domain/post_models.dart';
import '../../users/domain/user_models.dart';

class V2ChatGroup {
  V2ChatGroup({
    required this.groupId,
    required this.name,
    this.avatarUrl,
    required this.memberCount,
    required this.channelCount,
    required this.unreadCount,
    required this.role,
    required this.canManage,
  });

  final int groupId;
  final String name;
  final String? avatarUrl;
  final int memberCount;
  final int channelCount;
  final int unreadCount;
  final String role;
  final bool canManage;

  factory V2ChatGroup.fromJson(Map<String, dynamic> json) {
    final membership = toMap(json['membership']);
    return V2ChatGroup(
      groupId: toInt(json['group_id']) ?? 0,
      name: toStr(json['name']),
      avatarUrl: toStrOrNull(json['avatar_url']),
      memberCount: toInt(json['member_count']) ?? 0,
      channelCount: toInt(json['channel_count']) ?? 0,
      unreadCount: toInt(json['unread_count']) ?? 0,
      role: toStr(membership['role'], defaultValue: 'member'),
      canManage: toBool(membership['can_manage']),
    );
  }
}

class V2ChatMember {
  V2ChatMember.fromJson(Map<String, dynamic> json)
    : userId = toInt(json['user_id']) ?? 0,
      username = toStr(json['username']),
      displayName = toStr(json['display_name']),
      avatarUrl = toStrOrNull(json['avatar_url']),
      role = toStr(json['role']),
      status = toStr(json['status']),
      onlineStatus = toStr(json['online_status']),
      lastSeenAt = json['online_status'] == 'offline'
          ? DateTime.tryParse(toStr(json['last_seen_at']))
          : null;

  final int userId;
  final String username;
  final String displayName;
  final String? avatarUrl;
  final String role;
  final String status;
  final String onlineStatus;
  final DateTime? lastSeenAt;
}

class V2ChatLastMessage {
  V2ChatLastMessage({
    required this.messageId,
    required this.content,
    required this.authorName,
    required this.createdAt,
  });

  final int messageId;
  final String content;
  final String authorName;
  final String createdAt;

  factory V2ChatLastMessage.fromJson(Map<String, dynamic> json) {
    return V2ChatLastMessage(
      messageId: toInt(json['message_id']) ?? 0,
      content: toStr(json['content']),
      authorName: toStr(json['author_name']),
      createdAt: toStr(json['created_at']),
    );
  }
}

class V2ChatChannel {
  V2ChatChannel({
    required this.channelId,
    required this.groupId,
    required this.name,
    required this.type,
    required this.category,
    required this.position,
    required this.isPrivate,
    required this.isMutedByMe,
    required this.unreadCount,
    this.lastMessage,
    required this.createdAt,
    required this.updatedAt,
    required this.canManage,
  });

  final int channelId;
  final int groupId;
  final String name;
  final String type;
  final String category;
  final int position;
  final bool isPrivate;
  final bool isMutedByMe;
  final int unreadCount;
  final V2ChatLastMessage? lastMessage;
  final String createdAt;
  final String updatedAt;
  final bool canManage;

  factory V2ChatChannel.fromJson(Map<String, dynamic> json) {
    return V2ChatChannel(
      channelId: toInt(json['channel_id']) ?? 0,
      groupId: toInt(json['group_id']) ?? 0,
      name: toStr(json['name']),
      type: toStr(json['type'], defaultValue: 'text'),
      category: toStr(json['category']),
      position: toInt(json['position']) ?? 0,
      isPrivate: toBool(json['is_private']),
      isMutedByMe: toBool(json['is_muted_by_me']),
      unreadCount: toInt(json['unread_count']) ?? 0,
      lastMessage: json['last_message'] is Map<String, dynamic>
          ? V2ChatLastMessage.fromJson(
              json['last_message'] as Map<String, dynamic>,
            )
          : null,
      createdAt: toStr(json['created_at']),
      updatedAt: toStr(json['updated_at']),
      canManage: toBool(json['can_manage']),
    );
  }
}

class V2ChatReactionSummary {
  V2ChatReactionSummary({
    required this.emoji,
    required this.count,
    required this.reactedByMe,
  });

  final String emoji;
  final int count;
  final bool reactedByMe;

  factory V2ChatReactionSummary.fromJson(Map<String, dynamic> json) {
    return V2ChatReactionSummary(
      emoji: toStr(json['emoji']),
      count: toInt(json['count']) ?? 0,
      reactedByMe: toBool(json['reacted_by_me']),
    );
  }
}

class V2ChatMessageReply {
  V2ChatMessageReply({
    required this.messageId,
    required this.content,
    required this.authorName,
  });

  final int messageId;
  final String content;
  final String authorName;

  factory V2ChatMessageReply.fromJson(Map<String, dynamic> json) {
    return V2ChatMessageReply(
      messageId: toInt(json['message_id']) ?? 0,
      content: toStr(json['content']),
      authorName: toStr(json['author_name']),
    );
  }
}

class V2ChatMessage {
  V2ChatMessage({
    required this.messageId,
    required this.channelId,
    required this.groupId,
    required this.messageType,
    required this.content,
    required this.author,
    this.replyTo,
    required this.media,
    required this.reactions,
    required this.isPinned,
    required this.isDeleted,
    required this.canDelete,
    required this.canPin,
    required this.createdAt,
    required this.updatedAt,
    this.editedAt,
    this.deletedAt,
  });

  final int messageId;
  final int channelId;
  final int groupId;
  final String messageType;
  final String content;
  final V2PublicUser author;
  final V2ChatMessageReply? replyTo;
  final List<V2MediaAsset> media;
  final List<V2ChatReactionSummary> reactions;
  final bool isPinned;
  final bool isDeleted;
  final bool canDelete;
  final bool canPin;
  final String createdAt;
  final String updatedAt;
  final String? editedAt;
  final String? deletedAt;

  factory V2ChatMessage.fromJson(Map<String, dynamic> json) {
    return V2ChatMessage(
      messageId: toInt(json['message_id']) ?? 0,
      channelId: toInt(json['channel_id']) ?? 0,
      groupId: toInt(json['group_id']) ?? 0,
      messageType: toStr(json['message_type'], defaultValue: 'text'),
      content: toStr(json['content']),
      author: V2PublicUser.fromJson(toMap(json['author'])),
      replyTo: json['reply_to'] is Map<String, dynamic>
          ? V2ChatMessageReply.fromJson(
              json['reply_to'] as Map<String, dynamic>,
            )
          : null,
      media: toList(json['media'], (e) => V2MediaAsset.fromJson(toMap(e))),
      reactions: toList(
        json['reactions'],
        (e) => V2ChatReactionSummary.fromJson(toMap(e)),
      ),
      isPinned: toBool(json['is_pinned']),
      isDeleted: toBool(json['is_deleted']),
      canDelete: toBool(json['can_delete']),
      canPin: toBool(json['can_pin']),
      createdAt: toStr(json['created_at']),
      updatedAt: toStr(json['updated_at']),
      editedAt: toStrOrNull(json['edited_at']),
      deletedAt: toStrOrNull(json['deleted_at']),
    );
  }
}

class V2DirectConversation {
  V2DirectConversation({
    required this.conversationId,
    required this.participant,
    required this.unreadCount,
    this.lastMessage,
    required this.createdAt,
    required this.updatedAt,
  });

  final int conversationId;
  final V2PublicUser participant;
  final int unreadCount;
  final V2ChatLastMessage? lastMessage;
  final String createdAt;
  final String updatedAt;

  factory V2DirectConversation.fromJson(Map<String, dynamic> json) {
    return V2DirectConversation(
      conversationId: toInt(json['conversation_id']) ?? 0,
      participant: V2PublicUser.fromJson(toMap(json['participant'])),
      unreadCount: toInt(json['unread_count']) ?? 0,
      lastMessage: json['last_message'] is Map<String, dynamic>
          ? V2ChatLastMessage.fromJson(
              json['last_message'] as Map<String, dynamic>,
            )
          : null,
      createdAt: toStr(json['created_at']),
      updatedAt: toStr(json['updated_at']),
    );
  }
}

const directMessageMaxMedia = 32;
typedef V2DirectReadStatus = ({
  int conversationId,
  int? lastReadMessageId,
  int? participantLastReadMessageId,
  int unreadCount,
});

const directMessageMaxContentBytes = 4000;
final _invalidDirectEmoji = RegExp(
  r'[\u0000-\u001f\u007f\uD800-\uDFFF]',
  unicode: true,
);
final _unpairedSurrogate = RegExp(r'[\uD800-\uDFFF]', unicode: true);

bool validDirectMessageContent(String text) =>
    !_unpairedSurrogate.hasMatch(text) &&
    utf8.encode(text).length <= directMessageMaxContentBytes;

bool validDirectMessageEmoji(String emoji) =>
    emoji.isNotEmpty &&
    emoji.length <= 16 &&
    utf8.encode(emoji).length <= 32 &&
    !_invalidDirectEmoji.hasMatch(emoji);

bool _directId(Object? value) =>
    value is int && value > 0 && value <= 9007199254740991;

class V2DirectMessage {
  V2DirectMessage({
    required this.messageId,
    required this.conversationId,
    required this.content,
    required this.author,
    required this.isDeleted,
    required this.canDelete,
    required this.createdAt,
    required this.updatedAt,
    this.editedAt,
    this.deletedAt,
    this.replyTo,
    this.media = const [],
    this.reactions = const [],
  });

  final int messageId;
  final int conversationId;
  final String content;
  final V2PublicUser author;
  final bool isDeleted;
  final bool canDelete;
  final String createdAt;
  final String updatedAt;
  final String? editedAt;
  final String? deletedAt;
  final V2ChatMessageReply? replyTo;
  final List<V2MediaAsset> media;
  final List<V2ChatReactionSummary> reactions;

  V2DirectMessage withoutReply() => V2DirectMessage(
    messageId: messageId,
    conversationId: conversationId,
    content: content,
    author: author,
    isDeleted: isDeleted,
    canDelete: canDelete,
    createdAt: createdAt,
    updatedAt: updatedAt,
    editedAt: editedAt,
    deletedAt: deletedAt,
    media: media,
    reactions: reactions,
  );

  factory V2DirectMessage.fromJson(Map<String, dynamic> json) {
    return V2DirectMessage(
      messageId: toInt(json['message_id']) ?? 0,
      conversationId: toInt(json['conversation_id']) ?? 0,
      content: toStr(json['content']),
      author: V2PublicUser.fromJson(toMap(json['author'])),
      isDeleted: toBool(json['is_deleted']),
      canDelete: toBool(json['can_delete']),
      createdAt: toStr(json['created_at']),
      updatedAt: toStr(json['updated_at']),
      editedAt: toStrOrNull(json['edited_at']),
      deletedAt: toStrOrNull(json['deleted_at']),
      replyTo: json.containsKey('reply_to')
          ? _directReply(json['reply_to'], json['message_id'])
          : null,
      media: json.containsKey('media') ? _directMedia(json['media']) : const [],
      reactions: json.containsKey('reactions')
          ? _directReactions(json['reactions'])
          : const [],
    );
  }
}

V2ChatMessageReply _directReply(Object? raw, Object? messageId) {
  if (raw is! Map<String, dynamic> ||
      !_directId(raw['message_id']) ||
      raw['message_id'] == messageId ||
      raw['content'] is! String ||
      raw['author_name'] is! String) {
    throw const FormatException('Invalid direct message reply');
  }
  return V2ChatMessageReply.fromJson(raw);
}

List<V2MediaAsset> _directMedia(Object? raw) {
  const invalid = FormatException('Invalid direct message media');
  if (raw is! List<Object?> || raw.length > directMessageMaxMedia) {
    throw invalid;
  }
  final ids = <int>{};
  return List.unmodifiable(
    raw.map((item) {
      if (item is! Map<String, dynamic> || !_directId(item['media_id'])) {
        throw invalid;
      }
      final asset = V2MediaAsset.fromJson(item);
      if (asset.status != 'ready' ||
          asset.privateContentPath == null ||
          asset.thumbnailUrl != null ||
          !ids.add(asset.mediaId)) {
        throw invalid;
      }
      return asset;
    }),
  );
}

List<V2ChatReactionSummary> _directReactions(Object? raw) {
  const invalid = FormatException('Invalid direct message reactions');
  if (raw is! List<Object?>) throw invalid;
  final seen = <String>{};
  return List.unmodifiable(
    raw.map((item) {
      if (item is! Map<String, dynamic>) throw invalid;
      final emoji = item['emoji'];
      if (emoji is! String ||
          emoji != emoji.trim() ||
          !validDirectMessageEmoji(emoji) ||
          !_directId(item['count']) ||
          item['reacted_by_me'] is! bool ||
          !seen.add(emoji)) {
        throw invalid;
      }
      return V2ChatReactionSummary.fromJson(item);
    }),
  );
}
