import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/shared/routing/detail_page.dart';
import 'package:nekotribe/shared/theme/app_theme.dart';
import 'package:nekotribe/shared/widgets/glass/liquid_glass_overlays.dart';
import 'package:nekotribe/shared/widgets/glass/liquid_glass_surface.dart';
import 'package:nekotribe/shared/widgets/glass/liquid_glass_tokens.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final intensity in LiquidGlassIntensity.values) {
      for (final width in [390.0, 1200.0]) {
        for (final reduced in [false, true]) {
          for (final contrast in [false, true]) {
            testWidgets('overlays $brightness $intensity ${width}px reduced=$reduced contrast=$contrast', (tester) async {
              await tester.binding.setSurfaceSize(Size(width, 800));
              addTearDown(() => tester.binding.setSurfaceSize(null));
              final theme = brightness == Brightness.dark ? AppTheme.dark : AppTheme.light;
              await tester.pumpWidget(MaterialApp(
                theme: theme(AppTheme.defaultSeedColor, intensity),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(disableAnimations: reduced, highContrast: contrast),
                  child: child!,
                ),
                home: Scaffold(body: Builder(builder: (context) => Column(children: [
                  LiquidGlassFab(label: 'Create', icon: Icons.add, onPressed: () => showLiquidGlassDialog<void>(
                    context: context, builder: (_) => const LiquidGlassAlertContent(title: Text('Create'), content: Text('Preview')))),
                  TextButton(onPressed: () => showLiquidGlassBottomSheet<void>(context: context,
                    builder: (_) => const SizedBox(height: 200, child: Center(child: Text('Channels')))), child: const Text('Sheet')),
                  TextButton(onPressed: () => ScaffoldMessenger.of(context).showSnackBar(liquidGlassSnackBar(context, 'Saved')),
                    child: const Text('Toast')),
                ]))),
              ));
              await tester.tap(find.byTooltip('Create'));
              await tester.pumpAndSettle();
              final dialog = find.byType(Dialog);
              expect(tester.getSize(dialog).width, lessThanOrEqualTo(width));
              final route = ModalRoute.of(tester.element(find.text('Preview')))!;
              expect(route.transitionDuration == Duration.zero, reduced);
              await tester.tapAt(const Offset(6, 6));
              await tester.pumpAndSettle();
              expect(dialog, findsNothing);
              await tester.tap(find.text('Sheet'));
              await tester.pumpAndSettle();
              final channels = find.text('Channels');
              final position = tester.getCenter(channels);
              final drag = await tester.startGesture(position);
              await drag.moveBy(const Offset(0, 22));
              await drag.moveBy(const Offset(0, 34));
              await tester.pump();
              expect(tester.getCenter(channels).dy, greaterThan(position.dy));
              await tester.pump(const Duration(milliseconds: 150));
              await drag.up();
              await tester.pumpAndSettle();
              expect(tester.getCenter(channels), position);
              await tester.drag(channels, const Offset(0, 180));
              await tester.pumpAndSettle();
              expect(channels, findsNothing);
              await tester.tap(find.text('Toast'));
              await tester.pumpAndSettle();
              final toast = tester.widget<SnackBar>(find.byType(SnackBar));
              expect(toast.behavior, SnackBarBehavior.floating);
              expect(find.descendant(of: find.byType(SnackBar), matching: find.byType(LiquidGlassSurface)), findsOneWidget);
              final scheme = Theme.of(tester.element(find.text('Saved'))).colorScheme;
              final ink = tester.widget<Text>(find.text('Saved')).style!.color!;
              final tint = LiquidGlassSpec.resolve(LiquidGlassPreset.popover, scheme, intensity).tintColor;
              final backdrop = brightness == Brightness.light ? Colors.black : Colors.white;
              final fill = Color.alphaBlend(scheme.surface.withValues(alpha: 0.64), Color.alphaBlend(tint, backdrop));
              final a = ink.computeLuminance(), b = fill.computeLuminance();
              expect((a > b ? (a + 0.05) / (b + 0.05) : (b + 0.05) / (a + 0.05)), greaterThanOrEqualTo(4.5));
              expect(tester.takeException(), isNull);
            });
          }
        }
      }
    }
  }

  testWidgets('reduced detail route opens and closes without transition frames', (tester) async {
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
      home: Builder(builder: (context) => TextButton(
        onPressed: () => Navigator.of(context).push(const DetailPage(key: ValueKey('detail'),
          child: Scaffold(body: Text('Preview'))).createRoute(context)), child: const Text('Open')))));
    await tester.tap(find.text('Open'));
    await tester.pump();
    final context = tester.element(find.text('Preview'));
    final route = ModalRoute.of(context)!;
    expect(route.transitionDuration, Duration.zero);
    expect(route.reverseTransitionDuration, Duration.zero);
    Navigator.pop(context);
    await tester.pumpAndSettle();
    expect(find.text('Preview'), findsNothing);
  });

  if (kIsWeb) return;
  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets('edge drag tracks and pops on $platform', (tester) async {
      await tester.pumpWidget(MaterialApp(theme: ThemeData(platform: platform),
        home: Builder(builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(const DetailPage(
            key: ValueKey('detail'), child: Scaffold(body: Center(child: Text('Detail')))).createRoute(context)),
          child: const Text('Open')))));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final detail = find.text('Detail');
      final center = tester.getCenter(detail);
      final cancel = await tester.startGesture(Offset(1, center.dy));
      await cancel.moveBy(const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 200));
      await cancel.up();
      await tester.pumpAndSettle();
      expect(tester.getCenter(detail), center);
      final drag = await tester.startGesture(Offset(1, center.dy));
      await drag.moveBy(const Offset(24, 0));
      await drag.moveBy(Offset(center.dx * 1.4, 0));
      await tester.pump();
      expect(tester.getCenter(detail).dx, greaterThan(center.dx));
      await drag.up();
      await tester.pumpAndSettle();
      expect(detail, findsNothing);
    });
  }
}
