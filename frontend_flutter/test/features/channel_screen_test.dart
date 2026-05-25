import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_response.dart';
import 'package:nekotribe/features/chat/data/chat_api.dart';
import 'package:nekotribe/features/chat/domain/chat_models.dart';
import 'package:nekotribe/features/chat/presentation/channel_screen.dart';
import 'package:nekotribe/features/media/data/media_api.dart';
import 'package:nekotribe/features/posts/domain/post_models.dart';
import 'package:nekotribe/features/realtime/data/realtime_service.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  FilePicker? originalFilePicker;

  setUp(() {
    try {
      originalFilePicker = FilePicker.platform;
    } catch (_) {
      originalFilePicker = null;
    }
    FilePicker.platform = _FakeFilePicker([]);
  });

  tearDown(() {
    if (originalFilePicker != null) {
      FilePicker.platform = originalFilePicker!;
    } else {
      FilePicker.platform = _FakeFilePicker([]);
    }
  });

  testWidgets('channel composer uploads attachment media before sending', (
    tester,
  ) async {
    final chatApi = _FakeChatApi();
    final mediaApi = _FakeMediaApi();
    FilePicker.platform = _FakeFilePicker([_pickedFile('chat.pdf')]);

    await tester.pumpWidget(_testApp(chatApi: chatApi, mediaApi: mediaApi));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('chat-channel-attach-button')));
    await tester.pumpAndSettle();

    expect(find.text('chat.pdf'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-channel-send-button')));
    await tester.pumpAndSettle();

    expect(mediaApi.uploadedFileNames, ['chat.pdf']);
    expect(chatApi.sentChannelId, 7);
    expect(chatApi.sentContent, '');
    expect(chatApi.sentMediaIds, [501]);
    expect(find.text('chat.pdf'), findsOneWidget);
  });

  testWidgets('channel composer exposes web toolbar actions', (tester) async {
    final chatApi = _FakeChatApi();
    final mediaApi = _FakeMediaApi();
    FilePicker.platform = _FakeFilePicker([_pickedFile('cat.png')]);

    await tester.pumpWidget(_testApp(chatApi: chatApi, mediaApi: mediaApi));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('chat-channel-attach-button')), findsOneWidget);
    expect(find.byKey(const Key('chat-channel-image-button')), findsOneWidget);
    expect(find.byKey(const Key('chat-channel-emoji-button')), findsOneWidget);
    expect(
      find.byKey(const Key('chat-channel-mention-button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('chat-channel-channel-button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('chat-channel-sticker-button')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('chat-channel-image-button')));
    await tester.pumpAndSettle();
    expect(find.text('cat.png'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-channel-emoji-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('😀').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-channel-mention-button')));
    await tester.tap(find.byKey(const Key('chat-channel-channel-button')));
    await tester.tap(find.byKey(const Key('chat-channel-sticker-button')));
    await tester.pumpAndSettle();

    final composer = tester.widget<TextField>(
      find.byKey(const Key('chat-channel-composer-field')),
    );
    expect(composer.controller?.text, '😀@#🎁 ');
  });

  testWidgets('channel composer sends selected reply target', (tester) async {
    final chatApi = _FakeChatApi(
      initialMessages: [_message(messageId: 1001, content: 'Original note')],
    );
    final mediaApi = _FakeMediaApi();

    await tester.pumpWidget(_testApp(chatApi: chatApi, mediaApi: mediaApi));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('chat-channel-reply-1001')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('chat-channel-reply-preview')), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Reply from Flutter');
    await tester.tap(find.byKey(const Key('chat-channel-send-button')));
    await tester.pumpAndSettle();

    expect(chatApi.sentContent, 'Reply from Flutter');
    expect(chatApi.sentReplyToMessageId, 1001);
    expect(find.byKey(const Key('chat-channel-reply-preview')), findsNothing);
  });

  testWidgets('channel message menu edits and deletes messages', (
    tester,
  ) async {
    final chatApi = _FakeChatApi(
      initialMessages: [_message(messageId: 1002, content: 'Draft message')],
    );
    final mediaApi = _FakeMediaApi();

    await tester.pumpWidget(_testApp(chatApi: chatApi, mediaApi: mediaApi));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('chat-channel-more-1002')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-channel-edit-1002')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('chat-channel-edit-content-field')),
      'Edited message',
    );
    await tester.tap(find.byKey(const Key('chat-channel-edit-save-button')));
    await tester.pumpAndSettle();

    expect(chatApi.editedMessageId, 1002);
    expect(chatApi.editedContent, 'Edited message');
    expect(find.text('Edited message'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-channel-more-1002')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-channel-delete-1002')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('chat-channel-delete-confirm-button')),
    );
    await tester.pumpAndSettle();

    expect(chatApi.deletedMessageId, 1002);
    expect(find.text('Edited message'), findsNothing);
  });

  testWidgets('channel reaction summary toggles existing reaction', (
    tester,
  ) async {
    final chatApi = _FakeChatApi(
      initialMessages: [
        _message(
          messageId: 1003,
          content: 'Reactable message',
          reactions: [
            V2ChatReactionSummary(emoji: '🔥', count: 2, reactedByMe: true),
          ],
        ),
      ],
    );
    final mediaApi = _FakeMediaApi();

    await tester.pumpWidget(_testApp(chatApi: chatApi, mediaApi: mediaApi));
    await tester.pumpAndSettle();

    expect(find.text('🔥'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-channel-reaction-1003-🔥')));
    await tester.pumpAndSettle();

    expect(chatApi.unreactedMessageId, 1003);
    expect(chatApi.unreactedEmoji, '🔥');
    expect(chatApi.reactedMessageId, isNull);
  });

  testWidgets('channel realtime inserts server chat message events', (
    tester,
  ) async {
    final chatApi = _FakeChatApi();
    final mediaApi = _FakeMediaApi();
    final realtime = _FakeRealtimeService();

    await tester.pumpWidget(
      _testApp(chatApi: chatApi, mediaApi: mediaApi, realtime: realtime),
    );
    await tester.pumpAndSettle();

    realtime.emit({
      'type': 'chat_message',
      'data': {
        'channel_id': 7,
        'message': _messageJson(messageId: 1004, content: 'Realtime message'),
      },
    });
    await tester.pumpAndSettle();

    expect(find.text('Realtime message'), findsOneWidget);
  });

  testWidgets('channel realtime updates server chat message events', (
    tester,
  ) async {
    final chatApi = _FakeChatApi(
      initialMessages: [_message(messageId: 1005, content: 'Before edit')],
    );
    final mediaApi = _FakeMediaApi();
    final realtime = _FakeRealtimeService();

    await tester.pumpWidget(
      _testApp(chatApi: chatApi, mediaApi: mediaApi, realtime: realtime),
    );
    await tester.pumpAndSettle();

    realtime.emit({
      'type': 'chat_message_updated',
      'data': {
        'channel_id': 7,
        'message': _messageJson(
          messageId: 1005,
          content: 'After realtime edit',
        ),
      },
    });
    await tester.pumpAndSettle();

    expect(find.text('Before edit'), findsNothing);
    expect(find.text('After realtime edit'), findsOneWidget);
  });

  testWidgets('channel realtime removes server deleted message events', (
    tester,
  ) async {
    final chatApi = _FakeChatApi(
      initialMessages: [_message(messageId: 1006, content: 'Delete me live')],
    );
    final mediaApi = _FakeMediaApi();
    final realtime = _FakeRealtimeService();

    await tester.pumpWidget(
      _testApp(chatApi: chatApi, mediaApi: mediaApi, realtime: realtime),
    );
    await tester.pumpAndSettle();

    realtime.emit({
      'type': 'chat_message_deleted',
      'data': {'channel_id': 7, 'message_id': 1006},
    });
    await tester.pumpAndSettle();

    expect(find.text('Delete me live'), findsNothing);
  });

  testWidgets('channel realtime updates server reaction events', (
    tester,
  ) async {
    final chatApi = _FakeChatApi(
      initialMessages: [_message(messageId: 1007, content: 'React live')],
    );
    final mediaApi = _FakeMediaApi();
    final realtime = _FakeRealtimeService();

    await tester.pumpWidget(
      _testApp(chatApi: chatApi, mediaApi: mediaApi, realtime: realtime),
    );
    await tester.pumpAndSettle();

    realtime.emit({
      'type': 'chat_reaction_updated',
      'data': {
        'channel_id': 7,
        'message': _messageJson(
          messageId: 1007,
          content: 'React live',
          reactions: [
            {'emoji': '✨', 'count': 3, 'reacted_by_me': true},
          ],
        ),
      },
    });
    await tester.pumpAndSettle();

    expect(find.text('✨'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });
}

Widget _testApp({
  required ChatApi chatApi,
  required MediaApi mediaApi,
  _FakeRealtimeService? realtime,
}) {
  return ProviderScope(
    overrides: [
      appConfigBundleProvider.overrideWithValue(_testBundle),
      appConfigInitialProvider.overrideWithValue(_testConfig),
      chatApiProvider.overrideWithValue(chatApi),
      mediaApiProvider.overrideWithValue(mediaApi),
      realtimeServiceProvider.overrideWithValue(
        realtime ?? _FakeRealtimeService(),
      ),
    ],
    child: const MaterialApp(home: ChannelScreen(groupId: 42, channelId: 7)),
  );
}

class _FakeChatApi extends ChatApi {
  _FakeChatApi({List<V2ChatMessage> initialMessages = const []})
    : messages = List.of(initialMessages),
      super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  final List<V2ChatMessage> messages;
  int? sentChannelId;
  String? sentContent;
  int? sentReplyToMessageId;
  List<int>? sentMediaIds;
  int? editedMessageId;
  String? editedContent;
  int? deletedMessageId;
  int? reactedMessageId;
  String? reactedEmoji;
  int? unreactedMessageId;
  String? unreactedEmoji;

  @override
  Future<PagedResult<V2ChatMessage>> listMessages({
    required int channelId,
    int page = 1,
    int size = 30,
    int? beforeMessageId,
  }) async {
    return PagedResult(
      items: List.of(messages),
      meta: ApiMeta(
        page: 1,
        pageSize: 30,
        total: messages.length,
        hasNext: false,
      ),
    );
  }

  @override
  Future<void> setChannelReadStatus({
    required int channelId,
    int? lastReadMessageId,
  }) async {}

  @override
  Future<V2ChatMessage> sendChannelMessage({
    required int channelId,
    required String content,
    int? replyToMessageId,
    List<int> mediaIds = const [],
    String messageType = 'text',
  }) async {
    sentChannelId = channelId;
    sentContent = content;
    sentReplyToMessageId = replyToMessageId;
    sentMediaIds = mediaIds;
    return _message(content: content, media: [_asset()]);
  }

  @override
  Future<V2ChatMessage> editMessage({
    required int messageId,
    required String content,
  }) async {
    editedMessageId = messageId;
    editedContent = content;
    final updated = _message(messageId: messageId, content: content);
    final index = messages.indexWhere((m) => m.messageId == messageId);
    if (index >= 0) messages[index] = updated;
    return updated;
  }

  @override
  Future<void> deleteMessage(int messageId) async {
    deletedMessageId = messageId;
    messages.removeWhere((m) => m.messageId == messageId);
  }

  @override
  Future<void> reactMessage({
    required int messageId,
    required String emoji,
  }) async {
    reactedMessageId = messageId;
    reactedEmoji = emoji;
  }

  @override
  Future<void> unreactMessage({
    required int messageId,
    required String emoji,
  }) async {
    unreactedMessageId = messageId;
    unreactedEmoji = emoji;
  }
}

class _FakeMediaApi extends MediaApi {
  _FakeMediaApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  final uploadedFileNames = <String>[];

  @override
  Future<V2MediaAsset> uploadBytes({
    required Uint8List bytes,
    required String fileName,
    String mediaType = 'image',
    String? mimeType,
    String? altText,
    String? description,
    void Function(int sent, int total)? onProgress,
  }) async {
    uploadedFileNames.add(fileName);
    return _asset(fileName: fileName, mediaType: mediaType);
  }
}

class _FakeRealtimeService extends RealtimeService {
  _FakeRealtimeService()
    : super(config: _testConfig, tokenStore: _FakeTokenStore());

  final List<RealtimeListener> listeners = [];

  void emit(Map<String, dynamic> event) {
    for (final listener in List<RealtimeListener>.of(listeners)) {
      listener(event);
    }
  }

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  void send(Map<String, dynamic> payload) {}

  @override
  void addListener(RealtimeListener listener) {
    listeners.add(listener);
  }

  @override
  void removeListener(RealtimeListener listener) {
    listeners.remove(listener);
  }
}

FilePickerResult _pickedFile(String name) {
  return FilePickerResult([
    PlatformFile(name: name, size: 4, bytes: Uint8List.fromList([1, 2, 3, 4])),
  ]);
}

class _FakeFilePicker extends FilePicker {
  _FakeFilePicker(this._results);

  final List<FilePickerResult> _results;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    return _results.removeAt(0);
  }
}

V2ChatMessage _message({
  int messageId = 9001,
  String content = '',
  V2ChatMessageReply? replyTo,
  List<V2MediaAsset> media = const [],
  List<V2ChatReactionSummary> reactions = const [],
}) {
  return V2ChatMessage(
    messageId: messageId,
    channelId: 7,
    groupId: 42,
    messageType: 'text',
    content: content,
    author: _user,
    replyTo: replyTo,
    media: media,
    reactions: reactions,
    isPinned: false,
    isDeleted: false,
    canDelete: true,
    canPin: true,
    createdAt: '2026-05-25T00:00:00.000Z',
    updatedAt: '2026-05-25T00:00:00.000Z',
  );
}

Map<String, dynamic> _messageJson({
  int messageId = 9001,
  String content = '',
  List<Map<String, dynamic>> reactions = const [],
}) {
  return {
    'message_id': messageId,
    'channel_id': 7,
    'group_id': 42,
    'message_type': 'text',
    'content': content,
    'author': _userJson,
    'reply_to': null,
    'media': [],
    'reactions': reactions,
    'is_pinned': false,
    'is_deleted': false,
    'can_delete': true,
    'can_pin': true,
    'created_at': '2026-05-25T00:00:00.000Z',
    'updated_at': '2026-05-25T00:00:00.000Z',
    'edited_at': null,
    'deleted_at': null,
  };
}

V2MediaAsset _asset({String fileName = 'chat.pdf', String mediaType = 'file'}) {
  return V2MediaAsset(
    mediaId: 501,
    mediaType: mediaType,
    fileName: fileName,
    publicUrl: '/uploads/$fileName',
    fileSize: 4,
    mimeType: mediaType == 'image' ? 'image/png' : 'application/pdf',
    status: 'active',
    createdAt: '2026-05-25T00:00:00.000Z',
  );
}

final _user = V2PublicUser(
  userId: 1,
  username: 'edge',
  displayName: 'Edge',
  avatarUrl: '',
  bio: '',
  location: '',
  website: '',
  isVerified: 0,
  followersCount: 0,
  followingCount: 0,
  postsCount: 0,
  likesCount: 0,
  relationship: V2Relationship.empty(),
  onlineStatus: 'online',
);

final _userJson = {
  'user_id': 1,
  'username': 'edge',
  'display_name': 'Edge',
  'avatar_url': '',
  'bio': '',
  'location': '',
  'website': '',
  'is_verified': 0,
  'followers_count': 0,
  'following_count': 0,
  'posts_count': 0,
  'likes_count': 0,
  'relationship': {
    'is_self': false,
    'is_following': false,
    'is_blocked': false,
    'is_blocking': false,
    'relation': 'stranger',
  },
  'online_status': 'online',
  'last_seen_at': null,
};

const _testConfig = AppConfig(
  apiBaseUrl: 'http://example.test',
  wsBaseUrl: 'ws://example.test',
  storageBaseUrl: 'http://example.test',
);

const _testBundle = AppConfigBundle(defaults: _testConfig, presets: []);

class _FakeTokenStore extends TokenStore {
  @override
  Future<TokenPair?> read() async => null;

  @override
  Future<void> write(TokenPair pair) async {}

  @override
  Future<void> clear() async {}
}
