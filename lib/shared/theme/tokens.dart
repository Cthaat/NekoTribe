import 'package:flutter/material.dart';

import '../widgets/glass/liquid_glass_tokens.dart';

/// Five-level concentric corner radii (`28 -> 26 -> 18 -> 14 / 999`).
abstract final class AppRadius {
  static const double canvas = 28.0;
  static const double card = 26.0;
  static const double tile = 18.0;
  static const double inner = 14.0;
  static const double chip = 999.0;
  static const double pill = 999.0;

  static const double xs = 8.0;
  static const double sm = inner;
  static const double md = inner;
  static const double lg = card;
  static const double xl = canvas;
}

/// Spacing scale tailored for Quiet Tonal Bento grids and cards.
abstract final class AppGap {
  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 12.0;
  static const double lg = 16.0;
  static const double xl = 24.0;
}

/// Critical-damping / glide motion tokens (`zeta ~= 0.88`, minimal overshoot).
abstract final class AppMotion {
  static const Duration micro = Duration(milliseconds: 120);
  static const Duration fast = Duration(milliseconds: 160);
  static const Duration base = Duration(milliseconds: 220);
  static const Duration glide = Duration(milliseconds: 220);
  static const Duration sheet = Duration(milliseconds: 280);
  static const Duration likeBurst = Duration(milliseconds: 260);
  static const Duration staggerStep = Duration(milliseconds: 24);
  static const int staggerMaxItems = 8;

  static const Curve glideCurve = Cubic(0.22, 1.0, 0.36, 1.0);
  static const Curve sheetCurve = Cubic(0.32, 0.72, 0.0, 1.0);
  static const Curve curve = Curves.easeOutCubic;
  static const Curve standardCurve = Curves.easeOutCubic;
  static const Curve emphasizedDecelerate = Curves.easeOutCubic;

  static const SpringDescription dampedSpring = SpringDescription(
    mass: 1,
    stiffness: 420,
    damping: 36,
  );

  static const SpringDescription springSnappy = dampedSpring;

  static const SpringDescription springGentle = SpringDescription(
    mass: 1,
    stiffness: 280,
    damping: 30,
  );

  static bool reduced(BuildContext context) {
    final mq = MediaQuery.maybeOf(context);
    return (mq?.disableAnimations ?? false) ||
        (mq?.accessibleNavigation ?? false);
  }

  static Duration resolve(BuildContext context, Duration duration) =>
      reduced(context) ? Duration.zero : duration;
}

/// Quiet Tonal Bento palette extension (`L0 -> L1 -> L2 -> L3` + semantics).
@immutable
class SocialColors extends ThemeExtension<SocialColors> {
  const SocialColors({
    required this.shellFrame,
    required this.surfaceBase,
    required this.surfaceCard,
    required this.surfaceSubtle,
    required this.surfaceHover,
    required this.primarySoft,
    required this.inkTertiary,
    required this.gridLine,
    required this.like,
    required this.repost,
    required this.bookmark,
    required this.hover,
    required this.divider,
    required this.glassSurface,
    this.statusOnlineBg = const Color(0x2934C759),
    this.statusOnlineFg = const Color(0xFF34C759),
    this.glassIntensity = LiquidGlassIntensity.standard,
  });

  final Color shellFrame;
  final Color surfaceBase;
  final Color surfaceCard;
  final Color surfaceSubtle;
  final Color surfaceHover;
  final Color primarySoft;
  final Color inkTertiary;
  final Color gridLine;
  final Color like;
  final Color repost;
  final Color bookmark;
  final Color hover;
  final Color divider;
  final Color glassSurface;
  final Color statusOnlineBg;
  final Color statusOnlineFg;
  final LiquidGlassIntensity glassIntensity;

  static const SocialColors light = SocialColors(
    shellFrame: Color(0xFFE8ECF2),
    surfaceBase: Color(0xFFF2F4F7),
    surfaceCard: Color(0xFFFFFFFF),
    surfaceSubtle: Color(0xFFEEF1F6),
    surfaceHover: Color(0xFFE3E8F0),
    primarySoft: Color(0x1A007AFF),
    inkTertiary: Color(0xFF8E96A0),
    gridLine: Color(0x090F172A),
    like: Color(0xFFE5486D),
    repost: Color(0xFF10B981),
    bookmark: Color(0xFF007AFF),
    hover: Color(0xFFE3E8F0),
    divider: Color(0x0D0F172A),
    glassSurface: Color(0x99FFFFFF),
    statusOnlineBg: Color(0x2934C759),
    statusOnlineFg: Color(0xFF34C759),
  );

  static const SocialColors dark = SocialColors(
    shellFrame: Color(0xFF060709),
    surfaceBase: Color(0xFF090A0D),
    surfaceCard: Color(0xFF16181D),
    surfaceSubtle: Color(0xFF20232A),
    surfaceHover: Color(0xFF2A2E37),
    primarySoft: Color(0x268CC8FF),
    inkTertiary: Color(0xFF606770),
    gridLine: Color(0x09FFFFFF),
    like: Color(0xFFFB7185),
    repost: Color(0xFF34D399),
    bookmark: Color(0xFF8CC8FF),
    hover: Color(0xFF2A2E37),
    divider: Color(0x0DFFFFFF),
    glassSurface: Color(0x9916181D),
    statusOnlineBg: Color(0x2934C759),
    statusOnlineFg: Color(0xFF34C759),
  );

  static SocialColors fromScheme(
    ColorScheme scheme, {
    required bool isDark,
    required LiquidGlassIntensity glassIntensity,
  }) {
    final base = isDark ? dark : light;
    return base.copyWith(
      primarySoft: scheme.primary.withValues(alpha: isDark ? 0.15 : 0.10),
      bookmark: scheme.primary,
      glassIntensity: glassIntensity,
    );
  }

  static SocialColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<SocialColors>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  @override
  SocialColors copyWith({
    Color? shellFrame,
    Color? surfaceBase,
    Color? surfaceCard,
    Color? surfaceSubtle,
    Color? surfaceHover,
    Color? primarySoft,
    Color? inkTertiary,
    Color? gridLine,
    Color? like,
    Color? repost,
    Color? bookmark,
    Color? hover,
    Color? divider,
    Color? glassSurface,
    Color? statusOnlineBg,
    Color? statusOnlineFg,
    LiquidGlassIntensity? glassIntensity,
  }) {
    return SocialColors(
      shellFrame: shellFrame ?? this.shellFrame,
      surfaceBase: surfaceBase ?? this.surfaceBase,
      surfaceCard: surfaceCard ?? this.surfaceCard,
      surfaceSubtle: surfaceSubtle ?? this.surfaceSubtle,
      surfaceHover: surfaceHover ?? this.surfaceHover,
      primarySoft: primarySoft ?? this.primarySoft,
      inkTertiary: inkTertiary ?? this.inkTertiary,
      gridLine: gridLine ?? this.gridLine,
      like: like ?? this.like,
      repost: repost ?? this.repost,
      bookmark: bookmark ?? this.bookmark,
      hover: hover ?? this.hover,
      divider: divider ?? this.divider,
      glassSurface: glassSurface ?? this.glassSurface,
      statusOnlineBg: statusOnlineBg ?? this.statusOnlineBg,
      statusOnlineFg: statusOnlineFg ?? this.statusOnlineFg,
      glassIntensity: glassIntensity ?? this.glassIntensity,
    );
  }

  @override
  SocialColors lerp(covariant ThemeExtension<SocialColors>? other, double t) {
    if (other is! SocialColors) return this;
    return SocialColors(
      shellFrame: Color.lerp(shellFrame, other.shellFrame, t) ?? shellFrame,
      surfaceBase: Color.lerp(surfaceBase, other.surfaceBase, t) ?? surfaceBase,
      surfaceCard: Color.lerp(surfaceCard, other.surfaceCard, t) ?? surfaceCard,
      surfaceSubtle:
          Color.lerp(surfaceSubtle, other.surfaceSubtle, t) ?? surfaceSubtle,
      surfaceHover:
          Color.lerp(surfaceHover, other.surfaceHover, t) ?? surfaceHover,
      primarySoft: Color.lerp(primarySoft, other.primarySoft, t) ?? primarySoft,
      inkTertiary: Color.lerp(inkTertiary, other.inkTertiary, t) ?? inkTertiary,
      gridLine: Color.lerp(gridLine, other.gridLine, t) ?? gridLine,
      like: Color.lerp(like, other.like, t) ?? like,
      repost: Color.lerp(repost, other.repost, t) ?? repost,
      bookmark: Color.lerp(bookmark, other.bookmark, t) ?? bookmark,
      hover: Color.lerp(hover, other.hover, t) ?? hover,
      divider: Color.lerp(divider, other.divider, t) ?? divider,
      glassSurface:
          Color.lerp(glassSurface, other.glassSurface, t) ?? glassSurface,
      statusOnlineBg:
          Color.lerp(statusOnlineBg, other.statusOnlineBg, t) ?? statusOnlineBg,
      statusOnlineFg:
          Color.lerp(statusOnlineFg, other.statusOnlineFg, t) ?? statusOnlineFg,
      glassIntensity: t < 0.5 ? glassIntensity : other.glassIntensity,
    );
  }
}
