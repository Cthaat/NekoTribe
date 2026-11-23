import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:passkeys/exceptions.dart';

import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_exception.dart';
import 'package:nekotribe/features/auth/data/auth_api.dart';
import 'package:nekotribe/features/auth/data/auth_repository.dart';
import 'package:nekotribe/features/auth/data/passkey_client.dart';
import 'package:nekotribe/features/auth/presentation/login_screen.dart';
import 'package:nekotribe/features/users/data/users_api.dart';
import 'package:nekotribe/features/users/data/users_repository.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/features/users/presentation/security_screen.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  testWidgets('blank passwordless login reuses remember me and 2FA routing', (
    tester,
  ) async {
    final fixture = _Fixture(store: _TokenStore());
    await fixture.pump(tester, const LoginScreen(inviteCode: 'abcdef'));
    await tester.tap(find.byType(Checkbox));
    final signIn = find.text('使用 Passkey 登录');
    await tester.ensureVisible(signIn);
    await tester.tap(signIn);
    await tester.pumpAndSettle();
    expect(find.text('2FA:second-factor:edge:ABCDEF'), findsOneWidget);
    expect(fixture.passkeys.authenticationOptions, _options);
    expect(fixture.adapter.requests.map((request) => request.path), [
      _authOptions,
      _authVerify,
    ]);
    final verify = fixture.adapter.requests.last;
    expect(verify.headers['Authorization'], isNull);
    expect(verify.headers['Cookie'], 'nekotribe_trusted_device=$_trusted');
    expect(verify.followRedirects, isFalse);
    expect(verify.data, {
      'challenge_id': _challengeId,
      'credential': _proof,
      'remember_me': true,
    });
  });

  testWidgets(
    'cancelled selector and unavailable server leave password login',
    (tester) async {
      final fixture = _Fixture(store: _TokenStore());
      await fixture.pump(tester, const LoginScreen());
      fixture.passkeys.cancel = true;
      final signIn = find.text('使用 Passkey 登录');
      await tester.ensureVisible(signIn);
      await tester.tap(signIn);
      await tester.pumpAndSettle();
      expect(fixture.adapter.requests.single.path, _authOptions);
      expect(find.widgetWithText(FilledButton, '登录'), findsOneWidget);
      fixture.adapter.unavailable = true;
      await tester.tap(signIn);
      await tester.pumpAndSettle();
      expect(find.text('当前服务器尚未启用 Passkey。'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '登录'), findsOneWidget);
      expect(fixture.adapter.requests.map((request) => request.path), [
        _authOptions,
        _authOptions,
      ]);
    },
  );

  testWidgets('security lists, registers by name and removes signed-in keys', (
    tester,
  ) async {
    final fixture = _Fixture(store: _TokenStore(signedIn: true));
    await fixture.pump(tester, const SecurityScreen());
    await _openManagement(tester);
    expect(find.text('Laptop'), findsOneWidget);
    await _register(tester, '  Phone  ');
    expect(find.text('Phone'), findsOneWidget);
    final phone = find.ancestor(
      of: find.text('Phone'),
      matching: find.byType(ListTile),
    );
    final remove = find.descendant(
      of: phone,
      matching: find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == '移除 Passkey',
      ),
    );
    await Scrollable.ensureVisible(tester.element(remove), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(remove);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '移除 Passkey'));
    await tester.pumpAndSettle();
    expect(find.text('Phone'), findsNothing);
    expect(find.text('Laptop'), findsOneWidget);
    expect(fixture.adapter.requests.map((request) => request.path), [
      _list,
      _registrationOptions,
      _registrationVerify,
      '$_list/phone_key',
    ]);
    expect(fixture.adapter.requests[2].data, {
      'challenge_id': _challengeId,
      'credential': _proof,
      'label': 'Phone',
    });
    expect(fixture.adapter.requests.last.method, 'DELETE');
    for (final request in fixture.adapter.requests) {
      expect(request.headers['Authorization'], 'Bearer access');
      expect(request.followRedirects, isFalse);
    }
  });

  testWidgets('security drops a proof returned after an account change', (
    tester,
  ) async {
    final fixture = _Fixture(store: _TokenStore(signedIn: true));
    await fixture.pump(tester, const SecurityScreen());
    fixture.passkeys.pendingCreation = Completer<Map<String, dynamic>>();
    await _openManagement(tester);
    await _register(tester, 'Phone', settle: false);
    expect(fixture.adapter.requests.last.path, _registrationOptions);
    fixture.store.beginSessionChange();
    await tester.pump();
    fixture.passkeys.pendingCreation!.complete(_proof);
    await tester.pumpAndSettle();
    expect(fixture.adapter.requests.length, 2);
    expect(find.text('重新打开安全设置'), findsOneWidget);
    expect(find.text('Laptop'), findsNothing);
  });

  test('a rejected registration proof never triggers token refresh', () async {
    final fixture = _Fixture(store: _TokenStore(signedIn: true));
    fixture.adapter.invalidRegistration = true;
    await expectLater(
      fixture.api.verifyPasskeyRegistration(
        challengeId: _challengeId,
        credential: _proof,
        label: '',
      ),
      throwsA(
        isA<ApiException>().having((error) => error.statusCode, 'HTTP', 401),
      ),
    );
    expect(fixture.adapter.requests.single.path, _registrationVerify);
    expect((await fixture.store.read())?.sessionId, 'current');
  });

  test('Windows rejects foreign and insecure relying party requests', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final backend in [
      'https://other-example.test',
      'http://example.test',
    ]) {
      final passkeys = PasskeyClient(readApiBaseUrl: () => backend);
      await expectLater(
        passkeys.authenticate(_options),
        throwsA(isA<DomainNotAssociatedException>()),
      );
    }
  });

  test('queued passkey registration cannot send a newer bearer', () async {
    final fixture = _Fixture(store: _TokenStore(signedIn: true));
    final queued = fixture.api.verifyPasskeyRegistration(
      challengeId: _challengeId,
      credential: _proof,
      label: '',
    );
    fixture.store.beginSessionChange();
    await expectLater(
      queued,
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'kind',
          DioExceptionType.cancel,
        ),
      ),
    );
    expect(fixture.adapter.requests, isEmpty);
  });
}

Future<void> _openManagement(WidgetTester tester) async {
  final title = find.text('Passkey');
  await tester.ensureVisible(title);
  await tester.tap(title);
  await tester.pumpAndSettle();
}

Future<void> _register(
  WidgetTester tester,
  String label, {
  bool settle = true,
}) async {
  final add = find.widgetWithText(OutlinedButton, '登记 Passkey');
  await tester.ensureVisible(add);
  await tester.tap(add);
  await tester.pumpAndSettle();
  await tester.enterText(
    find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    ),
    label,
  );
  await tester.pump();
  await tester.tap(find.widgetWithText(FilledButton, '登记 Passkey'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
}

const _challengeId = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _options = {'challenge': _challengeId, 'rpId': 'example.test'};
const _proof = <String, dynamic>{'id': 'synthetic'};
const _trusted =
    'td1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _list = '/api/v2/users/me/passkeys';
const _authOptions = '/api/v2/auth/passkeys/authentication/options';
const _authVerify = '/api/v2/auth/passkeys/authentication/verification';
const _registrationOptions = '/api/v2/auth/passkeys/registration/options';
const _registrationVerify = '/api/v2/auth/passkeys/registration/verification';

class _Fixture {
  _Fixture({required this.store}) {
    final client = ApiClient(
      config: const AppConfig(
        apiBaseUrl: 'https://example.test',
        wsBaseUrl: 'wss://example.test',
        storageBaseUrl: 'https://example.test',
      ),
      tokenStore: store,
      dio: Dio()..httpClientAdapter = adapter,
    );
    api = AuthApi(client);
    auth = AuthRepository(api: api, tokenStore: store);
    users = _Users(UsersApi(client));
  }

  final _TokenStore store;
  final adapter = _Adapter();
  final passkeys = _Passkeys();
  late final AuthApi api;
  late final AuthRepository auth;
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
          authRepositoryProvider.overrideWithValue(auth),
          tokenStoreProvider.overrideWithValue(store),
          usersRepositoryProvider.overrideWithValue(users),
          passkeyClientProvider.overrideWithValue(passkeys),
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

class _Passkeys extends PasskeyClient {
  _Passkeys() : super(readApiBaseUrl: () => 'https://example.test');

  bool cancel = false;
  Map<String, dynamic>? authenticationOptions;
  Completer<Map<String, dynamic>>? pendingCreation;

  @override
  bool get isSupported => true;

  @override
  Future<Map<String, dynamic>> authenticate(
    Map<String, dynamic> options,
  ) async {
    authenticationOptions = options;
    if (cancel) throw PasskeyAuthCancelledException(null);
    return _proof;
  }

  @override
  Future<Map<String, dynamic>> create(Map<String, dynamic> options) async =>
      pendingCreation == null ? _proof : await pendingCreation!.future;
}

class _TokenStore extends TokenStore {
  _TokenStore({this.signedIn = false});
  final bool signedIn;

  @override
  Future<TokenPair?> read() async => !signedIn
      ? null
      : const TokenPair(
          accessToken: 'access',
          refreshToken: 'refresh',
          sessionId: 'current',
        );

  @override
  Future<String> deviceFingerprint() async => 'synthetic-device';

  @override
  Future<String?> readTrustedDevice(String endpoint) async => _trusted;
}

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  bool unavailable = false;
  bool invalidRegistration = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (unavailable ||
        (invalidRegistration && options.path == _registrationVerify)) {
      return _response(null, unavailable ? 503 : 401);
    }
    return switch (options.path) {
      _authOptions || _registrationOptions => _response({
        'challenge_id': _challengeId,
        'options': _options,
      }),
      _authVerify => _response({
        'two_factor_required': true,
        'challenge_id': 'second-factor',
        'account': 'edge',
        'expires_at': '2030-01-01T00:00:00Z',
      }),
      _list => _response({
        'credentials': [_credential('laptop_key', 'Laptop')],
      }),
      _registrationVerify => _response({
        'credential': _credential('phone_key', 'Phone'),
      }),
      '$_list/phone_key' => _response(null),
      _ => throw StateError('Unexpected request: ${options.path}'),
    };
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _credential(String id, String label) => {
  'credential_id': id,
  'label': label,
  'created_at': '2026-11-22T00:00:00Z',
  'last_used_at': null,
};

ResponseBody _response(Object? value, [int status = 200]) =>
    ResponseBody.fromString(
      jsonEncode({'code': status, 'message': 'fixture', 'data': value}),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
