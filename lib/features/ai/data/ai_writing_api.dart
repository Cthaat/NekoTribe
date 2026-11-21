import 'package:dio/dio.dart';

import '../../../core/constants/api_paths.dart';
import '../../../core/network/api_client.dart';
import '../../../core/utils/json_utils.dart';
import 'ai_model_version.dart';

class AiSkillAvailability {
  const AiSkillAvailability({
    required this.id,
    required this.purpose,
    required this.version,
    required this.enabled,
    this.explicitSelection = false,
  });

  final String id;
  final String purpose;
  final int version;
  final bool enabled;
  final bool explicitSelection;
}

class AiAvailability {
  const AiAvailability({
    required this.knowledge,
    required this.writing,
    this.inference,
    this.group,
    this.moderation,
    this.groupInference,
    this.moderationInference,
    this.skills = const {},
    this.modelConfigRevision,
  });

  final bool knowledge;
  final bool writing;
  final ({bool knowledge, bool writing})? inference;
  final bool? group, moderation, groupInference, moderationInference;
  final Map<String, AiSkillAvailability> skills;
  final int? modelConfigRevision;

  static const _skillIds = {
    'knowledge': 'knowledge-answer',
    'writing': 'writing-draft',
    'group': 'group-brief',
    'moderation': 'moderation-advice',
  };

  String workflowStatus({required bool forModeration}) {
    if ((forModeration ? moderation : group) == false) return 'disabled';
    if ((forModeration ? moderationInference : groupInference) == false) {
      return 'unconfigured';
    }
    return 'enabled';
  }

  static bool? _workflowFlag(Map data, String name) {
    if (!data.containsKey(name)) return null;
    final value = data[name];
    if (value is! bool) throw const FormatException('Invalid AI availability');
    return value;
  }

  static Map<String, AiSkillAvailability> _decodeSkills(
    Object? raw,
    Map<String, bool?> availability,
  ) {
    const invalid = FormatException('Invalid AI skill availability');
    if (raw is! List || raw.length != _skillIds.length) throw invalid;
    final skills = <String, AiSkillAvailability>{};
    for (final item in raw) {
      if (item is! Map<String, dynamic>) throw invalid;
      final purpose = item['purpose'];
      final id = item['id'];
      final version = item['version'];
      final enabled = item['enabled'];
      final explicitSelection = item['explicit_selection'];
      if (purpose is! String ||
          id is! String ||
          _skillIds[purpose] != id ||
          skills.containsKey(purpose) ||
          version is! num ||
          !version.isFinite ||
          version < 1 ||
          version > 9007199254740991 ||
          version != version.truncateToDouble() ||
          enabled is! bool ||
          (item.containsKey('explicit_selection') &&
              explicitSelection is! bool) ||
          availability[purpose] != enabled) {
        throw invalid;
      }
      skills[purpose] = AiSkillAvailability(
        id: id,
        purpose: purpose,
        version: version.toInt(),
        enabled: enabled,
        explicitSelection: explicitSelection == true,
      );
    }
    return Map.unmodifiable(skills);
  }

  factory AiAvailability.fromJson(Map<String, dynamic> data) {
    final knowledge = data['knowledge'], writing = data['writing'];
    if (knowledge is! bool || writing is! bool) {
      throw const FormatException('Invalid AI availability');
    }
    final group = _workflowFlag(data, 'group');
    final moderation = _workflowFlag(data, 'moderation');
    final revision = data['model_config_revision'];
    if (revision != null &&
        (revision is! num ||
            !revision.isFinite ||
            revision < 1 ||
            revision > 999999999999999 ||
            revision != revision.truncateToDouble())) {
      throw const FormatException(
        'Invalid AI availability model configuration revision',
      );
    }
    final modelConfigRevision = (revision as num?)?.toInt();
    final skills = data.containsKey('skills')
        ? _decodeSkills(data['skills'], {
            'knowledge': knowledge,
            'writing': writing,
            'group': group,
            'moderation': moderation,
          })
        : const <String, AiSkillAvailability>{};
    if (!data.containsKey('inference')) {
      return AiAvailability(
        knowledge: knowledge,
        writing: writing,
        group: group,
        moderation: moderation,
        skills: skills,
        modelConfigRevision: modelConfigRevision,
      );
    }
    final flags = data['inference'];
    if (flags is Map) {
      final modelKnowledge = flags['knowledge'],
          modelWriting = flags['writing'];
      if (modelKnowledge is bool && modelWriting is bool) {
        return AiAvailability(
          knowledge: knowledge,
          writing: writing,
          inference: (knowledge: modelKnowledge, writing: modelWriting),
          group: group,
          moderation: moderation,
          groupInference: _workflowFlag(flags, 'group'),
          moderationInference: _workflowFlag(flags, 'moderation'),
          skills: skills,
          modelConfigRevision: modelConfigRevision,
        );
      }
    }
    throw const FormatException('Invalid AI availability');
  }
}

class AiConversation {
  const AiConversation({
    required this.id,
    required this.purpose,
    required this.title,
    required this.updatedAt,
  });
  final String id;
  final String purpose;
  final String? title;
  final String updatedAt;
  factory AiConversation.fromJson(Map<String, dynamic> data) {
    final id = data['conversation_id'],
        purpose = data['purpose'],
        title = data['title'],
        updated = data['updated_at'];
    if (id is! String ||
        id.isEmpty ||
        purpose is! String ||
        (title != null && title is! String) ||
        updated is! String) {
      throw const FormatException('Invalid AI conversation');
    }
    return AiConversation(
      id: id,
      purpose: purpose,
      title: title as String?,
      updatedAt: updated,
    );
  }
}

class AiConversationPage {
  const AiConversationPage({required this.items, required this.nextCursor});
  final List<AiConversation> items;
  final String? nextCursor;
}

class AiKnowledgeCitation {
  const AiKnowledgeCitation({
    required this.kind,
    required this.id,
    this.postId,
    this.groupId,
    this.version,
  });
  final String kind;
  final int id;
  final int? postId;
  final int? groupId;
  final String? version;

  factory AiKnowledgeCitation.fromJson(Map<String, dynamic> data) {
    final kind = data['kind'],
        id = data['id'],
        version = data['version'],
        postId = data['post_id'],
        groupId = data['group_id'];
    final group = kind == 'group_post' || kind == 'group_comment';
    if ((!group && kind != 'post' && kind != 'comment' && kind != 'terms') ||
        id is! int ||
        id < 1 ||
        id > 999999999999999 ||
        version is! String ||
        version.length != 64 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(version) ||
        (postId != null &&
            (postId is! int || postId < 1 || postId > 999999999999999)) ||
        (kind == 'post' && postId != null && postId != id) ||
        (group
            ? (postId == null ||
                  groupId is! int ||
                  groupId < 1 ||
                  groupId > 999999999999999 ||
                  (kind == 'group_post' && postId != id))
            : data.containsKey('group_id')) ||
        (kind == 'terms' && (id > 8 || data.containsKey('post_id')))) {
      throw const FormatException('Invalid AI citation');
    }
    return AiKnowledgeCitation(
      kind: kind as String,
      id: id,
      postId: postId as int?,
      groupId: groupId as int?,
      version: version,
    );
  }
}

class AiWritingMessage {
  const AiWritingMessage({
    required this.id,
    required this.sequence,
    required this.role,
    required this.content,
    this.modelVersion,
    this.configRevision,
    this.citations = const [],
  });

  final String id;
  final int sequence;
  final String role;
  final String content;
  final String? modelVersion;
  final int? configRevision;
  final List<AiKnowledgeCitation> citations;

  factory AiWritingMessage.fromJson(Map<String, dynamic> json) {
    final id = json['message_id'];
    final sequence = json['sequence_no'];
    final role = json['role'];
    final content = json['content'];
    if (id is! String ||
        id.isEmpty ||
        sequence is! int ||
        sequence < 1 ||
        sequence > 9999999999 ||
        (role != 'user' && role != 'assistant') ||
        content is! String) {
      throw const FormatException('Invalid AI message');
    }
    final citations = json['citations'];
    if (citations != null && citations is! List) {
      throw const FormatException('Invalid AI citations');
    }
    return AiWritingMessage(
      id: id,
      sequence: sequence,
      role: role as String,
      content: content,
      modelVersion: aiModelVersion(role, json['model_version']),
      configRevision: aiReplyConfigRevision(role, json['config_revision']),
      citations:
          (citations as List?)
              ?.map((item) => AiKnowledgeCitation.fromJson(toMap(item)))
              .toList() ??
          const [],
    );
  }
}

class AiWritingApi {
  AiWritingApi(this._client);
  final ApiClient _client;

  Future<AiAvailability> availability() => availabilityWithCancel(null);

  Future<AiAvailability> availabilityWithCancel(CancelToken? token) =>
      _client.requestData<AiAvailability>(
        ApiPaths.aiAvailability,
        cancelToken: token,
        decode: (raw) => AiAvailability.fromJson(toMap(raw)),
      );

  Future<AiConversation> readConversation(String id) =>
      _client.requestData<AiConversation>(
        '${ApiPaths.aiConversations}/${Uri.encodeComponent(id)}',
        decode: (raw) => AiConversation.fromJson(toMap(raw)),
      );

  Future<AiConversationPage> listConversations({
    String? afterId,
    String? purpose,
  }) => _client.requestData<AiConversationPage>(
    ApiPaths.aiConversations,
    query: {
      'limit': 50,
      if (afterId != null) 'after_id': afterId,
      if (purpose != null) 'purpose': purpose,
    },
    decode: (raw) {
      final data = toMap(raw),
          items = data['items'],
          next = data['next_cursor'];
      if (items is! List ||
          (next != null && (next is! String || next.isEmpty))) {
        throw const FormatException('Invalid AI conversation page');
      }
      return AiConversationPage(
        items: items
            .map((item) => AiConversation.fromJson(toMap(item)))
            .toList(),
        nextCursor: next as String?,
      );
    },
  );

  Future<String> createConversation({String? title}) =>
      _client.requestData<String>(
        ApiPaths.aiConversations,
        method: 'POST',
        data: {'purpose': 'writing', if (title != null) 'title': title},
        decode: (data) {
          final id = toMap(data)['conversation_id'];
          if (id is! String || id.isEmpty) {
            throw const FormatException('Invalid AI conversation');
          }
          return id;
        },
      );

  Future<String> createKnowledgeConversation({String? title}) =>
      _client.requestData<String>(
        ApiPaths.aiConversations,
        method: 'POST',
        data: {'purpose': 'knowledge', if (title != null) 'title': title},
        decode: (data) {
          final id = toMap(data)['conversation_id'];
          if (id is! String || id.isEmpty) {
            throw const FormatException('Invalid AI conversation');
          }
          return id;
        },
      );

  Future<bool> generateKnowledge(
    String id, {
    String? searchPhrase,
    CancelToken? cancelToken,
    bool selectSkill = false,
    int? expectedSequence,
  }) => _client.requestData<bool>(
    '${ApiPaths.aiConversations}/${Uri.encodeComponent(id)}/knowledge-generate',
    method: 'POST',
    cancelToken: cancelToken,
    data: searchPhrase == null && !selectSkill && expectedSequence == null
        ? null
        : {
            if (searchPhrase != null) 'search_phrase': searchPhrase,
            if (selectSkill) 'skill_id': 'knowledge-answer',
            if (expectedSequence != null) 'expected_sequence': expectedSequence,
          },
    decode: (data) {
      final result = toMap(data);
      final status = result['status'];
      if (status == 'insufficient_evidence' && result['message'] == null) {
        return false;
      }
      if (status == 'generated') {
        _validateAssistantReceipt(result['message'], id, expectedSequence);
        return true;
      }
      throw const FormatException('Invalid knowledge generation result');
    },
  );

  Future<int> appendMessage(String id, String content) =>
      _client.requestData<int>(
        '${ApiPaths.aiConversations}/${Uri.encodeComponent(id)}/messages',
        method: 'POST',
        data: {'content': content},
        decode: (data) => _messageReceiptSequence(data, id, 'user'),
      );

  Future<void> generate(
    String id, {
    CancelToken? cancelToken,
    bool selectSkill = false,
    int? expectedSequence,
  }) async {
    await _client.requestData<void>(
      '${ApiPaths.aiConversations}/${Uri.encodeComponent(id)}/generate',
      method: 'POST',
      data: selectSkill || expectedSequence != null
          ? {
              if (selectSkill) 'skill_id': 'writing-draft',
              if (expectedSequence != null)
                'expected_sequence': expectedSequence,
            }
          : null,
      cancelToken: cancelToken,
      decode: (data) => _validateAssistantReceipt(data, id, expectedSequence),
    );
  }

  void _validateAssistantReceipt(
    Object? raw,
    String id,
    int? expectedSequence,
  ) {
    final sequence = _messageReceiptSequence(raw, id, 'assistant');
    if (expectedSequence != null && sequence != expectedSequence + 1) {
      throw const FormatException('Invalid AI assistant sequence');
    }
  }

  int _messageReceiptSequence(Object? raw, String id, String role) {
    final receipt = toMap(raw);
    final message = receipt['message_id'];
    final sequence = receipt['sequence_no'];
    if (receipt['conversation_id'] != id ||
        receipt['role'] != role ||
        message is! String ||
        message.isEmpty ||
        sequence is! int ||
        sequence < 1 ||
        sequence > 9999999999) {
      throw const FormatException('Invalid AI message receipt');
    }
    return sequence;
  }

  Future<void> deleteConversation(String id) async {
    await _client.request<void>(
      '${ApiPaths.aiConversations}/${Uri.encodeComponent(id)}',
      method: 'DELETE',
      decode: (_) {},
    );
  }

  Future<List<AiWritingMessage>> listMessages(
    String id, {
    int afterSequence = 0,
    int? beforeSequence,
  }) => _client.requestData<List<AiWritingMessage>>(
    '${ApiPaths.aiConversations}/${Uri.encodeComponent(id)}/messages',
    query: {
      if (beforeSequence == null) 'after_sequence': afterSequence,
      if (beforeSequence != null) 'before_sequence': beforeSequence,
      'limit': 50,
    },
    decode: (value) {
      if (value is! List || value.length > 50) {
        throw const FormatException('Invalid AI message page');
      }
      final messageIds = <String>{};
      return value.map((item) {
        final row = toMap(item);
        if (row['conversation_id'] != id) {
          throw const FormatException(
            'AI message belongs to another conversation',
          );
        }
        final message = AiWritingMessage.fromJson(row);
        if (!messageIds.add(message.id)) {
          throw const FormatException('Duplicate AI history message');
        }
        return message;
      }).toList();
    },
  );
}
