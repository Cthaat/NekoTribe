import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nekotribe/features/users/presentation/about_screen.dart';

void main() {
  testWidgets('about presents the current assistants and opens their routes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const AboutScreen()),
        GoRoute(
          path: '/ai/knowledge',
          builder: (_, _) => const Scaffold(body: Text('Knowledge route')),
        ),
        GoRoute(
          path: '/ai/writing',
          builder: (_, _) => const Scaffold(body: Text('Writing route')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(find.text('SentimentFlow'), findsNothing);
    await tester.ensureVisible(find.text('知识问答'));
    await tester.tap(find.text('知识问答'));
    await tester.pumpAndSettle();
    expect(find.text('Knowledge route'), findsOneWidget);

    router.pop();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('AI 写作'));
    await tester.tap(find.text('AI 写作'));
    await tester.pumpAndSettle();
    expect(find.text('Writing route'), findsOneWidget);
  });
}
