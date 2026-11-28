import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> checkMediaFlight(WidgetTester tester) async {
  final source = find.byWidgetPredicate((w) => w is Hero && w.tag is (BuildContext, int)).first;
  final tag = tester.widget<Hero>(source).tag;
  final matches = find.byWidgetPredicate((w) => w is Hero && w.tag == tag, skipOffstage: false);
  await tester.ensureVisible(source);
  await tester.tap(source);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 80));
  expect(matches, findsNWidgets(2));
  expect(find.descendant(of: matches, matching: find.byType(Offstage), skipOffstage: false), findsWidgets);
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(Icons.close));
  await tester.pumpAndSettle();
  expect(matches, findsOneWidget);
}
