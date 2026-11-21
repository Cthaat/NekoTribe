import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_response.dart';
import 'package:nekotribe/features/auth/data/auth_api.dart';
import 'package:nekotribe/features/auth/data/auth_repository.dart';
import 'package:nekotribe/features/posts/data/posts_api.dart';
import 'package:nekotribe/features/posts/domain/post_models.dart';
import 'package:nekotribe/features/posts/presentation/search_screen.dart';
import 'package:nekotribe/features/users/data/users_api.dart';
import 'package:nekotribe/features/users/data/users_repository.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/shared/i18n/app_localizations.dart';
import 'package:nekotribe/shared/providers/providers.dart';
import 'package:nekotribe/shared/widgets/status_views.dart';

void main() {
  testWidgets(
    'post search shows matching tags and clears them with the query',
    (tester) async {
      final fixture = _DiscoveryFixture();
      await tester.pumpWidget(fixture.screen());
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Cats');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(fixture.posts.lastTagQuery, 'Cats');
      expect(find.widgetWithText(ActionChip, '#Cats'), findsOneWidget);
      await tester.tap(find.byKey(const Key('search-clear-button')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ActionChip, '#Cats'), findsNothing);
    },
  );
  testWidgets(
    'Users tab recommends accounts and pages through submitted search results',
    (tester) async {
      final fixture = _DiscoveryFixture();
      await tester.pumpWidget(fixture.screen());
      await tester.pumpAndSettle();
      await tester.tap(find.text('用户'));
      await tester.pumpAndSettle();
      expect(find.text('Recommended account'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Alice');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(fixture.users.searches, [('Alice', 1)]);
      expect(find.text('Alice page 1'), findsOneWidget);
      expect(find.text('Recommended account'), findsNothing);
      await tester.tap(find.text('加载更多用户'));
      await tester.pumpAndSettle();
      expect(fixture.users.searches, [('Alice', 1), ('Alice', 2)]);
      expect(find.text('Alice page 1'), findsOneWidget);
      expect(find.text('Alice page 2'), findsOneWidget);

      await tester.tap(find.byKey(const Key('search-clear-button')));
      await tester.pumpAndSettle();
      expect(find.text('Recommended account'), findsOneWidget);
      expect(find.text('Alice page 1'), findsNothing);
    },
  );

  testWidgets('changing accounts discards a pending recommendation response', (
    tester,
  ) async {
    final fixture = _DiscoveryFixture();
    final old = Completer<List<V2PublicUser>>();
    fixture.users.pending = old;
    await tester.pumpWidget(fixture.screen());
    await tester.pumpAndSettle();
    await tester.tap(find.text('用户'));
    await tester.pump();
    expect(fixture.users.recommendationRequests, 1);
    fixture.users.pending = null;
    final finishSwitch = Completer<void>();
    final switching = fixture.store.runSessionChange(
      (_) => finishSwitch.future,
    );
    old.complete([_account(8, 'Old account recommendation')]);
    await tester.pump();
    expect(fixture.users.recommendationRequests, 1);
    expect(find.text('Old account recommendation'), findsNothing);
    finishSwitch.complete();
    await switching;
    await tester.pumpAndSettle();
    expect(fixture.users.recommendationRequests, 2);
    expect(find.text('Old account recommendation'), findsNothing);
    expect(find.text('Recommended account'), findsOneWidget);
  });

  testWidgets('search shows clear icon and empty results state', (
    tester,
  ) async {
    final api = _FakePostsApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [postsApiProvider.overrideWithValue(api)],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supported,
          home: const SearchScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('search-clear-button')), findsNothing);
    expect(find.text('趋势标签'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'nope');
    await tester.pump();
    expect(find.byKey(const Key('search-clear-button')), findsOneWidget);

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(api.lastSearchQuery, 'nope');
    expect(find.byType(EmptyView), findsOneWidget);
    expect(find.text('没有找到相关内容'), findsOneWidget);

    await tester.tap(find.byKey(const Key('search-clear-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('search-clear-button')), findsNothing);
    expect(find.text('趋势标签'), findsOneWidget);
    expect(find.text('没有找到相关内容'), findsNothing);

    final pending = Completer<PagedResult<V2Post>>();
    api.pendingSearch = pending;
    await tester.enterText(find.byType(TextField), 'old keyword');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.tap(find.byKey(const Key('search-clear-button')));
    pending.complete(const PagedResult<V2Post>(items: []));
    await tester.pumpAndSettle();
    expect(find.text('趋势标签'), findsOneWidget);
    expect(find.text('没有找到相关内容'), findsNothing);
  });
}

class _FakePostsApi extends PostsApi {
  _FakePostsApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  String? lastSearchQuery;
  String? lastTagQuery;
  Completer<PagedResult<V2Post>>? pendingSearch;

  @override
  Future<List<V2TagItem>> getTrendingTags({int limit = 10}) async {
    return [V2TagItem(tagId: 1, name: 'flutter')];
  }

  @override
  Future<List<V2TagItem>> searchTags(String query) async {
    lastTagQuery = query;
    return [V2TagItem(tagId: 2, name: query)];
  }

  @override
  Future<PagedResult<V2Post>> searchPosts({
    required String query,
    int page = 1,
    int size = 20,
  }) async {
    lastSearchQuery = query;
    final pending = pendingSearch;
    if (pending != null) return pending.future;
    return const PagedResult<V2Post>(
      items: [],
      meta: ApiMeta(page: 1, pageSize: 20, total: 0, hasNext: false),
    );
  }
}

class _DiscoveryFixture {
  final store = _FakeTokenStore();
  final posts = _FakePostsApi();
  late final client = ApiClient(config: _testConfig, tokenStore: store);
  late final users = _FakeUsersRepository(UsersApi(client));

  Widget screen() => ProviderScope(
    overrides: [
      postsApiProvider.overrideWithValue(posts),
      usersRepositoryProvider.overrideWithValue(users),
      authRepositoryProvider.overrideWithValue(
        AuthRepository(api: AuthApi(client), tokenStore: store),
      ),
      authSessionProvider.overrideWith(
        (ref) => AuthSessionController(store)..markLoggedIn(),
      ),
    ],
    child: const MaterialApp(home: SearchScreen()),
  );
}

class _FakeUsersRepository extends UsersRepository {
  _FakeUsersRepository(super.api);

  final searches = <(String, int)>[];
  int recommendationRequests = 0;
  Completer<List<V2PublicUser>>? pending;

  @override
  Future<List<V2PublicUser>> recommendations({int limit = 10}) async {
    recommendationRequests++;
    final response = pending;
    if (response != null) return response.future;
    return [_account(7, 'Recommended account')];
  }

  @override
  Future<PagedResult<V2PublicUser>> searchUsers(
    String query, {
    int page = 1,
    int size = 20,
  }) async {
    searches.add((query, page));
    return PagedResult(
      items: [_account(page, '$query page $page')],
      meta: ApiMeta(page: page, pageSize: size, total: 2, hasNext: page == 1),
    );
  }
}

V2PublicUser _account(int id, String label) => V2PublicUser.fromJson({
  'user_id': id,
  'username': 'sample$id',
  'display_name': label,
});

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
