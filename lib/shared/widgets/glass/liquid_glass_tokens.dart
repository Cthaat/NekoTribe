import 'package:flutter/material.dart';

enum LiquidGlassIntensity { standard, subtle }

enum LiquidGlassPreset {
  navDock,
  stickyHeader,
  floatingIsland,
  iconButton,
  popover,
  pillIndicator,
}

@immutable
class LiquidGlassSpec {
  const LiquidGlassSpec._({
    required this.blurSigma,
    required this.saturation,
    required this.tintColor,
    required this.topSheenAlpha,
    required this.rimTopAlpha,
    required this.rimBottomAlpha,
    required this.rimStrokeWidth,
    required this.bezelWidth,
    required this.refractionPx,
    required this.aberrationPx,
    required this.enableShadow,
    required this.enableRefraction,
  });

  factory LiquidGlassSpec.resolve(
    LiquidGlassPreset preset,
    ColorScheme scheme,
    LiquidGlassIntensity intensity,
  ) {
    final isDark = scheme.brightness == Brightness.dark;
    final subtle = intensity == LiquidGlassIntensity.subtle;
    final (
      lightAlpha,
      darkAlpha,
      bezel,
      refraction,
      aberration,
      shadow,
    ) = switch (preset) {
      LiquidGlassPreset.navDock => (0.43, 0.32, 16.0, 12.0, 1.5, true),
      LiquidGlassPreset.stickyHeader => (0.64, 0.46, 8.0, 4.0, 0.5, false),
      LiquidGlassPreset.floatingIsland => (0.56, 0.38, 12.0, 7.0, 0.8, true),
      LiquidGlassPreset.iconButton => (0.58, 0.40, 8.0, 5.0, 0.6, true),
      LiquidGlassPreset.popover => (0.66, 0.56, 10.0, 6.0, 0.7, true),
      LiquidGlassPreset.pillIndicator => (0.16, 0.58, 0.0, 0.0, 0.0, false),
    };
    final pill = preset == LiquidGlassPreset.pillIndicator;
    final sticky = preset == LiquidGlassPreset.stickyHeader;
    final tint = pill
        ? (isDark
              ? Color.lerp(const Color(0xFF0E263E), scheme.primary, 0.24)!
              : scheme.primary)
        : Color.lerp(
            isDark ? const Color(0xFF141820) : const Color(0xFFFAFCFF),
            scheme.primary,
            isDark ? 0.035 : 0.02,
          )!;
    return LiquidGlassSpec._(
      blurSigma: preset == LiquidGlassPreset.navDock
          ? (subtle ? 8 : 3)
          : sticky
          ? 20
          : subtle
          ? 16
          : 22,
      saturation: subtle
          ? 1.25
          : isDark
          ? 1.72
          : 1.62,
      tintColor: tint.withValues(alpha: isDark ? darkAlpha : lightAlpha),
      topSheenAlpha: sticky
          ? 0.0
          : pill
          ? (isDark ? 0.14 : 0.48)
          : isDark
          ? 0.11
          : 0.42,
      rimTopAlpha: sticky ? 0.0 : (isDark ? 0.34 : 0.88),
      rimBottomAlpha: sticky ? 0.0 : (isDark ? 0.18 : 0.52),
      rimStrokeWidth: sticky ? 0.0 : 1.1,
      bezelWidth: bezel,
      refractionPx: refraction,
      aberrationPx: aberration,
      enableShadow: shadow,
      enableRefraction: !subtle && !pill,
    );
  }

  final double blurSigma;
  final double saturation;
  final Color tintColor;
  final double topSheenAlpha;
  final double rimTopAlpha;
  final double rimBottomAlpha;
  final double rimStrokeWidth;
  final double bezelWidth;
  final double refractionPx;
  final double aberrationPx;
  final bool enableShadow;
  final bool enableRefraction;
}

List<double> saturationColorMatrix(double saturation) {
  final inverse = 1 - saturation;
  final r = inverse * 0.2126;
  final g = inverse * 0.7152;
  final b = inverse * 0.0722;
  return [
    r + saturation,
    g,
    b,
    0,
    0,
    r,
    g + saturation,
    b,
    0,
    0,
    r,
    g,
    b + saturation,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ];
}
