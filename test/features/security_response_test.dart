import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/features/users/data/users_api.dart';
import 'package:nekotribe/features/users/domain/security_action.dart';

void main() {
  final fixture =
      jsonDecode(
            File(
              'contracts/scenarios/auth-security-client-response-vectors.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  for (final c in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
    test('shared security response: ${c['id']}', () async {
      final Object? body = jsonDecode(
        jsonEncode(
          c.containsKey('root') ? c['root'] : fixture['bases'][c['operation']],
        ),
      );
      for (final edit in (c['changes'] as List).cast<Map<String, dynamic>>()) {
        final path = edit['path'] as List;
        dynamic node = body;
        for (final part in path.take(path.length - 1)) {
          node = node[part];
        }
        if (edit['remove'] == true) {
          (node as Map).remove(path.last);
        } else {
          node[path.last] = edit['value'];
        }
      }
      final store = _Store(),
          adapter = _Adapter(body),
          dio = Dio()..httpClientAdapter = adapter;
      final api = UsersApi(
        ApiClient(
          config: const AppConfig(
            apiBaseUrl: 'http://example.test',
            wsBaseUrl: 'ws://example.test',
            storageBaseUrl: 'http://example.test',
          ),
          tokenStore: store,
          dio: dio,
        ),
      );
      try {
        final Future<Object?> pending = switch (c['operation']) {
          'setup' => api.setupTwoFactor(password: 'x'),
          'confirm' => api.confirmTwoFactor(code: '123456'),
          'disable' => api.disableTwoFactor(password: 'x', code: '123456'),
          _ => api.deleteMe(password: 'x', confirmation: 'DELETE'),
        };
        if (c['accepted'] == true) {
          final result = await pending;
          final data =
              (body as Map<String, dynamic>)['data'] as Map<String, dynamic>;
          switch (result) {
            case V2TwoFactorSetupData():
              expect(result.secret, data['secret']);
              expect(result.otpauthUrl, data['otpauth_url']);
            case V2TwoFactorConfirmData():
              expect(result.enabled, isTrue);
              expect(result.recoveryCodes, data['recovery_codes']);
              expect(
                () => result.recoveryCodes.clear(),
                throwsUnsupportedError,
              );
            case V2TwoFactorDisabledData():
              expect(result.enabled, isFalse);
            case V2AccountDeletionData():
              expect(result.deleted, isTrue);
              expect(result.userId, data['user_id']);
            default:
              fail('Expected a typed security action result');
          }
        } else {
          await expectLater(
            pending,
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'safe error',
                'Invalid security action response',
              ),
            ),
          );
        }
        expect(adapter.calls, 1);
        expect(store.writes, 0);
        expect(store.clears, 0);
      } finally {
        dio.close(force: true);
      }
    });
  }
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.body);
  final Object? body;
  int calls = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _Store extends TokenStore {
  int writes = 0, clears = 0;
  @override
  Future<TokenPair?> read() async => null;
  @override
  Future<void> write(TokenPair pair) async {
    writes++;
  }

  @override
  Future<void> clear() async {
    clears++;
  }

  @override
  Future<String> deviceFingerprint() async => 'synthetic-device';
}
