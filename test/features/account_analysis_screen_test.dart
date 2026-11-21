import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_response.dart';
import 'package:nekotribe/features/posts/data/posts_api.dart';
import 'package:nekotribe/features/posts/domain/post_models.dart';
import 'package:nekotribe/features/users/data/users_api.dart';
import 'package:nekotribe/features/users/data/users_repository.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/features/users/presentation/account_analytics_screen.dart';
import 'package:nekotribe/features/users/presentation/account_data_analytics_screen.dart';
import 'package:nekotribe/features/users/presentation/account_posts_screen.dart';
import 'package:nekotribe/shared/i18n/app_localizations.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  testWidgets('removing a bookmark reloads the first page', (tester) async {
    final api = _FakeBookmarkedPostsApi();
    final tokens = _FakeTokenStore();
    await tester.pumpWidget(
      _testApp(
        overrides: [
          postsApiProvider.overrideWithValue(api),
          tokenStoreProvider.overrideWithValue(tokens),
          authSessionProvider.overrideWith((ref) {
            return AuthSessionController(tokens)..markLoggedIn();
          }),
        ],
        child: const AccountPostsScreen(kind: AccountPostsKind.bookmarks),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Saved post'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.bookmark));
    await tester.pumpAndSettle();
    expect(api.requests, [1, 1]);
    expect(find.text('Saved post'), findsNothing);
  });

  testWidgets('own post opens analytics for that post only', (tester) async {
    final api = _FakePostsApi();
    await tester.pumpWidget(
      _testApp(
        overrides: [postsApiProvider.overrideWithValue(api)],
        child: const AccountPostsScreen(kind: AccountPostsKind.posts),
      ),
    );
    await tester.pumpAndSettle();
    final stats = find.widgetWithText(TextButton, '单条动态统计');
    await tester.scrollUntilVisible(
      stats,
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(stats);
    await tester.pumpAndSettle();
    expect(api.pages, [1]);
    expect(api.analyticsIds, [100001]);
    expect(find.text('单条动态统计'), findsOneWidget);
    expect(find.text('32'), findsOneWidget);
  });

  testWidgets('deleting an own post refreshes the active search', (
    tester,
  ) async {
    final api = _FakePostsApi();
    final tokens = _FakeTokenStore();
    await tester.pumpWidget(
      _testApp(
        overrides: [
          postsApiProvider.overrideWithValue(api),
          tokenStoreProvider.overrideWithValue(tokens),
          authSessionProvider.overrideWith((ref) {
            return AuthSessionController(tokens)..markLoggedIn();
          }),
        ],
        child: const AccountPostsScreen(kind: AccountPostsKind.posts),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'original');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('post-more-button-100001')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.ancestor(
        of: find.text('删除'),
        matching: find.byWidgetPredicate((widget) => widget is PopupMenuItem),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(api.deletedPostId, 100001);
    expect(api.queries, [
      (1, 'newest', ''),
      (1, 'newest', 'original'),
      (1, 'newest', 'original'),
    ]);
    expect(find.text('NekoTribe analytics should be visible'), findsNothing);
  });

  testWidgets('own posts keep the submitted search and sort when paging', (
    tester,
  ) async {
    final api = _FakePostsApi();
    await tester.pumpWidget(
      _testApp(
        overrides: [postsApiProvider.overrideWithValue(api)],
        child: const AccountPostsScreen(kind: AccountPostsKind.posts),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  cats  ');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('我的动态排序'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.ancestor(
        of: find.text('最早发布'),
        matching: find.byWidgetPredicate((widget) => widget is PopupMenuItem),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('按可见范围筛选已加载动态'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.ancestor(
        of: find.text('私密'),
        matching: find.byWidgetPredicate((widget) => widget is PopupMenuItem),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已加载的动态中没有匹配项'), findsOneWidget);
    final more = find.text('加载更多动态');
    await tester.scrollUntilVisible(
      more,
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.text('Another post'), findsOneWidget);
    expect(find.text('NekoTribe analytics should be visible'), findsNothing);
    expect(api.queries, [
      (1, 'newest', ''),
      (1, 'newest', 'cats'),
      (1, 'oldest', 'cats'),
      (2, 'oldest', 'cats'),
    ]);
    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pumpAndSettle();
    expect(api.queries.last, (1, 'oldest', ''));
  });

  testWidgets('liked posts ignore responses from the previous sort', (
    tester,
  ) async {
    final api = _FakeLikedPostsApi();
    await tester.pumpWidget(
      _testApp(
        overrides: [postsApiProvider.overrideWithValue(api)],
        child: const AccountPostsScreen(kind: AccountPostsKind.likes),
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('点赞列表排序'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(
      find.ancestor(
        of: find.text('最早点赞'),
        matching: find.byWidgetPredicate((widget) => widget is PopupMenuItem),
      ),
    );
    await tester.pumpAndSettle();
    expect(api.requests, [(1, 'newest'), (1, 'oldest')]);
    expect(find.text('Oldest result'), findsOneWidget);
    api.newest.complete(_FakeLikedPostsApi.result('Outdated result'));
    await tester.pumpAndSettle();
    expect(find.text('Oldest result'), findsOneWidget);
    expect(find.text('Outdated result'), findsNothing);
  });

  testWidgets('account analytics screen renders personal analysis data', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testApp(
        overrides: [
          usersRepositoryProvider.overrideWithValue(_FakeUsersRepository()),
        ],
        child: const AccountAnalyticsScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('个人分析'), findsWidgets);
    expect(find.text('总动态'), findsOneWidget);
    expect(find.text('12'), findsWidgets);
    expect(find.text('2026-05-24'), findsOneWidget);
    expect(find.text('互动得分'), findsWidgets);
  });

  testWidgets(
    'post analytics paginates and excludes unmatched results from totals',
    (tester) async {
      final api = _FakePostsApi();
      await tester.pumpWidget(
        _testApp(
          overrides: [postsApiProvider.overrideWithValue(api)],
          child: const AccountDataAnalyticsScreen(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('数据分析'), findsWidgets);
      expect(find.textContaining('NekoTribe analytics'), findsOneWidget);
      expect(find.text('浏览'), findsWidgets);
      expect(find.text('32'), findsWidgets);
      expect(find.text('点赞率'), findsWidgets);
      expect(find.text('25.0%'), findsWidgets);
      final more = find.byKey(const Key('account-data-load-more'));
      await tester.scrollUntilVisible(
        more,
        220,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(api.pages, [1, 2]);
      expect(find.text('这条帖子的统计暂不可用'), findsOneWidget);
      expect(find.text('999'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('已加载 2 条帖子，其中 1 条有统计数据'),
        -220,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('32'), findsWidgets);
    },
  );
}

Widget _testApp({required List<Override> overrides, required Widget child}) {
  return ProviderScope(
    overrides: [
      appConfigBundleProvider.overrideWithValue(_testBundle),
      appConfigInitialProvider.overrideWithValue(_testConfig),
      ...overrides,
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
      home: child,
    ),
  );
}

class _FakeUsersRepository extends UsersRepository {
  _FakeUsersRepository()
    : super(
        UsersApi(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore())),
      );

  @override
  Future<V2SelfUser> getCurrentUser() async => _selfUser;

  @override
  Future<V2UserAnalytics> getUserAnalytics(int userId) async =>
      V2UserAnalytics.fromJson({
        'user_id': userId,
        'total_posts': 12,
        'posts_this_week': 3,
        'posts_this_month': 7,
        'total_likes_received': 40,
        'avg_likes_per_post': 3.3,
        'total_likes_given': 18,
        'total_comments_made': 11,
        'engagement_score': 9.5,
      });

  @override
  Future<List<V2UserDailyAnalytics>> getUserDailyAnalytics(
    int userId, {
    int days = 14,
  }) async => [
    V2UserDailyAnalytics.fromJson({
      'day': '2026-05-24',
      'posts_count': 2,
      'likes_received': 6,
      'comments_received': 4,
      'retweets_received': 1,
      'likes_given': 3,
      'comments_made': 2,
      'engagement_score': 12.5,
    }),
  ];
}

class _FakeBookmarkedPostsApi extends PostsApi {
  _FakeBookmarkedPostsApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  final requests = <int>[];
  bool saved = true;

  @override
  Future<PagedResult<V2Post>> getMyBookmarks({
    int page = 1,
    int size = 20,
  }) async {
    requests.add(page);
    return PagedResult(
      items: [
        if (saved)
          V2Post.fromJson({
            'post_id': 100001,
            'content': 'Saved post',
            'viewer_state': {'is_bookmarked': true},
          }),
      ],
      meta: ApiMeta(
        page: page,
        pageSize: size,
        total: saved ? 1 : 0,
        hasNext: false,
      ),
    );
  }

  @override
  Future<V2ViewerPostState> unbookmarkPost(int postId) async {
    saved = false;
    return V2ViewerPostState.fromJson({'is_bookmarked': false});
  }
}

class _FakeLikedPostsApi extends PostsApi {
  _FakeLikedPostsApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  final requests = <(int, String)>[];
  final newest = Completer<PagedResult<V2Post>>();

  static PagedResult<V2Post> result(String content) => PagedResult(
    items: [
      V2Post.fromJson({'post_id': 100001, 'content': content}),
    ],
    meta: const ApiMeta(page: 1, pageSize: 20, total: 1, hasNext: false),
  );

  @override
  Future<PagedResult<V2Post>> getMyLikes({
    int page = 1,
    int size = 20,
    String sort = 'newest',
  }) async {
    requests.add((page, sort));
    if (sort == 'newest') return newest.future;
    return result('Oldest result');
  }
}

class _FakePostsApi extends PostsApi {
  _FakePostsApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  final pages = <int>[];
  final analyticsIds = <int>[];
  final queries = <(int, String, String?)>[];
  int? deletedPostId;

  @override
  Future<void> deletePost(int postId) async {
    deletedPostId = postId;
  }

  @override
  Future<PagedResult<V2Post>> getMyPosts({
    int page = 1,
    int size = 20,
    String sort = 'newest',
    String? query,
  }) async {
    pages.add(page);
    queries.add((page, sort, query));
    if (deletedPostId != null) {
      return PagedResult(
        items: const [],
        meta: ApiMeta(page: page, pageSize: size, total: 0, hasNext: false),
      );
    }
    return PagedResult(
      items: page == 1
          ? [_post]
          : [
              V2Post.fromJson({
                'post_id': 100002,
                'content': 'Another post',
                'visibility': 'private',
                'stats': {'views_count': 999},
              }),
            ],
      meta: ApiMeta(page: page, pageSize: size, total: 2, hasNext: page == 1),
    );
  }

  @override
  Future<V2PostAnalytics> getPostAnalytics(int postId) async {
    analyticsIds.add(postId);
    return V2PostAnalytics.fromJson({
      'post_id': 100001,
      'views_count': postId == 100001 ? 32 : 999,
      'likes_count': 8,
      'comments_count': 3,
      'replies_count': 2,
      'retweets_count': 1,
      'engagement_score': 14.5,
      'like_rate': 0.25,
    });
  }
}

final _selfUser = V2SelfUser(
  userId: 1,
  username: 'edge',
  displayName: 'Edge',
  avatarUrl: '',
  bio: '',
  location: '',
  website: '',
  isVerified: 0,
  followersCount: 5,
  followingCount: 7,
  postsCount: 12,
  likesCount: 18,
  relationship: V2Relationship.empty(),
  onlineStatus: 'online',
  email: 'edge@example.test',
  phone: '',
  birthDate: null,
  emailVerifiedAt: '2026-05-24T00:00:00.000Z',
  isActive: 1,
  status: 'active',
  createdAt: '2026-05-24T00:00:00.000Z',
  updatedAt: '2026-05-24T00:00:00.000Z',
);

final _post = V2Post(
  postId: 100001,
  author: _selfUser,
  content: 'NekoTribe analytics should be visible',
  postType: 'normal',
  visibility: 'public',
  language: 'zh',
  location: '',
  media: const [],
  tags: const [],
  mentions: const [],
  stats: V2PostStats(
    likesCount: 8,
    commentsCount: 3,
    repliesCount: 2,
    retweetsCount: 1,
    viewsCount: 32,
    engagementScore: 14.5,
  ),
  viewerState: V2ViewerPostState(
    isLiked: false,
    isBookmarked: false,
    canDelete: true,
  ),
  createdAt: '2026-05-24T00:00:00.000Z',
  updatedAt: '2026-05-24T00:00:00.000Z',
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
