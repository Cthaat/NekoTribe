import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:nekotribe/features/users/domain/security_action.dart';
import 'package:nekotribe/features/users/presentation/security_screen.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  testWidgets(
    'status reload blocks retained recovery-code copy callbacks before and after repaint',
    (tester) async {
      final users = _FakeUsersRepository(twoFactorEnabled: false),
          auth = _FakeAuthRepository();
      int writes = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') writes++;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await _pumpSecurity(tester, users, auth: auth);
      await tester.enterText(find.byType(TextField).at(0), 'x');
      await tester.tap(find.text('开始设置'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(1), '123456');
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      final copy = tester
          .widget<OutlinedButton>(
            find.widgetWithIcon(OutlinedButton, Icons.copy_all_outlined),
          )
          .onPressed!;
      users.pendingStatus = Completer<V2UserSettings>();
      tester
          .widget<IconButton>(find.byKey(const Key('security-reload-status')))
          .onPressed!();
      copy();
      await tester.pump();
      users.pendingStatus!.complete(_settings(true));
      await tester.pumpAndSettle();
      copy();
      await tester.pump();
      expect(writes, 0);
    },
  );
  testWidgets(
    'failed status remains unknown and retry is explicit without enabling two-factor actions',
    (tester) async {
      final users = _FakeUsersRepository(twoFactorEnabled: false)
        ..statusFailure = true;
      await _pumpSecurity(tester, users);
      expect(find.text('开始设置'), findsNothing);
      expect(find.text('未启用，开启前需要验证当前密码。'), findsNothing);
      expect(find.byKey(const Key('security-reload-status')), findsOneWidget);
      users.statusFailure = false;
      users.pendingStatus = Completer<V2UserSettings>();
      final reload = tester
          .widget<IconButton>(find.byKey(const Key('security-reload-status')))
          .onPressed!;
      reload();
      reload();
      await tester.pump();
      expect(users.statusReads, 2);
      users.pendingStatus!.complete(_settings(false));
      await tester.pumpAndSettle();
      expect(users.statusReads, 2);
      expect(find.text('开始设置'), findsOneWidget);
    },
  );
  testWidgets(
    'pending identity blocks reopening and old callbacks before the old frame unmounts',
    (tester) async {
      final users = _FakeUsersRepository(twoFactorEnabled: false),
          auth = _FakeAuthRepository();
      await _pumpSecurity(tester, users, auth: auth);
      await tester.enterText(find.byType(TextField).at(0), 'x');
      final oldStart = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '开始设置'))
          .onPressed!;
      final gate = Completer<void>(),
          pending = auth._testStore.runSessionChange((_) => gate.future);
      oldStart();
      await tester.pump();
      expect(users.setupPassword, isNull);
      final reopen = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '重新打开安全设置'),
      );
      expect(reopen.onPressed, isNull);
      expect(find.byType(TextField), findsNothing);
      gate.complete();
      await pending;
      await tester.pumpAndSettle();
      await tester.tap(find.text('重新打开安全设置'));
      await tester.pumpAndSettle();
      expect(users.statusReads, 2);
      expect(find.byType(TextField), findsWidgets);
    },
  );

  testWidgets(
    'a response from the disposed owner cannot release a new setup or publish its secret',
    (tester) async {
      final old = Completer<Map<String, dynamic>>(),
          current = Completer<Map<String, dynamic>>();
      final users = _FakeUsersRepository(twoFactorEnabled: false)
        ..pendingSetup = old;
      final auth = _FakeAuthRepository();
      await _pumpSecurity(tester, users, auth: auth);
      await tester.enterText(find.byType(TextField).at(0), 'x');
      await tester.tap(find.text('开始设置'));
      await tester.pump();
      auth.revision++;
      await tester.pumpAndSettle();
      await tester.tap(find.text('重新打开安全设置'));
      await tester.pumpAndSettle();
      users.pendingSetup = current;
      await tester.enterText(find.byType(TextField).at(0), 'x');
      await tester.tap(find.text('开始设置'));
      await tester.pump();
      old.complete(_factorSetupJson);
      await tester.pump();
      expect(find.text(_testFactorSecret), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '开始设置'))
            .onPressed,
        isNull,
      );
      current.complete(_factorSetupJson);
      await tester.pumpAndSettle();
      expect(find.text(_testFactorSecret), findsOneWidget);
    },
  );

  testWidgets(
    'repository replacement expires the owner and unsubscribes from the previous repository',
    (tester) async {
      final users = _FakeUsersRepository(twoFactorEnabled: false),
          old = _FakeAuthRepository(),
          current = _FakeAuthRepository();
      await _pumpSecurity(tester, users, auth: old);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SecurityScreen)),
      );
      container.updateOverrides([
        usersRepositoryProvider.overrideWithValue(users),
        authRepositoryProvider.overrideWithValue(current),
      ]);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('重新打开安全设置'));
      await tester.pumpAndSettle();
      old.revision++;
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsWidgets);
    },
  );

  for (final stale in [false, true]) {
    testWidgets(
      'parent routes a ${stale ? 'stale' : 'current'} deletion receipt after the child has unmounted',
      (tester) async {
        final users = _FakeUsersRepository(twoFactorEnabled: false),
            auth = _FakeAuthRepository()..pendingClear = Completer<void>();
        await _pumpSecurity(
          tester,
          users,
          auth: auth,
          loginText: 'Receipt login',
        );
        await tester.scrollUntilVisible(
          find.byKey(const Key('security-delete-password')),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.enterText(
          find.byKey(const Key('security-delete-password')),
          'x',
        );
        await tester.enterText(
          find.byKey(const Key('security-delete-confirmation')),
          'DELETE',
        );
        await tester.tap(find.widgetWithText(FilledButton, '删除账号'));
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsNothing);
        if (stale) auth.revision++;
        auth.pendingClear!.complete();
        await tester.pumpAndSettle();
        expect(
          find.text('Receipt login'),
          stale ? findsNothing : findsOneWidget,
        );
      },
    );
  }
  testWidgets(
    'a retained recovery-code copy callback cannot write the clipboard after identity change',
    (tester) async {
      final users = _FakeUsersRepository(twoFactorEnabled: false),
          auth = _FakeAuthRepository();
      int writes = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') writes++;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await _pumpSecurity(tester, users, auth: auth);
      await tester.enterText(find.byType(TextField).at(0), 'x');
      await tester.tap(find.text('开始设置'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(1), '123456');
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      final copy = tester
          .widget<OutlinedButton>(
            find.widgetWithIcon(OutlinedButton, Icons.copy_all_outlined),
          )
          .onPressed!;
      auth.revision++;
      copy();
      await tester.pumpAndSettle();
      copy();
      await tester.pump();
      expect(writes, 0);
    },
  );
  testWidgets(
    'identity change hides an already displayed secret and reopening starts with empty forms',
    (tester) async {
      final users = _FakeUsersRepository(twoFactorEnabled: false),
          auth = _FakeAuthRepository();
      await _pumpSecurity(tester, users, auth: auth);
      await tester.enterText(find.byType(TextField).at(0), 'current-password');
      await tester.tap(find.text('开始设置'));
      await tester.pumpAndSettle();
      expect(find.text(_testFactorSecret), findsOneWidget);
      auth.revision++;
      await tester.pumpAndSettle();
      expect(find.text(_testFactorSecret), findsNothing);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('重新打开安全设置'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsWidgets);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        isEmpty,
      );
      expect(find.text(_testFactorSecret), findsNothing);
    },
  );

  testWidgets('identity change removes already delivered recovery codes', (
    tester,
  ) async {
    final users = _FakeUsersRepository(twoFactorEnabled: false),
        auth = _FakeAuthRepository();
    await _pumpSecurity(tester, users, auth: auth);
    await tester.enterText(find.byType(TextField).at(0), 'current-password');
    await tester.tap(find.text('开始设置'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), '123456');
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(find.textContaining('ABCDE-FGHIJ-KLMNO'), findsWidgets);
    auth.revision++;
    await tester.pumpAndSettle();
    expect(find.textContaining('ABCDE-FGHIJ-KLMNO'), findsNothing);
    expect(find.text('重新打开安全设置'), findsOneWidget);
  });
  testWidgets('unknown two-factor status fits a 320px viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpSecurity(
      tester,
      _FakeUsersRepository(twoFactorEnabled: false)..statusFailure = true,
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('security-reload-status')), findsOneWidget);
    expect(find.text('开始设置'), findsNothing);
  });
  for (final deletion in [false, true]) {
    testWidgets(
      'security stale ${deletion ? 'deletion' : 'setup'} cannot affect another session',
      (tester) async {
        final users = _FakeUsersRepository(twoFactorEnabled: false),
            auth = _FakeAuthRepository();
        final reply = Completer<Map<String, dynamic>>();
        if (deletion) {
          users.pendingDeletion = reply;
        } else {
          users.pendingSetup = reply;
        }
        await _pumpSecurity(tester, users, auth: auth);
        if (deletion) {
          await tester.scrollUntilVisible(
            find.byKey(const Key('security-delete-password')),
            300,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.enterText(
            find.byKey(const Key('security-delete-password')),
            ' x ',
          );
          await tester.enterText(
            find.byKey(const Key('security-delete-confirmation')),
            ' DELETE ',
          );
          await tester.tap(find.widgetWithText(FilledButton, '删除账号'));
        } else {
          await tester.enterText(find.byType(TextField).at(0), ' x ');
          await tester.tap(find.text('开始设置'));
        }
        await tester.pump();
        auth.revision++;
        reply.complete(
          deletion ? {'deleted': true, 'user_id': 1} : _factorSetupJson,
        );
        await tester.pumpAndSettle();
        expect(auth.logoutCalled, isFalse);
        expect(auth.credentialCleared, isFalse);
        expect(find.text(_testFactorSecret), findsNothing);
        expect(find.text('账号已删除'), findsNothing);
      },
    );
  }
  final rules =
      jsonDecode(
            File(
              'contracts/scenarios/auth-account-input.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  for (final c
      in (rules['emailCases'] as List).cast<Map<String, dynamic>>().where(
        (c) => c['raw'] is String,
      )) {
    testWidgets(
      'security validates canonical new email before OTP: ${c['id']}',
      (tester) async {
        final users = _FakeUsersRepository(twoFactorEnabled: false),
            auth = _FakeAuthRepository();
        await _pumpSecurity(tester, users, auth: auth);
        await tester.enterText(
          find.byKey(const Key('security-email-field')),
          c['raw'] as String,
        );
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, '获取验证码'),
            )
            .onPressed!();
        await tester.pumpAndSettle();
        expect(
          auth.otpRequests,
          (c['widgetValid'] ?? c['valid']) == true ? 1 : 0,
        );
        if ((c['widgetValid'] ?? c['valid']) == true) {
          expect(
            auth.requestedOtpAccount,
            c['widgetNormalized'] ?? c['normalized'],
          );
        }
      },
    );
  }
  testWidgets('OTP completion after dispose has no page effects', (
    tester,
  ) async {
    final users = _FakeUsersRepository(twoFactorEnabled: false);
    final auth = _FakeAuthRepository()..pendingOtp = Completer<V2AuthOtpData>();
    await _pumpSecurity(tester, users, auth: auth);
    await tester.enterText(
      find.byKey(const Key('security-email-field')),
      'next@example.test',
    );
    tester
        .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '获取验证码'))
        .onPressed!();
    await tester.pumpWidget(const SizedBox.shrink());
    auth.pendingOtp!.complete(
      V2AuthOtpData(
        account: 'next@example.test',
        verificationId: 'late-otp',
        expiresAt: '2026-05-24T00:05:00Z',
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(users.changedEmail, isNull);
    expect(auth.logoutCalled, isFalse);
  });

  testWidgets('wrong-account OTP response cannot authorize email change', (
    tester,
  ) async {
    final users = _FakeUsersRepository(twoFactorEnabled: false);
    final auth = _FakeAuthRepository()..pendingOtp = Completer<V2AuthOtpData>();
    await _pumpSecurity(tester, users, auth: auth);
    await tester.enterText(
      find.byKey(const Key('security-email-field')),
      'next@example.test',
    );
    tester
        .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '获取验证码'))
        .onPressed!();
    auth.pendingOtp!.complete(
      V2AuthOtpData(
        account: 'wrong@example.test',
        verificationId: 'wrong-otp',
        expiresAt: '2026-05-24T00:05:00Z',
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('security-email-code')),
      '123456',
    );
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '修改邮箱'))
        .onPressed!();
    await tester.pumpAndSettle();
    expect(users.changedEmail, isNull);
    expect(auth.logoutCalled, isFalse);
  });

  testWidgets('failed email change keeps the session and releases submission', (
    tester,
  ) async {
    final users = _FakeUsersRepository(twoFactorEnabled: false)
      ..pendingChange = Completer<void>();
    final auth = _FakeAuthRepository();
    await _pumpSecurity(tester, users, auth: auth);
    await tester.enterText(
      find.byKey(const Key('security-email-field')),
      'next@example.test',
    );
    tester
        .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '获取验证码'))
        .onPressed!();
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('security-email-code')),
      '123456',
    );
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '修改邮箱'))
        .onPressed!();
    users.pendingChange!.completeError(StateError('isolated change failure'));
    await tester.pumpAndSettle();
    expect(auth.logoutCalled, isFalse);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '修改邮箱'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('email OTP ignores repeated callbacks and releases failed send', (
    tester,
  ) async {
    final users = _FakeUsersRepository(twoFactorEnabled: false);
    final auth = _FakeAuthRepository()..pendingOtp = Completer<V2AuthOtpData>();
    await _pumpSecurity(tester, users, auth: auth);
    await tester.enterText(
      find.byKey(const Key('security-email-field')),
      'next@example.test',
    );
    final send = tester
        .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '获取验证码'))
        .onPressed!;
    send();
    send();
    auth.pendingOtp!.completeError(StateError('isolated send failure'));
    await tester.pumpAndSettle();
    expect(auth.otpRequests, 1);
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '获取验证码'))
          .onPressed,
      isNotNull,
    );
    auth.pendingOtp = null;
    tester
        .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '获取验证码'))
        .onPressed!();
    await tester.pumpAndSettle();
    expect(auth.otpRequests, 2);
  });

  for (final changeSession in [false, true]) {
    testWidgets(
      'email OTP rejects a previous ${changeSession ? 'session' : 'account ABA'} verification',
      (tester) async {
        final users = _FakeUsersRepository(twoFactorEnabled: false);
        final auth = _FakeAuthRepository();
        await _pumpSecurity(tester, users, auth: auth);
        await tester.enterText(
          find.byKey(const Key('security-email-field')),
          'next@example.test',
        );
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, '获取验证码'),
            )
            .onPressed!();
        await tester.pumpAndSettle();
        if (changeSession) {
          auth.revision++;
          await tester.pumpAndSettle();
          expect(find.byType(TextField), findsNothing);
          await tester.tap(find.text('重新打开安全设置'));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const Key('security-email-field')),
            'next@example.test',
          );
        } else {
          await tester.enterText(
            find.byKey(const Key('security-email-field')),
            'other@example.test',
          );
          await tester.enterText(
            find.byKey(const Key('security-email-field')),
            'next@example.test',
          );
        }
        await tester.enterText(
          find.byKey(const Key('security-email-code')),
          '123456',
        );
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '修改邮箱'))
            .onPressed!();
        await tester.pumpAndSettle();
        expect(users.changedEmail, isNull);
        expect(auth.logoutCalled, isFalse);
      },
    );
  }

  testWidgets(
    'late old-account send cannot unblock or replace the newer request',
    (tester) async {
      final users = _FakeUsersRepository(twoFactorEnabled: false);
      final old = Completer<V2AuthOtpData>(),
          current = Completer<V2AuthOtpData>();
      final auth = _FakeAuthRepository()..pendingOtp = old;
      await _pumpSecurity(tester, users, auth: auth);
      await tester.enterText(
        find.byKey(const Key('security-email-field')),
        'old@example.test',
      );
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '获取验证码'))
          .onPressed!();
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('security-email-field')),
        'next@example.test',
      );
      auth.pendingOtp = current;
      await tester.pump();
      final send = tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '获取验证码'))
          .onPressed;
      expect(send, isNotNull);
      send!();
      await tester.pump();
      old.complete(
        V2AuthOtpData(
          account: 'old@example.test',
          verificationId: 'old-otp',
          expiresAt: '2026-05-24T00:05:00Z',
        ),
      );
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, '获取验证码'),
            )
            .onPressed,
        isNull,
      );
      current.complete(
        V2AuthOtpData(
          account: 'next@example.test',
          verificationId: 'new-otp',
          expiresAt: '2026-05-24T00:05:00Z',
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('security-email-code')),
        '123456',
      );
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '修改邮箱'))
          .onPressed!();
      await tester.pumpAndSettle();
      expect(users.changedEmailVerificationId, 'new-otp');
    },
  );

  testWidgets(
    'a late send after session change cannot authorize an email mutation',
    (tester) async {
      final users = _FakeUsersRepository(twoFactorEnabled: false);
      final auth = _FakeAuthRepository()
        ..pendingOtp = Completer<V2AuthOtpData>();
      await _pumpSecurity(tester, users, auth: auth);
      await tester.enterText(
        find.byKey(const Key('security-email-field')),
        'next@example.test',
      );
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '获取验证码'))
          .onPressed!();
      auth.revision++;
      auth.pendingOtp!.complete(
        V2AuthOtpData(
          account: 'next@example.test',
          verificationId: 'late-otp',
          expiresAt: '2026-05-24T00:05:00Z',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('重新打开安全设置'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('security-email-field')),
        'next@example.test',
      );
      await tester.enterText(
        find.byKey(const Key('security-email-code')),
        '123456',
      );
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '修改邮箱'))
          .onPressed!();
      await tester.pumpAndSettle();
      expect(users.changedEmail, isNull);
      expect(auth.logoutCalled, isFalse);
    },
  );

  testWidgets(
    'editing email while its mutation is pending suppresses late logout',
    (tester) async {
      final users = _FakeUsersRepository(twoFactorEnabled: false)
        ..pendingChange = Completer<void>();
      final auth = _FakeAuthRepository();
      await _pumpSecurity(tester, users, auth: auth);
      await tester.enterText(
        find.byKey(const Key('security-email-field')),
        'next@example.test',
      );
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '获取验证码'))
          .onPressed!();
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('security-email-code')),
        '123456',
      );
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '修改邮箱'))
          .onPressed!();
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('security-email-field')),
        'other@example.test',
      );
      users.pendingChange!.complete();
      await tester.pumpAndSettle();
      expect(auth.logoutCalled, isFalse);
    },
  );

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
    expect(find.text(_testFactorSecret), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(1), '123456');
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    expect(users.confirmCode, '123456');
    expect(find.textContaining('ABCDE-FGHIJ-KLMNO'), findsWidgets);
  });

  testWidgets(
    'regeneration clears the old setup even when the new response is malformed',
    (tester) async {
      final users = _FakeUsersRepository(twoFactorEnabled: false),
          auth = _FakeAuthRepository();
      await _pumpSecurity(tester, users, auth: auth);
      await tester.enterText(find.byType(TextField).at(0), 'current-password');
      await tester.tap(find.text('开始设置'));
      await tester.pumpAndSettle();
      expect(find.text(_testFactorSecret), findsOneWidget);
      final reply = Completer<Map<String, dynamic>>();
      users.pendingSetup = reply;
      await tester.tap(find.text('开始设置'));
      await tester.pump();
      final previousSecretStillVisible = find
          .text(_testFactorSecret)
          .evaluate()
          .isNotEmpty;
      reply.complete({
        'secret': 'MALFORMED-PRIVATE',
        'otpauth_url': 'https://bad.test',
      });
      await tester.pumpAndSettle();
      expect(previousSecretStillVisible, isFalse);
      expect(find.text(_testFactorSecret), findsNothing);
      expect(find.textContaining('MALFORMED-PRIVATE'), findsNothing);
      expect(auth.credentialCleared, isFalse);
    },
  );

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
    expect(auth.credentialCleared, isTrue);
    expect(auth.logoutCalled, isFalse);
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
        authRepositoryProvider.overrideWithValue(auth ?? _FakeAuthRepository()),
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
  Completer<void>? pendingChange;
  int statusReads = 0;
  bool statusFailure = false;
  Completer<V2UserSettings>? pendingStatus;
  Completer<Map<String, dynamic>>? pendingSetup, pendingDeletion;

  @override
  Future<V2UserSettings> getSettings() async {
    statusReads++;
    if (statusFailure) {
      throw const FormatException('Invalid account settings response');
    }
    if (pendingStatus != null) return pendingStatus!.future;
    return _settings(twoFactorEnabled);
  }

  @override
  Future<V2TwoFactorSetupData> setupTwoFactor({
    required String password,
  }) async {
    setupPassword = password;
    return V2TwoFactorSetupData.fromJson(
      pendingSetup != null ? await pendingSetup!.future : _factorSetupJson,
    );
  }

  @override
  Future<V2TwoFactorConfirmData> confirmTwoFactor({
    required String code,
  }) async {
    confirmCode = code;
    twoFactorEnabled = true;
    return V2TwoFactorConfirmData.fromJson({
      'enabled': true,
      'recovery_codes': List.filled(10, 'ABCDE-FGHIJ-KLMNO'),
    });
  }

  @override
  Future<V2TwoFactorDisabledData> disableTwoFactor({
    required String password,
    required String code,
  }) async {
    disablePassword = password;
    disableCode = code;
    twoFactorEnabled = false;
    return V2TwoFactorDisabledData.fromJson({'enabled': false});
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
    await pendingChange?.future;
  }

  @override
  Future<V2AccountDeletionData> deleteAccount({
    required String password,
    required String confirmation,
  }) async {
    deletePassword = password;
    deleteConfirmation = confirmation;
    return V2AccountDeletionData.fromJson(
      pendingDeletion != null
          ? await pendingDeletion!.future
          : {'deleted': true, 'user_id': 1},
    );
  }
}

const _testFactorSecret = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
const _factorSetupJson = {
  'secret': _testFactorSecret,
  'otpauth_url':
      'otpauth://totp/NekoTribe:edge?secret=$_testFactorSecret&issuer=NekoTribe&algorithm=SHA1&digits=6&period=30',
};

class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository() : this._(_FakeTokenStore());
  _FakeAuthRepository._(TokenStore store)
    : _testStore = store,
      super(
        api: AuthApi(
          ApiClient(config: _testConfig, tokenStore: _FakeTokenStore()),
        ),
        tokenStore: store,
      );

  final TokenStore _testStore;

  String? requestedOtpAccount;
  String? requestedOtpPurpose;
  bool logoutCalled = false;
  bool credentialCleared = false;
  int get revision => _testStore.revision;
  set revision(int value) {
    assert(value == revision + 1);
    _testStore.beginSessionChange();
  }

  int otpRequests = 0;
  Completer<void>? pendingClear;
  @override
  Future<SessionClearReceipt?> clearAfterCredentialMutation(
    int expectedRevision,
  ) async {
    if (revision != expectedRevision) return null;
    credentialCleared = true;
    final clearedRevision = ++revision;
    await pendingClear?.future;
    return SessionClearReceipt(clearedRevision);
  }

  Completer<V2AuthOtpData>? pendingOtp;

  @override
  int get sessionRevision => revision;

  @override
  Future<V2AuthOtpData> requestOtp({
    required String account,
    required String purpose,
  }) async {
    requestedOtpAccount = account;
    requestedOtpPurpose = purpose;
    otpRequests++;
    if (pendingOtp != null) return pendingOtp!.future;
    return V2AuthOtpData(
      account: account,
      verificationId: 'otp-1',
      expiresAt: '2026-05-24T00:05:00.000Z',
    );
  }

  @override
  Future<SessionClearReceipt?> logout() async {
    logoutCalled = true;
    return SessionClearReceipt(sessionRevision);
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
