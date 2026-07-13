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
import 'package:nekotribe/features/chat/presentation/conversation_screen.dart';
import 'package:nekotribe/features/realtime/data/realtime_service.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/shared/i18n/app_localizations.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
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

  testWidgets('conversation empty state when no messages', (tester) async {
    final api = _FakeChatApi();

    await _pumpConversation(tester, api);
    await tester.pumpAndSettle();

    expect(find.text('还没有私信，打个招呼吧'), findsOneWidget);
  });

  testWidgets('conversation reverses ASC page so newest sits nearest composer', (
    tester,
  ) async {
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
  });

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
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appConfigBundleProvider.overrideWithValue(_testBundle),
        appConfigInitialProvider.overrideWithValue(_testConfig),
        chatApiProvider.overrideWithValue(api),
        realtimeServiceProvider.overrideWithValue(_FakeRealtimeService()),
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
    this.pageWindows,
    Map<int, bool>? pageHasNext,
  }) : messages = List.of(initialMessages),
       pageHasNext = pageHasNext ?? const {},
       super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  final List<V2DirectMessage> messages;
  final Map<int, List<V2DirectMessage>>? pageWindows;
  final Map<int, bool> pageHasNext;
  String? sentContent;
  int? sentConversationId;
  int? lastListPage;
  int? lastBeforeMessageId;
  final List<int> listedPages = [];
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
    messages.removeWhere((m) => m.messageId == messageId);
  }
}

class _FakeRealtimeService extends RealtimeService {
  _FakeRealtimeService()
    : super(config: _testConfig, tokenStore: _FakeTokenStore());

  final List<RealtimeListener> listeners = [];

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
  @override
  Future<TokenPair?> read() async => null;

  @override
  Future<void> write(TokenPair pair) async {}

  @override
  Future<void> clear() async {}

  @override
  Future<String> deviceFingerprint() async => 'test-device';
}
