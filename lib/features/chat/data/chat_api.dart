import '../../../core/constants/api_paths.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_response.dart';
import '../../../core/utils/json_utils.dart';
import '../domain/chat_models.dart';

class ChatApi {
  ChatApi(this._client);

  final ApiClient _client;

  Future<PagedResult<V2ChatGroup>> listChatGroups({int page = 1}) {
    return _client.requestPaged<V2ChatGroup>(
      ApiPaths.chatGroups,
      query: {'page': page, 'page_size': 20},
      decodeItem: (item) => V2ChatGroup.fromJson(toMap(item)),
    );
  }

  Future<List<V2ChatChannel>> listChannels(int groupId) {
    return _client.requestData<List<V2ChatChannel>>(
      '${ApiPaths.chatGroups}/$groupId/channels',
      decode: (data) {
        if (data is! List<Object?>) {
          throw const FormatException('Invalid chat channel list');
        }
        final ids = <int>{};
        return data.map((item) {
          final channel = _confirmChannel(item, groupId: groupId);
          if (!ids.add(channel.channelId)) {
            throw const FormatException('Invalid chat channel list');
          }
          return channel;
        }).toList();
      },
    );
  }

  Future<List<V2ChatMember>> listMembers(int groupId) {
    return _client.requestList<V2ChatMember>(
      '${ApiPaths.chatGroups}/$groupId/members',
      decodeItem: (item) => V2ChatMember.fromJson(toMap(item)),
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
      decode: (data) => _confirmChannel(data, groupId: groupId),
    );
  }

  Future<V2ChatChannel> updateChannel({
    required int channelId,
    String? name,
    String? category,
    bool? isPrivate,
  }) {
    return _client.requestData<V2ChatChannel>(
      '${ApiPaths.chatChannels}/$channelId',
      method: 'PATCH',
      data: {
        if (name != null) 'name': name,
        if (category != null) 'category': category,
        if (isPrivate != null) 'is_private': isPrivate,
      },
      decode: (data) => _confirmChannel(data, channelId: channelId),
    );
  }

  Future<void> deleteChannel(int channelId) async {
    await _client.request<void>(
      '${ApiPaths.chatChannels}/$channelId',
      method: 'DELETE',
      decode: (_) {},
      validateSuccessEnvelope: (value) {
        if (value is! Map<String, Object?> ||
            value['code'] != 200 ||
            value['message'] != 'chat channel deleted' ||
            !value.containsKey('data') ||
            value['data'] != null ||
            !value.containsKey('meta') ||
            value['meta'] != null) {
          throw const FormatException('Invalid chat channel delete response');
        }
      },
    );
  }

  V2ChatChannel _confirmChannel(Object? data, {int? groupId, int? channelId}) {
    final channel = toMap(data);
    final id = channel['channel_id'];
    final group = channel['group_id'];
    if (id is! int ||
        id <= 0 ||
        id > 9007199254740991 ||
        group is! int ||
        group <= 0 ||
        group > 9007199254740991 ||
        (groupId != null && group != groupId) ||
        (channelId != null && id != channelId)) {
      throw const FormatException('Invalid chat channel write response');
    }
    return V2ChatChannel.fromJson(channel);
  }

  Future<PagedResult<V2ChatMessage>> listMessages({
    required int channelId,
    int page = 1,
    int size = 30,
    String? search,
    // Kept for API compatibility; server pagination is page/page_size only
    // and ignores `before`. Prefer page-based history loading in screens.
    int? beforeMessageId,
  }) {
    const invalid = FormatException('Invalid channel message history response');
    return _readChatPage<V2ChatMessage>(
      '${ApiPaths.chatChannels}/$channelId/messages',
      page: page,
      size: size,
      filters: {
        if (beforeMessageId != null) 'before': beforeMessageId,
        if (search != null && search.isNotEmpty) 'q': search,
      },
      invalid: invalid,
      idOf: (message) => message.messageId,
      decodeItem: (item) {
        final message = toMap(item);
        if (message['channel_id'] is! int ||
            message['channel_id'] != channelId ||
            !_safeId(message['message_id']) ||
            !_safeId(message['group_id']) ||
            message['is_deleted'] != false) {
          throw invalid;
        }
        return V2ChatMessage.fromJson(message);
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
      decode: (data) {
        final receipt = toMap(data);
        if (receipt['content'] != content.trim()) {
          throw const FormatException('Invalid chat message edit response');
        }
        return _confirmMessageMutation(messageId, receipt);
      },
    );
  }

  Future<void> deleteMessage(int messageId) async {
    await _client.request<void>(
      '${ApiPaths.chatMessages}/$messageId',
      method: 'DELETE',
      decode: (_) {},
      validateSuccessEnvelope: (value) {
        if (value is! Map<String, Object?> ||
            value['code'] != 200 ||
            value['message'] != 'chat message deleted' ||
            !value.containsKey('data') ||
            value['data'] != null ||
            !value.containsKey('meta') ||
            value['meta'] != null) {
          throw const FormatException('Invalid chat message delete response');
        }
      },
    );
  }

  Future<V2ChatMessage> reactMessage({
    required int messageId,
    required String emoji,
  }) => _setMessageReaction(messageId, emoji, true);

  Future<V2ChatMessage> unreactMessage({
    required int messageId,
    required String emoji,
  }) => _setMessageReaction(messageId, emoji, false);

  Future<V2ChatMessage> _setMessageReaction(
    int messageId,
    String emoji,
    bool reacted,
  ) {
    return _client.requestData<V2ChatMessage>(
      '${ApiPaths.chatMessages}/$messageId/reactions',
      method: reacted ? 'POST' : 'DELETE',
      data: {'emoji': emoji},
      decode: (data) {
        final receipt = toMap(data);
        final reactions = receipt['reactions'];
        if (reactions is! List<Object?>) {
          throw const FormatException('Invalid chat reaction response');
        }
        final emojis = <String>{};
        var targetReacted = false;
        for (final entry in reactions) {
          final reaction = toMap(entry);
          final symbol = reaction['emoji'];
          final selected = reaction['reacted_by_me'];
          if (symbol is! String ||
              symbol.isEmpty ||
              !emojis.add(symbol) ||
              !_safeId(reaction['count']) ||
              selected is! bool) {
            throw const FormatException('Invalid chat reaction response');
          }
          if (symbol == emoji.trim()) targetReacted = selected;
        }
        if (targetReacted != reacted) {
          throw const FormatException('Invalid chat reaction response');
        }
        return _confirmMessageMutation(messageId, receipt);
      },
    );
  }

  Future<V2ChatMessage> pinMessage(int messageId) =>
      _setMessagePinStatus(messageId, true);

  Future<V2ChatMessage> unpinMessage(int messageId) =>
      _setMessagePinStatus(messageId, false);

  Future<V2ChatMessage> _setMessagePinStatus(int messageId, bool isPinned) {
    return _client.requestData<V2ChatMessage>(
      '${ApiPaths.chatMessages}/$messageId/pin-status',
      method: 'PUT',
      data: {'is_pinned': isPinned},
      decode: (data) {
        final receipt = toMap(data);
        if (receipt['is_pinned'] != isPinned) {
          throw const FormatException('Invalid chat message pin response');
        }
        return _confirmMessageMutation(messageId, receipt);
      },
    );
  }

  V2ChatMessage _confirmMessageMutation(
    int messageId,
    Map<String, Object?> receipt,
  ) {
    if (!_safeId(receipt['message_id']) ||
        receipt['message_id'] != messageId ||
        !_safeId(receipt['channel_id']) ||
        !_safeId(receipt['group_id']) ||
        receipt['is_deleted'] != false) {
      throw const FormatException('Invalid chat message response');
    }
    return V2ChatMessage.fromJson(receipt);
  }

  Future<void> setChannelReadStatus({
    required int channelId,
    int? lastReadMessageId,
  }) async {
    await _client.request<void>(
      '${ApiPaths.chatChannels}/$channelId/read-status',
      method: 'PUT',
      data: {'last_read_message_id': lastReadMessageId},
      decode: (_) {},
    );
  }

  Future<bool> setChannelMuteStatus({
    required int channelId,
    required bool isMuted,
  }) {
    return _client.requestData<bool>(
      '${ApiPaths.chatChannels}/$channelId/mute-status',
      method: 'PUT',
      data: {'is_muted': isMuted},
      decode: (data) {
        final receipt = toMap(data);
        final confirmed = receipt['is_muted'];
        if (receipt['channel_id'] is! int ||
            receipt['channel_id'] != channelId ||
            confirmed is! bool) {
          throw const FormatException('Invalid channel mute acknowledgement');
        }
        return confirmed;
      },
    );
  }

  Future<PagedResult<V2DirectConversation>> listConversations({int page = 1}) =>
      _readDirectConversations(page: page, size: 20);

  Future<V2DirectConversation?> getDirectConversation(
    int conversationId,
  ) async {
    if (!_safeId(conversationId)) {
      throw const FormatException('Invalid direct conversation ID');
    }
    final result = await _readDirectConversations(
      page: 1,
      size: 1,
      conversationId: conversationId,
    );
    return result.items.isEmpty ? null : result.items.single;
  }

  Future<PagedResult<V2DirectConversation>> _readDirectConversations({
    required int page,
    required int size,
    int? conversationId,
  }) {
    const invalid = FormatException(
      'Invalid direct conversation list response',
    );
    return _readChatPage<V2DirectConversation>(
      ApiPaths.chatDirectConversations,
      page: page,
      size: size,
      filters: {if (conversationId != null) 'conversation_id': conversationId},
      invalid: invalid,
      idOf: (conversation) => conversation.conversationId,
      decodeItem: (item) {
        final conversation = toMap(item);
        final participant = toMap(conversation['participant']);
        final unread = conversation['unread_count'];
        if (!_safeId(conversation['conversation_id']) ||
            (conversationId != null &&
                conversation['conversation_id'] != conversationId) ||
            !_safeId(participant['user_id']) ||
            unread is! int ||
            unread < 0 ||
            unread > 9007199254740991) {
          throw invalid;
        }
        return V2DirectConversation.fromJson(conversation);
      },
    );
  }

  Future<V2DirectConversation> openConversation({required int userId}) {
    return _client.requestData<V2DirectConversation>(
      ApiPaths.chatDirectConversations,
      method: 'POST',
      data: {'target_user_id': userId},
      decode: (data) {
        final receipt = toMap(data);
        final participant = toMap(receipt['participant']);
        final id = receipt['conversation_id'];
        if (!_safeId(id) ||
            participant['user_id'] is! int ||
            participant['user_id'] != userId) {
          throw const FormatException('Invalid direct conversation response');
        }
        return V2DirectConversation.fromJson(receipt);
      },
    );
  }

  Future<PagedResult<V2DirectMessage>> listDirectMessages({
    required int conversationId,
    int page = 1,
    int size = 30,
    // Kept for API compatibility; server pagination is page/page_size only
    // and ignores `before`. Prefer page-based history loading in screens.
    int? beforeMessageId,
  }) {
    const invalid = FormatException('Invalid direct message history response');
    return _readChatPage<V2DirectMessage>(
      '${ApiPaths.chatDirectConversations}/$conversationId/messages',
      page: page,
      size: size,
      filters: {if (beforeMessageId != null) 'before': beforeMessageId},
      invalid: invalid,
      idOf: (message) => message.messageId,
      decodeItem: (item) {
        final message = toMap(item);
        final author = toMap(message['author']);
        if (!_safeId(message['message_id']) ||
            message['conversation_id'] is! int ||
            message['conversation_id'] != conversationId ||
            !_safeId(author['user_id']) ||
            message['content'] is! String ||
            message['created_at'] is! String ||
            message['is_deleted'] != false) {
          throw invalid;
        }
        return V2DirectMessage.fromJson(message);
      },
    );
  }

  Future<PagedResult<T>> _readChatPage<T>(
    String path, {
    required int page,
    required int size,
    required FormatException invalid,
    required T Function(Object?) decodeItem,
    required int Function(T) idOf,
    Map<String, Object> filters = const {},
  }) async {
    final query = <String, dynamic>{
      'page': page,
      'page_size': size,
      ...filters,
    };
    final result = await _client.request<List<T>>(
      path,
      query: query,
      validateSuccessEnvelope: (value) {
        if (value is! Map<String, Object?> || value['code'] != 200) {
          throw invalid;
        }
        final meta = value['meta'];
        if (meta is! Map ||
            meta['page'] is! int ||
            meta['page'] != page ||
            meta['page_size'] is! int ||
            meta['page_size'] != size ||
            meta['has_next'] is! bool) {
          throw invalid;
        }
        final total = meta['total'];
        if (total is! int || total < 0 || total > 9007199254740991) {
          throw invalid;
        }
      },
      decode: (data) {
        if (data is! List<Object?> || data.length > size) throw invalid;
        final ids = <int>{};
        return data.map((item) {
          final decoded = decodeItem(item);
          if (!ids.add(idOf(decoded))) throw invalid;
          return decoded;
        }).toList();
      },
    );
    return PagedResult(items: result.data, meta: result.meta);
  }

  Future<V2DirectMessage> sendDirectMessage({
    required int conversationId,
    required String content,
  }) {
    return _client.requestData<V2DirectMessage>(
      '${ApiPaths.chatDirectConversations}/$conversationId/messages',
      method: 'POST',
      data: {'content': content},
      decode: (data) {
        final receipt = toMap(data);
        if (!_safeId(receipt['message_id']) ||
            receipt['conversation_id'] is! int ||
            receipt['conversation_id'] != conversationId ||
            receipt['is_deleted'] != false ||
            receipt['content'] != content.trim()) {
          throw const FormatException('Invalid direct message response');
        }
        return V2DirectMessage.fromJson(receipt);
      },
    );
  }

  Future<void> deleteDirectMessage({
    required int conversationId,
    required int messageId,
  }) async {
    await _client.request<void>(
      '${ApiPaths.chatDirectConversations}/$conversationId/messages/$messageId',
      method: 'DELETE',
      decode: (data) {
        if (data != null) {
          throw const FormatException('Invalid direct message delete receipt');
        }
      },
    );
  }

  bool _safeId(Object? value) =>
      value is int && value > 0 && value <= 9007199254740991;
}
