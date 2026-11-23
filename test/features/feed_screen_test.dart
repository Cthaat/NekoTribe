import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_response.dart';
import 'package:nekotribe/features/groups/data/groups_api.dart';
import 'package:nekotribe/features/groups/domain/group_models.dart';
import 'package:nekotribe/features/groups/presentation/group_post_card.dart';
import 'package:nekotribe/features/posts/data/posts_api.dart';
import 'package:nekotribe/features/posts/domain/post_models.dart';
import 'package:nekotribe/features/posts/presentation/feed_screen.dart';
import 'package:nekotribe/features/posts/presentation/post_card.dart';
import 'package:nekotribe/shared/i18n/app_localizations.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  testWidgets('feed tabs fit inside mobile width', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigBundleProvider.overrideWithValue(_testBundle),
          appConfigInitialProvider.overrideWithValue(_testConfig),
          postsApiProvider.overrideWithValue(_FakePostsApi(_Tokens())),
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
          home: const FeedScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    var previous = 0.0;
    for (final label in ['推荐', '关注', '热门', '群动态']) {
      final rect = tester.getRect(find.text(label));
      expect(rect.left, greaterThanOrEqualTo(previous));
      expect(rect.right, lessThanOrEqualTo(390));
      previous = rect.right;
    }

    expect(find.byKey(const Key('feed-search-button')), findsOneWidget);
  });

  test(
    'home endpoints use the canonical paths and keep group DTO extras',
    () async {
      final client = _client(_Tokens());
      addTearDown(client.dispose);
      final requests = <RequestOptions>[];
      client.raw.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            final group = request.path == '/api/v2/feed/groups';
            handler.resolve(
              Response(
                requestOptions: request,
                statusCode: 200,
                data: {
                  'code': 200,
                  'message': 'success',
                  'data': [group ? _groupJson(91) : _postJson(51)],
                  'meta': {
                    'page': 2,
                    'page_size': 20,
                    'has_next': true,
                    'total': 45,
                  },
                },
              ),
            );
          },
        ),
      );
      final posts = PostsApi(client);
      final groups = GroupsApi(client);
      await posts.getFeed(mode: 'recommended', page: 2);
      await posts.getFeed(mode: 'following', page: 2);
      expect((await posts.getTrendingPage(page: 2)).hasNext, isTrue);
      final activity = await groups.homeActivity(page: 2);
      expect(activity.hasNext, isTrue);
      expect(activity.items.single.groupName, 'Cats Club');
      expect(activity.items.single.markdown, '# Group heading 91');
      expect(activity.items.single.poll?.options.first.text, 'Choice A');
      expect(requests.map((request) => (request.method, request.path)), [
        ('GET', '/api/v2/posts'),
        ('GET', '/api/v2/posts'),
        ('GET', '/api/v2/posts/trending'),
        ('GET', '/api/v2/feed/groups'),
      ]);
      expect(requests[0].queryParameters['timeline'], 'recommended');
      expect(requests[1].queryParameters['timeline'], 'following');
      for (final request in requests) {
        expect(request.queryParameters['page'], 2);
        expect(request.queryParameters['page_size'], 20);
      }
      expect(requests.last.headers['Authorization'], 'Bearer fixture-token');
    },
  );

  testWidgets(
    'late recommendations stay in their original tab and trending pages',
    (tester) async {
      final tokens = _Tokens();
      final preferred = Completer<PagedResult<V2Post>>();
      final posts = _FakePostsApi(tokens)
        ..recommended = preferred.future
        ..following = _page([_post(71)])
        ..trending[1] = _page([_post(81)], hasNext: true)
        ..trending[2] = _page([_post(81), _post(82)]);
      await tester.pumpWidget(_app(tokens, posts, _FakeGroupsApi(tokens)));
      await tester.pump();
      expect(find.textContaining('近 30 天'), findsOneWidget);
      await tester.tap(find.text('关注'));
      await tester.pumpAndSettle();
      expect(find.text('Post 71'), findsOneWidget);
      preferred.complete(_page([_post(72)]));
      await tester.pumpAndSettle();
      expect(find.text('Post 71'), findsOneWidget);
      expect(find.text('Post 72'), findsNothing);
      await _select(tester, '推荐');
      expect(find.text('Post 72'), findsOneWidget);
      await _select(tester, '热门');
      expect(find.text('Post 81'), findsOneWidget);
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(find.text('Post 81'), findsOneWidget);
      expect(find.text('Post 82'), findsOneWidget);
      expect(posts.calls, [
        ('recommended', 1),
        ('following', 1),
        ('trending', 1),
        ('trending', 2),
      ]);
    },
  );

  testWidgets(
    'active group tab retains card content, likes and opens the actual post',
    (tester) async {
      final tokens = _Tokens();
      final groups = _FakeGroupsApi(tokens)
        ..next = Future.value(_page([_group(91)]));
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const FeedScreen()),
          GoRoute(
            path: '/groups/posts',
            builder: (_, state) => Scaffold(
              body: Text(
                'Open ${state.uri.queryParameters['group']}:${state.uri.queryParameters['post']}',
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        _app(tokens, _FakePostsApi(tokens), groups, router: router),
      );
      await tester.pumpAndSettle();
      await _select(tester, '群动态');
      final card = find.byType(GroupPostCard);
      expect(card, findsOneWidget);
      expect(find.textContaining('Cats Club'), findsOneWidget);
      expect(find.text('Group heading 91', findRichText: true), findsWidgets);
      expect(find.text('Choice A'), findsOneWidget);
      final like = find.descendant(
        of: card,
        matching: find.byIcon(Icons.favorite_border),
      );
      await tester.tap(like);
      await tester.pumpAndSettle();
      expect(groups.likes, [(13, 91, true)]);
      expect(tester.widget<GroupPostCard>(card).post.likesCount, 4);
      await tester.tap(find.textContaining('Cats Club'));
      await tester.pumpAndSettle();
      expect(find.text('Open 13:91'), findsOneWidget);
    },
  );

  testWidgets('a backend or account change discards a pending group result', (
    tester,
  ) async {
    final tokens = _Tokens();
    final pending = Completer<PagedResult<V2GroupPost>>();
    final groups = _FakeGroupsApi(tokens)..next = pending.future;
    await tester.pumpWidget(_app(tokens, _FakePostsApi(tokens), groups));
    await tester.pumpAndSettle();
    await tester.tap(find.text('群动态'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(groups.reads, [1]);
    groups.next = Future.value(_page([_group(92)]));
    await tokens.switchEndpoint(() {});
    await tester.pumpAndSettle();
    pending.complete(_page([_group(91)]));
    await tester.pumpAndSettle();
    expect(groups.reads, [1, 1]);
    expect(find.text('Group heading 91', findRichText: true), findsNothing);
    expect(find.text('Group heading 92', findRichText: true), findsWidgets);
  });

  testWidgets('signed-out group feed does not load membership-scoped content', (
    tester,
  ) async {
    final tokens = _Tokens();
    final groups = _FakeGroupsApi(tokens);
    await tester.pumpWidget(
      _app(tokens, _FakePostsApi(tokens), groups, signedIn: false),
    );
    await tester.pumpAndSettle();
    await _select(tester, '群动态');
    expect(groups.reads, isEmpty);
    expect(find.text('登录后可查看你加入的群的动态。'), findsOneWidget);
  });

  testWidgets('confirmed recommendation feedback refreshes its timeline', (
    tester,
  ) async {
    final tokens = _Tokens();
    final posts = _FakePostsApi(tokens)
      ..recommended = Future.value(_page([_post(51)]));
    await tester.pumpWidget(_app(tokens, posts, _FakeGroupsApi(tokens)));
    await tester.pumpAndSettle();
    expect(find.byType(PostCard), findsOneWidget);
    await tester.tap(find.byKey(const Key('post-more-button-51')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('不感兴趣'));
    await tester.pumpAndSettle();
    expect(posts.feedback, [(51, 'not_interested')]);
    expect(posts.calls, [('recommended', 1), ('recommended', 1)]);
    expect(find.byType(PostCard), findsNothing);
  });
}

class _FakePostsApi extends PostsApi {
  _FakePostsApi(TokenStore tokens) : super(_client(tokens));

  final calls = <(String, int)>[];
  final feedback = <(int, String)>[];
  Future<PagedResult<V2Post>>? recommended;
  PagedResult<V2Post> following = _page([]);
  final trending = <int, PagedResult<V2Post>>{};

  @override
  Future<PagedResult<V2Post>> getFeed({
    String mode = 'home',
    int page = 1,
    int size = 20,
    String? cursor,
    String? language,
    String? sort,
  }) async {
    calls.add((mode, page));
    final pending = recommended;
    if (mode == 'recommended' && pending != null) return pending;
    return mode == 'following' ? following : _page([]);
  }

  @override
  Future<PagedResult<V2Post>> getTrendingPage({
    required int page,
    int size = 20,
  }) async {
    calls.add(('trending', page));
    return trending[page] ?? _page([]);
  }

  @override
  Future<void> recordRecommendationFeedback({
    required int postId,
    required String feedback,
  }) async {
    this.feedback.add((postId, feedback));
    recommended = Future.value(_page([]));
  }
}

class _FakeGroupsApi extends GroupsApi {
  _FakeGroupsApi(TokenStore tokens) : super(_client(tokens));

  Future<PagedResult<V2GroupPost>>? next;
  final reads = <int>[];
  final likes = <(int, int, bool)>[];

  @override
  Future<PagedResult<V2GroupPost>> homeActivity({
    required int page,
    int size = 20,
  }) async {
    reads.add(page);
    final pending = next;
    return pending == null ? _page([]) : await pending;
  }

  @override
  Future<({bool liked, int count})> setGroupPostLikeStatus({
    required int groupId,
    required int postId,
    required bool liked,
  }) async {
    likes.add((groupId, postId, liked));
    return (liked: liked, count: 4);
  }
}

Future<void> _select(WidgetTester tester, String tab) async {
  await tester.tap(find.text(tab));
  await tester.pumpAndSettle();
}

Widget _app(
  _Tokens tokens,
  _FakePostsApi posts,
  _FakeGroupsApi groups, {
  GoRouter? router,
  bool signedIn = true,
}) => ProviderScope(
  overrides: [
    tokenStoreProvider.overrideWithValue(tokens),
    appConfigBundleProvider.overrideWithValue(_testBundle),
    appConfigInitialProvider.overrideWithValue(_testConfig),
    postsApiProvider.overrideWithValue(posts),
    groupsApiProvider.overrideWithValue(groups),
    authSessionProvider.overrideWith((_) {
      final auth = AuthSessionController(tokens);
      if (signedIn) {
        auth.markLoggedIn();
      } else {
        auth.markLoggedOut();
      }
      return auth;
    }),
  ],
  child: router == null
      ? const MaterialApp(home: FeedScreen())
      : MaterialApp.router(routerConfig: router),
);

PagedResult<T> _page<T>(List<T> items, {bool hasNext = false}) => PagedResult(
  items: items,
  meta: ApiMeta(hasNext: hasNext),
);

ApiClient _client(TokenStore tokens) =>
    ApiClient(config: _testConfig, tokenStore: tokens);

Map<String, Object?> _postJson(int id) => {
  'post_id': id,
  'content': 'Post $id',
  'author': {'user_id': 1, 'username': 'User'},
};

V2Post _post(int id) => V2Post.fromJson(_postJson(id));

Map<String, Object?> _groupJson(int id) => {
  ..._postJson(id),
  'group_id': 13,
  'group_name': 'Cats Club',
  'markdown': '# Group heading $id',
  'likes_count': 3,
  'poll': {
    'poll_id': 8,
    'multiple': false,
    'closes_at': '2026-01-01T00:00:00.000Z',
    'closed': true,
    'total_ballots': 0,
    'my_option_ids': <int>[],
    'options': [
      {'option_id': 1, 'text': 'Choice A', 'votes_count': 0, 'percent': 0},
      {'option_id': 2, 'text': 'Choice B', 'votes_count': 0, 'percent': 0},
    ],
  },
};

V2GroupPost _group(int id) => V2GroupPost.fromJson(_groupJson(id));

class _Tokens extends TokenStore {
  @override
  Future<TokenPair?> read() async => const TokenPair(
    accessToken: 'fixture-token',
    refreshToken: 'fixture-refresh',
    sessionId: 'fixture-session',
  );

  @override
  Future<String> deviceFingerprint() async => 'test';
}

const _testConfig = AppConfig(
  apiBaseUrl: 'http://example.test',
  wsBaseUrl: 'ws://example.test',
  storageBaseUrl: 'http://example.test',
);

const _testBundle = AppConfigBundle(defaults: _testConfig, presets: []);
