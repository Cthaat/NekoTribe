import 'dart:convert';

import '../../../core/utils/json_utils.dart';
import 'post_markdown.dart';
import 'post_poll.dart';

enum PostDraftStatus { draft, scheduled, failed, published }

class V2PostDraftInput {
  const V2PostDraftInput({
    this.groupId,
    required this.content,
    this.visibility = 'public',
    this.mediaIds = const [],
    this.tags = const [],
    this.mentionUserIds = const [],
    this.location = '',
    this.mediaUrls = const [],
    this.announcement = false,
    this.poll,
    this.markdown,
  });

  final int? groupId;
  final String content;
  final String visibility;
  final List<int> mediaIds;
  final List<String> tags;
  final List<int> mentionUserIds;
  final String location;
  final List<String> mediaUrls;
  final bool announcement;
  final V2CreatePostPoll? poll;
  final String? markdown;

  bool get canSave =>
      utf8.encode(content).length <= 4000 &&
      utf8.encode(location).length <= 100 &&
      (markdown == null || isValidPostMarkdown(markdown!)) &&
      (poll?.hasValidOptions ?? true);

  bool get canPublish =>
      canSave &&
      (poll?.isValid ?? true) &&
      (content.trim().isNotEmpty || (groupId == null && mediaIds.isNotEmpty));

  Map<String, Object?> toJson() => {
    'group_id': groupId,
    'content': content,
    if (groupId == null) ...{
      'visibility': visibility,
      if (mediaIds.isNotEmpty) 'media_ids': mediaIds,
      if (tags.isNotEmpty) 'tag_names': tags,
      if (mentionUserIds.isNotEmpty) 'mention_user_ids': mentionUserIds,
      if (location.isNotEmpty) 'location': location,
    } else ...{
      if (mediaUrls.isNotEmpty) 'media_urls': mediaUrls,
      'is_announcement': announcement,
    },
    if (poll != null) 'poll': poll!.toJson(),
    if (markdown != null) 'markdown': markdown,
  };

  bool matches(V2PostDraftInput other) =>
      jsonEncode(toJson()) == jsonEncode(other.toJson());

  factory V2PostDraftInput.fromJson(Map<String, dynamic> data) {
    final group = data['group_id'];
    final content = data['content'];
    if (!data.containsKey('group_id') ||
        (group != null && !V2PostDraft.validId(group)) ||
        content is! String) {
      throw const FormatException('Invalid post draft payload');
    }

    List<T> values<T>(String key) {
      final value = data[key];
      if (value == null) return <T>[];
      if (value is! List || value.any((item) => item is! T)) {
        throw const FormatException('Invalid post draft field');
      }
      return List<T>.unmodifiable(value.cast<T>());
    }

    final rawPoll = data['poll'];
    final markdown = readPostMarkdown(data['markdown']);
    if (data['markdown'] != null && markdown == null) {
      throw const FormatException('Invalid post draft Markdown');
    }
    V2CreatePostPoll? poll;
    if (rawPoll != null) {
      final input = toMap(rawPoll);
      final deadline = toDateTime(input['closes_at']);
      final multiple = input['multiple'];
      final options = input['options'];
      if (deadline == null ||
          multiple is! bool ||
          options is! List ||
          options.any((item) => item is! String)) {
        throw const FormatException('Invalid post draft poll');
      }
      poll = V2CreatePostPoll(
        options: List<String>.unmodifiable(options.cast<String>()),
        multiple: multiple,
        closesAt: deadline,
      );
    }

    return V2PostDraftInput(
      groupId: group as int?,
      content: content,
      visibility: toStr(data['visibility'], defaultValue: 'public'),
      mediaIds: values<int>('media_ids'),
      tags: values<String>('tag_names'),
      mentionUserIds: values<int>('mention_user_ids'),
      location: toStr(data['location']),
      mediaUrls: values<String>('media_urls'),
      announcement: toBool(data['is_announcement']),
      poll: poll,
      markdown: markdown,
    );
  }
}

class V2PostDraft {
  const V2PostDraft({
    required this.id,
    required this.payload,
    required this.status,
    required this.scheduledAt,
    required this.publishedPostId,
    required this.lastError,
    required this.updatedAt,
  });

  final int id;
  final V2PostDraftInput payload;
  final PostDraftStatus status;
  final DateTime? scheduledAt;
  final int? publishedPostId;
  final String? lastError;
  final DateTime updatedAt;

  static bool validId(Object? id) =>
      id is int && id > 0 && id <= 9007199254740991;

  factory V2PostDraft.fromJson(Map<String, dynamic> data) {
    final id = data['draft_id'];
    final status = PostDraftStatus.values.asNameMap()[data['status']];
    final updated = toDateTime(data['updated_at']);
    final scheduled = toDateTime(data['scheduled_at']);
    final postId = data['published_post_id'];
    final error = data['last_error'];
    if (!validId(id) ||
        status == null ||
        updated == null ||
        (status == PostDraftStatus.scheduled && scheduled == null) ||
        (status == PostDraftStatus.published && !validId(postId)) ||
        (postId != null && !validId(postId)) ||
        (error != null &&
            error != 'permission_denied' &&
            error != 'content_unavailable')) {
      throw const FormatException('Invalid post draft response');
    }
    return V2PostDraft(
      id: id as int,
      payload: V2PostDraftInput.fromJson(toMap(data['payload'])),
      status: status,
      scheduledAt: scheduled,
      publishedPostId: postId as int?,
      lastError: error as String?,
      updatedAt: updated,
    );
  }
}
