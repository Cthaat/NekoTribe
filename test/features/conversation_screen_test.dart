import 'dart:async';

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
import 'package:nekotribe/features/realtime/data/realtime_service.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/shared/i18n/app_localizations.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
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
    await tester.tap(find.byKey(const Key('dm-send-button')));
    await tester.pump();
    await tester.enterText(composer, 'next draft');
    receipt.complete();
    await tester.pumpAndSettle();
    expect(api.sentContent, 'first draft');
    expect(tester.widget<TextField>(composer).controller?.text, 'next draft');
  });

  testWidgets('incoming private messages coalesce a visible history refresh', (
    tester,
  ) async {
    final realtime = _FakeRealtimeService();
    addTearDown(realtime.dispose);
    final api = _FakeChatApi(
      initialMessages: [_message(messageId: 1, content: 'first page')],
    );
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
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(api.listedPages, [1, 1]);
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
    expect(api.listedPages, [1, 1]);

    navigator.pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    expect(api.listedPages, [1, 1, 1]);
    expect(find.text('incoming 4'), findsOneWidget);
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
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appConfigBundleProvider.overrideWithValue(_testBundle),
        appConfigInitialProvider.overrideWithValue(_testConfig),
        chatApiProvider.overrideWithValue(api),
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
  int? lastListPage;
  int? lastBeforeMessageId;
  final List<int> listedPages = [];
  final List<int> channelDeletes = [];
  final List<(int, int)> directDeletes = [];
  int _nextId = 100;

  @override
  Future<PagedResult<V2DirectMessage>> listDirectMessages({
    required int conversationId,
    int page = 1,
    int size = 30,
    int? beforeMessageId,
  }) async {
    lastListPage = page;
    lastBeforeMessageId = beforeMessageId;
    listedPages.add(page);
    await beforeList?.call();
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
  Future<V2DirectMessage> sendDirectMessage({
    required int conversationId,
    required String content,
  }) async {
    sentConversationId = conversationId;
    sentContent = content;
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
  bool canDelete = false,
}) {
  return V2DirectMessage(
    messageId: messageId,
    conversationId: conversationId,
    content: content,
    author: _user,
    isDeleted: false,
    canDelete: canDelete,
    createdAt: '2026-05-25T00:00:00.000Z',
    updatedAt: '2026-05-25T00:00:00.000Z',
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
