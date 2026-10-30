import '../../../core/constants/api_paths.dart';
import '../../../core/network/api_client.dart';
import '../../../core/utils/json_utils.dart';

class AiWritingMessage {
  const AiWritingMessage({
    required this.id,
    required this.sequence,
    required this.role,
    required this.content,
  });

  final String id;
  final int sequence;
  final String role;
  final String content;

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
    return AiWritingMessage(
      id: id,
      sequence: sequence,
      role: role as String,
      content: content,
    );
  }
}

class AiWritingApi {
  AiWritingApi(this._client);
  final ApiClient _client;

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
