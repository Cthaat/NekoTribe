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
import 'package:nekotribe/features/posts/presentation/search_screen.dart';
import 'package:nekotribe/shared/i18n/app_localizations.dart';
import 'package:nekotribe/shared/providers/providers.dart';
import 'package:nekotribe/shared/widgets/status_views.dart';

void main() {
  testWidgets('search shows clear icon and empty results state', (tester) async {
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
  });
}

class _FakePostsApi extends PostsApi {
  _FakePostsApi()
    : super(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()));

  String? lastSearchQuery;

  @override
  Future<List<V2TagItem>> getTrendingTags({int limit = 10}) async {
    return [V2TagItem(tagId: 1, name: 'flutter')];
  }

  @override
  Future<PagedResult<V2Post>> searchPosts({
    required String query,
    int page = 1,
    int size = 20,
  }) async {
    lastSearchQuery = query;
    return const PagedResult<V2Post>(
      items: [],
      meta: ApiMeta(page: 1, pageSize: 20, total: 0, hasNext: false),
    );
  }
}

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
