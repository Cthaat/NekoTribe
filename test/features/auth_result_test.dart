import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/constants/storage_keys.dart';
import 'package:nekotribe/features/auth/domain/auth_models.dart';
import 'package:nekotribe/features/auth/domain/passkey_models.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/features/auth/data/auth_api.dart';
import 'package:nekotribe/features/auth/data/auth_repository.dart';

Map<String, dynamic> success() => {
  'two_factor_required': false,
  'user': {'user_id': 1, 'username': 'edge'},
  'tokens': <String, dynamic>{
    'session_id': 'session',
    'access_token': 'access',
    'refresh_token': 'refresh',
    'access_token_expires_at': '2030-01-01T00:00:00Z',
    'refresh_token_expires_at': '2030-02-01T00:00:00Z',
  },
};

void main() {
  test(
    'passkey login reuses session storage and forwards remember me',
    () async {
      final store = TokenStore(storage: _Storage());
      final api = _Api();
      final repo = AuthRepository(api: api, tokenStore: store);
      final result = await repo.loginWithPasskey(
        authenticate: (options) async {
          expect(options['rpId'], 'example.test');
          return {'id': 'synthetic'};
        },
        rememberMe: true,
        isActive: () => true,
      );
      expect(result, isA<V2LoginSuccess>());
      expect(api.passkeySubmission, [
        'challenge',
        {'id': 'synthetic'},
        true,
      ]);
      expect((await store.read())?.sessionId, 'session');
    },
  );

  test(
    'passkey prompt superseded by another login never sends proof',
    () async {
      final store = TokenStore(storage: _Storage());
      final api = _Api();
      final repo = AuthRepository(api: api, tokenStore: store);
      final prompt = Completer<Map<String, dynamic>>();
      final opened = Completer<void>();
      final rejected = expectLater(
        repo.loginWithPasskey(
          authenticate: (_) {
            opened.complete();
            return prompt.future;
          },
          isActive: () => true,
        ),
        throwsStateError,
      );
      await opened.future;
      await repo.login(account: 'new', password: 'password');
      prompt.complete({'id': 'old'});
      await rejected;
      expect(api.passkeySubmission, isNull);
      expect((await store.read())?.sessionId, 'session');
    },
  );

  test(
    'storage cleanup failure propagates and still synchronizes only its own cleared epoch',
    () async {
      final storage = _Storage();
      final failing = TokenStore(storage: storage);
      await failing.write(
        const TokenPair(
          accessToken: 'old',
          refreshToken: 'r',
          sessionId: 'old',
        ),
      );
      storage.failDeleteKey = StorageKeys.accessToken;
      final api = _Api(), observed = <int>[];
      final repo = AuthRepository(
        api: api,
        tokenStore: failing,
        onSessionCleared: (revision) async {
          observed.add(revision);
        },
      );
      await expectLater(
        repo.requestPasswordReset(
          email: 'synthetic@example.test',
          verificationId: 'otp',
          code: '123456',
          newPassword: 'synthetic',
        ),
        throwsStateError,
      );
      expect(observed, [failing.revision]);
      expect(await failing.read(), isNull);
    },
  );
  test(
    'password reset clears the original credentials only after API success',
    () async {
      final store = TokenStore(storage: _Storage());
      await store.write(
        const TokenPair(
          accessToken: 'old',
          refreshToken: 'r',
          sessionId: 'old',
        ),
      );
      final api = _Api()..pendingReset = Completer<void>();
      final repo = AuthRepository(api: api, tokenStore: store);
      final pending = repo.requestPasswordReset(
        email: 'synthetic@example.test',
        verificationId: 'otp',
        code: '123456',
        newPassword: 'synthetic',
      );
      expect((await store.read())!.sessionId, 'old');
      api.pendingReset!.complete();
      await pending;
      expect(await store.read(), isNull);
    },
  );
  test(
    'late reset success preserves a newer login and is not current completion',
    () async {
      final store = TokenStore(storage: _Storage()),
          api = _Api()..pendingReset = Completer<void>();
      final repo = AuthRepository(api: api, tokenStore: store);
      final pending = repo.requestPasswordReset(
        email: 'synthetic@example.test',
        verificationId: 'otp',
        code: '123456',
        newPassword: 'synthetic',
      );
      final rejected = expectLater(pending, throwsStateError);
      await repo.login(account: 'new', password: 'x');
      api.pendingReset!.complete();
      await rejected;
      expect((await store.read())!.sessionId, 'session');
    },
  );
  test('failed reset preserves existing credentials', () async {
    final store = TokenStore(storage: _Storage()),
        api = _Api()..pendingReset = Completer<void>();
    await store.write(
      const TokenPair(accessToken: 'old', refreshToken: 'r', sessionId: 'old'),
    );
    final repo = AuthRepository(api: api, tokenStore: store);
    final rejected = expectLater(
      repo.requestPasswordReset(
        email: 'synthetic@example.test',
        verificationId: 'otp',
        code: '123456',
        newPassword: 'synthetic',
      ),
      throwsStateError,
    );
    api.pendingReset!.completeError(StateError('isolated failure'));
    await rejected;
    expect((await store.read())!.sessionId, 'old');
  });
  test(
    'shared token model accepts real leap dates and timezone offsets without calendar normalization',
    () {
      final data = Map<String, dynamic>.from(success()['tokens'] as Map);
      data['access_token_expires_at'] = '2032-02-29T12:30:00.123456789+08:00';
      data['refresh_token_expires_at'] = '2032-03-01T00:00:00Z';
      expect(TokenPair.fromJson(data).accessTokenExpiresAt!.hour, 4);
      for (final invalid in [
        '2031-02-29T00:00:00Z',
        '2032-13-01T00:00:00Z',
        '2032-02-29T24:00:00Z',
        '2032-02-29T12:60:00Z',
        '2032-02-29T12:00:00+25:00',
      ]) {
        data['access_token_expires_at'] = invalid;
        expect(() => TokenPair.fromJson(data), throwsFormatException);
      }
    },
  );
  test('late logout completion preserves a newer login', () async {
    final store = TokenStore(storage: _Storage());
    final api = _Api()..pendingLogout = Completer<void>();
    final repo = AuthRepository(api: api, tokenStore: store);
    final oldLogout = repo.logout();
    await repo.login(account: 'new', password: 'x');
    api.pendingLogout!.complete();
    await oldLogout;
    expect((await store.read())!.sessionId, 'session');
  });
  test(
    'a superseded conditional write removes its marker before unlocking',
    () async {
      final storage = _Storage()..gate = Completer<void>();
      final store = TokenStore(storage: storage);
      final revision = store.beginSessionChange();
      final writing = store.writeIfCurrent(
        const TokenPair(accessToken: 'a', refreshToken: 'r', sessionId: 's'),
        revision,
      );
      await Future<void>.delayed(Duration.zero);
      store.beginSessionChange();
      storage.gate!.complete();
      expect(await writing, isFalse);
      expect(await store.read(), isNull);
      expect(await TokenStore(storage: storage).read(), isNull);
    },
  );
  test('logout invalidates a pending login response', () async {
    final store = TokenStore(storage: _Storage());
    final api = _Api()..pending = Completer<V2LoginResult>();
    final repo = AuthRepository(api: api, tokenStore: store);
    final login = repo.login(account: 'edge', password: 'x');
    await repo.logout();
    final rejected = expectLater(login, throwsStateError);
    api.pending!.complete(parseLoginResult(success()));
    await rejected;
    expect(await store.read(), isNull);
  });
  test(
    'a newer login takes precedence over an older pending response',
    () async {
      final store = TokenStore(storage: _Storage());
      final api = _Api()..pending = Completer<V2LoginResult>();
      final repo = AuthRepository(api: api, tokenStore: store);
      final old = api.pending!;
      final first = repo.login(account: 'old', password: 'x');
      api.pending = null;
      await repo.login(account: 'new', password: 'x');
      final rejected = expectLater(first, throwsStateError);
      old.complete(parseLoginResult(success()));
      await rejected;
      expect((await store.read())!.sessionId, 'session');
    },
  );
  test(
    'clear waits for an active write and removes its durable result',
    () async {
      final storage = _Storage()..gate = Completer<void>();
      final store = TokenStore(storage: storage);
      final writing = store.write(
        const TokenPair(accessToken: 'a', refreshToken: 'r', sessionId: 's'),
      );
      await Future<void>.delayed(Duration.zero);
      final cleared = store.clear();
      storage.gate!.complete();
      await Future.wait([writing, cleared]);
      expect(await store.read(), isNull);
      expect(await TokenStore(storage: storage).read(), isNull);
    },
  );
  test(
    'repository propagates storage failure for both login paths and rejects incomplete typed tokens',
    () async {
      for (final challenge in [false, true]) {
        final storage = _Storage()..failKey = StorageKeys.accessToken;
        final store = TokenStore(storage: storage);
        final api = _Api();
        final repo = AuthRepository(api: api, tokenStore: store);
        Future<V2LoginResult> attempt() => challenge
            ? repo.completeTwoFactor(challengeId: 'challenge', code: '123456')
            : repo.login(account: 'edge', password: 'x');
        await expectLater(attempt(), throwsStateError);
        expect(await repo.hasSession(), isFalse);
        storage.failKey = null;
        api.result = V2LoginSuccess(
          user: (parseLoginResult(success()) as V2LoginSuccess).user,
          tokens: V2TokenData(sessionId: 'session'),
        );
        await expectLater(attempt(), throwsFormatException);
        expect(storage.data, isEmpty);
      }
    },
  );
  test('challenge does not overwrite the existing token pair', () async {
    final store = TokenStore(storage: _Storage());
    await store.write(
      const TokenPair(
        accessToken: 'old',
        refreshToken: 'refresh',
        sessionId: 'session',
      ),
    );
    final api = _Api()
      ..result = V2TwoFactorRequired(
        challengeId: 'challenge',
        account: 'edge',
        expiresAt: '2030-01-01T00:00:00Z',
      );
    await AuthRepository(
      api: api,
      tokenStore: store,
    ).login(account: 'edge', password: 'x');
    expect((await store.read())!.accessToken, 'old');
  });
  test('login accepts complete success and strict challenge responses', () {
    expect(parseLoginResult(success()), isA<V2LoginSuccess>());
    expect(
      parseLoginResult({
        'two_factor_required': true,
        'challenge_id': 'challenge',
        'account': 'edge',
        'expires_at': '2030-01-01T00:00:00Z',
      }),
      isA<V2TwoFactorRequired>(),
    );
  });
  for (final key in [
    'session_id',
    'access_token',
    'refresh_token',
    'access_token_expires_at',
    'refresh_token_expires_at',
  ]) {
    test('login rejects missing or malformed $key', () {
      for (final value in [null, '', ' ', 123, [], {}]) {
        final data = success();
        (data['tokens'] as Map)[key] = value;
        expect(() => parseLoginResult(data), throwsFormatException);
      }
    });
  }
  test(
    'login rejects coerced flags, empty identity, invalid expiry and incomplete challenges',
    () {
      for (final value in ['false', 0, null]) {
        final data = success();
        data['two_factor_required'] = value;
        expect(() => parseLoginResult(data), throwsFormatException);
      }
      final data = success();
      data['user'] = {};
      expect(() => parseLoginResult(data), throwsFormatException);
      final expired = success();
      (expired['tokens'] as Map)['access_token_expires_at'] = 'not-a-date';
      expect(() => parseLoginResult(expired), throwsFormatException);
      for (final key in ['challenge_id', 'account', 'expires_at']) {
        final challenge = <String, dynamic>{
          'two_factor_required': true,
          'challenge_id': 'challenge',
          'account': 'edge',
          'expires_at': '2030-01-01T00:00:00Z',
        }..remove(key);
        expect(() => parseLoginResult(challenge), throwsFormatException);
      }
    },
  );
  test(
    'failed durable writes never publish a cached or mixed token pair',
    () async {
      for (final failedKey in [
        StorageKeys.accessToken,
        StorageKeys.refreshToken,
        StorageKeys.sessionId,
      ]) {
        final storage = _Storage();
        final store = TokenStore(storage: storage);
        await store.write(
          const TokenPair(
            accessToken: 'old-access',
            refreshToken: 'old-refresh',
            sessionId: 'old-session',
          ),
        );
        storage.failKey = failedKey;
        await expectLater(
          store.write(
            const TokenPair(
              accessToken: 'new-access',
              refreshToken: 'new-refresh',
              sessionId: 'new-session',
            ),
          ),
          throwsStateError,
        );
        expect(await store.read(), isNull);
        expect(await TokenStore(storage: storage).read(), isNull);
      }
    },
  );
  test(
    'successful replacement removes absent expiry instead of retaining old values',
    () async {
      final storage = _Storage();
      final store = TokenStore(storage: storage);
      await store.write(
        TokenPair(
          accessToken: 'a',
          refreshToken: 'r',
          sessionId: 's',
          accessTokenExpiresAt: DateTime.utc(2030),
          refreshTokenExpiresAt: DateTime.utc(2031),
        ),
      );
      await store.write(
        const TokenPair(accessToken: 'b', refreshToken: 't', sessionId: 'v'),
      );
      final read = await TokenStore(storage: storage).read();
      expect(read!.accessTokenExpiresAt, isNull);
      expect(read.refreshTokenExpiresAt, isNull);
    },
  );
}

class _Api extends AuthApi {
  _Api()
    : super(
        ApiClient(
          config: const AppConfig(
            apiBaseUrl: 'http://example.test',
            wsBaseUrl: 'ws://example.test',
            storageBaseUrl: 'http://example.test',
          ),
          tokenStore: TokenStore(),
        ),
      );
  V2LoginResult result = parseLoginResult(success());
  Completer<V2LoginResult>? pending;
  Completer<void>? pendingLogout;
  Completer<void>? pendingReset;
  List<Object>? passkeySubmission;

  @override
  Future<PasskeyChallenge> beginPasskeyAuthentication() async =>
      const PasskeyChallenge('challenge', {'rpId': 'example.test'});

  @override
  Future<V2LoginResult> verifyPasskeyAuthentication({
    required String challengeId,
    required Map<String, dynamic> credential,
    required bool rememberMe,
  }) async {
    passkeySubmission = [challengeId, credential, rememberMe];
    return result;
  }

  @override
  Future<void> requestPasswordReset({
    required String email,
    required String verificationId,
    required String code,
    required String newPassword,
  }) async {
    await pendingReset?.future;
  }

  @override
  Future<void> logout() async {
    await pendingLogout?.future;
  }

  @override
  Future<V2LoginResult> login({
    required String account,
    required String password,
    bool rememberMe = false,
  }) async => pending?.future ?? result;
  @override
  Future<V2LoginSuccess> completeTwoFactor({
    required String challengeId,
    required String code,
  }) async => result as V2LoginSuccess;
}

class _Storage implements FlutterSecureStorage {
  final data = <String, String>{};
  String? failKey;
  String? failDeleteKey;
  Completer<void>? gate;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    final key = invocation.namedArguments[#key] as String;
    if (invocation.memberName == #read) return Future<String?>.value(data[key]);
    if (invocation.memberName == #delete) {
      if (key == failDeleteKey) {
        return Future<void>.error(StateError('isolated deletion failure'));
      }
      data.remove(key);
      return Future<void>.value();
    }
    if (invocation.memberName == #write) {
      if (key == StorageKeys.accessToken && gate != null) {
        return gate!.future.then((_) {
          data[key] = invocation.namedArguments[#value] as String;
        });
      }
      if (key == failKey) {
        return Future<void>.error(StateError('isolated storage failure'));
      }
      data[key] = invocation.namedArguments[#value] as String;
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}
