import '../../../core/constants/api_paths.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_response.dart';
import '../../../core/utils/json_utils.dart';
import '../domain/chat_models.dart';

class ChatApi {
  ChatApi(this._client);

  final ApiClient _client;

  Future<List<V2ChatGroup>> listChatGroups() {
    return _client.requestData<List<V2ChatGroup>>(
      ApiPaths.chatGroups,
      decode: (data) {
        final map = toMap(data);
        return toList(
          map['items'],
          (e) => V2ChatGroup.fromJson(toMap(e)),
        );
      },
    );
  }

  Future<List<V2ChatChannel>> listChannels(int groupId) {
    return _client.requestData<List<V2ChatChannel>>(
      '${ApiPaths.chatGroups}/$groupId/channels',
      decode: (data) {
        final map = toMap(data);
        return toList(
          map['items'],
          (e) => V2ChatChannel.fromJson(toMap(e)),
        );
      },
    );
  }

  Future<V2ChatChannel> createChannel({
    required int groupId,
    required String name,
    String type = 'text',
    String? category,
    bool isPrivate = false,
  }) {
    return _client.requestData<V2ChatChannel>(
      '${ApiPaths.chatGroups}/$groupId/channels',
      method: 'POST',
      data: {
        'name': name,
        'type': type,
        if (category != null) 'category': category,
        'is_private': isPrivate,
      },
      decode: (data) => V2ChatChannel.fromJson(toMap(data)),
    );
  }

  Future<PagedResult<V2ChatMessage>> listMessages({
    required int channelId,
    int page = 1,
    int size = 30,
    int? beforeMessageId,
  }) {
    final query = <String, dynamic>{
      'page': page,
      'size': size,
    };
    if (beforeMessageId != null) query['before'] = beforeMessageId;
    return _client.requestData<PagedResult<V2ChatMessage>>(
      '${ApiPaths.chatChannels}/$channelId/messages',
      query: query,
      decode: (data) {
        final map = toMap(data);
        final items = toList(
          map['items'],
          (e) => V2ChatMessage.fromJson(toMap(e)),
        );
        final meta = map['meta'] is Map<String, dynamic>
            ? ApiMeta.fromJson(map['meta'] as Map<String, dynamic>)
            : null;
        return PagedResult<V2ChatMessage>(items: items, meta: meta);
      },
    );
  }

  Future<V2ChatMessage> sendChannelMessage({
    required int channelId,
    required String content,
    int? replyToMessageId,
    List<int> mediaIds = const [],
    String messageType = 'text',
  }) {
    return _client.requestData<V2ChatMessage>(
      '${ApiPaths.chatChannels}/$channelId/messages',
      method: 'POST',
      data: {
        'content': content,
        'message_type': messageType,
        if (replyToMessageId != null) 'reply_to_message_id': replyToMessageId,
        if (mediaIds.isNotEmpty) 'media_ids': mediaIds,
      },
      decode: (data) => V2ChatMessage.fromJson(toMap(data)),
    );
  }

  Future<V2ChatMessage> editMessage({
    required int messageId,
    required String content,
  }) {
    return _client.requestData<V2ChatMessage>(
      '${ApiPaths.chatMessages}/$messageId',
      method: 'PATCH',
      data: {'content': content},
      decode: (data) => V2ChatMessage.fromJson(toMap(data)),
    );
  }

  Future<void> deleteMessage(int messageId) async {
    await _client.request<void>(
      '${ApiPaths.chatMessages}/$messageId',
      method: 'DELETE',
      decode: (_) {},
    );
  }

  Future<void> reactMessage({
    required int messageId,
    required String emoji,
  }) async {
    await _client.request<void>(
      '${ApiPaths.chatMessages}/$messageId/reactions',
      method: 'PUT',
      data: {'emoji': emoji},
      decode: (_) {},
    );
  }

  Future<void> unreactMessage({
    required int messageId,
    required String emoji,
  }) async {
    await _client.request<void>(
      '${ApiPaths.chatMessages}/$messageId/reactions',
      method: 'DELETE',
      data: {'emoji': emoji},
      decode: (_) {},
    );
  }

  Future<void> pinMessage(int messageId) async {
    await _client.request<void>(
      '${ApiPaths.chatMessages}/$messageId/pin',
      method: 'PUT',
      decode: (_) {},
    );
  }

  Future<void> unpinMessage(int messageId) async {
    await _client.request<void>(
      '${ApiPaths.chatMessages}/$messageId/pin',
      method: 'DELETE',
      decode: (_) {},
    );
  }

  Future<List<V2DirectConversation>> listConversations() {
    return _client.requestData<List<V2DirectConversation>>(
      ApiPaths.chatDirectConversations,
      decode: (data) {
        final map = toMap(data);
        return toList(
          map['items'],
          (e) => V2DirectConversation.fromJson(toMap(e)),
        );
      },
    );
  }

  Future<V2DirectConversation> openConversation({required int userId}) {
    return _client.requestData<V2DirectConversation>(
      ApiPaths.chatDirectConversations,
      method: 'POST',
      data: {'user_id': userId},
      decode: (data) => V2DirectConversation.fromJson(toMap(data)),
    );
  }

  Future<PagedResult<V2DirectMessage>> listDirectMessages({
    required int conversationId,
    int page = 1,
    int size = 30,
    int? beforeMessageId,
  }) {
    final query = <String, dynamic>{
      'page': page,
      'size': size,
    };
    if (beforeMessageId != null) query['before'] = beforeMessageId;
    return _client.requestData<PagedResult<V2DirectMessage>>(
      '${ApiPaths.chatDirectConversations}/$conversationId/messages',
      query: query,
      decode: (data) {
        final map = toMap(data);
        final items = toList(
          map['items'],
          (e) => V2DirectMessage.fromJson(toMap(e)),
        );
        final meta = map['meta'] is Map<String, dynamic>
            ? ApiMeta.fromJson(map['meta'] as Map<String, dynamic>)
            : null;
        return PagedResult<V2DirectMessage>(items: items, meta: meta);
      },
    );
  }

  Future<V2DirectMessage> sendDirectMessage({
    required int conversationId,
    required String content,
  }) {
    return _client.requestData<V2DirectMessage>(
      '${ApiPaths.chatDirectConversations}/$conversationId/messages',
      method: 'POST',
      data: {'content': content},
      decode: (data) => V2DirectMessage.fromJson(toMap(data)),
    );
  }
}
