import 'ai_stream.dart';

import 'package:dio/dio.dart';

import '../../../core/constants/api_paths.dart';
import '../../../core/network/api_client.dart';
import '../../../core/utils/json_utils.dart';
import 'ai_conversation_page.dart';
import 'ai_model_version.dart';

enum GroupDraftKind {
  weeklyReport('weekly_report'),
  faq('faq'),
  announcement('announcement'),
  activityPlan('activity_plan');

  const GroupDraftKind(this.key);
  final String key;
}

typedef GroupDraftSource = ({String kind, int id, int postId});
typedef GroupDraftMessage = ({
  String id,
  int sequence,
  String role,
  String content,
  String? modelVersion,
  int? configRevision,
  List<GroupDraftSource> sources,
  List<String> tools,
});
typedef GroupDraftConversation = ({
  String id,
  String purpose,
  int? groupId,
  String? title,
  String updatedAt,
});
typedef GroupDraftHistory = ({
  List<GroupDraftConversation> items,
  String? next,
});

final _conversationId = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
);
const _groupToolNames = {
  'public_search',
  'public_statistics',
  'community_sentiment_summary',
};
bool _validNumber(Object? value) =>
    value is int && value > 0 && value <= 9007199254740991;
bool _validConversation(Object? value) =>
    value is String && value.length == 36 && _conversationId.hasMatch(value);

GroupDraftConversation _conversation(Object? raw) {
  final data = toMap(raw);
  final id = data['conversation_id'],
      purpose = data['purpose'],
      groupId = data['group_id'],
      title = data['title'],
      updatedAt = data['updated_at'];
  if (!_validConversation(id) ||
      purpose is! String ||
      (groupId != null && !_validNumber(groupId)) ||
      (title != null && title is! String) ||
      updatedAt is! String) {
    throw const FormatException('Invalid AI group conversation');
  }
  return (
    id: id as String,
    purpose: purpose,
    groupId: groupId as int?,
    title: title as String?,
    updatedAt: updatedAt,
  );
}

GroupDraftSource _source(Object? raw) {
  final data = toMap(raw);
  final kind = data['kind'], id = data['source_id'], postId = data['post_id'];
  if ((kind != 'post' && kind != 'comment') ||
      !_validNumber(id) ||
      !_validNumber(postId) ||
      (kind == 'post' && id != postId)) {
    throw const FormatException('Invalid AI group source');
  }
  return (kind: kind as String, id: id as int, postId: postId as int);
}

GroupDraftMessage _message(Object? raw, String conversationId) {
  final data = toMap(raw);
  final id = data['message_id'],
      sequence = data['sequence_no'],
      role = data['role'],
      content = data['content'],
      sources = data['group_sources'],
      tools = data['group_tools'];
  if (data['conversation_id'] != conversationId ||
      id is! String ||
      id.isEmpty ||
      sequence is! int ||
      sequence < 1 ||
      sequence > 9999999999 ||
      role is! String ||
      content is! String ||
      (sources != null && (sources is! List || sources.length > 8))) {
    throw const FormatException('Invalid AI group message');
  }
  if (data.containsKey('group_tools') &&
      (role != 'assistant' ||
          sources is! List ||
          sources.isEmpty ||
          tools is! List ||
          tools.length > _groupToolNames.length ||
          !tools.contains('public_search') ||
          tools.toSet().length != tools.length ||
          !tools.every(_groupToolNames.contains))) {
    throw const FormatException('Invalid AI group tools');
  }
  return (
    id: id,
    sequence: sequence,
    role: role,
    content: content,
    modelVersion: aiModelVersion(role, data['model_version']),
    configRevision: aiReplyConfigRevision(role, data['config_revision']),
    sources: (sources as List<Object?>?)?.map(_source).toList() ?? const [],
    tools: (tools as List<Object?>?)?.cast<String>().toList() ?? const [],
  );
}

class AiGroupDraftApi {
  AiGroupDraftApi(this._client);
  final ApiClient _client;

  static String _path(String id) =>
      '${ApiPaths.aiConversations}/${Uri.encodeComponent(id)}';

  Future<GroupDraftHistory> history(
    int groupId,
    String? after,
    CancelToken cancel,
  ) => _client.requestData<GroupDraftHistory>(
    ApiPaths.aiConversations,
    query: {
      'limit': 50,
      'purpose': 'group',
      'group_id': groupId,
      if (after != null) 'after_id': after,
    },
    cancelToken: cancel,
    decode: (raw) {
      final data = toMap(raw),
          items = data['items'],
          next = data['next_cursor'];
      if (items is! List || items.length > 50) {
        throw const FormatException('Invalid AI group history');
      }
      final entries = items.map(_conversation).toList();
      return (
        items: entries,
        next: validateAiConversationPage(
          entries.map((item) => item.id),
          after,
          next,
        ),
      );
    },
  );

  Future<GroupDraftConversation> create(int groupId, CancelToken cancel) =>
      _client.requestData<GroupDraftConversation>(
        ApiPaths.aiConversations,
        method: 'POST',
        data: {'purpose': 'group', 'group_id': groupId},
        cancelToken: cancel,
        decode: (raw) {
          final entry = _conversation(raw);
          if (entry.purpose != 'group' || entry.groupId != groupId) {
            throw const FormatException('Invalid AI group scope');
          }
          return entry;
        },
      );

  Future<List<GroupDraftMessage>> messages(
    String id,
    int after,
    int limit,
    CancelToken cancel, {
    int? before,
  }) => _client.requestData<List<GroupDraftMessage>>(
    '${_path(id)}/messages',
    query: {
      if (before == null)
        'after_sequence': after
      else
        'before_sequence': before,
      'limit': limit,
    },
    cancelToken: cancel,
    decode: (raw) {
      if (raw is! List || raw.length > limit) {
        throw const FormatException('Invalid AI group messages');
      }
      final entries = raw.map((row) => _message(row, id)).toList();
      final ids = <String>{};
      var previous = after;
      for (final entry in entries) {
        if (!ids.add(entry.id) ||
            entry.sequence <= previous ||
            (before != null && entry.sequence >= before)) {
          throw const FormatException('Invalid AI history page');
        }
        previous = entry.sequence;
      }
      return entries;
    },
  );

  Future<void> remove(String id, CancelToken cancel) async {
    await _client.request<void>(
      _path(id),
      method: 'DELETE',
      cancelToken: cancel,
      decode: (data) {
        if (data != null) throw const FormatException('Invalid delete receipt');
      },
    );
  }

  Future<bool> generate(
    String id,
    GroupDraftKind kind,
    int sequence,
    CancelToken cancel, {
    bool explicitlySelectGroupBrief = false,
    String? searchTerm,
    void Function(String)? onDelta,
  }) => generateAiData<bool>(
    _client,
    '${_path(id)}/group-generate',
    method: 'POST',
    data: {
      'kind': kind.key,
      'expected_sequence': sequence,
      if (explicitlySelectGroupBrief) 'skill_id': 'group-brief',
      if (searchTerm != null) 'search_term': searchTerm,
    },
    cancelToken: cancel,
    onDelta: onDelta,
    decode: (raw) {
      final data = toMap(raw);
      if (data['status'] == 'insufficient_evidence' &&
          data['message'] == null) {
        return false;
      }
      final receipt = toMap(data['message']);
      final messageId = receipt['message_id'];
      if (data['status'] == 'generated' &&
          messageId is String &&
          messageId.isNotEmpty &&
          receipt['conversation_id'] == id &&
          receipt['sequence_no'] == sequence + 1 &&
          receipt['role'] == 'assistant') {
        return true;
      }
      throw const FormatException('Invalid AI group generation receipt');
    },
  );
}
