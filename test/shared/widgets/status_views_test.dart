import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nekotribe/core/network/api_exception.dart';
import 'package:nekotribe/shared/i18n/app_localizations.dart';
import 'package:nekotribe/shared/widgets/status_views.dart';

void main() {
  Widget wrapError(Object error) {
    return MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: const [
        AppLocalizationsDelegate(),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supported,
      home: Scaffold(body: ErrorView(error: error)),
    );
  }

  testWidgets(
    'ErrorView maps browser connection errors to compact mobile-safe copy',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        wrapError(
          'DioException [connection error]: '
          'The connection errored: XMLHttpRequest onError callback '
          'was called. This indicates an error on the network layer.',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('XMLHttpRequest'), findsNothing);
      expect(find.text('无法连接到服务，请确认后端入口已启动后重试。'), findsOneWidget);
    },
  );

  testWidgets(
    'ErrorView maps 401 ApiException to unauthorized copy without code',
    (tester) async {
      await tester.pumpWidget(
        wrapError(
          ApiException(code: 40101, statusCode: 401, message: 'x'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('登录已失效，请重新登录'), findsOneWidget);
      expect(find.textContaining('[40101]'), findsNothing);
    },
  );

  testWidgets(
    'ErrorView maps 404 ApiException to not_found copy without code',
    (tester) async {
      await tester.pumpWidget(
        wrapError(
          ApiException(code: 40401, statusCode: 404, message: 'nope'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('内容不存在或已删除'), findsOneWidget);
      expect(find.textContaining('[40401]'), findsNothing);
    },
  );

  testWidgets('EmptyView optional action invokes onAction when tapped', (
    tester,
  ) async {
    var actionTapped = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EmptyView(
            message: 'Nothing here yet',
            actionLabel: 'Refresh',
            onAction: () => actionTapped = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Nothing here yet'), findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);
    expect(actionTapped, isFalse);

    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();

    expect(actionTapped, isTrue);
  });
}
