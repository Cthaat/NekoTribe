import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
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

import '../support/media_preview_flight.dart';

void main() {
  testWidgets('channel typing is scoped and cleared when opening the roster', (
    tester,
  ) async {
    final socket = _FakeRealtimeService();
    addTearDown(socket.dispose);
    await tester.pumpWidget(
      _testApp(
        chatApi: _FakeChatApi(),
        mediaApi: _FakeMediaApi(),
        realtime: socket,
        tokenStore: _FakeTokenStore(userId: 1),
      ),
    );
    await tester.pumpAndSettle();
    final composer = find.byKey(const Key('chat-channel-composer-field'));
    await tester.enterText(composer, 'draft');
    expect(socket.sent.last, {
      'type': 'typing_start',
      'data': {'channel_id': 7},
    });
    void peer(int channel) => socket.emit({
      'type': 'typing_start',
      'timestamp': 3,
      'data': {'channel_id': channel, 'user_id': 2},
    });
    peer(8);
    await tester.pump();
    expect(find.text('有人正在输入…'), findsNothing);
    peer(7);
    await tester.pump();
    expect(find.text('有人正在输入…'), findsOneWidget);

    final roster = find.byKey(const Key('chat-channel-members'));
    await tester.tap(roster);
    await tester.pumpAndSettle();
    expect(socket.sent.last, {
      'type': 'typing_stop',
      'data': {'channel_id': 7},
    });
    await tester.tap(roster);
    await tester.pumpAndSettle();
    expect(find.text('有人正在输入…'), findsNothing);
  });
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

  testWidgets(
    'channel loads message content and uses channel name in app bar',
    (tester) async {
      final chatApi = _FakeChatApi(
        initialMessages: [_message(messageId: 42, content: 'hello')],
      );
      final mediaApi = _FakeMediaApi();

      await tester.pumpWidget(
        _testApp(chatApi: chatApi, mediaApi: mediaApi, channelName: 'general'),
      );
      await tester.pumpAndSettle();

      expect(find.text('#general'), findsOneWidget);
      expect(find.text('hello'), findsOneWidget);
      expect(chatApi.reads, [(7, 42)]);
    },
  );

  testWidgets('channel public thumbnail shares its Hero with the preview', (tester) async {
    final photo = _asset(fileName: 'chat.png', mediaType: 'image');
    final api = _FakeChatApi(initialMessages: [_message(messageId: 42, content: 'photo', media: [photo])]);
    await tester.pumpWidget(_testApp(chatApi: api, mediaApi: _FakeMediaApi()));
    await tester.pumpAndSettle();
    await checkMediaFlight(tester);
  });

  testWidgets('failed read acknowledgement keeps loaded history visible', (
    tester,
  ) async {
    final chatApi = _FakeChatApi(
      initialMessages: [_message(messageId: 42, content: 'still visible')],
    );
    chatApi.failRead = true;
    await tester.pumpWidget(
      _testApp(chatApi: chatApi, mediaApi: _FakeMediaApi()),
    );
    await tester.pumpAndSettle();
    expect(chatApi.reads, [(7, 42)]);
    expect(find.text('still visible'), findsOneWidget);
  });

  testWidgets('channel opens its group roster and returns to messages', (
    tester,
  ) async {
    final chatApi = _FakeChatApi(
      initialMessages: [_message(messageId: 42, content: 'channel history')],
    );
    await tester.pumpWidget(
      _testApp(chatApi: chatApi, mediaApi: _FakeMediaApi()),
    );
    await tester.pumpAndSettle();
    expect(chatApi.memberRequests, isEmpty);
    await tester.tap(find.byKey(const Key('chat-channel-members')));
    await tester.pumpAndSettle();
    expect(chatApi.memberRequests, [42]);
    expect(find.text('channel history'), findsNothing);
    expect(find.text('Quiet Member'), findsOneWidget);
    expect(find.text('群主'), findsOneWidget);
    await tester.tap(find.byKey(const Key('chat-channel-members')));
    await tester.pumpAndSettle();
    expect(find.text('channel history'), findsOneWidget);
  });

  testWidgets('a previous endpoint cannot display a late member list', (
    tester,
  ) async {
    final reply = Completer<List<V2ChatMember>>();
    final tokens = _FakeTokenStore();
    final chatApi = _FakeChatApi()..pendingMembers = reply.future;
    await tester.pumpWidget(
      _testApp(chatApi: chatApi, mediaApi: _FakeMediaApi(), tokenStore: tokens),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-channel-members')));
    await tester.pump();
    expect(chatApi.memberRequests, [42]);
    await tokens.switchEndpoint(() {});
    reply.complete([
      V2ChatMember.fromJson({'display_name': 'Previous member'}),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Previous member'), findsNothing);
    expect(find.text('#7'), findsOneWidget);
  });

  testWidgets(
    'channel search reads matching history without acknowledging it',
    (tester) async {
      final chatApi = _FakeChatApi(
        initialMessages: [
          _message(messageId: 41, content: 'other message'),
          _message(messageId: 42, content: 'match this'),
        ],
      );
      await tester.pumpWidget(
        _testApp(chatApi: chatApi, mediaApi: _FakeMediaApi()),
      );
      await tester.pumpAndSettle();
      final toggle = find.byKey(const Key('chat-channel-search-toggle'));
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await tester.tap(find.text('发送者'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Quiet Member'));
      await tester.pumpAndSettle();
      final today = DateTime.now();
      for (final label in ['开始日期', '结束日期']) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        final picker = tester.element(find.byType(DatePickerDialog));
        await tester.tap(
          find.text(MaterialLocalizations.of(picker).okButtonLabel),
        );
        await tester.pumpAndSettle();
      }
      await tester.enterText(
        find.byKey(const Key('chat-channel-search-input')),
        ' match ',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(chatApi.lastSearch, 'match');
      expect(chatApi.searchDetails, (
        7,
        DateTime(today.year, today.month, today.day).toUtc(),
        DateTime(today.year, today.month, today.day + 1).toUtc(),
      ));
      expect(find.text('match this'), findsOneWidget);
      expect(find.text('other message'), findsNothing);
      expect(chatApi.reads, [(7, 42)]);
      await tester.tap(find.text('清除筛选'));
      await tester.pumpAndSettle();
      expect(chatApi.lastSearch, '');
      expect(chatApi.searchDetails, (null, null, null));
      expect(find.text('other message'), findsOneWidget);
    },
  );

  testWidgets('channel reverses ASC page so newest sits nearest composer', (
    tester,
  ) async {
    final chatApi = _FakeChatApi(
      initialMessages: [
        _message(messageId: 1, content: 'A-old'),
        _message(messageId: 2, content: 'B-mid'),
        _message(messageId: 3, content: 'C-new'),
      ],
    );
    final mediaApi = _FakeMediaApi();

    await tester.pumpWidget(_testApp(chatApi: chatApi, mediaApi: mediaApi));
    await tester.pumpAndSettle();

    final a = tester.getTopLeft(find.text('A-old'));
    final c = tester.getTopLeft(find.text('C-new'));
    expect(c.dy, greaterThan(a.dy));
  });

  testWidgets('channel composer uploads attachment media before sending', (
    tester,
  ) async {
    final chatApi = _FakeChatApi()..failSend = true;
    final mediaApi = _FakeMediaApi();
    final picker = _FakeFilePicker([_pickedFile('chat.pdf')]);
    FilePicker.platform = picker;

    await tester.pumpWidget(_testApp(chatApi: chatApi, mediaApi: mediaApi));
    await tester.pumpAndSettle();
    final send = find.byKey(const Key('chat-channel-send-button'));
    expect(tester.widget<IconButton>(send).onPressed, isNull);

    await tester.tap(find.byKey(const Key('chat-channel-attach-button')));
    await tester.pumpAndSettle();

    expect(find.text('chat.pdf'), findsOneWidget);
    expect(picker.withEagerData, isFalse);

    expect(tester.widget<IconButton>(send).onPressed, isNotNull);
    await tester.tap(send);
    await tester.pumpAndSettle();

    expect(mediaApi.uploadedFileNames, ['chat.pdf']);
    expect(chatApi.sentMediaIds, [501]);
    expect(find.byTooltip('下载附件'), findsNothing);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    chatApi.failSend = false;
    await tester.tap(find.byKey(const Key('chat-channel-send-button')));
    await tester.pumpAndSettle();

    expect(mediaApi.uploadedFileNames, ['chat.pdf']);
    expect(mediaApi.accessScopes, ['chat']);
    expect(chatApi.sentChannelId, 7);
    expect(chatApi.sentContent, '');
    expect(chatApi.sentMediaIds, [501]);
    expect(find.text('chat.pdf'), findsOneWidget);
    expect(find.byTooltip('下载附件'), findsOneWidget);
  });

  testWidgets('channel rejects oversized selections before adding files', (
    tester,
  ) async {
    final chatApi = _FakeChatApi();
    final mediaApi = _FakeMediaApi();
    FilePicker.platform = _FakeFilePicker([
      _pickedFile('existing.pdf'),
      FilePickerResult([
        PlatformFile(name: 'large.mp4', size: 500 * 1024 * 1024 + 1),
        ..._pickedFile('other.pdf').files,
      ]),
    ]);
    await tester.pumpWidget(_testApp(chatApi: chatApi, mediaApi: mediaApi));
    await tester.pumpAndSettle();
    final attach = find.byKey(const Key('chat-channel-attach-button'));
    await tester.tap(attach);
    await tester.pumpAndSettle();
    await tester.tap(attach);
    await tester.pumpAndSettle();

    expect(find.text('existing.pdf'), findsOneWidget);
    expect(find.text('large.mp4'), findsNothing);
    expect(find.text('other.pdf'), findsNothing);
    expect(find.text('单个附件大小不能超过 500 MiB。'), findsOneWidget);
    expect(mediaApi.uploadedFileNames, isEmpty);
  });

  testWidgets('failed attachment stream requires reselection before sending', (
    tester,
  ) async {
    final chatApi = _FakeChatApi();
    final mediaApi = _FakeMediaApi()..failStream = true;
    Stream<List<int>> chunks() async* {
      yield [1, 2, 3];
    }

    FilePicker.platform = _FakeFilePicker([
      FilePickerResult([
        ..._pickedFile('existing.pdf').files,
        PlatformFile(name: 'video.mp4', size: 3, readStream: chunks()),
      ]),
    ]);
    await tester.pumpWidget(_testApp(chatApi: chatApi, mediaApi: mediaApi));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-channel-attach-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-channel-send-button')));
    await tester.pumpAndSettle();

    expect(chatApi.sentChannelId, isNull);
    expect(mediaApi.uploadedFileNames, ['existing.pdf', 'video.mp4']);
    expect(mediaApi.accessScopes, ['chat', 'chat']);
    expect(find.text('existing.pdf'), findsOneWidget);
    expect(find.text('video.mp4'), findsNothing);
    expect(find.text('video.mp4: 附件上传失败，请重新选择。'), findsOneWidget);
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

  testWidgets('channel message menu edits and deletes messages', (
    tester,
  ) async {
    final chatApi = _FakeChatApi(
      initialMessages: [_message(messageId: 1002, content: 'Draft message')],
    );
    final mediaApi = _FakeMediaApi();

    await tester.pumpWidget(
      _testApp(
        chatApi: chatApi,
        mediaApi: mediaApi,
        tokenStore: _FakeTokenStore(userId: 1),
      ),
    );
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

  testWidgets(
    'permission to delete another user message does not grant editing',
    (tester) async {
      final api = _FakeChatApi(
        initialMessages: [_message(messageId: 1002, content: 'Other author')],
      );
      await tester.pumpWidget(
        _testApp(
          chatApi: api,
          mediaApi: _FakeMediaApi(),
          tokenStore: _FakeTokenStore(userId: 2),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chat-channel-more-1002')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-channel-edit-1002')), findsNothing);
      expect(find.byKey(const Key('chat-channel-delete-1002')), findsOneWidget);
    },
  );

  testWidgets('channel reply is available from message overflow menu', (
    tester,
  ) async {
    final chatApi = _FakeChatApi(
      initialMessages: [_message(messageId: 1001, content: 'Original note')],
    );
    final mediaApi = _FakeMediaApi();

    await tester.pumpWidget(_testApp(chatApi: chatApi, mediaApi: mediaApi));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('chat-channel-more-1001')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-channel-reply-1001')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('chat-channel-reply-preview')), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Reply from Flutter');
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-channel-send-button')));
    await tester.pumpAndSettle();

    expect(chatApi.sentContent, 'Reply from Flutter');
    expect(chatApi.sentReplyToMessageId, 1001);
    expect(find.byKey(const Key('chat-channel-reply-preview')), findsNothing);
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
    final realtime = _FakeRealtimeService();
    final pending = Completer<void>();
    chatApi.beforeReaction = () => pending.future;

    await tester.pumpWidget(
      _testApp(chatApi: chatApi, mediaApi: mediaApi, realtime: realtime),
    );
    await tester.pumpAndSettle();

    expect(find.text('🔥'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-channel-reaction-1003-🔥')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-channel-reaction-1003-🔥')));
    expect(chatApi.reactionCalls, 1);
    realtime.emit({
      'type': 'chat_message_updated',
      'data': {
        'channel_id': 7,
        'viewer_neutral': true,
        'message': _messageJson(
          messageId: 1003,
          content: 'Edited during reaction',
          reactions: [
            {'emoji': '🔥', 'count': 2, 'reacted_by_me': false},
          ],
        ),
      },
    });
    pending.complete();
    await tester.pumpAndSettle();

    expect(chatApi.unreactedMessageId, 1003);
    expect(chatApi.unreactedEmoji, '🔥');
    expect(find.text('7'), findsOneWidget);
    expect(chatApi.reactedMessageId, isNull);
    expect(find.text('Edited during reaction'), findsOneWidget);
  });

  testWidgets('channel realtime inserts messages and batches read status', (
    tester,
  ) async {
    final chatApi = _FakeChatApi();
    final mediaApi = _FakeMediaApi();
    final realtime = _FakeRealtimeService();

    await tester.pumpWidget(
      _testApp(chatApi: chatApi, mediaApi: mediaApi, realtime: realtime),
    );
    await tester.pumpAndSettle();

    for (final id in [1004, 1005]) {
      realtime.emit({
        'type': 'chat_message',
        'data': {
          'channel_id': 7,
          'message': _messageJson(messageId: id, content: 'Realtime $id'),
        },
      });
    }
    expect(chatApi.reads, isEmpty);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('Realtime 1004'), findsOneWidget);
    expect(find.text('Realtime 1005'), findsOneWidget);
    expect(chatApi.reads, [(7, 1005)]);
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
      initialMessages: [
        _message(
          messageId: 1007,
          content: 'React live',
          reactions: [
            V2ChatReactionSummary(emoji: '✨', count: 1, reactedByMe: true),
          ],
        ),
      ],
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
        'viewer_neutral': true,
        'message': _messageJson(
          messageId: 1007,
          content: 'React live',
          reactions: [
            {'emoji': '✨', 'count': 3, 'reacted_by_me': false},
          ],
        ),
      },
    });
    await tester.pumpAndSettle();

    expect(find.text('✨'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    await tester.tap(find.byKey(const Key('chat-channel-reaction-1007-✨')));
    await tester.pumpAndSettle();
    expect(chatApi.unreactedMessageId, 1007);
    expect(find.text('7'), findsOneWidget);
  });
}

Widget _testApp({
  required ChatApi chatApi,
  required MediaApi mediaApi,
  _FakeRealtimeService? realtime,
  String? channelName,
  TokenStore? tokenStore,
}) {
  return ProviderScope(
    overrides: [
      appConfigBundleProvider.overrideWithValue(_testBundle),
      appConfigInitialProvider.overrideWithValue(_testConfig),
      chatApiProvider.overrideWithValue(chatApi),
      mediaApiProvider.overrideWithValue(mediaApi),
      if (tokenStore != null) tokenStoreProvider.overrideWithValue(tokenStore),
      realtimeServiceProvider.overrideWithValue(
        realtime ?? _FakeRealtimeService(),
      ),
    ],
    child: MaterialApp(
      home: ChannelScreen(groupId: 42, channelId: 7, channelName: channelName),
    ),
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
  int reactionCalls = 0;
  Future<void> Function()? beforeReaction;
  int? lastListPage;
  int? lastBeforeMessageId;
  String? lastSearch;
  bool failRead = false;
  bool failSend = false;
  final reads = <(int, int?)>[];
  final memberRequests = <int>[];
  (int?, DateTime?, DateTime?)? searchDetails;
  Future<List<V2ChatMember>>? pendingMembers;

  @override
  Future<List<V2ChatMember>> listMembers(int groupId) async {
    memberRequests.add(groupId);
    final pending = pendingMembers;
    if (pending != null) return pending;
    return [
      V2ChatMember.fromJson({
        'user_id': 7,
        'username': 'quiet',
        'display_name': 'Quiet Member',
        'role': 'owner',
        'status': 'active',
        'online_status': 'hidden',
        'last_seen_at': '2026-11-19T10:00:00Z',
      }),
    ];
  }

  @override
  Future<PagedResult<V2ChatMessage>> listMessages({
    required int channelId,
    int page = 1,
    int size = 30,
    String? search,
    int? senderId,
    DateTime? startAt,
    DateTime? endAt,
    int? beforeMessageId,
  }) async {
    lastListPage = page;
    lastBeforeMessageId = beforeMessageId;
    lastSearch = search;
    searchDetails = (senderId, startAt, endAt);
    final matching = messages
        .where((message) => message.content.contains(search ?? ''))
        .toList();
    return PagedResult(
      items: matching,
      meta: ApiMeta(
        page: page,
        pageSize: size,
        total: matching.length,
        hasNext: false,
      ),
    );
  }

  @override
  Future<void> setChannelReadStatus({
    required int channelId,
    int? lastReadMessageId,
  }) async {
    reads.add((channelId, lastReadMessageId));
    if (failRead) throw StateError('read unavailable');
  }

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
    if (failSend) throw StateError('send failed');
    return _message(
      content: content,
      media: mediaIds.isEmpty
          ? []
          : [_asset(publicUrl: '/api/v2/media/501/content')],
    );
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
  Future<V2ChatMessage> reactMessage({
    required int messageId,
    required String emoji,
  }) async {
    reactedMessageId = messageId;
    reactedEmoji = emoji;
    reactionCalls++;
    await beforeReaction?.call();
    return _reactionResult(messageId, emoji, true);
  }

  @override
  Future<V2ChatMessage> unreactMessage({
    required int messageId,
    required String emoji,
  }) async {
    unreactedMessageId = messageId;
    unreactedEmoji = emoji;
    reactionCalls++;
    await beforeReaction?.call();
    return _reactionResult(messageId, emoji, false);
  }

  V2ChatMessage _reactionResult(int id, String emoji, bool reacted) {
    return _message(
      messageId: id,
      content: messages
          .firstWhere((message) => message.messageId == id)
          .content,
      reactions: [
        V2ChatReactionSummary(emoji: emoji, count: 7, reactedByMe: reacted),
      ],
    );
  }
}

class _FakeMediaApi extends MediaApi {
  _FakeMediaApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  final uploadedFileNames = <String>[];
  final accessScopes = <String?>[];
  bool failStream = false;

  @override
  Future<V2MediaAsset> uploadStream({
    required Stream<List<int>> chunks,
    required int length,
    required String fileName,
    required String mediaType,
    String? altText,
    String? accessScope,
    CancelToken? cancelToken,
  }) async {
    final bytes = await chunks.expand((chunk) => chunk).toList();
    expect(bytes.length, length);
    expect(altText, fileName);
    uploadedFileNames.add(fileName);
    accessScopes.add(accessScope);
    if (failStream) throw StateError('failed upload');
    return _asset(
      fileName: fileName,
      mediaType: mediaType,
      publicUrl: '/api/v2/media/501/content',
    );
  }

  @override
  Future<V2MediaAsset> uploadBytes({
    required Uint8List bytes,
    required String fileName,
    String mediaType = 'image',
    String? mimeType,
    String? altText,
    String? description,
    String? accessScope,
    CancelToken? cancelToken,
    void Function(int sent, int total)? onProgress,
  }) async {
    uploadedFileNames.add(fileName);
    accessScopes.add(accessScope);
    return _asset(
      fileName: fileName,
      mediaType: mediaType,
      publicUrl: '/api/v2/media/501/content',
    );
  }
}

class _FakeRealtimeService extends RealtimeService {
  _FakeRealtimeService()
    : super(config: _testConfig, tokenStore: _FakeTokenStore());

  final List<RealtimeListener> listeners = [];
  final sent = <Map<String, dynamic>>[];

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
  bool send(Map<String, dynamic> payload) {
    sent.add(payload);
    return true;
  }

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
  bool? withEagerData;

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
    withEagerData = withData;
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

V2MediaAsset _asset({
  String fileName = 'chat.pdf',
  String mediaType = 'file',
  String? publicUrl,
}) {
  return V2MediaAsset(
    mediaId: 501,
    mediaType: mediaType,
    fileName: fileName,
    publicUrl: publicUrl ?? '/uploads/$fileName',
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
  _FakeTokenStore({this.userId});

  final int? userId;

  @override
  Future<TokenPair?> read() async {
    if (userId == null) return null;
    final payload = base64Url.encode(
      utf8.encode(jsonEncode({'userId': userId})),
    );
    return TokenPair(
      accessToken: 'fixture.$payload.signature',
      refreshToken: '',
      sessionId: 'fixture',
    );
  }

  @override
  Future<void> write(TokenPair pair) async {}

  @override
  Future<void> clear() async {}
}
