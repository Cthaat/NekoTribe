import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_response.dart';
import 'package:nekotribe/features/chat/data/chat_api.dart';
import 'package:nekotribe/features/chat/domain/chat_models.dart';
import 'package:nekotribe/features/groups/data/groups_api.dart';
import 'package:nekotribe/features/groups/domain/group_models.dart';
import 'package:nekotribe/features/notifications/data/notifications_api.dart';
import 'package:nekotribe/features/notifications/domain/notification_models.dart';
import 'package:nekotribe/features/notifications/presentation/notifications_screen.dart';
import 'package:nekotribe/features/realtime/data/realtime_service.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  test('notification model rejects noncanonical resource identifiers', () {
    for (final id in [7001.5, true, '07001', 9007199254740992]) {
      expect(V2Notification.fromJson({'resource_id': id}).resourceId, isNull);
    }
    expect(V2Notification.fromJson({'resource_id': '7001'}).resourceId, 7001);
  });

  testWidgets('legacy comment notifications open the cited comment', (
    tester,
  ) async {
    final api = _FakeNotificationsApi([
      _notification(
        type: 'comment',
        title: '新评论',
        resourceType: 'comment',
        resourceId: 7001,
        metadata: {'post_id': 100001},
      ),
    ]);
    final router = _router();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(api),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('新评论'));
    await tester.pumpAndSettle();

    expect(find.text('Post 100001 Comment 7001'), findsOneWidget);
    expect(api.readNotificationId, 3001);
    expect(api.readStatus, isTrue);
  });

  testWidgets('conflicting comment IDs open only the valid source post', (
    tester,
  ) async {
    final api = _FakeNotificationsApi([
      _notification(
        type: 'comment',
        title: '评论回复',
        resourceType: 'comment',
        resourceId: 7001,
        metadata: {
          'target_post_id': 100002.5,
          'post_id': '100001',
          'comment_id': 7002,
          'parent_comment_id': 7000,
        },
      ),
    ]);
    final router = _router();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(api),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('评论回复'));
    await tester.pumpAndSettle();
    expect(find.text('Post 100001'), findsOneWidget);
    expect(router.routeInformationProvider.value.uri.queryParameters, isEmpty);
  });

  testWidgets(
    'group comment notifications locate the new reply without listing groups',
    (tester) async {
      final api = _FakeNotificationsApi([
        _notification(
          type: 'group_comment',
          title: '群组新评论',
          resourceType: 'group_comment',
          resourceId: 7001,
          metadata: {
            'group_id': 88,
            'post_id': 100002,
            'parent_comment_id': 7000,
          },
        ),
      ]);
      final router = _router();
      final groups = _FakeGroupsApi();
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ..._overrides(api),
            groupsApiProvider.overrideWithValue(groups),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('群组新评论'));
      await tester.pumpAndSettle();

      expect(find.text('Group 88 Post 100002 Comment 7001'), findsOneWidget);
      expect(groups.myGroupsReads, 0);
      expect(api.readNotificationId, 3001);
      expect(api.readStatus, isTrue);
    },
  );

  testWidgets('group invitation notices open the matching invitation filter', (tester) async {
    final api = _FakeNotificationsApi([
      _notification(
        type: 'group_invite',
        title: '群邀请',
        resourceType: 'group_invite',
        resourceId: 12,
        metadata: {'invite_id': '12'},
      ),
    ]);
    final router = _router();
    addTearDown(router.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: _overrides(api),
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('群邀请'));
    await tester.pumpAndSettle();
    expect(find.text('Invites 12'), findsOneWidget);
  });

  testWidgets('direct message notifications open their conversation detail', (
    tester,
  ) async {
    final api = _FakeNotificationsApi([
      _notification(
        type: 'direct_message',
        title: '新私信',
        resourceType: 'direct_message',
        resourceId: 7001,
        metadata: {'conversation_id': 9001, 'participant_name': 'Old title'},
      ),
    ]);
    final router = _router();
    addTearDown(router.dispose);

    final chat = _NotificationChatApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ..._overrides(api),
          chatApiProvider.overrideWithValue(chat),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('新私信'));
    await tester.pumpAndSettle();

    expect(chat.requested, [9001]);
    expect(find.text('Conversation 9001'), findsNothing);
    expect(find.text('这条私信的会话已不可访问。'), findsOneWidget);
    expect(api.readNotificationId, isNull);

    chat.accessible = true;
    await tester.tap(find.text('新私信'));
    await tester.pumpAndSettle();

    expect(chat.requested, [9001, 9001]);
    expect(find.text('Conversation 9001'), findsOneWidget);
    expect(find.text('Edge'), findsOneWidget);
    expect(find.text('Old title'), findsNothing);
    expect(api.readNotificationId, 3001);
    expect(api.readStatus, isTrue);
  });

  testWidgets('deleted notifications move to trash and can be restored', (
    tester,
  ) async {
    final api = _FakeNotificationsApi([
      _notification(
        notificationId: 3001,
        type: 'comment',
        title: '未读待删',
        resourceType: 'comment',
        resourceId: 7001,
        isRead: 0,
        metadata: {'post_id': 100001},
      ),
    ]);
    final router = _router();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ..._overrides(api),
          notificationsUnreadProvider.overrideWith(
            (ref) => NotificationsUnreadController(ref)..set(2),
          ),
        ],
        child: MaterialApp.router(
          locale: const Locale('zh'),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Soft-load sets unread from API (1 unread item).
    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotificationsScreen)),
    );
    expect(container.read(notificationsUnreadProvider), 1);

    const actions = ValueKey('notification-actions-3001');
    const trash = Key('notifications-toggle-trash');
    await tester.tap(find.byKey(actions));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(api.deletedNotificationId, 3001);
    expect(container.read(notificationsUnreadProvider), 0);
    expect(find.text('未读待删'), findsNothing);

    await tester.tap(find.byKey(trash));
    await tester.pumpAndSettle();
    expect(find.text('未读待删'), findsOneWidget);
    await tester.tap(find.byKey(actions));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();
    expect(find.text('未读待删'), findsNothing);
    expect(container.read(notificationsUnreadProvider), 1);

    await tester.tap(find.byKey(trash));
    await tester.pumpAndSettle();
    expect(find.text('未读待删'), findsOneWidget);
  });

  testWidgets(
    'marks only listed unread notifications before marking all read',
    (tester) async {
      final api = _FakeNotificationsApi([
        _notification(
          notificationId: 3001,
          type: 'comment',
          title: '未读A',
          resourceType: 'comment',
          resourceId: 7001,
          isRead: 0,
          metadata: {'post_id': 100001},
        ),
        _notification(
          notificationId: 3002,
          type: 'like',
          title: '已读B',
          resourceType: 'post',
          resourceId: 100002,
          isRead: 1,
          metadata: {'post_id': 100002},
        ),
        _notification(
          notificationId: 3003,
          type: 'like',
          title: '未读C',
          resourceType: 'post',
          resourceId: 100003,
          isRead: 0,
        ),
      ]);
      final router = _router();
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: _overrides(api),
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('未读A'), findsOneWidget);
      expect(find.text('已读B'), findsOneWidget);

      await tester.tap(find.byKey(const Key('notifications-filter-unread')));
      await tester.pumpAndSettle();

      expect(api.lastUnreadOnly, isTrue);
      expect(find.text('未读A'), findsOneWidget);
      expect(find.text('已读B'), findsNothing);

      await tester.tap(find.byIcon(Icons.filter_list));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate(
          (item) => item is PopupMenuItem<String> && item.value == 'comment',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('未读C'), findsNothing);

      final listed = find.byKey(const Key('notifications-mark-listed-read'));
      await tester.tap(listed);
      await tester.pumpAndSettle();
      expect(api.listedIds, [3001]);
      expect(api.markAllReadCalled, isFalse);
      expect(api.items.last.readFlag, isFalse);
      expect(tester.widget<IconButton>(listed).onPressed, isNull);

      await tester.tap(find.byKey(const Key('notifications-mark-all-read')));
      await tester.pumpAndSettle();

      expect(api.markAllReadCalled, isTrue);
    },
  );
}

List<Override> _overrides(NotificationsApi api) {
  return [
    notificationsApiProvider.overrideWithValue(api),
    realtimeServiceProvider.overrideWithValue(_FakeRealtimeService()),
  ];
}

GoRouter _router() {
  return GoRouter(
    initialLocation: '/notifications',
    routes: [
      GoRoute(
        path: '/notifications',
        builder: (_, __) => const NotificationsScreen(),
      ),
      GoRoute(
        path: '/posts/:postId',
        builder: (_, state) {
          final comment = state.uri.queryParameters['comment'];
          return Scaffold(
            body: Text(
              'Post ${state.pathParameters['postId']}'
              '${comment == null ? '' : ' Comment $comment'}',
            ),
          );
        },
      ),
      GoRoute(
        path: '/groups/posts',
        builder: (_, state) => Scaffold(
          body: Text(
            'Group ${state.uri.queryParameters['group']} '
            'Post ${state.uri.queryParameters['post']} '
            'Comment ${state.uri.queryParameters['comment']}',
          ),
        ),
      ),
      GoRoute(
        path: '/chat/conversation/:id',
        builder: (_, state) => Scaffold(
          body: Column(
            children: [
              Text('Conversation ${state.pathParameters['id']}'),
              Text((state.extra as Map?)?['title'] as String? ?? ''),
            ],
          ),
        ),
      ),
      GoRoute(
        path: '/users/:userId',
        builder: (_, state) =>
            Scaffold(body: Text('User ${state.pathParameters['userId']}')),
      ),
      GoRoute(
        path: '/account/active',
        builder: (_, __) => const Scaffold(body: Text('Sessions')),
      ),
      GoRoute(
        path: '/groups/invites',
        builder: (_, state) => Scaffold(
          body: Text('Invites ${state.uri.queryParameters['invite'] ?? 'all'}'),
        ),
      ),
    ],
  );
}

class _NotificationChatApi extends ChatApi {
  _NotificationChatApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  final requested = <int>[];
  bool accessible = false;

  @override
  Future<V2DirectConversation?> getDirectConversation(
    int conversationId,
  ) async {
    requested.add(conversationId);
    if (!accessible) return null;
    return V2DirectConversation(
      conversationId: conversationId,
      participant: _actor,
      unreadCount: 1,
      createdAt: '2026-05-24T00:00:00.000Z',
      updatedAt: '2026-05-24T00:00:00.000Z',
    );
  }
}

class _FakeNotificationsApi extends NotificationsApi {
  _FakeNotificationsApi(this.items)
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  final List<V2Notification> items;
  int? readNotificationId;
  bool? readStatus;
  bool markAllReadCalled = false;
  List<int> listedIds = [];
  bool? lastUnreadOnly;
  int? deletedNotificationId;

  @override
  Future<PagedResult<V2Notification>> list({
    int page = 1,
    int size = 20,
    String? type,
    bool? unreadOnly,
    bool showDeleted = false,
  }) async {
    lastUnreadOnly = unreadOnly;
    final filtered = items
        .where(
          (item) =>
              item.isDeleted == showDeleted &&
              (type == null || item.type == type) &&
              (unreadOnly != true || !item.readFlag),
        )
        .toList();
    return PagedResult(
      items: filtered,
      meta: ApiMeta(
        page: page,
        pageSize: size,
        total: filtered.length,
        hasNext: false,
      ),
    );
  }

  @override
  Future<int> unreadCount() async =>
      items.where((item) => !item.readFlag && !item.isDeleted).length;

  @override
  Future<void> setReadStatus({
    required int notificationId,
    required bool isRead,
  }) async {
    readNotificationId = notificationId;
    readStatus = isRead;
    final index = items.indexWhere(
      (item) => item.notificationId == notificationId,
    );
    if (index >= 0) {
      items[index] = items[index].copyWith(isRead: isRead ? 1 : 0);
    }
  }

  @override
  Future<void> markRead(List<int> ids) async {
    listedIds = List.of(ids);
    for (final id in ids) {
      await setReadStatus(notificationId: id, isRead: true);
    }
  }

  @override
  Future<void> markAllRead() async {
    markAllReadCalled = true;
    for (var index = 0; index < items.length; index++) {
      if (!items[index].isDeleted) {
        items[index] = items[index].copyWith(isRead: 1);
      }
    }
  }

  @override
  Future<void> deleteNotification(int id) async {
    deletedNotificationId = id;
    final index = items.indexWhere((item) => item.notificationId == id);
    if (index >= 0) {
      items[index] = items[index].copyWith(deletedAt: '2026-11-18T00:00:00Z');
    }
  }

  @override
  Future<void> restoreNotification(int id) async {
    final index = items.indexWhere((item) => item.notificationId == id);
    if (index >= 0) items[index] = items[index].copyWith(deletedAt: '');
  }
}

class _FakeGroupsApi extends GroupsApi {
  _FakeGroupsApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));
  int myGroupsReads = 0;

  @override
  Future<PagedResult<V2Group>> myGroups({
    int page = 1,
    int size = 20,
    String? category,
    String? privacy,
    String? search,
  }) async {
    myGroupsReads++;
    return PagedResult(
      items: [_group],
      meta: ApiMeta(page: page, pageSize: size, total: 1, hasNext: false),
    );
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
  bool send(Map<String, dynamic> payload) => true;

  @override
  void addListener(RealtimeListener listener) {
    listeners.add(listener);
  }

  @override
  void removeListener(RealtimeListener listener) {
    listeners.remove(listener);
  }
}

V2Notification _notification({
  int notificationId = 3001,
  required String type,
  required String title,
  required String resourceType,
  required int resourceId,
  int isRead = 0,
  Map<String, Object?> metadata = const {},
}) {
  return V2Notification(
    notificationId: notificationId,
    type: type,
    title: title,
    message: '查看详情',
    resourceType: resourceType,
    resourceId: resourceId,
    priority: 'normal',
    isRead: isRead,
    actor: _actor,
    metadata: metadata,
    createdAt: '2026-05-24T00:00:00.000Z',
  );
}

final _actor = V2PublicUser(
  userId: 42,
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

final _group = V2Group(
  groupId: 88,
  name: 'Neko News',
  slug: 'neko-news',
  description: '',
  tags: const [],
  owner: _actor,
  privacy: 'public',
  privacyDesc: '公开',
  joinApproval: false,
  postPermission: 'all',
  memberCount: 1,
  postCount: 1,
  isActive: 1,
  membership: V2GroupMembership(isMember: true, role: 'member'),
  createdAt: '2026-05-24T00:00:00.000Z',
  updatedAt: '2026-05-24T00:00:00.000Z',
);

const _testConfig = AppConfig(
  apiBaseUrl: 'http://example.test',
  wsBaseUrl: 'ws://example.test',
  storageBaseUrl: 'http://example.test',
);

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
