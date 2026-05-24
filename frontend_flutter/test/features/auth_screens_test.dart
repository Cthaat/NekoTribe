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
import 'package:nekotribe/features/auth/presentation/forgot_password_screen.dart';
import 'package:nekotribe/features/auth/presentation/register_screen.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
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

  @override
  Future<V2AuthOtpData> requestOtp({
    required String account,
    required String purpose,
  }) async {
    requestedOtpPurpose = purpose;
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
    verifiedOtpVerificationId = verificationId;
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
    registerVerificationId = verificationId;
    registerAgreeToTerms = agreeToTerms;
    return _testUser(
      email: email,
      username: username,
      displayName: displayName,
    );
  }

  @override
  Future<void> requestPasswordReset({
    required String email,
    required String verificationId,
    required String code,
    required String newPassword,
  }) async {
    resetVerificationId = verificationId;
    resetCode = code;
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
