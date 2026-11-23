import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_response.dart';
import 'package:nekotribe/features/chat/data/chat_api.dart';
import 'package:nekotribe/features/chat/domain/chat_models.dart';
import 'package:nekotribe/features/chat/presentation/chat_home_screen.dart';
import 'package:nekotribe/features/realtime/data/realtime_service.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  testWidgets('only my read events refresh direct conversation unread badges', (
    tester,
  ) async {
    final api = _FakeChatApi()
      ..conversations = [_conversation(9, 'new post', unread: 2)];
    final socket = _HomeRealtime();
    addTearDown(socket.dispose);
    await _pumpChatHome(
      tester,
      api,
      realtime: socket,
      tokenStore: _FakeTokenStore(
        const TokenPair(
          accessToken: 'e30.eyJ1c2VySWQiOjF9.fixture',
          refreshToken: 'fixture',
          sessionId: 'fixture',
        ),
      ),
    );
    expect(find.text('2'), findsOneWidget);
    api.conversations = [_conversation(9, 'new post')];
    void read(int user) => socket.deliver({
      'type': 'direct_read_updated',
      'data': {
        'conversation_id': 11,
        'reader_id': user,
        'last_read_message_id': 9,
      },
    });
    read(22);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    expect(api.conversationPages, [1]);
    expect(find.text('2'), findsOneWidget);
    read(1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pumpAndSettle();
    expect(api.conversationPages, [1, 1]);
    expect(find.text('2'), findsNothing);
  });
  testWidgets(
    'switching the API endpoint clears an open group channel picker',
    (tester) async {
      final original = _FakeChatApi();
      final replacement = _FakeChatApi();
      final switched = StateProvider<bool>((_) => false);
      await _pumpChatHome(
        tester,
        original,
        selectApi: (ref) => ref.watch(switched) ? replacement : original,
      );
      await _openGroupPicker(tester);
      expect(find.text('#general'), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ChatHomeScreen)),
      );
      container.read(switched.notifier).state = true;
      await tester.pumpAndSettle();
      expect(find.text('#general'), findsNothing);
      expect(find.text('会话已变化，请重新打开频道列表。'), findsOneWidget);
    },
  );

  testWidgets('realtime deletion refreshes the selected conversation page', (
    tester,
  ) async {
    final api = _FakeChatApi()
      ..conversations = [_conversation(9, 'recent page')]
      ..secondConversationPage = [_conversation(8, 'older page')];
    final realtime = _HomeRealtime();
    addTearDown(realtime.dispose);
    await _pumpChatHome(tester, api, realtime: realtime);
    await tester.tap(find.text('下一页'));
    await tester.pumpAndSettle();
    expect(find.text('older page'), findsOneWidget);
    api.secondConversationPage = [_conversation(7, 'new preview')];
    realtime.deliver({
      'type': 'direct_message_deleted',
      'data': {'conversation_id': 11, 'message_id': 8},
    });
    await tester.pump();
    expect(find.text('older page'), findsNothing);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(find.text('new preview'), findsOneWidget);
    expect(find.text('recent page'), findsNothing);
    expect(api.conversationPages, [1, 2, 2]);
  });
  testWidgets('group chat appends the next page without duplicating groups', (
    tester,
  ) async {
    final api = _FakeChatApi()..hasSecondGroupPage = true;
    await _pumpChatHome(tester, api);
    await tester.tap(find.text('群聊'));
    await tester.pumpAndSettle();
    expect(find.text('Cat Town'), findsOneWidget);
    await tester.tap(find.text('加载更多群组'));
    await tester.pumpAndSettle();
    expect(api.groupPages, [1, 2]);
    expect(find.text('Cat Town'), findsOneWidget);
    expect(find.text('Dog Town'), findsOneWidget);
    expect(find.text('加载更多群组'), findsNothing);
  });
  testWidgets(
    'deleted private preview is hidden before the list refresh finishes',
    (tester) async {
      final api = _FakeChatApi()
        ..conversations = [_conversation(8, 'deleted text')];
      final realtime = _HomeRealtime();
      addTearDown(realtime.dispose);
      await _pumpChatHome(tester, api, realtime: realtime);
      expect(find.text('deleted text'), findsOneWidget);
      api.conversations = [_conversation(7, 'previous message')];
      realtime.deliver({
        'type': 'direct_message_deleted',
        'data': {'conversation_id': 11, 'message_id': 8},
      });
      await tester.pump();
      expect(find.text('deleted text'), findsNothing);
      expect(find.text('previous message'), findsNothing);
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      expect(find.text('previous message'), findsOneWidget);
    },
  );

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

    await tester.enterText(
      find.byKey(const Key('chat-channel-name-field')),
      List.filled(34, '猫').join(),
    );
    await tester.pump();
    expect(find.text('频道名称最多 100 个 UTF-8 字节。'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('chat-channel-save-button')),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(
      find.byKey(const Key('chat-channel-name-field')),
      'team-chat',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    await tester.pumpAndSettle();

    expect(api.createdChannelName, 'team-chat');
    expect(find.text('Channel 99'), findsOneWidget);
  });

  testWidgets('manager can mute, edit, and delete channels from picker', (
    tester,
  ) async {
    final api = _FakeChatApi();

    await _pumpChatHome(tester, api);
    await _openGroupPicker(tester);

    await tester.tap(find.byKey(const Key('chat-channel-actions-7')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-channel-mute-7')));
    await tester.pumpAndSettle();
    expect(api.mutedChannelId, 7);
    expect(api.mutedValue, true);

    await tester.tap(find.byKey(const Key('chat-channel-actions-7')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-channel-edit-7')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('chat-channel-name-field')),
      'ops-chat',
    );
    await tester.tap(find.byKey(const Key('chat-channel-save-button')));
    await tester.pumpAndSettle();
    expect(api.updatedChannelId, 7);
    expect(api.updatedChannelName, 'ops-chat');
    expect(api.updatedChannelCategory, '');
    expect(find.text('#ops-chat'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-channel-actions-8')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-channel-delete-8')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-channel-delete-confirm')));
    await tester.pumpAndSettle();
    expect(api.deletedChannelId, 8);
    expect(find.text('#announcements'), findsNothing);
  });

  testWidgets('mute control waits for the confirmed channel state', (
    tester,
  ) async {
    final api = _FakeChatApi()..muteReceipt = Completer<bool>();
    await _pumpChatHome(tester, api);
    await _openGroupPicker(tester);
    final actions = find.byKey(const Key('chat-channel-actions-7'));
    final mute = find.byKey(const Key('chat-channel-mute-7'));
    await tester.tap(actions);
    await tester.pumpAndSettle();
    await tester.tap(mute);
    await tester.pumpAndSettle();
    await tester.tap(actions);
    await tester.pumpAndSettle();
    expect(tester.widget<PopupMenuItem<String>>(mute).enabled, isFalse);
    expect(api.muteCalls, 1);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    api.muteReceipt!.complete(false);
    await tester.pumpAndSettle();
    expect(api.mutedValue, isTrue);
    final channelTile = find.ancestor(
      of: actions,
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(of: channelTile, matching: find.byTooltip('已静音')),
      findsNothing,
    );
    await tester.tap(actions);
    await tester.pumpAndSettle();
    expect(tester.widget<PopupMenuItem<String>>(mute).enabled, isTrue);
  });
}

Future<void> _pumpChatHome(
  WidgetTester tester,
  _FakeChatApi api, {
  _HomeRealtime? realtime,
  ChatApi Function(Ref)? selectApi,
  TokenStore? tokenStore,
}) async {
  final socket = realtime ?? _HomeRealtime();
  if (realtime == null) addTearDown(socket.dispose);
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
        chatApiProvider.overrideWith(selectApi ?? (_) => api),
        realtimeServiceProvider.overrideWithValue(socket),
        if (tokenStore != null)
          tokenStoreProvider.overrideWithValue(tokenStore),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

V2DirectConversation _conversation(
  int message,
  String content, {
  int unread = 0,
}) => V2DirectConversation.fromJson({
  'conversation_id': 11,
  'participant': {'user_id': 22, 'username': 'peer'},
  'unread_count': unread,
  'last_message': {'message_id': message, 'content': content},
});

class _HomeRealtime extends RealtimeService {
  _HomeRealtime() : super(config: _testConfig, tokenStore: _FakeTokenStore());

  final _listeners = <RealtimeListener>[];

  @override
  Future<void> connect() async {}

  @override
  void addListener(RealtimeListener listener) => _listeners.add(listener);

  @override
  void removeListener(RealtimeListener listener) => _listeners.remove(listener);

  void deliver(Map<String, dynamic> event) {
    for (final listener in List.of(_listeners)) {
      listener(event);
    }
  }
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
  int? mutedChannelId;
  bool? mutedValue;
  Completer<bool>? muteReceipt;
  int muteCalls = 0;
  bool hasSecondGroupPage = false;
  final groupPages = <int>[];
  int? updatedChannelId;
  String? updatedChannelName;
  String? updatedChannelCategory;
  int? deletedChannelId;
  List<V2DirectConversation> conversations = [];
  List<V2DirectConversation>? secondConversationPage;
  final conversationPages = <int>[];
  final channels = <V2ChatChannel>[
    V2ChatChannel(
      channelId: 7,
      groupId: 42,
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
      groupId: 42,
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
  Future<PagedResult<V2DirectConversation>> listConversations({
    int page = 1,
  }) async {
    conversationPages.add(page);
    return PagedResult(
      items: page == 1 ? conversations : secondConversationPage ?? [],
      meta: ApiMeta(
        page: page,
        hasNext: page == 1 && secondConversationPage != null,
      ),
    );
  }

  @override
  Future<PagedResult<V2ChatGroup>> listChatGroups({int page = 1}) async {
    groupPages.add(page);
    final first = V2ChatGroup(
      groupId: 42,
      name: 'Cat Town',
      memberCount: 3,
      channelCount: 2,
      unreadCount: 0,
      role: 'owner',
      canManage: true,
    );
    return PagedResult(
      items: [
        first,
        if (page == 2)
          V2ChatGroup(
            groupId: 44,
            name: 'Dog Town',
            memberCount: 1,
            channelCount: 1,
            unreadCount: 0,
            role: 'member',
            canManage: false,
          ),
      ],
      meta: ApiMeta(page: page, hasNext: page == 1 && hasSecondGroupPage),
    );
  }

  @override
  Future<List<V2ChatChannel>> listChannels(int groupId) async =>
      List.of(channels);

  @override
  Future<V2ChatChannel> createChannel({
    required int groupId,
    required String name,
    String type = 'text',
    String? category,
    bool isPrivate = false,
  }) async {
    createdChannelName = name;
    final channel = V2ChatChannel(
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
    channels.add(channel);
    return channel;
  }

  @override
  Future<bool> setChannelMuteStatus({
    required int channelId,
    required bool isMuted,
  }) async {
    muteCalls++;
    mutedChannelId = channelId;
    mutedValue = isMuted;
    final confirmed = await muteReceipt?.future ?? isMuted;
    final index = channels.indexWhere(
      (channel) => channel.channelId == channelId,
    );
    if (index >= 0) {
      channels[index] = _channelCopy(channels[index], isMutedByMe: confirmed);
    }
    return confirmed;
  }

  @override
  Future<V2ChatChannel> updateChannel({
    required int channelId,
    String? name,
    String? category,
    bool? isPrivate,
  }) async {
    updatedChannelId = channelId;
    updatedChannelName = name;
    updatedChannelCategory = category;
    final index = channels.indexWhere(
      (channel) => channel.channelId == channelId,
    );
    final old = channels[index];
    final updated = _channelCopy(
      old,
      name: name ?? old.name,
      category: category ?? old.category,
      isPrivate: isPrivate ?? old.isPrivate,
    );
    channels[index] = updated;
    return updated;
  }

  @override
  Future<void> deleteChannel(int channelId) async {
    deletedChannelId = channelId;
    channels.removeWhere((channel) => channel.channelId == channelId);
  }
}

V2ChatChannel _channelCopy(
  V2ChatChannel channel, {
  String? name,
  String? category,
  bool? isPrivate,
  bool? isMutedByMe,
}) {
  return V2ChatChannel(
    channelId: channel.channelId,
    groupId: channel.groupId,
    name: name ?? channel.name,
    type: channel.type,
    category: category ?? channel.category,
    position: channel.position,
    isPrivate: isPrivate ?? channel.isPrivate,
    isMutedByMe: isMutedByMe ?? channel.isMutedByMe,
    unreadCount: channel.unreadCount,
    lastMessage: channel.lastMessage,
    createdAt: channel.createdAt,
    updatedAt: channel.updatedAt,
    canManage: channel.canManage,
  );
}

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
