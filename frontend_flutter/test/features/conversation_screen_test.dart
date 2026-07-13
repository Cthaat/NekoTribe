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
  _FakeChatApi({List<V2DirectMessage> initialMessages = const []})
    : messages = List.of(initialMessages),
      super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  final List<V2DirectMessage> messages;
  String? sentContent;
  int? sentConversationId;
  int _nextId = 100;

  @override
  Future<PagedResult<V2DirectMessage>> listDirectMessages({
    required int conversationId,
    int page = 1,
    int size = 30,
    int? beforeMessageId,
  }) async {
    return PagedResult(
      items: List.of(messages),
      meta: ApiMeta(
        page: page,
        pageSize: size,
        total: messages.length,
        hasNext: false,
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
