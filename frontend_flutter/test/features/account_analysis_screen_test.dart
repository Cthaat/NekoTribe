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
import 'package:nekotribe/shared/i18n/app_localizations.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
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

    expect(find.text('个人分析'), findsOneWidget);
    expect(find.text('总动态'), findsOneWidget);
    expect(find.text('12'), findsWidgets);
    expect(find.text('2026-05-24'), findsOneWidget);
    expect(find.text('互动得分'), findsWidgets);
  });

  testWidgets('account data analytics screen renders post analytics', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testApp(
        overrides: [
          postsApiProvider.overrideWithValue(_FakePostsApi()),
        ],
        child: const AccountDataAnalyticsScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('数据分析'), findsOneWidget);
    expect(find.textContaining('NekoTribe analytics'), findsOneWidget);
    expect(find.text('浏览'), findsWidgets);
    expect(find.text('32'), findsWidgets);
    expect(find.text('点赞率'), findsWidgets);
    expect(find.text('25.0%'), findsOneWidget);
  });
}

Widget _testApp({
  required List<Override> overrides,
  required Widget child,
}) {
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

class _FakePostsApi extends PostsApi {
  _FakePostsApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  @override
  Future<PagedResult<V2Post>> getMyPosts({
    int page = 1,
    int size = 20,
    String mode = 'posts',
  }) async => PagedResult(
    items: [_post],
    meta: const ApiMeta(page: 1, pageSize: 20, total: 1, hasNext: false),
  );

  @override
  Future<V2PostAnalytics> getPostAnalytics(int postId) async =>
      V2PostAnalytics.fromJson({
        'post_id': postId,
        'views_count': 32,
        'likes_count': 8,
        'comments_count': 3,
        'replies_count': 2,
        'retweets_count': 1,
        'engagement_score': 14.5,
        'like_rate': 0.25,
      });
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
