import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/constants/api_paths.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_exception.dart';
import 'package:nekotribe/features/auth/data/auth_api.dart';
import 'package:nekotribe/features/auth/data/auth_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'remembered device cookie is stored and only sent to its login endpoint',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final store = TokenStore();
      final proof = 'td1_${'a' * 64}';
      final requests = <RequestOptions>[];
      ApiClient clientFor(AppConfig config) => ApiClient(
        config: config,
        tokenStore: store,
        dio: Dio()
          ..httpClientAdapter = _JsonAdapter((request) {
            requests.add(request);
            return _JsonResponse(
              statusCode: 200,
              headers: {
                'set-cookie': [
                  'access_token=access.jwt; Path=/; HttpOnly',
                  'refresh_token=refresh.jwt; Path=/; HttpOnly',
                  if (request.path.startsWith(ApiPaths.authTwoFactorChallenges))
                    'nekotribe_trusted_device=$proof; Path=/; HttpOnly',
                ],
              },
              body: {
                'code': 200,
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
            );
          }),
      );
      final first = clientFor(_testConfig);
      addTearDown(first.dispose);
      final repo = AuthRepository(api: AuthApi(first), tokenStore: store);
      await repo.completeTwoFactor(challengeId: 'fixture', code: '123456');
      await repo.login(account: 'edge', password: 'password');
      expect(
        requests.last.headers['Cookie'],
        'nekotribe_trusted_device=$proof',
      );
      expect(requests.last.followRedirects, isFalse);

      await store.switchEndpoint(() {});
      final second = clientFor(
        const AppConfig(
          apiBaseUrl: 'http://other.example.test',
          wsBaseUrl: 'ws://other.example.test',
          storageBaseUrl: 'http://other.example.test',
        ),
      );
      addTearDown(second.dispose);
      await AuthApi(second).login(account: 'edge', password: 'password');
      expect(requests.last.headers['Cookie'], isNull);
    },
  );

  test(
    'a late 401 cannot refresh or clear the session after an endpoint switch',
    () async {
      final store = _FakeTokenStore();
      const pair = TokenPair(
        accessToken: 'old',
        refreshToken: 'old-r',
        sessionId: 'session',
      );
      await store.write(pair);
      final started = Completer<void>(), reply = Completer<_JsonResponse>();
      final paths = <String>[];
      final dio = Dio()
        ..httpClientAdapter = _JsonAdapter((request) {
          paths.add(request.path);
          started.complete();
          return reply.future;
        });
      final client = ApiClient(
        config: _testConfig,
        tokenStore: store,
        dio: dio,
      );
      addTearDown(client.dispose);
      final cancelled = throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      );
      final response = expectLater(
        client.requestData<Object>(ApiPaths.usersMe),
        cancelled,
      );
      await started.future;
      // Invalidate immediately even if provider disposal is deferred.
      await store.switchEndpoint(() {});
      reply.complete(
        const _JsonResponse(statusCode: 401, body: {'code': 40101}),
      );
      await response;
      await expectLater(
        client.requestData<Object>(ApiPaths.usersMe),
        cancelled,
      );
      expect(paths, [ApiPaths.usersMe]);
      expect(store.writtenPair, same(pair));
      expect(store.clearCount, 0);
    },
  );

  test(
    'credential completion only clears its own revision and synchronizes local state',
    () async {
      final store = _FakeTokenStore();
      final client = ApiClient(config: _testConfig, tokenStore: store);
      var synchronized = 0;
      final repository = AuthRepository(
        api: AuthApi(client),
        tokenStore: store,
        onSessionCleared: (_) async {
          synchronized++;
        },
      );
      final old = store.revision;
      store.beginSessionChange();
      expect(await repository.clearAfterCredentialMutation(old), isNull);
      expect(store.clearCount, 0);
      final receipt = await repository.clearAfterCredentialMutation(
        store.revision,
      );
      expect(receipt, isNotNull);
      expect(repository.isCurrentReceipt(receipt!), isTrue);
      expect(store.clearCount, 1);
      expect(synchronized, 1);
    },
  );
  test(
    'late email success is cancelled before the envelope validator runs',
    () async {
      final store = _FakeTokenStore();
      await store.write(
        const TokenPair(
          accessToken: 'old',
          refreshToken: 'old-r',
          sessionId: 'old-s',
        ),
      );
      final started = Completer<void>(), reply = Completer<_JsonResponse>();
      var validated = false;
      final dio = Dio()
        ..httpClientAdapter = _JsonAdapter((_) {
          started.complete();
          return reply.future;
        });
      final client = ApiClient(
        config: _testConfig,
        tokenStore: store,
        dio: dio,
      );
      try {
        final pending = client.request<void>(
          ApiPaths.usersMeEmail,
          method: 'PATCH',
          decode: (_) {},
          validateSuccessEnvelope: (_) {
            validated = true;
          },
        );
        final rejected = expectLater(
          pending,
          throwsA(
            isA<DioException>().having(
              (e) => e.type,
              'cancelled',
              DioExceptionType.cancel,
            ),
          ),
        );
        await started.future;
        store.beginSessionChange();
        reply.complete(
          const _JsonResponse(
            statusCode: 200,
            body: {
              'code': 200,
              'message': 'success',
              'data': null,
              'meta': null,
            },
          ),
        );
        await rejected;
        expect(validated, isFalse);
        expect(store.clearCount, 0);
      } finally {
        dio.close(force: true);
      }
    },
  );
  for (final path in [
    '/api/v2/users/me/email',
    'http://example.test/api/v2/users/me/email?source=safety',
    '/api/v2/users/me',
    '/api/v2/users/me/two-factor',
    '/api/v2/users/me/two-factor/setup',
    '/api/v2/users/me/two-factor/confirm',
  ]) {
    for (final dioErrorBranch in [false, true]) {
      test(
        'email credential failure never refreshes/replays or clears: $path error=$dioErrorBranch',
        () async {
          final store = _FakeTokenStore();
          await store.write(
            const TokenPair(
              accessToken: 'old',
              refreshToken: 'old-r',
              sessionId: 'old-s',
            ),
          );
          final calls = <RequestOptions>[];
          var logouts = 0;
          final dio = Dio()
            ..httpClientAdapter = _JsonAdapter((o) {
              calls.add(o);
              return o.path == ApiPaths.authTokensCurrent
                  ? _refreshReply()
                  : const _JsonResponse(
                      statusCode: 401,
                      body: {
                        'code': 40101,
                        'message': '验证码错误',
                        'data': null,
                        'meta': null,
                      },
                    );
            });
          final client = ApiClient(
            config: _testConfig,
            tokenStore: store,
            dio: dio,
            onLogout: () async {
              logouts++;
            },
          );
          if (dioErrorBranch) {
            dio.options.validateStatus = (status) => status != 401;
          }
          try {
            await expectLater(
              client.request<void>(
                path,
                method: path.endsWith('/me') || path.endsWith('/two-factor')
                    ? 'DELETE'
                    : 'PATCH',
                data: {'new_email': 'next@example.test', 'code': 'wrong'},
                decode: (_) {},
              ),
              dioErrorBranch
                  ? throwsA(isA<DioException>())
                  : throwsA(isA<ApiException>()),
            );
            expect(calls, hasLength(1));
            expect(calls.single.headers['Authorization'], 'Bearer old');
            expect(store.clearCount, 0);
            expect(logouts, 0);
            expect(store.writtenPair?.accessToken, 'old');
          } finally {
            dio.close(force: true);
          }
        },
      );
    }
  }
  for (final invalid in [
    'missing-session',
    'other-session',
    'missing-access',
    'missing-refresh',
    'blank-token',
    'numeric-token',
    'missing-expiry',
    'invalid-date',
    'calendar-overflow',
    'no-zone',
    'reversed-expiry',
    'cookie-conflict',
  ]) {
    test(
      'refresh rejects $invalid without replaying the protected request',
      () async {
        final data = Map<String, dynamic>.from(
          _refreshReply().body['data'] as Map,
        );
        switch (invalid) {
          case 'missing-session':
            data.remove('session_id');
            break;
          case 'other-session':
            data['session_id'] = 'other';
            break;
          case 'missing-access':
            data.remove('access_token');
            break;
          case 'missing-refresh':
            data.remove('refresh_token');
            break;
          case 'blank-token':
            data['access_token'] = ' ';
            break;
          case 'numeric-token':
            data['access_token'] = 123;
            break;
          case 'missing-expiry':
            data.remove('access_token_expires_at');
            break;
          case 'invalid-date':
            data['access_token_expires_at'] = 'not-a-date';
            break;
          case 'calendar-overflow':
            data['access_token_expires_at'] = '2030-02-30T00:00:00Z';
            break;
          case 'no-zone':
            data['access_token_expires_at'] = '2030-01-01T00:00:00';
            break;
          case 'reversed-expiry':
            data['refresh_token_expires_at'] = '2029-01-01T00:00:00Z';
            break;
        }
        var posts = 0;
        final store = _FakeTokenStore();
        await store.write(
          const TokenPair(
            accessToken: 'old',
            refreshToken: 'old-r',
            sessionId: 'old-s',
          ),
        );
        final dio = Dio()
          ..httpClientAdapter = _JsonAdapter((o) {
            if (o.path == ApiPaths.authTokensCurrent) {
              return _JsonResponse(
                statusCode: 200,
                body: {'code': 200, 'data': data},
                headers: invalid == 'cookie-conflict'
                    ? {
                        'set-cookie': [
                          'access_token=different; Path=/; HttpOnly',
                        ],
                      }
                    : {},
              );
            }
            posts++;
            return posts == 1
                ? const _JsonResponse(statusCode: 401, body: {'code': 40101})
                : const _JsonResponse(
                    statusCode: 200,
                    body: {'code': 200, 'data': {}},
                  );
          });
        final client = ApiClient(
          config: _testConfig,
          tokenStore: store,
          dio: dio,
        );
        await expectLater(
          client.requestData<dynamic>(ApiPaths.posts),
          throwsA(isA<ApiException>()),
        );
        expect(posts, 1);
        expect(store.writtenPair, isNull);
      },
    );
  }
  test(
    'late private success is cancelled after the user changes session',
    () async {
      final started = Completer<void>(), reply = Completer<_JsonResponse>();
      final store = _FakeTokenStore();
      await store.write(
        const TokenPair(accessToken: 'old', refreshToken: 'r', sessionId: 's'),
      );
      final dio = Dio()
        ..httpClientAdapter = _JsonAdapter((o) {
          started.complete();
          return reply.future;
        });
      final client = ApiClient(
        config: _testConfig,
        tokenStore: store,
        dio: dio,
      );
      final request = client.requestData<dynamic>(ApiPaths.usersMe);
      await started.future;
      store.beginSessionChange();
      final rejected = expectLater(
        request,
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      reply.complete(
        const _JsonResponse(
          statusCode: 200,
          body: {
            'code': 200,
            'data': {'private': 'old user'},
          },
        ),
      );
      await rejected;
    },
  );
  test(
    'concurrent requests share one refresh and retry with its new access token',
    () async {
      final started = Completer<void>(), reply = Completer<_JsonResponse>();
      var refreshes = 0, posts = 0;
      final store = _FakeTokenStore();
      await store.write(
        const TokenPair(
          accessToken: 'old',
          refreshToken: 'old-r',
          sessionId: 'old-s',
        ),
      );
      final dio = Dio()
        ..httpClientAdapter = _JsonAdapter((o) {
          if (o.path == ApiPaths.authTokensCurrent) {
            refreshes++;
            if (!started.isCompleted) started.complete();
            return reply.future;
          }
          posts++;
          return o.headers['Authorization'] == 'Bearer rotated'
              ? const _JsonResponse(
                  statusCode: 200,
                  body: {
                    'code': 200,
                    'data': {'ok': true},
                  },
                )
              : const _JsonResponse(statusCode: 401, body: {'code': 40101});
        });
      final client = ApiClient(
        config: _testConfig,
        tokenStore: store,
        dio: dio,
      );
      final requests = [
        client.requestData<dynamic>(ApiPaths.posts),
        client.requestData<dynamic>(ApiPaths.posts),
      ];
      await started.future;
      await Future<void>.delayed(Duration.zero);
      reply.complete(_refreshReply());
      final results = await Future.wait(requests);
      expect(results.every((r) => r['ok'] == true), isTrue);
      expect(refreshes, 1);
      expect(posts, 4);
    },
  );
  test(
    'Dio error branch also preserves a newer session after late refresh failure',
    () async {
      final started = Completer<void>(), reply = Completer<_JsonResponse>();
      var logouts = 0;
      final store = _FakeTokenStore();
      await store.write(
        const TokenPair(
          accessToken: 'old',
          refreshToken: 'old-r',
          sessionId: 'old-s',
        ),
      );
      final dio = Dio()
        ..httpClientAdapter = _JsonAdapter((o) {
          if (o.path == ApiPaths.authTokensCurrent) {
            started.complete();
            return reply.future;
          }
          return const _JsonResponse(statusCode: 401, body: {'code': 40101});
        });
      final client = ApiClient(
        config: _testConfig,
        tokenStore: store,
        dio: dio,
        onLogout: () async {
          logouts++;
        },
      );
      dio.options.validateStatus = (status) => status != 401;
      final request = client.requestData<dynamic>(ApiPaths.posts);
      await started.future;
      store.beginSessionChange();
      await store.write(
        const TokenPair(
          accessToken: 'new',
          refreshToken: 'r',
          sessionId: 'new-s',
        ),
      );
      final rejected = expectLater(request, throwsA(isA<DioException>()));
      reply.complete(
        const _JsonResponse(statusCode: 401, body: {'code': 40101}),
      );
      await rejected;
      expect(logouts, 0);
      expect(store.writtenPair!.sessionId, 'new-s');
    },
  );
  test(
    'an old unauthorized request does not refresh or log out a newer session',
    () async {
      final started = Completer<void>(), reply = Completer<_JsonResponse>();
      var refreshes = 0, logouts = 0;
      final store = _FakeTokenStore();
      await store.write(
        const TokenPair(
          accessToken: 'old',
          refreshToken: 'old-r',
          sessionId: 'old-s',
        ),
      );
      final dio = Dio()
        ..httpClientAdapter = _JsonAdapter((o) {
          if (o.path == ApiPaths.authTokensCurrent) {
            refreshes++;
            return const _JsonResponse(statusCode: 401, body: {'code': 40101});
          }
          started.complete();
          return reply.future;
        });
      final client = ApiClient(
        config: _testConfig,
        tokenStore: store,
        dio: dio,
        onLogout: () async {
          logouts++;
        },
      );
      final request = client.requestData<dynamic>(ApiPaths.posts);
      await started.future;
      store.beginSessionChange();
      await store.write(
        const TokenPair(
          accessToken: 'new',
          refreshToken: 'new-r',
          sessionId: 'new-s',
        ),
      );
      final rejected = expectLater(request, throwsA(isA<ApiException>()));
      reply.complete(
        const _JsonResponse(statusCode: 401, body: {'code': 40101}),
      );
      await rejected;
      expect(refreshes, 0);
      expect(logouts, 0);
      expect(store.writtenPair!.sessionId, 'new-s');
    },
  );
  for (final failed in [false, true]) {
    test(
      'late refresh ${failed ? 'failure' : 'success'} preserves a newer login',
      () async {
        final started = Completer<void>(), reply = Completer<_JsonResponse>();
        var posts = 0, logouts = 0;
        final store = _FakeTokenStore();
        await store.write(
          const TokenPair(
            accessToken: 'old',
            refreshToken: 'old-r',
            sessionId: 'old-s',
          ),
        );
        final dio = Dio()
          ..httpClientAdapter = _JsonAdapter((o) {
            if (o.path == ApiPaths.authTokensCurrent) {
              started.complete();
              return reply.future;
            }
            posts++;
            return const _JsonResponse(statusCode: 401, body: {'code': 40101});
          });
        final client = ApiClient(
          config: _testConfig,
          tokenStore: store,
          dio: dio,
          onLogout: () async {
            logouts++;
          },
        );
        final request = client.requestData<dynamic>(ApiPaths.posts);
        await started.future;
        store.beginSessionChange();
        await store.write(
          const TokenPair(
            accessToken: 'new',
            refreshToken: 'new-r',
            sessionId: 'new-s',
          ),
        );
        final rejected = expectLater(request, throwsA(isA<ApiException>()));
        reply.complete(
          failed
              ? const _JsonResponse(statusCode: 401, body: {'code': 40101})
              : _refreshReply(),
        );
        await rejected;
        expect(posts, 1);
        expect(logouts, 0);
        expect(store.writtenPair!.sessionId, 'new-s');
      },
    );
  }
  test('a protected request is retried at most once after refresh', () async {
    var posts = 0, refreshes = 0;
    final store = _FakeTokenStore();
    await store.write(
      const TokenPair(
        accessToken: 'old',
        refreshToken: 'old-r',
        sessionId: 'old-s',
      ),
    );
    final dio = Dio()
      ..httpClientAdapter = _JsonAdapter((o) {
        if (o.path == ApiPaths.authTokensCurrent) {
          refreshes++;
          return _refreshReply();
        }
        posts++;
        return _JsonResponse(
          statusCode: posts < 3 ? 401 : 200,
          body: posts < 3 ? {'code': 40101} : {'code': 200, 'data': {}},
        );
      });
    final client = ApiClient(config: _testConfig, tokenStore: store, dio: dio);
    await expectLater(
      client.requestData<dynamic>(ApiPaths.posts),
      throwsA(isA<ApiException>()),
    );
    expect(posts, 2);
    expect(refreshes, 1);
  });
  test('API requests negotiate JSON by default', () async {
    RequestOptions? captured;
    final dio = Dio()
      ..httpClientAdapter = _JsonAdapter((options) {
        captured = options;
        return const _JsonResponse(
          statusCode: 200,
          body: {'code': 200, 'message': 'ok', 'data': null},
        );
      });
    final client = ApiClient(
      config: _testConfig,
      tokenStore: _FakeTokenStore(),
      dio: dio,
    );

    await client.requestData<dynamic>(ApiPaths.health);

    final acceptHeaders = captured!.headers.entries.where(
      (entry) => entry.key.toLowerCase() == 'accept',
    );
    expect(acceptHeaders, hasLength(1));
    expect(acceptHeaders.single.value, 'application/json');
  });

  for (final name in ['Accept', 'accept', 'ACCEPT', 'aCcEpT']) {
    test('preserves injected Dio $name instead of replacing it', () async {
      RequestOptions? captured;
      final dio = Dio(BaseOptions(headers: {name: 'text/event-stream'}))
        ..httpClientAdapter = _JsonAdapter((options) {
          captured = options;
          return const _JsonResponse(
            statusCode: 200,
            body: {'code': 200, 'message': 'ok', 'data': null},
          );
        });
      final client = ApiClient(
        config: _testConfig,
        tokenStore: _FakeTokenStore(),
        dio: dio,
      );

      await client.requestData<dynamic>(ApiPaths.health);

      final acceptHeaders = captured!.headers.entries.where(
        (entry) => entry.key.toLowerCase() == 'accept',
      );
      expect(acceptHeaders, hasLength(1));
      expect(acceptHeaders.single.value, 'text/event-stream');
    });

    test(
      'preserves per-request $name without duplicate JSON default',
      () async {
        RequestOptions? captured;
        final dio = Dio()
          ..httpClientAdapter = _JsonAdapter((options) {
            captured = options;
            return const _JsonResponse(
              statusCode: 200,
              body: {'code': 200, 'message': 'ok', 'data': null},
            );
          });
        final client = ApiClient(
          config: _testConfig,
          tokenStore: _FakeTokenStore(),
          dio: dio,
        );

        await client.requestData<dynamic>(
          ApiPaths.health,
          headers: {name: 'application/problem+json'},
        );

        final acceptHeaders = captured!.headers.entries.where(
          (entry) => entry.key.toLowerCase() == 'accept',
        );
        expect(acceptHeaders, hasLength(1));
        expect(acceptHeaders.single.value, 'application/problem+json');
      },
    );
  }

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

  test('requests opt into browser credentials for cookie auth', () async {
    RequestOptions? captured;
    final dio = Dio()
      ..httpClientAdapter = _JsonAdapter((options) {
        captured = options;
        return const _JsonResponse(
          statusCode: 200,
          body: {'code': 200, 'message': 'ok', 'data': <String, Object>{}},
        );
      });
    final client = ApiClient(
      config: _testConfig,
      tokenStore: _FakeTokenStore(),
      dio: dio,
    );

    await client.requestData<dynamic>(ApiPaths.health);

    expect(captured?.extra['withCredentials'], isTrue);
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
  Future<bool> writeIfCurrent(TokenPair pair, int expectedRevision) async {
    if (revision != expectedRevision) return false;
    await write(pair);
    return true;
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
    beginSessionChange();
    clearCount += 1;
    writtenPair = null;
  }

  @override
  Future<bool> clearIfCurrent(int expectedRevision) async {
    if (revision != expectedRevision) return false;
    await clear();
    return true;
  }

  @override
  Future<String> deviceFingerprint() async => 'test-device';
}

class _JsonAdapter implements HttpClientAdapter {
  _JsonAdapter(this._handler);

  final FutureOr<_JsonResponse> Function(RequestOptions options) _handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final response = await _handler(options);
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
_JsonResponse _refreshReply() => const _JsonResponse(
  statusCode: 200,
  body: {
    'code': 200,
    'data': {
      'session_id': 'old-s',
      'access_token': 'rotated',
      'refresh_token': 'rotated-r',
      'access_token_expires_at': '2030-01-01T00:00:00Z',
      'refresh_token_expires_at': '2030-02-01T00:00:00Z',
    },
  },
);
