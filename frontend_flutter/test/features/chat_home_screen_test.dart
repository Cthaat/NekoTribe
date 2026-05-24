import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigBundleProvider.overrideWithValue(_testBundle),
          appConfigInitialProvider.overrideWithValue(_testConfig),
          chatApiProvider.overrideWithValue(api),
        ],
        child: const MaterialApp(home: ChatHomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('群聊'));
    await tester.pumpAndSettle();

    expect(find.text('Cat Town'), findsOneWidget);

    await tester.tap(find.text('Cat Town'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('选择频道'), findsOneWidget);
    expect(find.text('#general'), findsOneWidget);
    expect(find.text('#announcements'), findsOneWidget);
  });
}

class _FakeChatApi extends ChatApi {
  _FakeChatApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

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
