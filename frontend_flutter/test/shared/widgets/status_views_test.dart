import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nekotribe/shared/i18n/app_localizations.dart';
import 'package:nekotribe/shared/widgets/status_views.dart';

void main() {
  testWidgets(
    'ErrorView maps browser connection errors to compact mobile-safe copy',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supported,
          home: const Scaffold(
            body: ErrorView(
              error:
                  'DioException [connection error]: '
                  'The connection errored: XMLHttpRequest onError callback '
                  'was called. This indicates an error on the network layer.',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('XMLHttpRequest'), findsNothing);
      expect(find.text('无法连接到服务，请确认后端入口已启动后重试。'), findsOneWidget);
    },
  );
}
