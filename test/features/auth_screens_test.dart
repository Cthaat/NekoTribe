import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_exception.dart';
import 'package:nekotribe/features/auth/data/auth_api.dart';
import 'package:nekotribe/features/auth/data/auth_repository.dart';
import 'package:nekotribe/features/auth/domain/auth_models.dart';
import 'package:nekotribe/features/auth/presentation/forgot_password_screen.dart';
import 'package:nekotribe/features/auth/presentation/login_screen.dart';
import 'package:nekotribe/features/auth/presentation/two_factor_screen.dart';
import 'package:nekotribe/features/auth/presentation/register_screen.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/features/users/presentation/endpoint_screen.dart';
import 'package:nekotribe/shared/providers/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'login can switch the backend without carrying the password over',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(const Size(900, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = _FakeTokenStore();
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const LoginScreen()),
          GoRoute(
            path: '/settings/endpoint',
            builder: (_, _) => const EndpointScreen(),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tokenStoreProvider.overrideWithValue(store),
            appConfigBundleProvider.overrideWithValue(
              const AppConfigBundle(defaults: _testConfig, presets: []),
            ),
            appConfigInitialProvider.overrideWithValue(_testConfig),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.enterText(find.byType(TextField).at(0), 'demo');
      await tester.enterText(find.byType(TextField).at(1), 'fixture-password');
      await tester.tap(find.byTooltip('服务器端点'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        'http://127.0.0.1:30006',
      );
      await tester.tap(find.text('保存自定义'));
      await tester.pumpAndSettle();
      expect(
        (await AppConfigLoader.readOverride())?.apiBaseUrl,
        'http://127.0.0.1:30006',
      );
      expect(store.endpointRevision, 1);
      router.pop();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).at(0)).controller!.text,
        'demo',
      );
      expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        isEmpty,
      );
    },
  );

  testWidgets('login explains secure browser storage before showing fields', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(_UnavailableSessionStore()),
        ],
        child: const MaterialApp(home: LoginScreen()),
      ),
    );
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('请使用 HTTPS'), findsOneWidget);
  });

  test(
    'unsupported session storage blocks authentication before a request',
    () async {
      final store = _UnavailableSessionStore();
      final repository = AuthRepository(
        api: AuthApi(ApiClient(config: _testConfig, tokenStore: store)),
        tokenStore: store,
      );
      await expectLater(
        repository.login(account: 'demo', password: 'fixture'),
        throwsA(isA<SessionStorageUnavailable>()),
      );
      expect(store.revision, 0);
      expect(await store.read(), isNull);
    },
  );

  testWidgets('registration can submit its old code after a throttled resend', (
    tester,
  ) async {
    final auth = _FakeAuthRepository();
    await _prepareRegistration(tester, auth);
    await tester.pump(const Duration(seconds: 60));
    final send = find.widgetWithText(OutlinedButton, '获取验证码');
    await tester.ensureVisible(send);
    auth.otpResult = Completer<V2AuthOtpData>();
    await tester.tap(send);
    await tester.pump();
    auth.otpResult!.completeError(
      ApiException(
        code: 42901,
        message: 'Rate limited',
        statusCode: 429,
        retryAfterSeconds: 42,
      ),
    );
    await tester.pump();
    final cooldown = find.widgetWithText(OutlinedButton, '42 秒后重试');
    expect(tester.widget<OutlinedButton>(cooldown).onPressed, isNull);
    expect(auth.otpCalls, 2);
    final submit = find.widgetWithText(FilledButton, '注册');
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(auth.verifiedOtpVerificationId, 'otp-1');
    expect(auth.registerVerificationId, 'otp-1');
  });

  final accountRules =
      jsonDecode(
            File(
              'contracts/scenarios/auth-account-input.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  for (final c
      in (accountRules['emailCases'] as List)
          .cast<Map<String, dynamic>>()
          .where((c) => c['raw'] is String)) {
    for (final registration in [false, true]) {
      testWidgets(
        '${registration ? 'register' : 'reset'} validates email before OTP: ${c['id']}',
        (tester) async {
          final auth = _FakeAuthRepository();
          await _pumpAuthRoute(
            tester,
            auth,
            registration
                ? const RegisterScreen()
                : const ForgotPasswordScreen(),
            loginText: 'Login route',
          );
          await tester.enterText(
            find.byType(TextField).at(0),
            c['raw'] as String,
          );
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, '获取验证码'),
              )
              .onPressed!();
          await tester.pumpAndSettle();
          expect(
            auth.otpCalls,
            (c['widgetValid'] ?? c['valid']) == true ? 1 : 0,
          );
        },
      );
    }
  }
  for (final c
      in (accountRules['nameCases'] as List).cast<Map<String, dynamic>>().where(
        (c) => c['raw'] is String,
      )) {
    for (final index in [2, 3]) {
      testWidgets(
        'register name field $index before verification: ${c['id']}',
        (tester) async {
          final auth = _FakeAuthRepository();
          await _pumpAuthRoute(
            tester,
            auth,
            const RegisterScreen(),
            loginText: 'Login route',
          );
          await tester.enterText(
            find.byType(TextField).at(0),
            'edge@example.test',
          );
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, '获取验证码'),
              )
              .onPressed!();
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField).at(1), '123456');
          await tester.enterText(find.byType(TextField).at(2), 'edge');
          await tester.enterText(find.byType(TextField).at(3), 'Edge');
          await tester.enterText(
            find.byType(TextField).at(index),
            c['raw'] as String,
          );
          await tester.enterText(find.byType(TextField).at(4), 'synthetic');
          await tester.enterText(find.byType(TextField).at(5), 'synthetic');
          await tester.ensureVisible(find.text('我已阅读并同意服务条款'));
          await tester.tap(find.text('我已阅读并同意服务条款'));
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '注册'))
              .onPressed!();
          await tester.pumpAndSettle();
          expect(auth.verificationCalls, c['valid'] == true ? 1 : 0);
          expect(auth.registerCalls, c['valid'] == true ? 1 : 0);
        },
      );
    }
  }
  final passwordRules =
      jsonDecode(
            File(
              'contracts/scenarios/auth-password-input.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  for (final c
      in (passwordRules['cases'] as List).cast<Map<String, dynamic>>()) {
    for (final registration in [false, true]) {
      testWidgets(
        '${registration ? 'register' : 'reset'} canonical new password: ${c['id']}',
        (tester) async {
          final auth = _FakeAuthRepository();
          await _pumpAuthRoute(
            tester,
            auth,
            registration
                ? const RegisterScreen()
                : const ForgotPasswordScreen(),
            loginText: 'Login route',
          );
          await tester.enterText(
            find.byType(TextField).at(0),
            'edge@example.test',
          );
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, '获取验证码'),
              )
              .onPressed!();
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField).at(1), '123456');
          if (registration) {
            await tester.enterText(find.byType(TextField).at(2), 'edge');
            await tester.enterText(find.byType(TextField).at(3), 'Edge');
            await tester.ensureVisible(find.text('我已阅读并同意服务条款'));
            await tester.tap(find.text('我已阅读并同意服务条款'));
          }
          await tester.enterText(
            find.byType(TextField).at(registration ? 4 : 2),
            c['raw'] as String,
          );
          await tester.enterText(
            find.byType(TextField).at(registration ? 5 : 3),
            c['confirm'] as String,
          );
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, registration ? '注册' : '提交'),
              )
              .onPressed!();
          await tester.pumpAndSettle();
          final valid = c['validNewPassword'] == true && c['matches'] == true;
          expect(
            registration ? auth.registerCalls : auth.resetCalls,
            valid ? 1 : 0,
          );
          if (valid) {
            expect(
              registration ? auth.registeredPassword : auth.resetPassword,
              c['normalized'],
            );
            if (registration) {
              expect(auth.registeredConfirm, c['normalizedConfirm']);
            }
          } else {
            expect(auth.verificationCalls, 0);
          }
        },
      );
    }
  }
  for (final password in ['x', '  x  ', '   ']) {
    testWidgets(
      'login normalizes but preserves legacy short password: "$password"',
      (tester) async {
        final auth = _FakeAuthRepository();
        await _pumpAuthRoute(
          tester,
          auth,
          const LoginScreen(),
          loginText: 'Login route',
        );
        await tester.enterText(find.byType(TextField).at(0), ' edge ');
        await tester.enterText(find.byType(TextField).at(1), password);
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '登录'))
            .onPressed!();
        if (auth.loginCalls > 0) {
          auth.loginResult.completeError(StateError('isolated login failure'));
        }
        await tester.pumpAndSettle();
        expect(auth.loginCalls, password.trim().isEmpty ? 0 : 1);
        if (auth.loginCalls > 0) {
          expect(auth.loginPassword, password.trim());
          expect(auth.loginAccount, 'edge');
        }
      },
    );
  }
  testWidgets(
    'a stale reset completion receipt cannot navigate a newer session',
    (tester) async {
      final auth = _FakeAuthRepository()
        ..resetResult = Completer<void>()
        ..resetReceipt = const SessionClearReceipt(0);
      await _pumpAuthRoute(
        tester,
        auth,
        const ForgotPasswordScreen(),
        loginText: 'Login route',
      );
      await tester.enterText(find.byType(TextField).at(0), 'edge@example.test');
      await tester.tap(find.text('获取验证码'));
      await tester.pumpAndSettle();
      for (final entry in <int, String>{
        1: '123456',
        2: 'password',
        3: 'password',
      }.entries) {
        await tester.enterText(
          find.byType(TextField).at(entry.key),
          entry.value,
        );
      }
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '提交'))
          .onPressed!();
      auth.revisionOverride = 1;
      auth.resetResult!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Login route'), findsNothing);
      expect(find.byType(ForgotPasswordScreen), findsOneWidget);
    },
  );
  for (final registration in [true, false]) {
    testWidgets(
      '${registration ? 'register' : 'reset'} rejects a late OTP for another email and repeated send callbacks',
      (tester) async {
        final auth = _FakeAuthRepository()
          ..otpResult = Completer<V2AuthOtpData>();
        await _pumpAuthRoute(
          tester,
          auth,
          registration ? const RegisterScreen() : const ForgotPasswordScreen(),
          loginText: 'Login route',
        );
        await tester.enterText(
          find.byType(TextField).at(0),
          'old@example.test',
        );
        final send = tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, '获取验证码'),
            )
            .onPressed!;
        send();
        send();
        expect(auth.otpCalls, 1);
        await tester.enterText(
          find.byType(TextField).at(0),
          'new@example.test',
        );
        auth.otpResult!.complete(
          V2AuthOtpData(
            account: 'old@example.test',
            verificationId: 'old-otp',
            expiresAt: '2030-01-01T00:00:00Z',
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).at(1), '123456');
        if (registration) {
          await tester.enterText(find.byType(TextField).at(2), 'edge');
          await tester.enterText(find.byType(TextField).at(3), 'Edge');
          await tester.enterText(find.byType(TextField).at(4), 'password');
          await tester.enterText(find.byType(TextField).at(5), 'password');
          await tester.ensureVisible(find.text('我已阅读并同意服务条款'));
          await tester.tap(find.text('我已阅读并同意服务条款'));
        } else {
          await tester.enterText(find.byType(TextField).at(2), 'password');
          await tester.enterText(find.byType(TextField).at(3), 'password');
        }
        final submit = find.widgetWithText(
          FilledButton,
          registration ? '注册' : '提交',
        );
        await tester.ensureVisible(submit);
        await tester.tap(submit);
        await tester.pumpAndSettle();
        expect(auth.registerCalls, 0);
        expect(auth.resetCalls, 0);
      },
    );
  }
  testWidgets(
    'register snapshots form data and ignores duplicate submits while verifying',
    (tester) async {
      final auth = _FakeAuthRepository()
        ..verificationResult = Completer<V2AuthOtpVerificationData>();
      await _prepareRegistration(tester, auth);
      final submit = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '注册'))
          .onPressed!;
      submit();
      submit();
      expect(auth.verificationCalls, 1);
      await tester.enterText(find.byType(TextField).at(2), 'changed');
      auth.verificationResult!.complete(
        V2AuthOtpVerificationData(
          account: 'edge@example.test',
          verified: true,
          verifiedAt: '2030-01-01T00:00:00Z',
        ),
      );
      await tester.pumpAndSettle();
      expect(auth.registerCalls, 1);
      expect(auth.registerUsername, 'edge');
    },
  );
  testWidgets('register never proceeds after a false OTP result', (
    tester,
  ) async {
    final auth = _FakeAuthRepository()
      ..verificationResult = Completer<V2AuthOtpVerificationData>();
    await _prepareRegistration(tester, auth);
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '注册'))
        .onPressed!();
    auth.verificationResult!.complete(
      V2AuthOtpVerificationData(
        account: 'edge@example.test',
        verified: false,
        verifiedAt: '2030-01-01T00:00:00Z',
      ),
    );
    await tester.pumpAndSettle();
    expect(auth.registerCalls, 0);
  });
  testWidgets(
    'reset ignores duplicate callbacks and allows explicit retry after failure',
    (tester) async {
      final auth = _FakeAuthRepository()..resetResult = Completer<void>();
      await _pumpAuthRoute(
        tester,
        auth,
        const ForgotPasswordScreen(),
        loginText: 'Login route',
      );
      await tester.enterText(find.byType(TextField).at(0), 'edge@example.test');
      await tester.tap(find.text('获取验证码'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(1), '123456');
      await tester.enterText(find.byType(TextField).at(2), 'password');
      await tester.enterText(find.byType(TextField).at(3), 'password');
      final submit = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '提交'))
          .onPressed!;
      submit();
      submit();
      expect(auth.resetCalls, 1);
      auth.resetResult!.completeError(StateError('isolated failure'));
      await tester.pumpAndSettle();
      auth.resetResult = null;
      submit();
      await tester.pumpAndSettle();
      expect(auth.resetCalls, 2);
      expect(find.text('Login route'), findsOneWidget);
    },
  );
  testWidgets(
    'pending login ignores repeated keyboard submissions and permits retry',
    (tester) async {
      final auth = _FakeAuthRepository();
      await _pumpAuthRoute(tester, auth, const LoginScreen(), loginText: '');
      await tester.enterText(find.byType(TextField).at(0), 'edge');
      await tester.enterText(find.byType(TextField).at(1), 'password');
      final submit = tester
          .widget<TextField>(find.byType(TextField).at(1))
          .onSubmitted!;
      submit('password');
      submit('password');
      expect(auth.loginCalls, 1);
      auth.loginResult.completeError(StateError('test unavailable'));
      await tester.pumpAndSettle();
      auth.loginResult = Completer<V2LoginResult>();
      submit('password');
      expect(auth.loginCalls, 2);
      auth.loginResult.completeError(StateError('test unavailable'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'pending challenge ignores an earlier button callback and permits retry',
    (tester) async {
      final auth = _FakeAuthRepository();
      await _pumpAuthRoute(
        tester,
        auth,
        const TwoFactorScreen(challengeId: 'challenge', account: 'edge'),
        loginText: '',
      );
      await tester.enterText(find.byType(TextField), '123456');
      final submit = tester
          .widget<FilledButton>(find.byType(FilledButton))
          .onPressed!;
      submit();
      submit();
      expect(auth.challengeCalls, 1);
      auth.challengeResult.completeError(StateError('test unavailable'));
      await tester.pumpAndSettle();
      auth.challengeResult = Completer<V2LoginSuccess>();
      submit();
      expect(auth.challengeCalls, 2);
      auth.challengeResult.completeError(StateError('test unavailable'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('register layout fits mobile width without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final auth = _FakeAuthRepository();
    await _pumpAuthRoute(tester, auth, const RegisterScreen(), loginText: '');

    expect(tester.takeException(), isNull);
    expect(find.text('注册'), findsWidgets);
    expect(find.text('获取验证码'), findsOneWidget);
    final sendButton = tester.getRect(
      find.widgetWithText(OutlinedButton, '获取验证码'),
    );
    expect(sendButton.right, lessThanOrEqualTo(390));
    expect(sendButton.left, greaterThanOrEqualTo(0));
    expect(sendButton.width, greaterThanOrEqualTo(120));
  });

  testWidgets('login layout fits mobile width without clipping actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final auth = _FakeAuthRepository();
    await _pumpAuthRoute(tester, auth, const LoginScreen(), loginText: '');

    expect(tester.takeException(), isNull);
    final forgotButton = tester.getRect(find.text('忘记密码'));
    expect(forgotButton.right, lessThanOrEqualTo(390));
    expect(forgotButton.left, greaterThanOrEqualTo(0));
  });

  testWidgets('register verifies OTP and submits verification id', (
    tester,
  ) async {
    final auth = _FakeAuthRepository();

    await _pumpAuthRoute(
      tester,
      auth,
      const RegisterScreen(),
      loginText: 'Login route',
    );

    await tester.enterText(find.byType(TextField).at(0), 'edge@example.test');
    await tester.tap(find.text('获取验证码'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(1), '123456');
    await tester.enterText(find.byType(TextField).at(2), 'edge');
    await tester.enterText(find.byType(TextField).at(3), 'Edge');
    await tester.enterText(find.byType(TextField).at(4), 'password-1');
    await tester.enterText(find.byType(TextField).at(5), 'password-1');
    await tester.ensureVisible(find.text('我已阅读并同意服务条款'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我已阅读并同意服务条款'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilledButton, '注册'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '注册'));
    await tester.pumpAndSettle();

    expect(auth.requestedOtpPurpose, 'register');
    expect(auth.verifiedOtpVerificationId, 'otp-1');
    expect(auth.registerVerificationId, 'otp-1');
    expect(auth.registerAgreeToTerms, isTrue);
    expect(find.text('Login route'), findsOneWidget);
  });

  testWidgets('forgot password submits verification id and code', (
    tester,
  ) async {
    final auth = _FakeAuthRepository();

    await _pumpAuthRoute(
      tester,
      auth,
      const ForgotPasswordScreen(),
      loginText: 'Login route',
    );

    await tester.enterText(find.byType(TextField).at(0), 'edge@example.test');
    await tester.tap(find.text('获取验证码'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(1), '654321');
    await tester.enterText(find.byType(TextField).at(2), 'password-2');
    await tester.enterText(find.byType(TextField).at(3), 'password-2');
    await tester.tap(find.text('提交'));
    await tester.pumpAndSettle();

    expect(auth.requestedOtpPurpose, 'password_reset');
    expect(auth.resetVerificationId, 'otp-1');
    expect(auth.resetCode, '654321');
    expect(find.text('Login route'), findsOneWidget);
  });
}

Future<void> _pumpAuthRoute(
  WidgetTester tester,
  _FakeAuthRepository auth,
  Widget home, {
  required String loginText,
}) async {
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => home),
      GoRoute(path: '/auth/login', builder: (_, _) => Text(loginText)),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [authRepositoryProvider.overrideWithValue(auth)],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _prepareRegistration(
  WidgetTester tester,
  _FakeAuthRepository auth,
) async {
  await _pumpAuthRoute(
    tester,
    auth,
    const RegisterScreen(),
    loginText: 'Login route',
  );
  await tester.enterText(find.byType(TextField).at(0), 'edge@example.test');
  await tester.tap(find.text('获取验证码'));
  await tester.pumpAndSettle();
  for (final entry in <int, String>{
    1: '123456',
    2: 'edge',
    3: 'Edge',
    4: 'password',
    5: 'password',
  }.entries) {
    await tester.enterText(find.byType(TextField).at(entry.key), entry.value);
  }
  await tester.ensureVisible(find.text('我已阅读并同意服务条款'));
  await tester.tap(find.text('我已阅读并同意服务条款'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.widgetWithText(FilledButton, '注册'));
  await tester.pumpAndSettle();
}

class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository()
    : super(
        api: AuthApi(
          ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()),
        ),
        tokenStore: _FakeTokenStore(),
      );

  String? requestedOtpPurpose;
  String? verifiedOtpVerificationId;
  String? registerVerificationId;
  bool? registerAgreeToTerms;
  String? resetVerificationId;
  String? resetCode;
  int loginCalls = 0;
  int challengeCalls = 0;
  Completer<V2LoginResult> loginResult = Completer<V2LoginResult>();
  Completer<V2LoginSuccess> challengeResult = Completer<V2LoginSuccess>();
  Completer<V2AuthOtpData>? otpResult;
  Completer<V2AuthOtpVerificationData>? verificationResult;
  Completer<void>? resetResult;
  SessionClearReceipt? resetReceipt;
  int? revisionOverride;
  @override
  int get sessionRevision => revisionOverride ?? super.sessionRevision;
  int otpCalls = 0, verificationCalls = 0, registerCalls = 0, resetCalls = 0;
  String? registerUsername;
  String? registeredPassword,
      registeredConfirm,
      resetPassword,
      loginPassword,
      loginAccount;

  @override
  Future<V2LoginResult> login({
    required String account,
    required String password,
    bool rememberMe = false,
  }) {
    loginCalls++;
    loginAccount = account;
    loginPassword = password;
    return loginResult.future;
  }

  @override
  Future<V2LoginSuccess> completeTwoFactor({
    required String challengeId,
    required String code,
  }) {
    challengeCalls++;
    return challengeResult.future;
  }

  @override
  Future<V2AuthOtpData> requestOtp({
    required String account,
    required String purpose,
  }) async {
    otpCalls++;
    requestedOtpPurpose = purpose;
    if (otpResult != null) return otpResult!.future;
    return V2AuthOtpData(
      account: account,
      verificationId: 'otp-1',
      expiresAt: '2026-05-24T00:05:00.000Z',
    );
  }

  @override
  Future<V2AuthOtpVerificationData> verifyOtp({
    required String account,
    required String purpose,
    required String verificationId,
    required String code,
  }) async {
    verificationCalls++;
    verifiedOtpVerificationId = verificationId;
    if (verificationResult != null) return verificationResult!.future;
    return V2AuthOtpVerificationData(
      account: account,
      verified: true,
      verifiedAt: '2026-05-24T00:00:00.000Z',
    );
  }

  @override
  Future<V2SelfUser> register({
    required String email,
    required String username,
    required String displayName,
    required String password,
    required String confirmPassword,
    required String verificationId,
    required bool agreeToTerms,
  }) async {
    registerCalls++;
    registerUsername = username;
    registeredPassword = password;
    registeredConfirm = confirmPassword;
    registerVerificationId = verificationId;
    registerAgreeToTerms = agreeToTerms;
    return _testUser(
      email: email,
      username: username,
      displayName: displayName,
    );
  }

  @override
  Future<SessionClearReceipt> requestPasswordReset({
    required String email,
    required String verificationId,
    required String code,
    required String newPassword,
  }) async {
    resetCalls++;
    resetPassword = newPassword;
    resetVerificationId = verificationId;
    resetCode = code;
    if (resetResult != null) await resetResult!.future;
    return resetReceipt ?? SessionClearReceipt(sessionRevision);
  }
}

V2SelfUser _testUser({
  required String email,
  required String username,
  required String displayName,
}) {
  return V2SelfUser(
    userId: 1,
    username: username,
    displayName: displayName,
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
    email: email,
    phone: '',
    birthDate: null,
    emailVerifiedAt: '2026-05-24T00:00:00.000Z',
    isActive: 1,
    status: 'active',
    createdAt: '2026-05-24T00:00:00.000Z',
    updatedAt: '2026-05-24T00:00:00.000Z',
  );
}

const _testConfig = AppConfig(
  apiBaseUrl: 'http://example.test',
  wsBaseUrl: 'ws://example.test',
  storageBaseUrl: 'http://example.test',
);

class _UnavailableSessionStore extends TokenStore {
  @override
  bool get supportsSessionStorage => false;
}

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
