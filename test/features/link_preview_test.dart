import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/features/links/data/link_preview_api.dart';
import 'package:nekotribe/features/links/domain/link_preview.dart';
import 'package:nekotribe/features/links/presentation/content_link_preview.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  test('only the first eligible external document link survives extraction', () {
    expect(
      firstPreviewUrl(
        'See (https://backend.invalid/posts/1) and (https://example.org/wiki/Test_(page)#fragment), then https://second.example.org',
        excludedHosts: {'backend.invalid'},
      ),
      Uri.parse('https://example.org/wiki/Test_(page)'),
    );
    const markdown = '''
![Visible alt](https://tracker.example.org/icon.png)

`https://inline-code.example.org`

~~~sh
https://fenced-code.example.org
~~~

<pre>https://raw-code.example.org</pre>

[internal](https://backend.invalid/posts/3)
[file](file:///tmp/irrelevant)
[credentialed](https://user@example.org)
[external](https://example.org/path#part)
[later](https://not-first.example.org/)
''';
    expect(
      firstPreviewUrl(markdown, excludedHosts: {'backend.invalid'}),
      Uri.parse('https://example.org/path'),
    );
    expect(firstPreviewUrl('![alt](https://images.example.org/icon)'), isNull);
    expect(normalizePreviewUrl('https://example.org:8443'), isNull);
    expect(normalizePreviewUrl('https://@example.org'), isNull);
    expect(
      normalizePreviewUrl('https://example.org:443/#private'),
      Uri.parse('https://example.org/'),
    );
    expect(normalizePreviewUrl('https://example.org/${'界' * 690}'), isNull);
  });

  test(
    'wire requests use the current backend and validate the final URL',
    () async {
      final client = _client(_Tokens());
      addTearDown(client.dispose);
      final requests = <RequestOptions>[];
      Object? preview = {
        'url': 'https://final.example.org/news',
        'title': 'Story',
        'description': 'Summary',
        'site_name': 'News',
        'image': 'https://tracker.example.org/not-rendered',
      };
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
                  'message': 'success',
                  'data': {'preview': preview},
                  'meta': null,
                },
              ),
            );
          },
        ),
      );
      final api = LinkPreviewApi(client);
      final uri = Uri.parse('https://example.org/post?q=1#omit');
      final token = CancelToken();
      final result = await api.read(uri, cancelToken: token);
      expect(result?.url, Uri.parse('https://final.example.org/news'));
      expect(result?.title, 'Story');
      expect(requests.single.method, 'GET');
      expect(requests.single.uri.host, 'backend.invalid');
      expect(requests.single.path, '/api/v2/links/preview');
      expect(requests.single.queryParameters, {
        'url': 'https://example.org/post?q=1',
      });
      expect(requests.single.headers['Authorization'], 'Bearer fixture-token');

      preview = null;
      expect(await api.read(uri, cancelToken: token), isNull);
      preview = {
        'url': 'javascript:blocked',
        'title': 'Wrong shape',
        'description': '',
        'site_name': '',
      };
      await expectLater(
        api.read(uri, cancelToken: token),
        throwsFormatException,
      );
    },
  );

  testWidgets(
    'visible duplicate cards share one text-only fetch and open on tap',
    (tester) async {
      final tokens = _Tokens();
      final api = _LinkApi(tokens);
      final opened = <Uri>[];
      Future<bool> launch(Uri uri) async {
        opened.add(uri);
        return true;
      }

      await tester.pumpWidget(
        _app(
          tokens,
          api,
          Column(
            children: [
              ContentLinkPreview(
                content: 'https://example.org#first',
                onOpenLink: launch,
              ),
              ContentLinkPreview(
                content: 'https://example.org/#second',
                onOpenLink: launch,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.calls.single.$1, Uri.parse('https://example.org/'));
      expect(find.text('Preview title'), findsNWidgets(2));
      expect(find.text('Description'), findsNWidgets(2));
      expect(find.byType(Image), findsNothing);
      expect(opened, isEmpty);
      await tester.tap(find.text('Preview title').first);
      expect(opened, [Uri.parse('https://final.example.org')]);
    },
  );

  testWidgets(
    'offscreen items request only after scrolling into the viewport',
    (tester) async {
      final tokens = _Tokens();
      final api = _LinkApi(tokens);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        _app(
          tokens,
          api,
          SingleChildScrollView(
            controller: scroll,
            child: const Column(
              children: [
                SizedBox(height: 900),
                ContentLinkPreview(content: 'https://example.org'),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.calls, isEmpty);
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(api.calls, hasLength(1));
      expect(find.text('Preview title'), findsOneWidget);
    },
  );

  testWidgets('late receipts from a changed account or endpoint stay hidden', (
    tester,
  ) async {
    final tokens = _Tokens();
    final api = _LinkApi(tokens);
    final first = Completer<V2LinkPreview?>();
    api.pending = first.future;
    final content = ValueNotifier('https://example.org/old');
    addTearDown(content.dispose);
    await tester.pumpWidget(
      _app(
        tokens,
        api,
        ValueListenableBuilder(
          valueListenable: content,
          builder: (_, value, _) => ContentLinkPreview(content: value),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final old = api.calls.single.$2;
    api.pending = Future.value(_preview('New receipt'));
    await tokens.switchEndpoint(() {});
    await tester.pumpAndSettle();
    first.complete(_preview('Old receipt'));
    await tester.pumpAndSettle();
    expect(old.isCancelled, isTrue);
    expect(api.calls, hasLength(1));
    expect(find.text('Old receipt'), findsNothing);
    content.value = 'https://example.org/new';
    await tester.pumpAndSettle();
    expect(api.calls, hasLength(2));
    expect(find.text('New receipt'), findsOneWidget);
  });

  testWidgets('signed-out and no-metadata cases keep the original text', (
    tester,
  ) async {
    final tokens = _Tokens();
    final api = _LinkApi(tokens)..pending = Future.value(null);
    const child = Column(
      children: [
        Text('Original message'),
        ContentLinkPreview(content: 'https://example.org'),
      ],
    );
    await tester.pumpWidget(_app(tokens, api, child, signedIn: false));
    await tester.pumpAndSettle();
    expect(api.calls, isEmpty);
    expect(find.text('Original message'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_app(tokens, api, child));
    await tester.pumpAndSettle();
    expect(api.calls, hasLength(1));
    expect(find.text('Original message'), findsOneWidget);
    expect(find.text('Preview title'), findsNothing);
  });
}

Widget _app(
  TokenStore store,
  LinkPreviewApi api,
  Widget child, {
  bool signedIn = true,
}) => ProviderScope(
  overrides: [
    appConfigBundleProvider.overrideWithValue(
      const AppConfigBundle(defaults: _config, presets: []),
    ),
    appConfigInitialProvider.overrideWithValue(_config),
    tokenStoreProvider.overrideWithValue(store),
    authSessionProvider.overrideWith((_) {
      final auth = AuthSessionController(store);
      if (signedIn) {
        auth.markLoggedIn();
      } else {
        auth.markLoggedOut();
      }
      return auth;
    }),
    linkPreviewApiProvider.overrideWithValue(api),
  ],
  child: MaterialApp(home: Scaffold(body: child)),
);

const _config = AppConfig(
  apiBaseUrl: 'https://backend.invalid',
  wsBaseUrl: 'wss://backend.invalid',
  storageBaseUrl: 'https://storage.invalid',
);

ApiClient _client(TokenStore store) =>
    ApiClient(config: _config, tokenStore: store);

V2LinkPreview _preview(String title) => V2LinkPreview(
  url: Uri.parse('https://final.example.org'),
  title: title,
  description: 'Description',
  siteName: 'Example',
);

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

class _LinkApi extends LinkPreviewApi {
  _LinkApi(TokenStore store) : super(_client(store));

  final calls = <(Uri, CancelToken)>[];
  Future<V2LinkPreview?>? pending;

  @override
  Future<V2LinkPreview?> read(Uri url, {required CancelToken cancelToken}) {
    calls.add((url, cancelToken));
    return pending ?? Future.value(_preview('Preview title'));
  }
}
