import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/features/auth/data/auth_api.dart';
import 'package:nekotribe/features/realtime/data/realtime_service.dart';
import 'package:nekotribe/features/notifications/data/notifications_api.dart';
import 'package:nekotribe/shared/providers/providers.dart';

const config = AppConfig(
  apiBaseUrl: 'http://example.test',
  wsBaseUrl: 'ws://example.test',
  storageBaseUrl: 'http://example.test',
);

class Store extends TokenStore {
  TokenPair? pair = const TokenPair(
    accessToken: 'old',
    refreshToken: 'r',
    sessionId: 'old',
  );
  final readGate = Completer<TokenPair?>();
  bool gateRead = false;
  @override
  Future<TokenPair?> read() async => gateRead ? readGate.future : pair;
  @override
  Future<bool> clearIfCurrent(int expected) async {
    if (revision != expected) return false;
    beginSessionChange();
    pair = null;
    return true;
  }
}

class Api extends AuthApi {
  Api(Store store) : super(ApiClient(config: config, tokenStore: store));
  final reset = Completer<void>();
  final pendingLogout = Completer<void>();
  @override
  Future<void> logout() => pendingLogout.future;
  @override
  Future<void> requestPasswordReset({
    required String email,
    required String verificationId,
    required String code,
    required String newPassword,
  }) => reset.future;
}

class Notifications extends NotificationsApi {
  Notifications(Store store)
    : super(ApiClient(config: config, tokenStore: store));
  final result = Completer<int>();
  @override
  Future<int> unreadCount() => result.future;
}

class Realtime extends RealtimeService {
  Realtime(Store store) : super(config: config, tokenStore: store);
  final started = Completer<void>(), gate = Completer<void>();
  bool wait = false;
  int calls = 0;
  @override
  Future<void> disconnect() async {
    calls++;
    if (!started.isCompleted) started.complete();
    if (wait) await gate.future;
  }
}

void main() {
  test(
    'old unread request cannot overwrite explicit reset or newer session state',
    () async {
      final store = Store(), api = Notifications(Store());
      final container = ProviderContainer(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          notificationsApiProvider.overrideWithValue(api),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(notificationsUnreadProvider.notifier),
          pending = container
              .read(notificationsUnreadProvider.notifier)
              .refresh();
      controller.set(0);
      api.result.complete(9);
      await pending;
      expect(container.read(notificationsUnreadProvider), 0);
    },
  );
  for (final logout in [false, true]) {
    test(
      'new login during ${logout ? 'logout' : 'reset'} teardown preserves global state',
      () async {
        final store = Store(),
            api = Api(Store()),
            realtime = Realtime(Store())..wait = true;
        final container = ProviderContainer(
          overrides: [
            tokenStoreProvider.overrideWithValue(store),
            authApiProvider.overrideWithValue(api),
            realtimeServiceProvider.overrideWithValue(realtime),
          ],
        );
        addTearDown(container.dispose);
        final controller = container.read(authSessionProvider.notifier);
        await Future<void>.delayed(Duration.zero);
        controller.markLoggedIn();
        container.read(notificationsUnreadProvider.notifier).set(7);
        final repository = container.read(authRepositoryProvider);
        final Future<Object?> pending = logout
            ? repository.logout()
            : repository.requestPasswordReset(
                email: 'synthetic@example.test',
                verificationId: 'otp',
                code: '123456',
                newPassword: 'synthetic',
              );
        final completed = logout
            ? pending.then<void>((result) {
                expect(result, isNull);
              })
            : expectLater(pending, throwsStateError);
        if (logout) {
          api.pendingLogout.complete();
        } else {
          api.reset.complete();
        }
        await realtime.started.future;
        store.beginSessionChange();
        store.pair = const TokenPair(
          accessToken: 'new',
          refreshToken: 'r',
          sessionId: 'new',
        );
        controller.markLoggedIn();
        container.read(notificationsUnreadProvider.notifier).set(11);
        realtime.gate.complete();
        await completed;
        expect(store.pair!.sessionId, 'new');
        expect(container.read(authSessionProvider).isAuthenticated, true);
        expect(container.read(notificationsUnreadProvider), 11);
      },
    );
  }
  test('hydration completing after provider disposal is ignored', () async {
    final store = Store()..gateRead = true;
    final container = ProviderContainer(
      overrides: [tokenStoreProvider.overrideWithValue(store)],
    );
    container.read(authSessionProvider);
    container.dispose();
    store.readGate.complete(null);
    await Future<void>.delayed(Duration.zero);
  });
  for (final loggedIn in [true, false]) {
    test(
      'late initial hydration cannot overwrite explicit ${loggedIn ? 'login' : 'logout'}',
      () async {
        final store = Store()..gateRead = true;
        final container = ProviderContainer(
          overrides: [tokenStoreProvider.overrideWithValue(store)],
        );
        final controller = container.read(authSessionProvider.notifier);
        if (loggedIn) {
          controller.markLoggedIn();
        } else {
          controller.markLoggedOut();
        }
        store.readGate.complete(loggedIn ? null : store.pair);
        await Future<void>.delayed(Duration.zero);
        expect(container.read(authSessionProvider).isAuthenticated, loggedIn);
        container.dispose();
      },
    );
  }
  test(
    'real provider reset clears auth and unread state and disconnects',
    () async {
      final store = Store(), api = Api(Store()), realtime = Realtime(Store());
      final container = ProviderContainer(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          authApiProvider.overrideWithValue(api),
          realtimeServiceProvider.overrideWithValue(realtime),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(authSessionProvider.notifier);
      await Future<void>.delayed(Duration.zero);
      controller.markLoggedIn();
      container.read(notificationsUnreadProvider.notifier).set(7);
      final pending = container
          .read(authRepositoryProvider)
          .requestPasswordReset(
            email: 'synthetic@example.test',
            verificationId: 'otp',
            code: '123456',
            newPassword: 'synthetic',
          );
      api.reset.complete();
      await pending;
      expect(store.pair, isNull);
      expect(container.read(authSessionProvider).isAuthenticated, false);
      expect(container.read(notificationsUnreadProvider), 0);
      expect(realtime.calls, 1);
    },
  );
}
