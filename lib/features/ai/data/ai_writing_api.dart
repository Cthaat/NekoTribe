import '../../../core/constants/api_paths.dart';
import '../../../core/network/api_client.dart';
import '../../../core/utils/json_utils.dart';

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
  const AiKnowledgeCitation({required this.kind, required this.id});
  final String kind;
  final int id;

  factory AiKnowledgeCitation.fromJson(Map<String, dynamic> data) {
    final kind = data['kind'], id = data['id'], version = data['version'];
    if ((kind != 'post' && kind != 'comment') ||
        id is! int ||
        id < 1 ||
        version is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(version)) {
      throw const FormatException('Invalid AI citation');
    }
    return AiKnowledgeCitation(kind: kind as String, id: id);
  }
}

class AiWritingMessage {
  const AiWritingMessage({
    required this.id,
    required this.sequence,
    required this.role,
    required this.content,
    this.citations = const [],
  });

  final String id;
  final int sequence;
  final String role;
  final String content;
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

  Future<AiConversationPage> listConversations({String? afterId}) =>
      _client.requestData<AiConversationPage>(
        ApiPaths.aiConversations,
        query: {'limit': 50, if (afterId != null) 'after_id': afterId},
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

  Future<String> createConversation() => _client.requestData<String>(
    ApiPaths.aiConversations,
    method: 'POST',
    data: {'purpose': 'writing'},
    decode: (data) {
      final id = toMap(data)['conversation_id'];
      if (id is! String || id.isEmpty) {
        throw const FormatException('Invalid AI conversation');
      }
      return id;
    },
  );

  Future<String> createKnowledgeConversation() => _client.requestData<String>(
    ApiPaths.aiConversations,
    method: 'POST',
    data: {'purpose': 'knowledge'},
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
  }) => _client.requestData<bool>(
    '${ApiPaths.aiConversations}/${Uri.encodeComponent(id)}/knowledge-generate',
    method: 'POST',
    data: searchPhrase == null ? null : {'search_phrase': searchPhrase},
    decode: (data) {
      final result = toMap(data);
      final status = result['status'];
      if (status == 'insufficient_evidence' && result['message'] == null) {
        return false;
      }
      if (status == 'generated' && result['message'] is Map) return true;
      throw const FormatException('Invalid knowledge generation result');
    },
  );

  Future<void> appendMessage(String id, String content) async {
    await _client.request<void>(
      '${ApiPaths.aiConversations}/${Uri.encodeComponent(id)}/messages',
      method: 'POST',
      data: {'content': content},
      decode: (_) {},
    );
  }

  Future<void> generate(String id) async {
    await _client.request<void>(
      '${ApiPaths.aiConversations}/${Uri.encodeComponent(id)}/generate',
      method: 'POST',
      decode: (_) {},
    );
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
  }) => _client.requestList<AiWritingMessage>(
    '${ApiPaths.aiConversations}/${Uri.encodeComponent(id)}/messages',
    query: {'after_sequence': afterSequence, 'limit': 50},
    decodeItem: (item) => AiWritingMessage.fromJson(toMap(item)),
  );
}
