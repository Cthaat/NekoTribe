import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_exception.dart';
import 'package:nekotribe/core/network/api_response.dart';
import 'package:nekotribe/features/posts/data/posts_api.dart';
import 'package:nekotribe/features/posts/domain/post_models.dart';
import 'package:nekotribe/features/posts/presentation/post_card.dart';
import 'package:nekotribe/features/users/data/users_api.dart';
import 'package:nekotribe/features/users/data/users_repository.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/features/users/presentation/profile_screen.dart';
import 'package:nekotribe/features/users/presentation/user_posts_screen.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  test('profile pin requests bind the expected paths and receipts', () async {
    final client = _client(_TestTokens());
    addTearDown(client.dispose);
    final requests = <RequestOptions>[];
    Object? response;
    client.raw.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          requests.add(request);
          handler.resolve(
            Response(
              requestOptions: request,
              statusCode: 200,
              data: {
                'code': 200,
                'message': 'ok',
                'data': response,
                'meta': null,
              },
            ),
          );
        },
      ),
    );
    final api = UsersApi(client);
    final token = CancelToken();
    response = {'post': _postJson(1, 41)};
    expect((await api.getPinnedPost(1, cancelToken: token))?.postId, 41);
    response = {'post': null};
    expect(await api.getPinnedPost(1, cancelToken: token), isNull);
    response = {'post': _postJson(2, 42)};
    await expectLater(
      api.getPinnedPost(1, cancelToken: token),
      throwsFormatException,
    );
    response = {'post_id': 41};
    await api.setPinnedPost(41, cancelToken: token);
    expect(requests.last.data, {'post_id': 41});
    await expectLater(
      api.setPinnedPost(42, cancelToken: token),
      throwsFormatException,
    );
    response = null;
    await api.clearPinnedPost(cancelToken: token);
    expect(requests.map((option) => (option.method, option.path)), [
      ('GET', '/api/v2/users/1/pinned-post'),
      ('GET', '/api/v2/users/1/pinned-post'),
      ('GET', '/api/v2/users/1/pinned-post'),
      ('PUT', '/api/v2/users/me/pinned-post'),
      ('PUT', '/api/v2/users/me/pinned-post'),
      ('DELETE', '/api/v2/users/me/pinned-post'),
    ]);
  });

  testWidgets(
    'profile owners replace and clear a pin without reordering ordinary posts',
    (tester) async {
      final tokens = _TestTokens();
      final users = _UsersApi(tokens)..pinned = _post(1, 42);
      final posts = _PostsApi(tokens)..pages[1] = [_post(1, 41), _post(1, 42)];
      await tester.pumpWidget(
        _app(tokens, users, posts, const ProfileScreen(userId: 1)),
      );
      await tester.pumpAndSettle();
      expect(_visible(tester), [42, 41]);
      expect(find.text('个人主页置顶'), findsOneWidget);
      expect(find.text('173'), findsOneWidget);

      await _openMenu(tester, 41);
      await tester.tap(find.text('置顶到个人主页'));
      await tester.pumpAndSettle();
      expect(users.writes, [41]);
      expect(_visible(tester), [41, 42]);
      expect(
        tester.widget<PostCard>(find.byType(PostCard).first).profilePinned,
        isTrue,
      );

      await _openMenu(tester, 41);
      await tester.tap(find.text('取消主页置顶'));
      await tester.pumpAndSettle();
      expect(users.writes, [41, null]);
      expect(_visible(tester), [41, 42]);
      expect(find.text('个人主页置顶'), findsNothing);
      expect(find.text('173'), findsOneWidget);
      expect(posts.reads, [(1, 1)]);
    },
  );

  testWidgets(
    'paged profile posts omit a pin repeated on either ordinary page',
    (tester) async {
      final tokens = _TestTokens();
      final users = _UsersApi(tokens)..pinned = _post(1, 42);
      final posts = _PostsApi(tokens)
        ..pages[1] = [_post(1, 41), _post(1, 42)]
        ..pages[2] = [_post(1, 42), _post(1, 43)];
      await tester.pumpWidget(
        _app(tokens, users, posts, const UserPostsScreen(userId: 1)),
      );
      await tester.pump();
      await tester.pump();
      expect(_visible(tester), [42, 41]);
      final scroll = tester.element(find.byType(ListView));
      ScrollUpdateNotification(
        metrics: FixedScrollMetrics(
          minScrollExtent: 0,
          maxScrollExtent: 1,
          pixels: 1,
          viewportDimension: 400,
          axisDirection: AxisDirection.down,
          devicePixelRatio: 1,
        ),
        context: scroll,
        scrollDelta: 1,
      ).dispatch(scroll);
      await tester.pumpAndSettle();
      expect(posts.reads, [(1, 1), (1, 2)]);
      expect(_visible(tester), [42, 41, 43]);
      expect(find.text('个人主页置顶'), findsOneWidget);
    },
  );

  testWidgets('a pin failure leaves a visitor’s ordinary timeline usable', (
    tester,
  ) async {
    final tokens = _TestTokens();
    final users = _UsersApi(tokens)..unavailable = true;
    final posts = _PostsApi(tokens)..pages[1] = [_post(2, 51)];
    await tester.pumpWidget(
      _app(tokens, users, posts, const ProfileScreen(userId: 2)),
    );
    await tester.pumpAndSettle();
    expect(_visible(tester), [51]);
    await _openMenu(tester, 51);
    expect(find.text('置顶到个人主页'), findsNothing);
    expect(find.text('取消主页置顶'), findsNothing);
    expect(find.text('举报'), findsOneWidget);
  });

  testWidgets(
    'new account and profile clear cached pin and discard a late write',
    (tester) async {
      final tokens = _TestTokens();
      final waiting = Completer<void>();
      final users = _UsersApi(tokens)
        ..pinned = _post(1, 42)
        ..pendingWrite = waiting.future;
      final posts = _PostsApi(tokens)..pages[1] = [_post(1, 41)];
      final target = ValueNotifier(1);
      addTearDown(target.dispose);
      await tester.pumpWidget(
        _app(
          tokens,
          users,
          posts,
          ValueListenableBuilder(
            valueListenable: target,
            builder: (_, id, _) => ProfileScreen(userId: id),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _openMenu(tester, 41);
      await tester.tap(find.text('置顶到个人主页'));
      await tester.pumpAndSettle();
      final cancelled = users.writeToken!;
      users.pinned = _post(2, 62);
      posts.pages[1] = [_post(2, 61)];
      tokens.beginSessionChange();
      target.value = 2;
      await tester.pumpAndSettle();
      waiting.complete();
      await tester.pumpAndSettle();
      expect(cancelled.isCancelled, isTrue);
      expect(_visible(tester), [62, 61]);
      expect(users.writes, [41]);
    },
  );
}

List<int> _visible(WidgetTester tester) => tester
    .widgetList<PostCard>(find.byType(PostCard))
    .map((card) => card.post.postId)
    .toList();

Future<void> _openMenu(WidgetTester tester, int postId) async {
  final button = find.byKey(Key('post-more-button-$postId'));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Widget _app(
  _TestTokens tokens,
  _UsersApi users,
  _PostsApi posts,
  Widget screen,
) => ProviderScope(
  overrides: [
    appConfigBundleProvider.overrideWithValue(
      const AppConfigBundle(defaults: _config, presets: []),
    ),
    appConfigInitialProvider.overrideWithValue(_config),
    tokenStoreProvider.overrideWithValue(tokens),
    authSessionProvider.overrideWith(
      (_) => AuthSessionController(tokens)..markLoggedIn(),
    ),
    usersApiProvider.overrideWithValue(users),
    usersRepositoryProvider.overrideWithValue(_UsersRepository(users)),
    postsApiProvider.overrideWithValue(posts),
  ],
  child: MaterialApp(home: screen),
);

const _config = AppConfig(
  apiBaseUrl: 'https://example.invalid',
  wsBaseUrl: 'wss://example.invalid',
  storageBaseUrl: 'https://example.invalid',
);

ApiClient _client(TokenStore store) =>
    ApiClient(config: _config, tokenStore: store);

class _TestTokens extends TokenStore {
  @override
  Future<String> deviceFingerprint() async => 'test';

  @override
  Future<TokenPair?> read() async => const TokenPair(
    accessToken: 'access-token',
    refreshToken: 'refresh-token',
    sessionId: 'session-1',
  );
}

Map<String, Object?> _userJson(int userId) => {
  'user_id': userId,
  'username': 'profile$userId',
  'display_name': 'Profile $userId',
  'posts_count': 173,
  'relationship': {'is_self': userId == 1},
};

Map<String, Object?> _postJson(int userId, int postId) => {
  'post_id': postId,
  'author': _userJson(userId),
  'content': 'Post $postId',
  'viewer_state': {'can_delete': userId == 1},
};

V2Post _post(int userId, int postId) =>
    V2Post.fromJson(_postJson(userId, postId));

class _UsersApi extends UsersApi {
  _UsersApi(TokenStore store) : super(_client(store));

  V2Post? pinned;
  bool unavailable = false;
  Future<void>? pendingWrite;
  CancelToken? writeToken;
  final writes = <int?>[];

  @override
  Future<V2Post?> getPinnedPost(
    int userId, {
    required CancelToken cancelToken,
  }) async {
    if (unavailable) {
      throw ApiException(code: 50301, message: 'Unavailable', statusCode: 503);
    }
    return pinned?.author.userId == userId ? pinned : null;
  }

  @override
  Future<void> setPinnedPost(
    int postId, {
    required CancelToken cancelToken,
  }) async {
    writes.add(postId);
    writeToken = cancelToken;
    await pendingWrite;
  }

  @override
  Future<void> clearPinnedPost({required CancelToken cancelToken}) async {
    writes.add(null);
  }
}

class _UsersRepository extends UsersRepository {
  _UsersRepository(super.api);

  @override
  Future<V2PublicUser> getUserById(int userId) async =>
      V2PublicUser.fromJson(_userJson(userId));
}

class _PostsApi extends PostsApi {
  _PostsApi(TokenStore store) : super(_client(store));

  final pages = <int, List<V2Post>>{};
  final reads = <(int, int)>[];

  @override
  Future<PagedResult<V2Post>> getUserPostsById(
    int userId, {
    int page = 1,
    int size = 20,
    String sort = 'newest',
  }) async {
    reads.add((userId, page));
    return PagedResult(
      items: pages[page] ?? [],
      meta: ApiMeta(page: page, hasNext: pages.containsKey(page + 1)),
    );
  }
}
