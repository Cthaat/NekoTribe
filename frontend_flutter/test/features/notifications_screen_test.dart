import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_response.dart';
import 'package:nekotribe/features/groups/data/groups_api.dart';
import 'package:nekotribe/features/groups/domain/group_models.dart';
import 'package:nekotribe/features/notifications/data/notifications_api.dart';
import 'package:nekotribe/features/notifications/domain/notification_models.dart';
import 'package:nekotribe/features/notifications/presentation/notifications_screen.dart';
import 'package:nekotribe/features/realtime/data/realtime_service.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  testWidgets('comment notifications open their source post detail', (
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

    expect(find.text('Post 100001'), findsOneWidget);
    expect(api.readNotificationId, 3001);
    expect(api.readStatus, isTrue);
  });

  testWidgets('group comment notifications open their group post detail', (
    tester,
  ) async {
    final api = _FakeNotificationsApi([
      _notification(
        type: 'group_comment',
        title: '群组新评论',
        resourceType: 'group_comment',
        resourceId: 7001,
        metadata: {'group_id': 88, 'post_id': 100002},
      ),
    ]);
    final router = _router();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ..._overrides(api),
          groupsApiProvider.overrideWithValue(_FakeGroupsApi()),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('群组新评论'));
    await tester.pumpAndSettle();

    expect(find.text('Group neko-news Post 100002'), findsOneWidget);
    expect(api.readNotificationId, 3001);
    expect(api.readStatus, isTrue);
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
        metadata: {'conversation_id': 9001},
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

    await tester.tap(find.text('新私信'));
    await tester.pumpAndSettle();

    expect(find.text('Conversation 9001'), findsOneWidget);
    expect(api.readNotificationId, 3001);
    expect(api.readStatus, isTrue);
  });

  testWidgets('deleting an unread notification decrements the badge', (
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

    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(api.deletedNotificationId, 3001);
    expect(container.read(notificationsUnreadProvider), 0);
  });

  testWidgets('unread filter and mark all read', (tester) async {
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

    await tester.tap(find.byKey(const Key('notifications-mark-all-read')));
    await tester.pumpAndSettle();

    expect(api.markAllReadCalled, isTrue);
  });
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
        builder: (_, state) =>
            Scaffold(body: Text('Post ${state.pathParameters['postId']}')),
      ),
      GoRoute(
        path: '/groups/:slug/posts/:postId',
        builder: (_, state) => Scaffold(
          body: Text(
            'Group ${state.pathParameters['slug']} '
            'Post ${state.pathParameters['postId']}',
          ),
        ),
      ),
      GoRoute(
        path: '/chat/conversation/:id',
        builder: (_, state) =>
            Scaffold(body: Text('Conversation ${state.pathParameters['id']}')),
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
        builder: (_, __) => const Scaffold(body: Text('Invites')),
      ),
    ],
  );
}

class _FakeNotificationsApi extends NotificationsApi {
  _FakeNotificationsApi(this.items)
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  final List<V2Notification> items;
  int? readNotificationId;
  bool? readStatus;
  bool markAllReadCalled = false;
  bool? lastUnreadOnly;
  int? deletedNotificationId;

  @override
  Future<PagedResult<V2Notification>> list({
    int page = 1,
    int size = 20,
    String? type,
    bool? unreadOnly,
  }) async {
    lastUnreadOnly = unreadOnly;
    final filtered = unreadOnly == true
        ? items.where((item) => !item.readFlag).toList()
        : items;
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
  }

  @override
  Future<void> markAllRead() async {
    markAllReadCalled = true;
  }

  @override
  Future<void> deleteNotification(int id) async {
    deletedNotificationId = id;
  }
}

class _FakeGroupsApi extends GroupsApi {
  _FakeGroupsApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  @override
  Future<PagedResult<V2Group>> myGroups({int page = 1, int size = 20}) async {
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
