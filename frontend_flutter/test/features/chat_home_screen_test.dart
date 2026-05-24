import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/features/chat/data/chat_api.dart';
import 'package:nekotribe/features/chat/domain/chat_models.dart';
import 'package:nekotribe/features/chat/presentation/chat_home_screen.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  testWidgets('group chat opens a channel picker before navigation', (
    tester,
  ) async {
    final api = _FakeChatApi();

    await _pumpChatHome(tester, api);
    await _openGroupPicker(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('选择频道'), findsOneWidget);
    expect(find.text('#general'), findsOneWidget);
    expect(find.text('#announcements'), findsOneWidget);
    expect(find.text('新建频道'), findsOneWidget);

    await tester.tap(find.text('#general'));
    await tester.pumpAndSettle();

    expect(find.text('Channel 7'), findsOneWidget);
  });

  testWidgets('manager can create a group channel from the picker', (
    tester,
  ) async {
    final api = _FakeChatApi();

    await _pumpChatHome(tester, api);
    await _openGroupPicker(tester);

    await tester.tap(find.text('新建频道'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('频道名称'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'team-chat');
    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    await tester.pumpAndSettle();

    expect(api.createdChannelName, 'team-chat');
    expect(find.text('Channel 99'), findsOneWidget);
  });
}

Future<void> _pumpChatHome(WidgetTester tester, _FakeChatApi api) async {
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const ChatHomeScreen()),
      GoRoute(
        path: '/chat/groups/:groupId/channels/:channelId',
        builder: (_, state) => Scaffold(
          body: Text('Channel ${state.pathParameters['channelId']}'),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appConfigBundleProvider.overrideWithValue(_testBundle),
        appConfigInitialProvider.overrideWithValue(_testConfig),
        chatApiProvider.overrideWithValue(api),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openGroupPicker(WidgetTester tester) async {
  await tester.tap(find.text('群聊'));
  await tester.pumpAndSettle();

  expect(find.text('Cat Town'), findsOneWidget);

  await tester.tap(find.text('Cat Town'));
  await tester.pumpAndSettle();
}

class _FakeChatApi extends ChatApi {
  _FakeChatApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  String? createdChannelName;

  @override
  Future<List<V2DirectConversation>> listConversations() async => [];

  @override
  Future<List<V2ChatGroup>> listChatGroups() async => [
    V2ChatGroup(
      groupId: 42,
      name: 'Cat Town',
      memberCount: 3,
      channelCount: 2,
      unreadCount: 0,
      role: 'owner',
      canManage: true,
    ),
  ];

  @override
  Future<List<V2ChatChannel>> listChannels(int groupId) async => [
    V2ChatChannel(
      channelId: 7,
      groupId: groupId,
      name: 'general',
      type: 'text',
      category: '',
      position: 1,
      isPrivate: false,
      isMutedByMe: false,
      unreadCount: 2,
      createdAt: '2026-05-24T00:00:00.000Z',
      updatedAt: '2026-05-24T00:00:00.000Z',
      canManage: true,
    ),
    V2ChatChannel(
      channelId: 8,
      groupId: groupId,
      name: 'announcements',
      type: 'text',
      category: '',
      position: 2,
      isPrivate: false,
      isMutedByMe: true,
      unreadCount: 0,
      createdAt: '2026-05-24T00:00:00.000Z',
      updatedAt: '2026-05-24T00:00:00.000Z',
      canManage: true,
    ),
  ];

  @override
  Future<V2ChatChannel> createChannel({
    required int groupId,
    required String name,
    String type = 'text',
    String? category,
    bool isPrivate = false,
  }) async {
    createdChannelName = name;
    return V2ChatChannel(
      channelId: 99,
      groupId: groupId,
      name: name,
      type: type,
      category: category ?? '',
      position: 3,
      isPrivate: isPrivate,
      isMutedByMe: false,
      unreadCount: 0,
      createdAt: '2026-05-24T00:00:00.000Z',
      updatedAt: '2026-05-24T00:00:00.000Z',
      canManage: true,
    );
  }
}

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
