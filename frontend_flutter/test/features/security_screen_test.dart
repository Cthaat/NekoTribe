import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/auth/token_store.dart';
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
}

Future<void> _pumpSecurity(
  WidgetTester tester,
  _FakeUsersRepository users,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [usersRepositoryProvider.overrideWithValue(users)],
      child: const MaterialApp(home: SecurityScreen()),
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
