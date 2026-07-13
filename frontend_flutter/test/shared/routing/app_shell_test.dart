import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nekotribe/shared/i18n/app_localizations.dart';
import 'package:nekotribe/shared/providers/providers.dart';
import 'package:nekotribe/shared/routing/app_shell.dart';

void main() {
  GoRouter buildRouter() {
    return GoRouter(
      initialLocation: '/feed',
      routes: [
        ShellRoute(
          builder: (context, state, child) => AppShell(child: child),
          routes: [
            GoRoute(
              path: '/feed',
              builder: (_, __) => const Text('feed route'),
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
    expect(find.byType(NavigationBar), findsOneWidget);

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
    expect(find.byType(NavigationBar), findsOneWidget);
  });
}
