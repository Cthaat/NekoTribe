import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_exception.dart';
import 'package:nekotribe/features/auth/data/auth_api.dart';

void main() {
  test('OTP rate limit exposes Retry-After on the API exception', () async {
    final adapter = _Adapter(null, status: 429, retryAfter: '42');
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(() => dio.close(force: true));
    final auth = AuthApi(
      ApiClient(
        config: const AppConfig(
          apiBaseUrl: 'http://example.test',
          wsBaseUrl: 'ws://example.test',
          storageBaseUrl: 'http://example.test',
        ),
        tokenStore: _Store(),
        dio: dio,
      ),
    );
    await expectLater(
      auth.requestOtp(account: 'edge@example.test', purpose: 'register'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 429)
            .having((e) => e.retryAfterSeconds, 'retryAfterSeconds', 42),
      ),
    );
    expect(adapter.calls, 1);
  });

  final fixture =
      jsonDecode(
            File(
              'contracts/scenarios/auth-public-response-vectors.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  for (final raw in fixture['cases'] as List<dynamic>) {
    final vector = raw as Map<String, dynamic>;
    test('shared public auth: ${vector['id']}', () async {
      final data =
          jsonDecode(
                jsonEncode(
                  (fixture['bases']
                      as Map<String, dynamic>)[vector['operation']],
                ),
              )
              as Map<String, dynamic>;
      for (final rawEdit in vector['changes'] as List<dynamic>) {
        final edit = rawEdit as Map<String, dynamic>,
            path = (rawEdit['path'] as List<dynamic>).cast<String>();
        var node = data;
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
          adapter = _Adapter(data),
          dio = Dio()..httpClientAdapter = adapter;
      final api = AuthApi(
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
        final account = fixture['account'] as String;
        final Future<Object> pending = switch (vector['operation']) {
          'create' => api.requestOtp(account: account, purpose: 'register'),
          'verify' => api.verifyOtp(
            account: account,
            purpose: 'register',
            verificationId: 'synthetic-otp',
            code: '123456',
          ),
          'register' => api.register(
            email: account,
            username: fixture['username'] as String,
            displayName: 'Synthetic',
            password: 'synthetic',
            confirmPassword: 'synthetic',
            verificationId: 'synthetic-otp',
            agreeToTerms: true,
          ),
          _ => throw StateError('Unknown operation'),
        };
        if (vector['accepted'] == true) {
          await pending;
        } else {
          await expectLater(pending, throwsFormatException);
        }
        expect(adapter.calls, 1);
        expect(store.writes, 0);
      } finally {
        dio.close(force: true);
      }
    });
  }
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.data, {this.status = 200, this.retryAfter});
  final Object? data;
  final int status;
  final String? retryAfter;
  int calls = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    return ResponseBody.fromString(
      jsonEncode({
        'code': status == 429 ? 42901 : 200,
        'message': 'success',
        'data': data,
        'meta': null,
      }),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        if (retryAfter case final value?) 'retry-after': [value],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _Store extends TokenStore {
  int writes = 0;
  @override
  Future<TokenPair?> read() async => null;
  @override
  Future<void> write(TokenPair pair) async {
    writes++;
  }

  @override
  Future<String> deviceFingerprint() async => 'synthetic-device';
}
