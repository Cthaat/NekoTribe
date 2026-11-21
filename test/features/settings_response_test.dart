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
  final fixture =
      jsonDecode(
            File(
              'contracts/scenarios/user-settings-client-response-vectors.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  for (final operation in ['get', 'patch']) {
    for (final c in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
      test('settings $operation: ${c['id']}', () async {
        final Object? body = jsonDecode(
          jsonEncode(c.containsKey('root') ? c['root'] : fixture['base']),
        );
        for (final e in (c['changes'] as List).cast<Map<String, dynamic>>()) {
          var n = body as Map<String, dynamic>;
          final path = (e['path'] as List).cast<String>();
          for (final k in path.take(path.length - 1)) {
            n = n[k] as Map<String, dynamic>;
          }
          if (e['remove'] == true) {
            n.remove(path.last);
          } else {
            n[path.last] = e['value'];
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
          final pending = operation == 'get'
              ? api.getSettings()
              : api.updateSettings({'login_alerts': true});
          if (c['accepted'] == true) {
            final result = await pending;
            final data =
                (body as Map<String, dynamic>)['data'] as Map<String, dynamic>;
            expect(result.userId, data['user_id']);
            expect(result.twoFactorEnabled, data['two_factor_enabled']);
            expect(result.loginAlerts, data['login_alerts']);
            expect(result.aiSentimentTopK, data['ai_sentiment_top_k']);
            expect(result.updatedAt, data['updated_at']);
          } else {
            await expectLater(
              pending,
              throwsA(
                isA<FormatException>().having(
                  (e) => e.message,
                  'safe error',
                  'Invalid account settings response',
                ),
              ),
            );
          }
          expect(adapter.calls, 1);
          expect(store.clears, 0);
          expect(store.writes, 0);
        } finally {
          dio.close(force: true);
        }
      });
    }
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
  int clears = 0, writes = 0;
  @override
  Future<TokenPair?> read() async => null;
  @override
  Future<void> clear() async {
    clears++;
  }

  @override
  Future<void> write(TokenPair pair) async {
    writes++;
  }

  @override
  Future<String> deviceFingerprint() async => 'synthetic-device';
}
