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
import 'package:nekotribe/features/auth/data/auth_api.dart';
import 'package:nekotribe/features/auth/data/auth_repository.dart';

void main() {
  test(
    '401 without a stored refresh token does not leak an unhandled refresh error',
    () async {
      final dio = Dio()
        ..httpClientAdapter = _JsonAdapter(
          (options) => _JsonResponse(
            statusCode: 401,
            body: {'code': 40101, 'message': '请先登录', 'data': null},
          ),
        );
      final tokenStore = _FakeTokenStore();
      final client = ApiClient(
        config: _testConfig,
        tokenStore: tokenStore,
        dio: dio,
      );
      final unhandledErrors = <Object>[];

      await runZonedGuarded(() async {
        await expectLater(
          client.requestData<dynamic>(ApiPaths.posts),
          throwsA(
            isA<ApiException>()
                .having((e) => e.code, 'code', 40101)
                .having((e) => e.statusCode, 'statusCode', 401),
          ),
        );
        await Future<void>.delayed(Duration.zero);
      }, (error, _) => unhandledErrors.add(error));

      expect(unhandledErrors, isEmpty);
      expect(tokenStore.clearCount, 1);
    },
  );

  test('unwraps Nuxt error envelope around v2 responses', () async {
    final dio = Dio()
      ..httpClientAdapter = _JsonAdapter(
        (options) => _JsonResponse(
          statusCode: 401,
          body: {
            'error': true,
            'statusCode': 401,
            'message': '请先登录',
            'data': {
              'code': 40101,
              'message': '请先登录',
              'data': null,
              'meta': null,
            },
          },
        ),
      );
    final client = ApiClient(
      config: _testConfig,
      tokenStore: _FakeTokenStore(),
      dio: dio,
    );

    await expectLater(
      client.requestData<dynamic>(ApiPaths.posts),
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', 40101)
            .having((e) => e.message, 'message', '请先登录'),
      ),
    );
  });

  test('login persists auth tokens from Set-Cookie headers', () async {
    final dio = Dio()
      ..httpClientAdapter = _JsonAdapter(
        (options) => _JsonResponse(
          statusCode: 200,
          headers: {
            'set-cookie': [
              'access_token=access.jwt; Path=/; HttpOnly; SameSite=Lax',
              'refresh_token=refresh.jwt; Path=/; HttpOnly; SameSite=Lax',
            ],
          },
          body: {
            'code': 200,
            'message': 'login success',
            'data': {
              'two_factor_required': false,
              'user': _selfUserJson,
              'tokens': {
                'session_id': 'session-1',
                'access_token_expires_at': '2026-05-23T12:00:00.000Z',
                'refresh_token_expires_at': '2026-06-23T12:00:00.000Z',
              },
            },
          },
        ),
      );
    final tokenStore = _FakeTokenStore();
    final client = ApiClient(
      config: _testConfig,
      tokenStore: tokenStore,
      dio: dio,
    );
    final repo = AuthRepository(api: AuthApi(client), tokenStore: tokenStore);

    await repo.login(account: 'edge', password: 'password');

    expect(tokenStore.writtenPair?.accessToken, 'access.jwt');
    expect(tokenStore.writtenPair?.refreshToken, 'refresh.jwt');
    expect(tokenStore.writtenPair?.sessionId, 'session-1');
  });
}

const _testConfig = AppConfig(
  apiBaseUrl: 'http://example.test',
  wsBaseUrl: 'ws://example.test',
  storageBaseUrl: 'http://example.test',
);

class _FakeTokenStore extends TokenStore {
  _FakeTokenStore() : super();

  int clearCount = 0;
  TokenPair? writtenPair;

  @override
  Future<TokenPair?> read() async => writtenPair;

  @override
  Future<void> write(TokenPair pair) async {
    writtenPair = pair;
  }

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
    writtenPair = null;
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
        ...response.headers,
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
    this.headers = const {},
  });

  final int statusCode;
  final Map<String, dynamic> body;
  final Map<String, List<String>> headers;
}

const _selfUserJson = {
  'user_id': 1,
  'username': 'edge',
  'display_name': 'Edge',
  'avatar_url': '',
  'bio': '',
  'location': '',
  'website': '',
  'is_verified': 0,
  'followers_count': 0,
  'following_count': 0,
  'posts_count': 0,
  'likes_count': 0,
  'relationship': {
    'is_self': true,
    'is_following': false,
    'is_blocked': false,
    'is_blocking': false,
    'relation': 'self',
  },
  'online_status': 'online',
  'email': 'edge@example.test',
  'phone': '',
  'birth_date': null,
  'email_verified_at': '2026-05-23T12:00:00.000Z',
  'is_active': 1,
  'status': 'active',
  'created_at': '2026-05-23T12:00:00.000Z',
  'updated_at': '2026-05-23T12:00:00.000Z',
};
