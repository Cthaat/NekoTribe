import 'package:flutter/material.dart';
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
}
