import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/features/auth/data/auth_api.dart';
import 'package:nekotribe/features/auth/data/auth_repository.dart';
import 'package:nekotribe/features/auth/domain/auth_models.dart';
import 'package:nekotribe/features/users/data/users_api.dart';
import 'package:nekotribe/features/users/data/users_repository.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/features/users/presentation/security_screen.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  testWidgets('security screen starts and confirms two-factor setup', (
    tester,
  ) async {
    final users = _FakeUsersRepository(twoFactorEnabled: false);

    await _pumpSecurity(tester, users);

    expect(find.text('未启用，开启前需要验证当前密码。'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), 'current-password');
    await tester.tap(find.text('开始设置'));
    await tester.pumpAndSettle();

    expect(users.setupPassword, 'current-password');
    expect(find.text('TOTPSECRET'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(1), '123456');
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    expect(users.confirmCode, '123456');
    expect(find.text('ABCD-EFGH'), findsOneWidget);
  });

  testWidgets('security screen disables two-factor with code', (tester) async {
    final users = _FakeUsersRepository(twoFactorEnabled: true);

    await _pumpSecurity(tester, users);

    expect(find.text('已启用，需要验证码或恢复码才能关闭。'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), 'current-password');
    await tester.enterText(find.byType(TextField).at(1), '654321');
    await tester.tap(find.text('关闭两步验证'));
    await tester.pumpAndSettle();

    expect(users.disablePassword, 'current-password');
    expect(users.disableCode, '654321');
    expect(find.text('未启用，开启前需要验证当前密码。'), findsOneWidget);
  });

  testWidgets('security screen changes email with OTP verification id', (
    tester,
  ) async {
    final users = _FakeUsersRepository(twoFactorEnabled: false);
    final auth = _FakeAuthRepository();

    await _pumpSecurity(tester, users, auth: auth);

    await tester.ensureVisible(find.byKey(const Key('security-email-field')));
    await tester.enterText(
      find.byKey(const Key('security-email-field')),
      'next@example.test',
    );
    await tester.tap(find.text('获取验证码'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('security-email-code')),
      '246810',
    );
    await tester.tap(find.widgetWithText(FilledButton, '修改邮箱'));
    await tester.pumpAndSettle();

    expect(auth.requestedOtpAccount, 'next@example.test');
    expect(auth.requestedOtpPurpose, 'change_email');
    expect(users.changedEmail, 'next@example.test');
    expect(users.changedEmailVerificationId, 'otp-1');
    expect(users.changedEmailCode, '246810');
  });

  testWidgets('security screen deletes account and returns to login', (
    tester,
  ) async {
    final users = _FakeUsersRepository(twoFactorEnabled: false);
    final auth = _FakeAuthRepository();

    await _pumpSecurity(tester, users, auth: auth, loginText: 'Login route');

    await tester.scrollUntilVisible(
      find.byKey(const Key('security-delete-password')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(
      find.byKey(const Key('security-delete-password')),
      'current-password',
    );
    await tester.enterText(
      find.byKey(const Key('security-delete-confirmation')),
      'DELETE',
    );
    await tester.tap(find.widgetWithText(FilledButton, '删除账号'));
    await tester.pumpAndSettle();

    expect(users.deletePassword, 'current-password');
    expect(users.deleteConfirmation, 'DELETE');
    expect(auth.logoutCalled, isTrue);
    expect(find.text('Login route'), findsOneWidget);
  });
}

Future<void> _pumpSecurity(
  WidgetTester tester,
  _FakeUsersRepository users, {
  _FakeAuthRepository? auth,
  String loginText = 'Login route',
}) async {
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const SecurityScreen()),
      GoRoute(path: '/auth/login', builder: (_, _) => Text(loginText)),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        usersRepositoryProvider.overrideWithValue(users),
        if (auth != null) authRepositoryProvider.overrideWithValue(auth),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

class _FakeUsersRepository extends UsersRepository {
  _FakeUsersRepository({required this.twoFactorEnabled})
    : super(
        UsersApi(ApiClient(config: _testConfig, tokenStore: _FakeTokenStore())),
      );

  bool twoFactorEnabled;
  String? setupPassword;
  String? confirmCode;
  String? disablePassword;
  String? disableCode;
  String? changedEmail;
  String? changedEmailVerificationId;
  String? changedEmailCode;
  String? deletePassword;
  String? deleteConfirmation;

  @override
  Future<V2UserSettings> getSettings() async => _settings(twoFactorEnabled);

  @override
  Future<Map<String, dynamic>> setupTwoFactor({
    required String password,
  }) async {
    setupPassword = password;
    return {
      'secret': 'TOTPSECRET',
      'otpauth_url': 'otpauth://totp/NekoTribe:edge',
    };
  }

  @override
  Future<Map<String, dynamic>> confirmTwoFactor({required String code}) async {
    confirmCode = code;
    twoFactorEnabled = true;
    return {
      'enabled': true,
      'recovery_codes': ['ABCD-EFGH'],
    };
  }

  @override
  Future<Map<String, dynamic>> disableTwoFactor({
    required String password,
    required String code,
  }) async {
    disablePassword = password;
    disableCode = code;
    twoFactorEnabled = false;
    return {'enabled': false};
  }

  @override
  Future<void> changeEmail({
    required String newEmail,
    required String verificationId,
    required String code,
  }) async {
    changedEmail = newEmail;
    changedEmailVerificationId = verificationId;
    changedEmailCode = code;
  }

  @override
  Future<Map<String, dynamic>> deleteAccount({
    required String password,
    required String confirmation,
  }) async {
    deletePassword = password;
    deleteConfirmation = confirmation;
    return {'deleted': true, 'user_id': 1};
  }
}

class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository()
    : super(
        api: AuthApi(
          ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()),
        ),
        tokenStore: _FakeTokenStore(),
      );

  String? requestedOtpAccount;
  String? requestedOtpPurpose;
  bool logoutCalled = false;

  @override
  Future<V2AuthOtpData> requestOtp({
    required String account,
    required String purpose,
  }) async {
    requestedOtpAccount = account;
    requestedOtpPurpose = purpose;
    return V2AuthOtpData(
      account: account,
      verificationId: 'otp-1',
      expiresAt: '2026-05-24T00:05:00.000Z',
    );
  }

  @override
  Future<void> logout() async {
    logoutCalled = true;
  }
}

V2UserSettings _settings(bool twoFactorEnabled) {
  return V2UserSettings(
    userId: 1,
    twoFactorEnabled: twoFactorEnabled,
    loginAlerts: true,
    profileVisibility: 'public',
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
