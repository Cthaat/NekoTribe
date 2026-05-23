import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/constants/api_paths.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_exception.dart';

void main() {
  test(
    '401 without a stored refresh token does not leak an unhandled refresh error',
    () async {
      final dio = Dio()
        ..httpClientAdapter = _JsonAdapter(
          (options) => _JsonResponse(
            statusCode: 401,
            body: {
              'code': 40101,
              'message': '请先登录',
              'data': null,
            },
          ),
        );
      final tokenStore = _FakeTokenStore();
      final client = ApiClient(
        config: _testConfig,
        tokenStore: tokenStore,
        dio: dio,
      );
      final unhandledErrors = <Object>[];

      await runZonedGuarded(
        () async {
          await expectLater(
            client.requestData<dynamic>(ApiPaths.posts),
            throwsA(
              isA<ApiException>()
                  .having((e) => e.code, 'code', 40101)
                  .having((e) => e.statusCode, 'statusCode', 401),
            ),
          );
          await Future<void>.delayed(Duration.zero);
        },
        (error, _) => unhandledErrors.add(error),
      );

      expect(unhandledErrors, isEmpty);
      expect(tokenStore.clearCount, 1);
    },
  );
}

const _testConfig = AppConfig(
  apiBaseUrl: 'http://example.test',
  wsBaseUrl: 'ws://example.test',
  storageBaseUrl: 'http://example.test',
);

class _FakeTokenStore extends TokenStore {
  _FakeTokenStore() : super();

  int clearCount = 0;

  @override
  Future<TokenPair?> read() async => null;

  @override
  Future<void> write(TokenPair pair) async {}

  @override
  Future<void> updateAccess({
    required String accessToken,
    DateTime? accessTokenExpiresAt,
    String? refreshToken,
    DateTime? refreshTokenExpiresAt,
  }) async {}

  @override
  Future<void> clear() async {
    clearCount += 1;
  }

  @override
  Future<String> deviceFingerprint() async => 'test-device';
}

class _JsonAdapter implements HttpClientAdapter {
  _JsonAdapter(this._handler);

  final _JsonResponse Function(RequestOptions options) _handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final response = _handler(options);
    return ResponseBody.fromString(
      jsonEncode(response.body),
      response.statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _JsonResponse {
  const _JsonResponse({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final Map<String, dynamic> body;
}
