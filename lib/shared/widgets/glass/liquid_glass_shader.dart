import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

abstract final class LiquidGlassShaderCache {
  static const asset = 'shaders/liquid_glass.frag';
  static Future<ui.FragmentProgram?>? _program;

  static bool get isSupported =>
      !kIsWeb && ui.ImageFilter.isShaderFilterSupported;

  static Future<ui.FragmentProgram?> load() => _program ??= _load();

  static Future<ui.FragmentProgram?> _load() async {
    if (!isSupported) return null;
    try {
      return await ui.FragmentProgram.fromAsset(asset);
    } on UnsupportedError {
      return null;
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'liquid glass',
          context: ErrorDescription('while loading $asset'),
        ),
      );
      rethrow;
    }
  }
}
