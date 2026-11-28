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

  testWidgets('tagged thumbnail flies to preview, drag returns and zoom springs', (tester) async {
    const photo = MediaLightboxItem(url: 'https://example.invalid/one.png', heroTag: 'photo');
    await tester.pumpWidget(harness(Builder(builder: (context) => Center(
      child: GestureDetector(onTap: () => showMediaLightbox(context: context, items: [photo]),
        child: const Hero(tag: 'photo', child: SizedBox.square(dimension: 40, child: Icon(Icons.image))))))));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.image));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    final heroes = find.byWidgetPredicate((w) => w is Hero && w.tag == 'photo', skipOffstage: false);
    expect(heroes, findsNWidgets(2));
    expect(find.descendant(of: heroes, matching: find.byType(Offstage), skipOffstage: false), findsWidgets);
    await tester.pumpAndSettle();
    final viewer = find.byType(InteractiveViewer);
    final center = tester.getCenter(viewer);
    final drag = await tester.startGesture(center);
    await drag.moveBy(const Offset(0, 24));
    await drag.moveBy(const Offset(0, 44));
    await tester.pump();
    expect(tester.getCenter(viewer).dy, greaterThan(center.dy));
    await tester.pump(const Duration(milliseconds: 180));
    await drag.up();
    await tester.pumpAndSettle();
    expect(tester.getCenter(viewer), center);
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 70));
    await tester.tapAt(center);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    final zoom = tester.widget<InteractiveViewer>(viewer).transformationController!;
    expect(zoom.value.getMaxScaleOnAxis(), inExclusiveRange(1, 2.2));
    await tester.pumpAndSettle();
    expect(zoom.value.getMaxScaleOnAxis(), closeTo(2.2, 0.001));
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.image), findsOneWidget);
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
