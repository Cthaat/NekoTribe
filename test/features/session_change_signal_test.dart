import 'dart:async';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/features/auth/data/auth_api.dart';
import 'package:nekotribe/features/auth/data/auth_repository.dart';
import 'package:nekotribe/features/auth/domain/auth_models.dart';

void main() {
  test(
    'queued credentials survive a switch and a stale clear cannot erase them',
    () async {
      final store = TokenStore(storage: _Storage());
      const pair = TokenPair(
        accessToken: 'fixture-access',
        refreshToken: 'fixture-refresh',
        sessionId: 'fixture-session',
      );
      final revision = store.revision;
      final write = store.writeIfCurrent(pair, revision);
      final endpoint = store.switchEndpoint(() {
        expect(store.endpointRevision, 1);
        expect(store.isSessionChanging, isTrue);
      });
      final lateClear = store.clearIfCurrent(revision);
      expect(await write, isTrue);
      await endpoint;
      expect(await lateClear, isFalse);
      expect((await store.read())?.sessionId, pair.sessionId);
      expect(store.isSessionChanging, isFalse);
    },
  );

  test(
    'tracked changes synchronously announce intent, remain pending across overlaps, and unsubscribe',
    () async {
      final store = TokenStore(storage: _Storage()),
          one = Completer<void>(),
          two = Completer<void>(),
          events = <String>[];
      final stop = store.listenSessionChanges(
        () => events.add('${store.revision}:${store.isSessionChanging}'),
      );
      final first = store.runSessionChange((_) => one.future),
          second = store.runSessionChange((_) => two.future);
      expect(events, ['1:true', '2:true']);
      one.complete();
      await first;
      expect(store.isSessionChanging, isTrue);
      two.complete();
      await second;
      expect(events, ['1:true', '2:true', '2:true', '2:false']);
      stop();
      store.beginSessionChange();
      expect(events.length, 4);
    },
  );
  for (final fails in [false, true]) {
    test(
      'local clear announces and releases even when storage ${fails ? 'fails' : 'succeeds'}',
      () async {
        final storage = _Storage()..fail = fails,
            store = TokenStore(storage: storage),
            events = <bool>[];
        store.listenSessionChanges(() => events.add(store.isSessionChanging));
        final pending = store.clear();
        expect(store.revision, 1);
        expect(store.isSessionChanging, isTrue);
        if (fails) {
          await expectLater(pending, throwsStateError);
        } else {
          await pending;
        }
        expect(events, [true, false]);
        expect(store.isSessionChanging, isFalse);
      },
    );
  }
  test(
    'stale conditional clear and ordinary token reads do not invalidate a page',
    () async {
      final store = TokenStore(storage: _Storage()),
          other = TokenStore(storage: _Storage()),
          events = <int>[];
      store.listenSessionChanges(() => events.add(store.revision));
      expect(await store.clearIfCurrent(99), isFalse);
      expect(await store.read(), isNull);
      other.beginSessionChange();
      expect(events, isEmpty);
    },
  );
  test(
    'clearIfCurrent is a no-op when no session is stored and notifies when one exists',
    () async {
      final storage = _Storage(),
          store = TokenStore(storage: storage),
          events = <int>[];
      store.listenSessionChanges(() => events.add(store.revision));
      expect(await store.clearIfCurrent(store.revision), isFalse);
      expect(store.revision, 0);
      expect(events, isEmpty);

      const pair = TokenPair(
        accessToken: 'fixture-access',
        refreshToken: 'fixture-refresh',
        sessionId: 'fixture-session',
      );
      await store.write(pair);
      expect(await store.clearIfCurrent(store.revision), isTrue);
      expect(store.revision, 1);
      expect(events, [1, 1]);
      expect(await store.read(), isNull);
    },
  );
  for (final operation in ['login', 'completion', 'logout']) {
    test(
      'actual repository tracks $operation network lifetime and releases failure',
      () async {
        final store = TokenStore(storage: _Storage()),
            api = _Api(),
            repository = AuthRepository(api: api, tokenStore: store);
        final events = <bool>[];
        repository.listenSessionChanges(
          () => events.add(repository.isSessionChanging),
        );
        final Future<Object?> pending = switch (operation) {
          'login' => repository.login(account: 'same-account', password: 'x'),
          'completion' => repository.completeTwoFactor(
            challengeId: 'synthetic',
            code: '123456',
          ),
          _ => repository.logout(),
        };
        expect(repository.isSessionChanging, isTrue);
        expect(repository.sessionRevision, 1);
        expect(events.first, isTrue);
        if (operation == 'logout') {
          api.gate.complete();
          await pending;
        } else {
          final error = expectLater(pending, throwsStateError);
          api.gate.completeError(StateError('isolated network failure'));
          await error;
        }
        expect(repository.isSessionChanging, isFalse);
        expect(events.last, isFalse);
      },
    );
  }
}

class _Storage implements FlutterSecureStorage {
  final _values = <String, String?>{};
  bool fail = false;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    final key = invocation.namedArguments[#key] as String;
    if (invocation.memberName == #read) {
      return Future<String?>.value(_values[key]);
    }
    if (invocation.memberName == #write) {
      _values[key] = invocation.namedArguments[#value] as String?;
      return Future<void>.value();
    }
    if (invocation.memberName == #delete) {
      if (fail) {
        return Future<void>.error(StateError('isolated storage failure'));
      }
      _values.remove(key);
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

const _config = AppConfig(
  apiBaseUrl: 'http://example.test',
  wsBaseUrl: 'ws://example.test',
  storageBaseUrl: 'http://example.test',
);

class _Api extends AuthApi {
  _Api() : super(ApiClient(config: _config, tokenStore: TokenStore()));
  final gate = Completer<void>();
  @override
  Future<V2LoginResult> login({
    required String account,
    required String password,
    bool rememberMe = false,
  }) async {
    await gate.future;
    throw StateError('No synthetic success configured');
  }

  @override
  Future<V2LoginSuccess> completeTwoFactor({
    required String challengeId,
    required String code,
  }) async {
    await gate.future;
    throw StateError('No synthetic success configured');
  }

  @override
  Future<void> logout() => gate.future;
}
