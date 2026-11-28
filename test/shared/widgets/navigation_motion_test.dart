import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/shared/theme/app_theme.dart';
import 'package:nekotribe/shared/widgets/glass/liquid_glass_bars.dart';
import 'package:nekotribe/shared/widgets/glass/liquid_glass_shader.dart';
import 'package:nekotribe/shared/widgets/glass/liquid_glass_surface.dart';
import 'package:nekotribe/shared/widgets/glass/liquid_glass_tokens.dart';

final _lens = find.byKey(const ValueKey('segment-lens'));
final _opacity = find.byKey(const ValueKey('header-glass-opacity'));
const _options = [(0, 'One'), (1, 'Two'), (2, 'Three')];

Widget _segments(ValueNotifier<int> value) => SizedBox(
  width: 301,
  child: ValueListenableBuilder<int>(
    valueListenable: value,
    builder: (_, selected, _) => LiquidGlassSegmentedControl<int>(
      options: _options,
      selected: selected,
      onSelect: (index) => value.value = index,
    ),
  ),
);

void main() {
  for (final direction in TextDirection.values) {
    testWidgets('scrub, snap and external selection in ${direction.name}', (t) async {
      final value = ValueNotifier(0);
      addTearDown(value.dispose);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetDevicePixelRatio);
      final body = Material(child: Center(child: _segments(value)));
      await t.pumpWidget(
        MaterialApp(
          home: Directionality(textDirection: direction, child: body),
        ),
      );
      final first = find.text('One');
      final second = find.text('Two');
      final last = find.text('Three');
      Color color(Finder label) => t.widget<Text>(label).style!.color!;
      void aligned(Finder label) =>
          expect((t.getCenter(_lens) - t.getCenter(label)).distance, lessThanOrEqualTo(0.5));
      aligned(first);
      final active = color(first);
      final idle = color(second);
      final start = t.getCenter(first);
      final step = t.getCenter(second) - start;
      final pointer = await t.startGesture(start);
      await pointer.moveBy(step * 0.25);
      await pointer.moveTo(start + step * 0.55);
      await t.pump();
      for (final label in [first, second]) {
        expect(color(label), isNot(isIn([active, idle])));
      }
      await pointer.moveTo(t.getCenter(last));
      await pointer.up();
      await t.pumpAndSettle();
      expect(value.value, 2);
      aligned(last);
      value.value = 0;
      await t.pumpAndSettle();
      aligned(first);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(value.value, 1);
      aligned(second);
    });
  }

  for (final dark in [false, true]) {
    for (final intensity in LiquidGlassIntensity.values) {
      for (final width in [390.0, 1200.0]) {
        for (final reduced in [false, true]) {
          for (final contrast in [false, true]) {
            final name = 'dark=$dark ${intensity.name} w=$width reduced=$reduced contrast=$contrast';
            testWidgets(name, (t) => _checkHeader(t, dark, intensity, width, reduced, contrast));
          }
        }
      }
    }
  }
}

Future<void> _checkHeader(WidgetTester t, bool dark, LiquidGlassIntensity intensity,
    double width, bool reduced, bool contrast) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = Size(width, 800);
  addTearDown(t.view.reset);
  final value = ValueNotifier(0);
  final scroll = ScrollController();
  addTearDown(value.dispose);
  addTearDown(scroll.dispose);
  final theme = (dark ? AppTheme.dark : AppTheme.light)(AppTheme.defaultSeedColor, intensity);
  await t.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced, highContrast: contrast),
          child: Scaffold(
            appBar: LiquidGlassAppBar(automaticallyImplyLeading: false, title: _segments(value)),
            body: ListView(controller: scroll, children: const [SizedBox(height: 2400)]),
          ),
        ),
      ),
    ),
  );
  double alpha() => t.widget<Opacity>(_opacity).opacity;
  expect(alpha(), 0);
  scroll.jumpTo(8);
  await t.pumpAndSettle();
  final partial = alpha();
  expect(partial, inExclusiveRange(0.0, 1.0));
  scroll.jumpTo(200);
  await t.pumpAndSettle();
  expect(alpha(), greaterThan(partial));
  final surface = find.descendant(of: _opacity, matching: find.byType(LiquidGlassSurface));
  final preset = t.widget<LiquidGlassSurface>(surface).preset;
  expect(preset, LiquidGlassPreset.stickyHeader);
  final spec = LiquidGlassSpec.resolve(preset, theme.colorScheme, intensity);
  final tint = find.descendant(of: surface, matching: find.byType(ColoredBox));
  final expectedAlpha = spec.tintColor.a + (contrast ? 0.22 : 0) + (reduced ? 0.015 : 0);
  expect(t.widget<ColoredBox>(tint.first).color.a, closeTo(expectedAlpha, 0.001));
  expect(t.getSize(tint.last).height, 1.0);
  if (!spec.enableRefraction || !LiquidGlassShaderCache.isSupported) {
    final backdrop = find.descendant(of: surface, matching: find.byType(BackdropFilter));
    expect(
      t.widget<BackdropFilter>(backdrop).filter,
      ui.ImageFilter.compose(
        outer: ui.ColorFilter.matrix(saturationColorMatrix(spec.saturation)),
        inner: ui.ImageFilter.blur(sigmaX: spec.blurSigma, sigmaY: spec.blurSigma, tileMode: TileMode.clamp),
      ),
    );
  }
  value.value = 2;
  await t.pump();
  final gap = (t.getCenter(_lens) - t.getCenter(find.text('Three'))).distance;
  expect(gap, reduced ? lessThanOrEqualTo(0.5) : greaterThan(1));
  await t.pumpAndSettle();
  scroll.jumpTo(0);
  await t.pumpAndSettle();
  expect(alpha(), 0);
}
