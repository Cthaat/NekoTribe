import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nekotribe/shared/routing/tab_transition.dart';

void main() {
  test('only primary locations and static Groups tabs belong to the dock', () {
    for (final (i, tab) in mobilePrimaryTabs.indexed) {
      expect(mobilePrimaryTabIndexOf(tab.$1), i);
    }
    for (final path in [
      '/groups/discover',
      '/groups/my',
      '/groups/invites?invite=1',
    ]) {
      expect(mobilePrimaryTabIndexOf(path), 1);
    }
    for (final path in [
      '/groups/invite',
      '/groups/some-group',
      '/chat/conversation/1',
      '/discover',
    ]) {
      expect(mobilePrimaryTabIndexOf(path), isNull);
    }
  });

  Future<GoRouter> mount(
    WidgetTester tester, {
    double width = 390,
    bool reduced = false,
  }) async {
    tester.view
      ..physicalSize = Size(width, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final tracker = TabTransitionTracker();
    final router = GoRouter(
      initialLocation: '/feed',
      routes: [
        ShellRoute(
          builder: (_, _, child) => child,
          routes: [
            for (final path in [
              ...mobilePrimaryTabs.map((tab) => tab.$1),
              '/groups/my',
            ])
              GoRoute(
                path: path,
                pageBuilder: (context, state) => buildDirectionalTabPage(
                  context,
                  state,
                  tracker,
                  SizedBox.expand(key: ValueKey(path), child: Text(path)),
                ),
              ),
            GoRoute(path: '/outside', builder: (_, _) => const Text('outside')),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    addTearDown(tracker.observe(router));
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
          child: child!,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  Future<void> sample(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 56));
  }

  double dx(WidgetTester tester, String path) =>
      tester.getTopLeft(find.byKey(ValueKey(path))).dx;

  testWidgets(
    'go replacements carry both live screens in opposite directions',
    (tester) async {
      final router = await mount(tester);
      router.go('/notifications');
      await sample(tester);
      expect(dx(tester, '/notifications'), greaterThan(0));
      expect(dx(tester, '/feed'), lessThan(0));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('/feed')), findsNothing);
      router.go('/feed');
      await sample(tester);
      expect(dx(tester, '/feed'), lessThan(0));
      expect(dx(tester, '/notifications'), greaterThan(0));
      await tester.pumpAndSettle();
      expect(dx(tester, '/feed'), 0);
    },
  );

  testWidgets(
    'reversing before the previous go settles changes the old page exit',
    (tester) async {
      final router = await mount(tester);
      router.go('/chat');
      await sample(tester);
      expect(dx(tester, '/chat'), greaterThan(0));
      expect(dx(tester, '/feed'), lessThan(0));
      final interruptedX = dx(tester, '/chat');
      router.go('/groups');
      await tester.pump();
      expect(dx(tester, '/chat'), closeTo(interruptedX, .01));
      await tester.pump(const Duration(milliseconds: 56));
      expect(dx(tester, '/groups'), lessThan(0));
      expect(dx(tester, '/chat'), greaterThan(interruptedX));
      await tester.pumpAndSettle();
      expect(dx(tester, '/groups'), 0);
    },
  );

  testWidgets(
    'pop to a primary tab reverses direction, returning from a detail resets it',
    (tester) async {
      final router = await mount(tester);
      router.push<void>('/chat');
      await tester.pumpAndSettle();
      router.pop();
      await sample(tester);
      expect(dx(tester, '/feed'), lessThan(0));
      expect(dx(tester, '/chat'), greaterThan(0));
      await tester.pumpAndSettle();
      router.push<void>('/outside');
      await tester.pumpAndSettle();
      router.pop();
      await sample(tester);
      expect(dx(tester, '/feed'), 0);
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'pushing the same primary location fades both instances in place',
    (tester) async {
      final router = await mount(tester);
      router.go('/chat');
      await tester.pumpAndSettle();
      router.push<void>('/chat');
      await sample(tester);
      final pages = find.byKey(const ValueKey('/chat'));
      expect(pages, findsNWidgets(2));
      for (final page in [pages.first, pages.last]) {
        expect(tester.getTopLeft(page).dx, 0);
      }
      await tester.pumpAndSettle();
    },
  );

  testWidgets('group sub-tabs fade in place', (tester) async {
    final router = await mount(tester);
    router.go('/groups');
    await tester.pumpAndSettle();
    router.go('/groups/my');
    await sample(tester);
    expect(dx(tester, '/groups'), 0);
    expect(dx(tester, '/groups/my'), 0);
    await tester.pumpAndSettle();
  });

  testWidgets('wide layout fades both screens without horizontal motion', (
    tester,
  ) async {
    final router = await mount(tester, width: 800);
    router.go('/chat');
    await sample(tester);
    expect(dx(tester, '/feed'), 0);
    expect(dx(tester, '/chat'), 0);
    await tester.pumpAndSettle();
  });

  testWidgets('reduced motion replaces the tab without sliding or waiting', (
    tester,
  ) async {
    final router = await mount(tester, reduced: true);
    router.go('/chat');
    await tester.pump();
    await tester.pump();
    expect(dx(tester, '/chat'), 0);
    expect(find.byKey(const ValueKey('/feed')), findsNothing);
  });
}
