import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/utils/auth_input.dart';

void main() {
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
    test(
      'canonical email rule without widget filtering: ${c['id']}',
      () => expect(validNewEmail(c['raw'] as String), c['valid']),
    );
  }
  for (final c
      in (accountRules['nameCases'] as List).cast<Map<String, dynamic>>().where(
        (c) => c['raw'] is String,
      )) {
    test(
      'canonical name rule: ${c['id']}',
      () => expect(validRegistrationName(c['raw'] as String), c['valid']),
    );
  }
  final f =
      jsonDecode(
            File(
              'contracts/scenarios/auth-password-input.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  for (final c in (f['cases'] as List).cast<Map<String, dynamic>>()) {
    test('canonical password: ${c['id']}', () {
      expect(trimAuthInput(c['raw'] as String), c['normalized']);
      expect(trimAuthInput(c['confirm'] as String), c['normalizedConfirm']);
      expect(validNewPassword(c['raw'] as String), c['validNewPassword']);
    });
  }
}
