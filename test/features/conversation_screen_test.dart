import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_response.dart';
import 'package:nekotribe/features/chat/data/chat_api.dart';
import 'package:nekotribe/features/chat/domain/chat_models.dart';
import 'package:nekotribe/features/chat/presentation/chat_realtime_binding.dart';
import 'package:nekotribe/features/chat/presentation/conversation_screen.dart';
import 'package:nekotribe/features/media/data/media_api.dart';
import 'package:nekotribe/features/media/presentation/private_attachment_button.dart';
import 'package:nekotribe/features/posts/domain/post_models.dart';
import 'package:nekotribe/features/realtime/data/realtime_service.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/shared/i18n/app_localizations.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  testWidgets(
    'direct search pages and recovers within the filters without committing reads',
    (tester) async {
      final socket = _FakeRealtimeService();
      addTearDown(socket.dispose);
      final lateSearch = Completer<void>();
      final api =
          _FakeChatApi(
              initialMessages: [
                _message(messageId: 3, content: 'ordinary history'),
              ],
            )
            ..supportsReadStatus = true
            ..ownRead = 3
            ..searchParticipant = V2PublicUser.fromJson({
              'user_id': 2,
              'username': 'moon',
              'display_name': 'Moon',
            })
            ..searchWindows = {
              1: [_message(messageId: 12, content: 'cat newest')],
              2: [_message(messageId: 10, content: 'cat older')],
            };
      await _pumpConversation(tester, api, realtime: socket, viewerId: 1);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('dm-search-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('发送者'));
      await tester.pumpAndSettle();
      expect(find.text('我'), findsOneWidget);
      await tester.tap(find.text('Moon'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('dm-search-input')), ' cat ');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('cat newest'), findsOneWidget);
      expect(find.text('ordinary history'), findsNothing);
      await tester.tap(find.text('加载更早的消息'));
      await tester.pumpAndSettle();
      expect(api.searchReads, [(1, 'cat', 2), (2, 'cat', 2)]);
      expect(find.text('cat older'), findsOneWidget);

      socket.listeners.single({
        'type': 'direct_message',
        'data': {
          'conversation_id': 11,
          'direct_message': {
            'conversation_id': 11,
            'message_id': 15,
            'content': 'unfiltered arrival',
            'author': {'user_id': 2},
            'created_at': '2026-05-25T00:00:01.000Z',
            'is_deleted': false,
          },
        },
      });
      await tester.pump();
      expect(find.text('unfiltered arrival'), findsNothing);
      socket.publish(RemoteEvents.connected);
      socket.recovered.add(1);
      await tester.pumpAndSettle();
      expect(api.searchReads.last, (1, 'cat', 2));
      expect(find.text('cat newest'), findsOneWidget);
      expect(api.readWrites, isEmpty);

      api.beforeSearch = () => lateSearch.future;
      socket.recovered.add(2);
      await tester.pump();
      await tester.tap(find.text('清除筛选'));
      lateSearch.complete();
      await tester.pumpAndSettle();
      expect(find.text('ordinary history'), findsOneWidget);
      expect(find.text('cat newest'), findsNothing);
      expect(find.byKey(const Key('dm-composer-field')), findsOneWidget);
      expect(api.historyMarkRead, everyElement(false));
      expect(api.readWrites, isEmpty);
    },
  );

  testWidgets('direct typing is scoped, throttled and expires', (tester) async {
    final realtime = _FakeRealtimeService();
    addTearDown(realtime.dispose);
    await _pumpConversation(
      tester,
      _FakeChatApi(),
      realtime: realtime,
      viewerId: 1,
    );
    await tester.pumpAndSettle();
    final composer = find.byKey(const Key('dm-composer-field'));
    await tester.enterText(composer, 'first');
    await tester.enterText(composer, 'more');
    expect(realtime.sent, [
      {
        'type': 'typing_start',
        'data': {'conversation_id': 11},
      },
    ]);
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.enterText(composer, '');
    expect(realtime.sent.last, {
      'type': 'typing_stop',
      'data': {'conversation_id': 11},
    });

    void typing(String type, int timestamp, int number, int reader) =>
        realtime.listeners.single({
          'type': type,
          'timestamp': timestamp,
          'data': {'conversation_id': number, 'user_id': reader},
        });
    typing('typing_start', 3, 88, 2);
    typing('typing_start', 3, 11, 1);
    await tester.pump();
    final hint = find.text('对方正在输入…');
    expect(hint, findsNothing);
    typing('typing_start', 3, 11, 2);
    typing('typing_stop', 2, 11, 2);
    await tester.pump();
    expect(hint, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 5000));
    expect(hint, findsNothing);
    typing('typing_start', 2, 11, 2);
    await tester.pump();
    expect(hint, findsNothing);
  });
  testWidgets('uploads the selected image privately only on explicit send', (
    tester,
  ) async {
    FilePicker? original;
    try {
      original = FilePicker.platform;
    } catch (_) {}
    FilePicker.platform = _DirectImagePicker();
    addTearDown(() => FilePicker.platform = original ?? _DirectImagePicker());
    final api = _FakeChatApi(
      initialMessages: [_message(messageId: 6, content: 'reply target')],
    );
    final media = _DirectMediaApi();
    await _pumpConversation(tester, api, media: media);
    await tester.pumpAndSettle();
    final send = find.byKey(const Key('dm-send-button'));
    expect(tester.widget<IconButton>(send).onPressed, isNull);
    await tester.tap(find.byKey(const Key('dm-reply-6')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('dm-attach-button')));
    await tester.pumpAndSettle();
    expect(find.text('draft.png'), findsOneWidget);
    expect(media.calls, isEmpty);
    expect(api.sentContent, isNull);
    expect(tester.widget<IconButton>(send).onPressed, isNotNull);
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(media.calls, [('image', 'chat')]);
    expect(api.sentContent, '');
    expect(api.sentAttachmentIds, [7]);
    expect(api.sentReplyId, 6);
  });

  testWidgets('updates only the addressed visible message with exact GET', (
    tester,
  ) async {
    final realtime = _FakeRealtimeService();
    addTearDown(realtime.dispose);
    final api = _FakeChatApi(
      initialMessages: [
        _message(messageId: 2, content: 'newest item'),
        _message(messageId: 1, content: 'known old item'),
      ],
    );
    await _pumpConversation(tester, api, realtime: realtime);
    await tester.pumpAndSettle();
    api.messages[1] = _message(messageId: 1, content: 'updated exact item');
    void event(int conversation, int message) => realtime.listeners.single({
      'type': 'direct_message_updated',
      'data': {'conversation_id': conversation, 'message_id': message},
    });
    event(18, 1);
    event(11, 10);
    event(11, 1);
    await tester.pumpAndSettle();
    expect(api.exactReads, [(11, 1)]);
    expect(api.listedPages, [1]);
    expect(find.text('newest item'), findsOneWidget);
    expect(find.text('known old item'), findsNothing);
    expect(find.text('updated exact item'), findsOneWidget);
  });

  testWidgets(
    'renders a private attachment and quote while toggling reactions',
    (tester) async {
      final api = _FakeChatApi(
        initialMessages: [
          _message(
            messageId: 9,
            content: 'latest',
            replyTo: V2ChatMessageReply(
              messageId: 8,
              content: 'earlier',
              authorName: 'Edge',
            ),
            media: [
              V2MediaAsset.fromJson({
                'media_id': 7,
                'public_url': '/api/v2/media/7/content',
                'file_name': 'private.png',
                'status': 'ready',
              }),
            ],
          ),
        ],
      );
      await _pumpConversation(tester, api);
      await tester.pumpAndSettle();
      expect(find.text('Edge: earlier'), findsOneWidget);
      expect(
        find.widgetWithText(PrivateAttachmentButton, 'private.png'),
        findsOneWidget,
      );
      expect(find.byType(Image), findsNothing);
      await tester.tap(find.byKey(const Key('dm-reaction-menu-9')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('👍'));
      await tester.pumpAndSettle();
      final reaction = find.byKey(const ValueKey('dm-reaction-9-👍'));
      expect(reaction, findsOneWidget);
      await tester.tap(reaction);
      await tester.pumpAndSettle();
      expect(reaction, findsNothing);
      expect(api.reactionWrites, [(11, 9, '👍', true), (11, 9, '👍', false)]);
      expect(api.listedPages, [1]);
      expect(find.text('Edge: earlier'), findsOneWidget);
    },
  );

  testWidgets('sending leaves text entered while the receipt is pending', (
    tester,
  ) async {
    final realtime = _FakeRealtimeService();
    addTearDown(realtime.dispose);
    final receipt = Completer<void>();
    final api = _FakeChatApi()..beforeSend = () => receipt.future;
    await _pumpConversation(tester, api, realtime: realtime);
    await tester.pumpAndSettle();
    final composer = find.byKey(const Key('dm-composer-field'));
    await tester.enterText(composer, 'first draft');
    await tester.pump();
    final send = find.byKey(const Key('dm-send-button'));
    await tester.tap(send);
    await tester.pump();
    expect(tester.widget<IconButton>(send).onPressed, isNull);
    await tester.enterText(composer, 'next draft');
    receipt.complete();
    await tester.pumpAndSettle();
    expect(api.sentContent, 'first draft');
    expect(tester.widget<TextField>(composer).controller?.text, 'next draft');
  });

  testWidgets('visible private messages coalesce an explicit read commit', (
    tester,
  ) async {
    final realtime = _FakeRealtimeService();
    addTearDown(realtime.dispose);
    final api = _FakeChatApi(
      initialMessages: [_message(messageId: 1, content: 'first page')],
    )..supportsReadStatus = true;
    await _pumpConversation(tester, api, realtime: realtime);
    await tester.pumpAndSettle();
    void receive(
      int id, {
      int conversation = 11,
      String type = 'direct_message',
    }) {
      realtime.listeners.single({
        'type': type,
        'data': {
          'conversation_id': conversation,
          'direct_message': {
            'message_id': id,
            'conversation_id': 11,
            'content': 'incoming $id',
            'author': {'user_id': 99, 'username': 'sender'},
            'created_at': '2026-05-25T00:00:01.000Z',
            'is_deleted': false,
          },
        },
      });
    }

    receive(5, conversation: 17);
    receive(6, type: 'notification_created');
    realtime.listeners.single({
      'type': 'direct_message_deleted',
      'data': {'conversation_id': 11, 'message_id': 1.5},
    });
    receive(2);
    receive(3);
    expect(api.listedPages, [1]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(api.listedPages, [1]);
    expect(api.historyMarkRead, [false]);
    expect(api.readWrites, [3]);
    expect(find.text('first page'), findsOneWidget);
    expect(find.text('incoming 2'), findsOneWidget);
    expect(find.text('incoming 3'), findsOneWidget);
    expect(find.text('incoming 5'), findsNothing);
    expect(find.text('incoming 6'), findsNothing);

    final navigator = Navigator.of(
      tester.element(find.byType(ConversationScreen)),
    );
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('covering route')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    receive(4);
    await tester.pump(const Duration(milliseconds: 300));
    expect(api.listedPages, [1]);
    expect(api.readWrites, [3]);

    navigator.pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    expect(api.listedPages, [1]);
    expect(api.readWrites, [3, 4]);
    expect(find.text('incoming 4'), findsOneWidget);
  });

  testWidgets(
    'read indicator follows the peer cursor and reloads on reconnect',
    (tester) async {
      final socket = _FakeRealtimeService();
      addTearDown(socket.dispose);
      final api =
          _FakeChatApi(
              initialMessages: [
                _message(messageId: 1, content: 'first'),
                _message(messageId: 2, content: 'second'),
                _message(messageId: 3, content: 'removed during disconnect'),
              ],
            )
            ..supportsReadStatus = true
            ..ownRead = 3
            ..peerRead = 1;
      await _pumpConversation(tester, api, realtime: socket, viewerId: 1);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dm-read-1')), findsOneWidget);
      expect(find.byKey(const Key('dm-read-2')), findsNothing);
      socket.listeners.single({
        'type': 'direct_read_updated',
        'data': {
          'conversation_id': 11,
          'reader_id': 1,
          'last_read_message_id': 2,
        },
      });
      await tester.pump();
      expect(find.byKey(const Key('dm-read-1')), findsOneWidget);

      api.peerRead = 2;
      api.messages.removeWhere((message) => message.messageId == 3);
      socket.publish(RemoteEvents.connected);
      socket.recovered.add(1);
      await tester.pumpAndSettle();
      expect(api.statusReads, 2);
      expect(api.listedPages, [1, 1]);
      expect(api.historyMarkRead, [false, false]);
      expect(find.byKey(const Key('dm-read-1')), findsNothing);
      expect(find.byKey(const Key('dm-read-2')), findsOneWidget);
      expect(find.text('removed during disconnect'), findsNothing);
    },
  );
  testWidgets('does not acknowledge fetched messages outside the viewport', (
    tester,
  ) async {
    final api = _FakeChatApi(
      initialMessages: [
        _message(
          messageId: 99,
          content: 'oldest in feed',
          createdAt: '2026-05-20T00:00:00Z',
        ),
        for (var id = 1; id <= 18; id++)
          _message(messageId: id, content: 'message $id'),
      ],
    )..supportsReadStatus = true;
    await _pumpConversation(tester, api);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    expect(api.readWrites, [18]);

    final controller = tester
        .widget<ListView>(find.byType(ListView))
        .controller!;
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('oldest in feed'), findsOneWidget);
    expect(api.readWrites, [18, 99]);
  });

  testWidgets(
    'an in-flight older page cannot restore a deleted direct message',
    (tester) async {
      final pending = Completer<void>();
      var reads = 0;
      final api = _FakeChatApi(
        pageWindows: {
          1: [_message(messageId: 20, content: 'newest')],
          2: [
            _message(messageId: 4, content: 'still older'),
            _message(messageId: 5, content: 'deleted during paging'),
          ],
        },
        pageHasNext: {1: true},
        beforeList: () async {
          if (++reads == 2) await pending.future;
        },
      );
      final realtime = _FakeRealtimeService();
      addTearDown(realtime.dispose);
      await _pumpConversation(tester, api, realtime: realtime);
      await tester.pumpAndSettle();
      await tester.tap(find.text('加载更早的消息'));
      await tester.pump();
      expect(api.listedPages, [1, 2]);
      for (final listener in List.of(realtime.listeners)) {
        listener({
          'type': 'direct_message_deleted',
          'data': {'conversation_id': 11, 'message_id': 5},
        });
      }
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.text('still older'), findsOneWidget);
      expect(find.text('newest'), findsOneWidget);
      expect(find.text('deleted during paging'), findsNothing);
    },
  );
  test(
    'channel rebind uses nested commands and discards the old listener',
    () async {
      final old = _FakeRealtimeService(), next = _FakeRealtimeService();
      final events = <Map<String, dynamic>>[];
      var resets = 0, reloads = 0;
      final binding = ChatRealtimeBinding(
        tokenStore: _FakeTokenStore(),
        channelId: 11,
        onEvent: events.add,
        onReset: () => resets++,
        onReload: () => reloads++,
      );
      try {
        binding.bind(old);
        final stale = old.listeners.single;
        await Future<void>.delayed(Duration.zero);
        expect(old.sent, isEmpty);
        old.publish(RemoteEvents.unavailable);
        await Future<void>.delayed(Duration.zero);
        expect(old.sent.single, {
          'type': 'chat_join_channel',
          'data': {'channelId': 11},
        });
        final oldRequest = binding.capture();
        binding.bind(next);
        stale({'type': 'chat_message'});
        expect(oldRequest(), false);
        expect(events, isEmpty);
        expect(old.listeners, isEmpty);
        expect(old.sent.last, {
          'type': 'chat_leave_channel',
          'data': {'channelId': 11},
        });
        expect(resets, 1);
        expect(reloads, 1);
        next.publish(RemoteEvents.connected);
        await Future<void>.delayed(Duration.zero);
        expect(next.sent.single, {
          'type': 'chat_join_channel',
          'data': {'channelId': 11},
        });
        next.publish(RemoteEvents.unknown);
        next.publish(RemoteEvents.connected);
        next.recovered.add(1);
        await Future<void>.delayed(Duration.zero);
        expect(next.sent, hasLength(2));
        expect(reloads, 2);
      } finally {
        binding.dispose();
        await old.dispose();
        await next.dispose();
      }
    },
  );

  testWidgets('conversation sends text and shows it', (tester) async {
    final api = _FakeChatApi(
      initialMessages: [_message(messageId: 1, content: 'hello edge')],
    );

    await _pumpConversation(tester, api, title: 'Edge');
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'Edge'), findsOneWidget);
    expect(find.text('hello edge'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('dm-composer-field')), 'ping');
    await tester.pump();
    await tester.tap(find.byKey(const Key('dm-send-button')));
    await tester.pumpAndSettle();

    expect(api.sentContent, 'ping');
    expect(find.text('ping'), findsOneWidget);
  });

  testWidgets(
    'private message deletion confirms and uses the conversation route',
    (tester) async {
      final api = _FakeChatApi(
        initialMessages: [
          _message(messageId: 5, content: 'private message', canDelete: true),
        ],
      );
      await _pumpConversation(tester, api, viewerId: 1);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('dm-delete-5')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dm-delete-confirm-button')), findsOneWidget);
      expect(api.directDeletes, isEmpty);
      await tester.tap(find.byKey(const Key('dm-delete-confirm-button')));
      await tester.pumpAndSettle();
      expect(api.directDeletes, [(11, 5)]);
      expect(api.channelDeletes, isEmpty);
      expect(find.text('private message'), findsNothing);
    },
  );

  testWidgets('a late history response preserves an incoming private message', (
    tester,
  ) async {
    final pending = Completer<void>();
    final realtime = _FakeRealtimeService();
    addTearDown(realtime.dispose);
    final api = _FakeChatApi(
      initialMessages: [_message(messageId: 5, content: 'older from history')],
      beforeList: () => pending.future,
    );
    await _pumpConversation(tester, api, realtime: realtime);
    await tester.pump();
    realtime.listeners.single({
      'type': 'direct_message',
      'data': {
        'conversation_id': 11,
        'direct_message': {
          'conversation_id': 11,
          'message_id': 6,
          'content': 'new from realtime',
          'author': {'user_id': 1, 'username': 'edge'},
          'created_at': '2026-05-25T00:00:01.000Z',
          'is_deleted': false,
        },
      },
    });
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('older from history'), findsOneWidget);
    expect(find.text('new from realtime'), findsOneWidget);
  });

  testWidgets(
    'mounted conversation reloads on endpoint change and ignores the old response',
    (tester) async {
      final pending = Completer<void>();
      final oldApi = _FakeChatApi(
        initialMessages: [_message(content: 'old backend')],
        beforeList: () => pending.future,
      );
      final nextApi = _FakeChatApi(
        initialMessages: [_message(content: 'new backend')],
      );
      final old = _FakeRealtimeService(), next = _FakeRealtimeService();
      final switchEndpoint = StateProvider<bool>((_) => false);
      final container = ProviderContainer(
        overrides: [
          chatApiProvider.overrideWith(
            (ref) => ref.watch(switchEndpoint) ? nextApi : oldApi,
          ),
          realtimeServiceProvider.overrideWith(
            (ref) => ref.watch(switchEndpoint) ? next : old,
          ),
        ],
      );
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              localizationsDelegates: [
                AppLocalizationsDelegate(),
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: AppLocalizations.supported,
              home: ConversationScreen(conversationId: 11),
            ),
          ),
        );
        await tester.pump();
        expect(old.listeners, hasLength(1));
        container.read(switchEndpoint.notifier).state = true;
        await tester.pumpAndSettle();
        expect(old.listeners, isEmpty);
        expect(next.listeners, hasLength(1));
        expect(find.text('new backend'), findsOneWidget);
        pending.complete();
        await tester.pumpAndSettle();
        expect(find.text('old backend'), findsNothing);
        expect(find.text('new backend'), findsOneWidget);
      } finally {
        if (!pending.isCompleted) pending.complete();
        await tester.pumpWidget(const SizedBox());
        container.dispose();
        await old.dispose();
        await next.dispose();
      }
    },
  );

  testWidgets('conversation empty state when no messages', (tester) async {
    final api = _FakeChatApi();

    await _pumpConversation(tester, api);
    await tester.pumpAndSettle();

    expect(find.text('还没有私信，打个招呼吧'), findsOneWidget);
  });

  testWidgets(
    'conversation reverses ASC page so newest sits nearest composer',
    (tester) async {
      // Server returns ASC [old, mid, new] within a page.
      final api = _FakeChatApi(
        initialMessages: [
          _message(messageId: 1, content: 'A-old'),
          _message(messageId: 2, content: 'B-mid'),
          _message(messageId: 3, content: 'C-new'),
        ],
      );

      await _pumpConversation(tester, api);
      await tester.pumpAndSettle();

      final a = tester.getTopLeft(find.text('A-old'));
      final c = tester.getTopLeft(find.text('C-new'));
      // reverse ListView: larger dy is closer to the bottom / composer.
      expect(c.dy, greaterThan(a.dy));
    },
  );

  testWidgets('conversation page history loads older messages without before', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final page1 = List.generate(
      8,
      (i) => _message(
        messageId: 100 + i,
        content: 'Page1 message $i\nsecond line\nthird line',
      ),
    );
    final api = _FakeChatApi(
      pageWindows: {
        1: page1,
        2: [
          _message(messageId: 0, content: 'Z-older'),
          _message(messageId: 1, content: 'A-old'),
        ],
      },
      pageHasNext: {1: true, 2: false},
    );

    await _pumpConversation(tester, api);
    await tester.pumpAndSettle();

    expect(api.lastListPage, 1);
    expect(api.lastBeforeMessageId, isNull);
    expect(find.text('Z-older'), findsNothing);

    // reverse:true — scroll toward maxScrollExtent to load older pages.
    final scrollables = tester.stateList<ScrollableState>(
      find.byType(Scrollable),
    );
    final position = scrollables
        .map((s) => s.position)
        .firstWhere(
          (p) => p.maxScrollExtent > 0,
          orElse: () => scrollables.first.position,
        );
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    for (var i = 0; i < 6 && (api.lastListPage ?? 1) < 2; i++) {
      await tester.fling(
        find.byType(ListView).first,
        const Offset(0, 900),
        3000,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();

    // Contract: history is page-based and never uses before=.
    expect(api.lastListPage, 2);
    expect(api.lastBeforeMessageId, isNull);
    expect(api.listedPages, containsAll([1, 2]));
  });
}

Future<void> _pumpConversation(
  WidgetTester tester,
  _FakeChatApi api, {
  String? title,
  _FakeRealtimeService? realtime,
  int? viewerId,
  MediaApi? media,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appConfigBundleProvider.overrideWithValue(_testBundle),
        appConfigInitialProvider.overrideWithValue(_testConfig),
        chatApiProvider.overrideWithValue(api),
        if (media != null) mediaApiProvider.overrideWithValue(media),
        if (viewerId == 1)
          tokenStoreProvider.overrideWithValue(
            _FakeTokenStore(
              const TokenPair(
                accessToken: 'e30.eyJ1c2VySWQiOjF9.fixture',
                refreshToken: 'fixture',
                sessionId: 'fixture',
              ),
            ),
          ),
        realtimeServiceProvider.overrideWithValue(
          realtime ?? _FakeRealtimeService(),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizationsDelegate(),
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supported,
        home: ConversationScreen(conversationId: 11, title: title),
      ),
    ),
  );
}

class _FakeChatApi extends ChatApi {
  _FakeChatApi({
    List<V2DirectMessage> initialMessages = const [],
    this.beforeList,
    this.pageWindows,
    Map<int, bool>? pageHasNext,
  }) : messages = List.of(initialMessages),
       pageHasNext = pageHasNext ?? const {},
       super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  final List<V2DirectMessage> messages;
  final Future<void> Function()? beforeList;
  final Map<int, List<V2DirectMessage>>? pageWindows;
  final Map<int, bool> pageHasNext;
  String? sentContent;
  Future<void> Function()? beforeSend;
  int? sentConversationId;
  final exactReads = <(int, int)>[];
  final reactionWrites = <(int, int, String, bool)>[];
  List<int>? sentAttachmentIds;
  int? sentReplyId;
  int? lastListPage;
  int? lastBeforeMessageId;
  final List<int> listedPages = [];
  final historyMarkRead = <bool>[];
  final searchReads = <(int, String, int?)>[];
  Map<int, List<V2DirectMessage>>? searchWindows;
  V2PublicUser? searchParticipant;
  Future<void> Function()? beforeSearch;
  final readWrites = <int>[];
  bool supportsReadStatus = false;
  int? ownRead, peerRead;
  int statusReads = 0;
  final List<int> channelDeletes = [];
  final List<(int, int)> directDeletes = [];
  int _nextId = 100;

  @override
  Future<PagedResult<V2DirectMessage>> listDirectMessages({
    required int conversationId,
    int page = 1,
    int size = 30,
    bool markRead = true,
    String? search,
    int? senderId,
    DateTime? startAt,
    DateTime? endAt,
    int? beforeMessageId,
  }) async {
    lastListPage = page;
    lastBeforeMessageId = beforeMessageId;
    listedPages.add(page);
    historyMarkRead.add(markRead);
    await beforeList?.call();
    final filtered = searchWindows;
    if (search != null && search.isNotEmpty && filtered != null) {
      searchReads.add((page, search, senderId));
      await beforeSearch?.call();
      final items = filtered[page] ?? [];
      return PagedResult(
        items: items,
        meta: ApiMeta(
          page: page,
          pageSize: size,
          total: filtered.values.fold<int>(0, (sum, rows) => sum + rows.length),
          hasNext: filtered.containsKey(page + 1),
        ),
      );
    }
    final window = pageWindows?[page];
    final items = window ?? List.of(messages);
    return PagedResult(
      items: items,
      meta: ApiMeta(
        page: page,
        pageSize: size,
        total: items.length,
        hasNext: pageHasNext[page] ?? false,
      ),
    );
  }

  @override
  Future<V2DirectConversation?> getDirectConversation(
    int conversationId,
  ) async {
    final participant = searchParticipant;
    if (participant == null) return null;
    return V2DirectConversation(
      conversationId: conversationId,
      participant: participant,
      unreadCount: 0,
      createdAt: '',
      updatedAt: '',
    );
  }

  @override
  Future<V2DirectReadStatus> getDirectReadStatus({
    required int conversationId,
    CancelToken? cancelToken,
  }) async {
    statusReads++;
    if (!supportsReadStatus) throw const FormatException('Legacy fixture');
    return _status(conversationId);
  }

  @override
  Future<V2DirectReadStatus> setDirectReadStatus({
    required int conversationId,
    required int lastReadMessageId,
    CancelToken? cancelToken,
  }) async {
    readWrites.add(lastReadMessageId);
    if (lastReadMessageId > (ownRead ?? 0)) ownRead = lastReadMessageId;
    return _status(conversationId);
  }

  V2DirectReadStatus _status(int conversationId) => (
    conversationId: conversationId,
    lastReadMessageId: ownRead,
    participantLastReadMessageId: peerRead,
    unreadCount: 0,
  );

  @override
  Future<V2DirectMessage> sendDirectMessage({
    required int conversationId,
    String content = '',
    List<int> mediaIds = const [],
    int? replyToMessageId,
    CancelToken? cancelToken,
  }) async {
    sentConversationId = conversationId;
    sentContent = content;
    sentAttachmentIds = mediaIds;
    sentReplyId = replyToMessageId;
    await beforeSend?.call();
    final message = _message(
      messageId: _nextId++,
      conversationId: conversationId,
      content: content,
      canDelete: true,
    );
    messages.add(message);
    return message;
  }

  @override
  Future<V2DirectMessage> getDirectMessage({
    required int conversationId,
    required int messageId,
    CancelToken? cancelToken,
  }) async {
    exactReads.add((conversationId, messageId));
    return messages.singleWhere((message) => message.messageId == messageId);
  }

  @override
  Future<V2DirectMessage> setDirectMessageReaction({
    required int conversationId,
    required int messageId,
    required String emoji,
    required bool reacted,
    CancelToken? cancelToken,
  }) async {
    reactionWrites.add((conversationId, messageId, emoji, reacted));
    final index = messages.indexWhere(
      (message) => message.messageId == messageId,
    );
    final message = messages[index];
    return messages[index] = _message(
      messageId: messageId,
      conversationId: conversationId,
      content: message.content,
      replyTo: message.replyTo,
      media: message.media,
      reactions: [
        if (reacted)
          V2ChatReactionSummary(emoji: emoji, count: 1, reactedByMe: true),
      ],
    );
  }

  @override
  Future<void> deleteMessage(int messageId) async {
    channelDeletes.add(messageId);
    messages.removeWhere((m) => m.messageId == messageId);
  }

  @override
  Future<void> deleteDirectMessage({
    required int conversationId,
    required int messageId,
  }) async {
    directDeletes.add((conversationId, messageId));
    messages.removeWhere(
      (m) => m.conversationId == conversationId && m.messageId == messageId,
    );
  }
}

class _DirectImagePicker extends FilePicker {
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
  }) async => FilePickerResult([
    PlatformFile(name: 'draft.png', size: 4, bytes: Uint8List(4)),
  ]);
}

class _DirectMediaApi extends MediaApi {
  _DirectMediaApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  final calls = <(String, String?)>[];

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
    calls.add((mediaType, accessScope));
    return V2MediaAsset.fromJson({
      'media_id': 7,
      'status': 'ready',
      'media_type': mediaType,
      'file_name': fileName,
      'public_url': '/api/v2/media/7/content',
    });
  }
}

class _FakeRealtimeService extends RealtimeService {
  _FakeRealtimeService()
    : super(config: _testConfig, tokenStore: _FakeTokenStore());

  final List<RealtimeListener> listeners = [];
  final sent = <Map<String, dynamic>>[];
  final status = StreamController<RemoteEvents>.broadcast();
  final recovered = StreamController<int>.broadcast();
  RemoteEvents _state = RemoteEvents.unknown;

  @override
  RemoteEvents get remoteEvents => _state;

  @override
  Stream<RemoteEvents> get remoteStatus => status.stream;

  @override
  Stream<int> get recovery => recovered.stream;

  void publish(RemoteEvents value) {
    _state = value;
    status.add(value);
  }

  @override
  Future<void> dispose() async {
    await super.dispose();
    await Future.wait([status.close(), recovered.close()]);
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

V2DirectMessage _message({
  int messageId = 1,
  int conversationId = 11,
  String content = '',
  String createdAt = '2026-05-25T00:00:00.000Z',
  bool canDelete = false,
  V2ChatMessageReply? replyTo,
  List<V2MediaAsset> media = const [],
  List<V2ChatReactionSummary> reactions = const [],
}) {
  return V2DirectMessage(
    messageId: messageId,
    conversationId: conversationId,
    content: content,
    author: _user,
    isDeleted: false,
    canDelete: canDelete,
    createdAt: createdAt,
    updatedAt: '2026-05-25T00:00:00.000Z',
    replyTo: replyTo,
    media: media,
    reactions: reactions,
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

const _testConfig = AppConfig(
  apiBaseUrl: 'http://example.test',
  wsBaseUrl: 'ws://example.test',
  storageBaseUrl: 'http://example.test',
);

const _testBundle = AppConfigBundle(defaults: _testConfig, presets: []);

class _FakeTokenStore extends TokenStore {
  _FakeTokenStore([this.pair]);
  final TokenPair? pair;
  @override
  Future<TokenPair?> read() async => pair;

  @override
  Future<void> write(TokenPair pair) async {}

  @override
  Future<void> clear() async {}

  @override
  Future<String> deviceFingerprint() async => 'test-device';
}
