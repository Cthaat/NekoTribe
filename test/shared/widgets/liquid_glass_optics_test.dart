import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/shared/widgets/glass/liquid_glass_shader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'translated lens bends its rim and samples the original center',
    () async {
      const size = 240;
      final backdrop = ui.PictureRecorder();
      final source = ui.Canvas(backdrop);
      source.drawColor(const ui.Color(0xff000000), ui.BlendMode.src);
      // Horizontal bars mark the inward sample and an unchanged center detail.
      for (final y in [168.0, 180.0]) {
        source.drawRect(
          ui.Rect.fromLTWH(0, y, size.toDouble(), 5),
          ui.Paint()..color = const ui.Color(0xffffffff),
        );
      }
      final background = backdrop.endRecording();
      final image = await background.toImage(size, size);
      final program = await ui.FragmentProgram.fromAsset(
        LiquidGlassShaderCache.asset,
      );
      final shader = program.fragmentShader()
        ..setImageSampler(0, image)
        ..setFloat(0, size.toDouble())
        ..setFloat(1, size.toDouble())
        ..setFloat(2, 12)
        ..setFloat(3, 6)
        ..setFloat(4, 5)
        ..setFloat(5, 0)
        ..setFloat(6, 20)
        ..setFloat(7, 160)
        ..setFloat(8, 60)
        ..setFloat(9, 24)
        ..setFloat(10, 2)
        ..setFloat(11, 0)
        ..setFloat(12, 0)
        ..setFloat(13, 2)
        ..setFloat(14, 1);
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawRect(
        const ui.Rect.fromLTWH(0, 0, 240, 240),
        ui.Paint()..shader = shader,
      );
      final picture = recorder.endRecording();
      final result = await picture.toImage(size, size);
      final bytes = (await result.toByteData())!;
      int red(int x, int y) => bytes.getUint8((y * size + x) * 4);
      expect(
        red(80, 162),
        greaterThan(240),
        reason: 'top edge bends the first bar',
      );
      expect(red(80, 181), 255, reason: 'flat center preserves the second bar');
      expect(red(80, 185), 0, reason: 'the center detail stays sharp');
      expect(red(8, 162), 0, reason: 'outside lens samples its own backdrop');
      result.dispose();
      picture.dispose();
      shader.dispose();
      image.dispose();
      background.dispose();
    },
  );
}
