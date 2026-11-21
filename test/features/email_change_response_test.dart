import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/features/users/data/users_api.dart';

void main() {
  final f =
      jsonDecode(
            File(
              'contracts/scenarios/auth-email-client-response-vectors.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  for (final c in (f['cases'] as List).cast<Map<String, dynamic>>()) {
    test('shared email response: ${c['id']}', () async {
      final Object? body = jsonDecode(
        jsonEncode(c.containsKey('root') ? c['root'] : f['base']),
      );
      for (final edit in (c['changes'] as List).cast<Map<String, dynamic>>()) {
        final path = (edit['path'] as List).cast<String>();
        var node = body as Map<String, dynamic>;
        for (final part in path.take(path.length - 1)) {
          node = node[part] as Map<String, dynamic>;
        }
        if (edit['remove'] == true) {
          node.remove(path.last);
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
        final pending = api.updateEmail(
          newEmail: f['account'] as String,
          verificationId: 'synthetic-otp',
          code: '123456',
        );
        if (c['accepted'] == true) {
          final result = await pending;
          expect(result.email, f['account']);
          expect(
            result.verifiedAt,
            (body as Map<String, dynamic>)['data']['email_verified_at'],
          );
        } else {
          await expectLater(
            pending,
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'safe error',
                'Invalid email change response',
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
