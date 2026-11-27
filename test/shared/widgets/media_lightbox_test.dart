import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/shared/i18n/app_localizations.dart';
import 'package:nekotribe/shared/providers/providers.dart';
import 'package:nekotribe/shared/theme/app_theme.dart';
import 'package:nekotribe/shared/widgets/media_lightbox.dart';

const _testConfig = AppConfig(
  apiBaseUrl: 'https://example.invalid',
  wsBaseUrl: 'wss://example.invalid',
  storageBaseUrl: 'https://example.invalid',
);
const _testBundle = AppConfigBundle(defaults: _testConfig, presets: []);

void main() {
  Widget harness(Widget child, {bool disableAnimations = false}) {
    return ProviderScope(
      overrides: [
        appConfigBundleProvider.overrideWithValue(_testBundle),
        appConfigInitialProvider.overrideWithValue(_testConfig),
      ],
      child: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: const [AppLocalizationsDelegate()],
          supportedLocales: AppLocalizations.supported,
          home: Scaffold(body: child),
        ),
      ),
    );
  }

  testWidgets('showMediaLightbox displays counter, navigates, and dismisses', (
    tester,
  ) async {
    const items = [
      MediaLightboxItem(
        url: 'https://example.invalid/one.png',
        description: 'First photo caption',
      ),
      MediaLightboxItem(
        url: 'https://example.invalid/two.png',
        description: 'Second photo caption',
      ),
    ];

    await tester.pumpWidget(
      harness(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showMediaLightbox(context: context, items: items),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.text('First photo caption'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();

    expect(find.text('2 / 2'), findsOneWidget);
    expect(find.text('Second photo caption'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.text('2 / 2'), findsNothing);
  });

  testWidgets('showMediaLightbox handles Escape key and reduced animations', (
    tester,
  ) async {
    const items = [
      MediaLightboxItem(url: 'https://example.invalid/only.png'),
    ];

    await tester.pumpWidget(
      harness(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showMediaLightbox(context: context, items: items),
            child: const Text('Open'),
          ),
        ),
        disableAnimations: true,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.close), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.close), findsNothing);
  });
}
