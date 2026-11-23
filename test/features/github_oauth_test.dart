import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/features/auth/data/auth_api.dart';
import 'package:nekotribe/features/auth/data/auth_repository.dart';
import 'package:nekotribe/features/auth/domain/auth_models.dart';
import 'package:nekotribe/features/auth/domain/github_oauth_models.dart';
import 'package:nekotribe/features/auth/presentation/github_oauth_dialog.dart';
import 'package:nekotribe/features/auth/presentation/login_screen.dart';
import 'package:nekotribe/features/users/data/users_api.dart';
import 'package:nekotribe/features/users/data/users_repository.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/features/users/presentation/security_screen.dart';
import 'package:nekotribe/shared/providers/providers.dart';

const id = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const key = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const authorize = 'https://github.com/login/oauth/authorize?state=fixture';

Map<String, Object> flow(String url) => {
  'flow_id': id,
  'flow_key': key,
  'authorization_url': url,
  'expires_in': 300,
};

void main() {
  test('opens only the exact HTTPS GitHub authorize endpoint', () {
    expect(
      GitHubOAuthFlow.fromJson(flow(authorize)).authorizationUrl.host,
      'github.com',
    );
    for (final url in [
      'http://github.com/login/oauth/authorize',
      'https://github.com@attacker.test/login/oauth/authorize',
      'https://github.com:8443/login/oauth/authorize',
      'https://github.com/login/oauth/access_token',
      '$authorize&flow_key=$key',
      '$authorize&state=$key',
    ]) {
      expect(() => GitHubOAuthFlow.fromJson(flow(url)), throwsFormatException);
    }
  });

  testWidgets('explicit user gesture opens GitHub, then polls into 2FA', (
    tester,
  ) async {
    final fixture = _Fixture();
    await fixture.pump(tester, const LoginScreen(inviteCode: 'abcdef'));
    await tester.tap(find.byType(Checkbox));
    await _tapVisible(tester, '使用 GitHub 登录');
    expect(fixture.urls, isEmpty);
    expect(fixture.adapter.requests.single.path, _loginFlows);
    await _tapVisible(tester, '打开 GitHub');
    expect(fixture.urls, [Uri.parse(authorize)]);
    expect(find.text('等待 GitHub 授权完成。'), findsOneWidget);
    final firstPoll = fixture.adapter.requests.last;
    expect(firstPoll.path, '$_loginFlows/$id/complete');
    expect(firstPoll.uri.query, isEmpty);
    expect(firstPoll.method, 'POST');
    expect(firstPoll.headers['Authorization'], isNull);
    expect(firstPoll.headers['Cookie'], 'nekotribe_trusted_device=$_trusted');
    expect(firstPoll.followRedirects, isFalse);
    expect(firstPoll.data, {'flow_key': key, 'remember_me': true});
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('2FA:second-factor:edge:ABCDEF'), findsOneWidget);
    expect(fixture.adapter.requests.length, 3);
  });

  for (final switchScope in [false, true]) {
    testWidgets(
      switchScope
          ? 'an account transition aborts the in-flight GitHub login'
          : 'cancel aborts the in-flight GitHub login',
      (tester) async {
        final fixture = _Fixture();
        final response = Completer<ResponseBody>();
        fixture.adapter.pendingPoll = response;
        await fixture.pump(tester, const LoginScreen());
        await _tapVisible(tester, '使用 GitHub 登录');
        await _tapVisible(tester, '打开 GitHub');
        expect(fixture.adapter.requests.length, 2);
        if (switchScope) {
          fixture.store.beginSessionChange();
          await tester.pumpAndSettle();
        } else {
          await _tapVisible(tester, '取消');
        }
        expect(fixture.adapter.cancelledPoll, isTrue);
        response.complete(_response(_challengeReceipt));
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        expect(fixture.adapter.requests.length, 2);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(LoginScreen), findsOneWidget);
      },
    );
  }

  testWidgets('authorization expires in five minutes and does not poll again', (
    tester,
  ) async {
    final fixture = _Fixture();
    fixture.adapter.remainsPending = true;
    await fixture.pump(tester, const LoginScreen());
    await _tapVisible(tester, '使用 GitHub 登录');
    await _tapVisible(tester, '打开 GitHub');
    await tester.pump(const Duration(minutes: 5));
    await tester.pumpAndSettle();
    expect(find.text('授权已过期，请重新开始。'), findsOneWidget);
    final before = fixture.adapter.requests.length;
    await tester.pump(const Duration(seconds: 15));
    expect(fixture.adapter.requests.length, before);
  });

  testWidgets('security reads a binding, confirms a link and unlinks it', (
    tester,
  ) async {
    final fixture = _Fixture(signedIn: true);
    await fixture.pump(tester, const SecurityScreen());
    await _tapVisible(tester, 'GitHub 绑定');
    expect(find.text('尚未绑定 GitHub。'), findsOneWidget);
    await _tapVisible(tester, '绑定 GitHub');
    await _tapVisible(tester, '打开 GitHub');
    expect(find.text('@octocat'), findsOneWidget);
    expect(fixture.adapter.requests.map((request) => request.path), [
      _linkPath,
      '$_linkPath/flows',
      '$_linkPath/flows/$id/complete',
    ]);
    expect(fixture.adapter.requests.last.data, {'flow_key': key});
    for (final request in fixture.adapter.requests) {
      expect(request.headers['Authorization'], 'Bearer access');
      expect(request.followRedirects, isFalse);
    }
    fixture.adapter.unlinkConflicts = true;
    await _tapVisible(tester, '解绑 GitHub');
    await tester.tap(find.widgetWithText(FilledButton, '解绑 GitHub'));
    await tester.pumpAndSettle();
    expect(find.text('@octocat'), findsOneWidget);
    fixture.adapter.unlinkConflicts = false;
    await _tapVisible(tester, '解绑 GitHub');
    await tester.tap(find.widgetWithText(FilledButton, '解绑 GitHub'));
    await tester.pumpAndSettle();
    expect(find.text('尚未绑定 GitHub。'), findsOneWidget);
    expect(fixture.adapter.requests.last.path, _linkPath);
    expect(fixture.adapter.requests.last.method, 'DELETE');
  });

  test('nested GitHub login receipts reuse native auth cookies', () async {
    final fixture = _Fixture();
    fixture.adapter.cookieLogin = true;
    final result = await fixture.repo.pollGitHubLogin(
      GitHubOAuthFlow.fromJson(flow(authorize)),
      rememberMe: false,
      cancelToken: CancelToken(),
    );
    expect(result, isA<V2LoginSuccess>());
    final tokens = (result as V2LoginSuccess).tokens;
    expect(tokens.accessToken, 'cookie-access');
    expect(tokens.refreshToken, 'cookie-refresh');
  });
}

Future<void> _tapVisible(WidgetTester tester, String label) async {
  final target = find.text(label);
  await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

const _loginFlows = '/api/v2/auth/oauth/github/login/flows';
const _linkPath = '/api/v2/users/me/oauth/github';
const _trusted =
    'td1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _pending = {'status': 'pending'};
const _challengeReceipt = {
  'status': 'completed',
  'login': {
    'two_factor_required': true,
    'challenge_id': 'second-factor',
    'account': 'edge',
    'expires_at': '2030-01-01T00:00:00Z',
  },
};

class _Fixture {
  _Fixture({bool signedIn = false}) : store = _TokenStore(signedIn) {
    final client = ApiClient(
      config: const AppConfig(
        apiBaseUrl: 'https://example.test',
        wsBaseUrl: 'wss://example.test',
        storageBaseUrl: 'https://example.test',
      ),
      tokenStore: store,
      dio: Dio()..httpClientAdapter = adapter,
    );
    repo = AuthRepository(api: AuthApi(client), tokenStore: store);
    users = _Users(UsersApi(client));
  }

  final _TokenStore store;
  final adapter = _Adapter();
  final urls = <Uri>[];
  late final AuthRepository repo;
  late final _Users users;

  Future<void> pump(WidgetTester tester, Widget home) async {
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => home),
        GoRoute(
          path: '/auth/2fa',
          builder: (_, state) {
            final extra = state.extra as Map<String, dynamic>;
            return Text(
              '2FA:${extra['challengeId']}:${extra['account']}:${state.uri.queryParameters['code']}',
            );
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          authRepositoryProvider.overrideWithValue(repo),
          usersRepositoryProvider.overrideWithValue(users),
          gitHubAuthorizationLauncherProvider.overrideWithValue((url) async {
            urls.add(url);
            return true;
          }),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }
}

class _Users extends UsersRepository {
  _Users(super.api);

  @override
  Future<V2UserSettings> getSettings() async => V2UserSettings(
    userId: 1,
    twoFactorEnabled: true,
    loginAlerts: true,
    profileVisibility: 'public',
    updatedAt: '2026-11-22T00:00:00Z',
  );
}

class _TokenStore extends TokenStore {
  _TokenStore(this.signedIn);
  final bool signedIn;

  @override
  Future<TokenPair?> read() async => signedIn
      ? const TokenPair(
          accessToken: 'access',
          refreshToken: 'refresh',
          sessionId: 'current',
        )
      : null;

  @override
  Future<String> deviceFingerprint() async => 'synthetic-device';

  @override
  Future<String?> readTrustedDevice(String endpoint) async => _trusted;
}

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  var _loginPolls = 0;
  bool remainsPending = false;
  bool cancelledPoll = false;
  bool cookieLogin = false;
  bool unlinkConflicts = false;
  Completer<ResponseBody>? pendingPoll;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.path == '$_loginFlows/$id/complete') {
      cancelFuture?.then((_) => cancelledPoll = true);
      final pending = pendingPoll;
      if (pending != null) return pending.future;
      if (cookieLogin) {
        return _response(
          {
            'status': 'completed',
            'login': {
              'two_factor_required': false,
              'user': {'user_id': 1, 'username': 'edge'},
              'tokens': {
                'session_id': 'current',
                'access_token_expires_at': '2030-01-01T00:00:00Z',
                'refresh_token_expires_at': '2030-02-01T00:00:00Z',
              },
            },
          },
          cookies: [
            'access_token=cookie-access',
            'refresh_token=cookie-refresh',
          ],
        );
      }
      return _response(
        ++_loginPolls == 1 || remainsPending ? _pending : _challengeReceipt,
      );
    }
    return switch ((options.method, options.path)) {
      ('POST', _loginFlows || '$_linkPath/flows') => _response(flow(authorize)),
      ('GET', _linkPath) => _response({'link': null}),
      ('POST', '$_linkPath/flows/$id/complete') => _response({
        'status': 'completed',
        'link': {
          'github_user_id': '1234',
          'github_login': 'octocat',
          'linked_at': '2026-11-22T00:00:00Z',
        },
      }),
      ('DELETE', _linkPath) => _response(
        null,
        status: unlinkConflicts ? 409 : 200,
      ),
      _ => throw StateError('Unexpected request: ${options.path}'),
    };
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _response(
  Object? value, {
  int status = 200,
  List<String> cookies = const [],
}) => ResponseBody.fromString(
  jsonEncode({'code': status, 'message': 'fixture', 'data': value}),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
    if (cookies.isNotEmpty) 'set-cookie': cookies,
  },
);
