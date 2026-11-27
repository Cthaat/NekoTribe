import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/features/notifications/data/notifications_api.dart';
import 'package:nekotribe/features/realtime/data/realtime_service.dart';
import 'package:nekotribe/shared/i18n/app_localizations.dart';
import 'package:nekotribe/shared/providers/providers.dart';
import 'package:nekotribe/shared/routing/app_shell.dart';
import 'package:nekotribe/shared/widgets/glass/liquid_glass_bars.dart';

void main() {
  GoRouter buildRouter({String initialLocation = '/feed'}) {
    return GoRouter(
      initialLocation: initialLocation,
      routes: [
        ShellRoute(
          builder: (context, state, child) => AppShell(child: child),
          routes: [
            GoRoute(
              path: '/feed',
              builder: (_, __) => const Text('feed route'),
            ),
            GoRoute(
              path: '/discover',
              builder: (_, __) => const Text('discover route'),
            ),
            GoRoute(
              path: '/groups',
              builder: (_, __) => const Text('groups route'),
            ),
            GoRoute(
              path: '/notifications',
              builder: (_, __) => const Text('notifications route'),
            ),
          ],
        ),
        GoRoute(
          path: '/meow',
          builder: (_, __) => const Text('compose post route'),
        ),
        GoRoute(
          path: '/account/profile',
          builder: (_, __) => const Text('profile edit route'),
        ),
      ],
    );
  }

  testWidgets('desktop discover keeps shell compose button', (tester) async {
    tester.view
      ..physicalSize = const Size(1200, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final router = buildRouter(initialLocation: '/discover');
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: const [AppLocalizationsDelegate()],
          supportedLocales: AppLocalizations.supported,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('discover route'), findsOneWidget);
    expect(find.byKey(const Key('app-shell-compose-button')), findsOneWidget);
  });

  testWidgets('mobile discover hides bottom navigation bar', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final router = buildRouter(initialLocation: '/discover');
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: const [AppLocalizationsDelegate()],
          supportedLocales: AppLocalizations.supported,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('discover route'), findsOneWidget);
    expect(find.byType(LiquidGlassNavDock), findsNothing);
  });

  testWidgets('desktop publish button opens the post composer route', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(1200, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final router = buildRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: const [AppLocalizationsDelegate()],
          supportedLocales: AppLocalizations.supported,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('app-shell-compose-button')));
    await tester.pumpAndSettle();

    expect(find.text('compose post route'), findsOneWidget);
    expect(find.text('profile edit route'), findsNothing);
  });

  testWidgets('desktop notifications nav shows unread badge count', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(1200, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final router = buildRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notificationsUnreadProvider.overrideWith(
            (ref) => NotificationsUnreadController(ref)..set(3),
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: const [AppLocalizationsDelegate()],
          supportedLocales: AppLocalizations.supported,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Badge), findsWidgets);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('notification events and recovery refresh the badge on feed', (
    tester,
  ) async {
    final router = buildRouter();
    addTearDown(router.dispose);
    final store = _BadgeSession();
    final socket = _BadgeRealtime(store);
    final alternate = _BadgeRealtime(store);
    final api = _BadgeNotifications(store);
    addTearDown(socket.dispose);
    addTearDown(alternate.dispose);
    final selectedSocket = StateProvider<RealtimeService>((_) => socket);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          realtimeServiceProvider.overrideWith(
            (ref) => ref.watch(selectedSocket),
          ),
          notificationsApiProvider.overrideWithValue(api),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('feed route'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(api.reads, 1);

    api.count = 7;
    socket.emit('notification_created');
    socket.emit('notification_restored');
    socket.recovered.add(1);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(find.text('7'), findsOneWidget);
    expect(api.reads, 2);

    final switching = Completer<void>();
    final transition = store.runSessionChange((_) => switching.future);
    socket.emit('notification_deleted');
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('7'), findsNothing);
    expect(api.reads, 2);
    api.count = 9;
    switching.complete();
    await transition;
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(find.text('9'), findsOneWidget);
    expect(api.reads, 3);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(AppShell)),
    );
    container.read(selectedSocket.notifier).state = alternate;
    socket.emit('notification_created');
    await tester.pump();
    expect(find.text('9'), findsNothing);

    api.count = 11;
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(find.text('11'), findsOneWidget);
    expect(api.reads, 4);
  });

  testWidgets('mobile bottom nav shows groups destination', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final router = buildRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          locale: const Locale('zh'),
          routerConfig: router,
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supported,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('群组'), findsOneWidget);
    expect(find.byType(LiquidGlassNavDock), findsOneWidget);

    await tester.tap(find.text('群组'));
    await tester.pumpAndSettle();

    expect(find.text('groups route'), findsOneWidget);
  });

  testWidgets('shell opens groups as selected primary tab on mobile', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final router = GoRouter(
      initialLocation: '/groups',
      routes: [
        ShellRoute(
          builder: (context, state, child) => AppShell(child: child),
          routes: [
            GoRoute(path: '/feed', builder: (_, __) => const Text('feed')),
            GoRoute(path: '/groups', builder: (_, __) => const Text('groups')),
            GoRoute(
              path: '/notifications',
              builder: (_, __) => const Text('notifications'),
            ),
            GoRoute(path: '/chat', builder: (_, __) => const Text('chat')),
            GoRoute(path: '/me', builder: (_, __) => const Text('me')),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          locale: const Locale('zh'),
          routerConfig: router,
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supported,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('groups'), findsOneWidget);
    expect(find.byType(LiquidGlassNavDock), findsOneWidget);
  });
}

const _badgeConfig = AppConfig(
  apiBaseUrl: 'http://example.test',
  wsBaseUrl: 'ws://example.test',
  storageBaseUrl: 'http://example.test',
);

class _BadgeSession extends TokenStore {
  @override
  Future<TokenPair?> read() async => const TokenPair(
    accessToken: 'test-token',
    refreshToken: 'test-refresh',
    sessionId: 'test-session',
  );
}

class _BadgeNotifications extends NotificationsApi {
  _BadgeNotifications(TokenStore store)
    : super(ApiClient(config: _badgeConfig, tokenStore: store));

  int reads = 0;
  int count = 3;

  @override
  Future<int> unreadCount() async {
    reads++;
    return count;
  }
}

class _BadgeRealtime extends RealtimeService {
  _BadgeRealtime(TokenStore store)
    : super(config: _badgeConfig, tokenStore: store);

  final recovered = StreamController<int>.broadcast(sync: true);
  final listeners = <RealtimeListener>{};

  @override
  Stream<int> get recovery => recovered.stream;

  @override
  Future<void> connect() async {}

  @override
  void addListener(RealtimeListener listener) => listeners.add(listener);

  @override
  void removeListener(RealtimeListener listener) => listeners.remove(listener);

  void emit(String type) {
    for (final listener in listeners.toList()) {
      listener({'type': type});
    }
  }

  @override
  Future<void> dispose() async {
    await recovered.close();
    await super.dispose();
  }
}
