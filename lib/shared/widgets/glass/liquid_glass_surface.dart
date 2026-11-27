import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../theme/tokens.dart';
import 'liquid_glass_shader.dart';
import 'liquid_glass_tokens.dart';

class LiquidGlassSurface extends StatelessWidget {
  const LiquidGlassSurface({
    super.key,
    required this.preset,
    required this.borderRadius,
    required this.child,
    this.padding,
    this.margin,
    this.blurEnabled = true,
    this.interactive = false,
    this.onTap,
    this.intensityOverride,
  });

  final LiquidGlassPreset preset;
  final BorderRadius borderRadius;
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final bool blurEnabled;
  final bool interactive;
  final VoidCallback? onTap;
  final LiquidGlassIntensity? intensityOverride;

  @override
  Widget build(BuildContext context) {
    final pressedSurface = interactive
        ? _GlassPress(
            onTap: onTap,
            builder: (context, highlight) => _buildSurface(context, highlight),
          )
        : _buildSurface(context, 0);
    return margin == null
        ? pressedSurface
        : Padding(padding: margin!, child: pressedSurface);
  }

  Widget _buildSurface(BuildContext context, double highlight) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final highContrast = MediaQuery.highContrastOf(context);
    final intensity =
        intensityOverride ?? SocialColors.of(context).glassIntensity;
    final spec = LiquidGlassSpec.resolve(preset, scheme, intensity);
    final tintAlpha =
        (spec.tintColor.a +
                (AppMotion.reduced(context) ? 0.015 : 0.0) +
                (highContrast ? 0.22 : 0.0))
            .clamp(0.0, 0.92);
    final tint = spec.tintColor.withValues(alpha: tintAlpha);
    final rimTopAlpha =
        (spec.rimTopAlpha + highlight * 0.07 + (highContrast ? 0.22 : 0.0))
            .clamp(0.0, 1.0);
    final rimBottomAlpha =
        (spec.rimBottomAlpha + highlight * 0.05 + (highContrast ? 0.18 : 0.0))
            .clamp(0.0, 1.0);
    final rimStrokeWidth = spec.rimStrokeWidth <= 0
        ? 0.0
        : (highContrast ? spec.rimStrokeWidth * 1.35 : spec.rimStrokeWidth);
    final plate = CustomPaint(
      foregroundPainter: _SpecularRimPainter(
        borderRadius: borderRadius,
        colors: [
          Colors.white.withValues(alpha: rimTopAlpha),
          Colors.white.withValues(alpha: dark ? 0.06 : 0.18),
          Colors.white.withValues(alpha: dark ? 0.05 : 0.12),
          Color.lerp(
            Colors.white,
            scheme.primary,
            0.32,
          )!.withValues(alpha: rimBottomAlpha),
        ],
        innerGlowColor: Colors.white.withValues(
          alpha: dark ? 0.045 : 0.16,
        ),
        strokeWidth: rimStrokeWidth,
      ),
      child: ColoredBox(
        color: tint,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: spec.topSheenAlpha <= 0
                ? null
                : LinearGradient(
                    begin: const Alignment(-0.35, -1),
                    end: const Alignment(0.25, 0.65),
                    colors: [
                      Colors.white.withValues(alpha: spec.topSheenAlpha),
                      Colors.white.withValues(alpha: dark ? 0.02 : 0.08),
                      Colors.transparent,
                    ],
                    stops: const [0, 0.45, 1],
                  ),
          ),
          child: padding == null
              ? child
              : Padding(padding: padding!, child: child),
        ),
      ),
    );
    final clipped = ClipRRect(
      borderRadius: borderRadius,
      child: blurEnabled
          ? _GlassBackdrop(
              spec: spec,
              cornerRadius: borderRadius.topLeft.x,
              child: plate,
            )
          : plate,
    );
    if (!spec.enableShadow) return clipped;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          if (dark)
            const BoxShadow(
              color: Color(0x38000000),
              blurRadius: 26,
              offset: Offset(0, 10),
            )
          else
            const BoxShadow(
              color: Color(0x140F172A),
              blurRadius: 24,
              offset: Offset(0, 8),
            ),
        ],
      ),
      child: clipped,
    );
  }
}

class _GlassBackdrop extends StatefulWidget {
  const _GlassBackdrop({
    required this.spec,
    required this.cornerRadius,
    required this.child,
  });

  final LiquidGlassSpec spec;
  final double cornerRadius;
  final Widget child;

  @override
  State<_GlassBackdrop> createState() => _GlassBackdropState();
}

class _GlassBackdropState extends State<_GlassBackdrop> {
  ui.FragmentShader? _shader;
  (double, double, double, double)? _uniforms;

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    final optics = ui.ImageFilter.compose(
      outer: ui.ColorFilter.matrix(saturationColorMatrix(spec.saturation)),
      inner: ui.ImageFilter.blur(
        sigmaX: spec.blurSigma,
        sigmaY: spec.blurSigma,
        tileMode: TileMode.clamp,
      ),
    );
    if (!spec.enableRefraction || !LiquidGlassShaderCache.isSupported) {
      return BackdropFilter(filter: optics, child: widget.child);
    }
    return FutureBuilder<ui.FragmentProgram?>(
      future: LiquidGlassShaderCache.load(),
      builder: (context, snapshot) {
        final program = snapshot.data;
        if (program == null) {
          return BackdropFilter(filter: optics, child: widget.child);
        }
        final shader = _shader ??= program.fragmentShader();
        final dpr = MediaQuery.devicePixelRatioOf(context).clamp(1.0, 4.0);
        final uniforms = (
          widget.cornerRadius * dpr,
          spec.bezelWidth * dpr,
          spec.refractionPx * dpr,
          spec.aberrationPx * dpr,
        );
        if (uniforms != _uniforms) {
          shader
            ..setFloat(2, uniforms.$1)
            ..setFloat(3, uniforms.$2)
            ..setFloat(4, uniforms.$3)
            ..setFloat(5, uniforms.$4);
          _uniforms = uniforms;
        }
        return BackdropFilter(
          filter: ui.ImageFilter.compose(
            outer: ui.ImageFilter.shader(shader),
            inner: optics,
          ),
          child: widget.child,
        );
      },
    );
  }
}

class _SpecularRimPainter extends CustomPainter {
  const _SpecularRimPainter({
    required this.borderRadius,
    required this.colors,
    required this.innerGlowColor,
    required this.strokeWidth,
  });

  final BorderRadius borderRadius;
  final List<Color> colors;
  final Color innerGlowColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (strokeWidth <= 0 || size.isEmpty) return;
    final bounds = Offset.zero & size;
    final baseRRect = borderRadius.toRRect(bounds).scaleRadii();
    canvas.drawRRect(
      baseRRect.deflate(strokeWidth / 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
          stops: const [0, 0.36, 0.70, 1],
        ).createShader(bounds),
    );
    final glowDeflate = strokeWidth * 1.45;
    if (size.width > glowDeflate * 2 && size.height > glowDeflate * 2) {
      canvas.drawRRect(
        baseRRect.deflate(glowDeflate),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth * 1.5
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              innerGlowColor,
              Colors.transparent,
              innerGlowColor.withValues(alpha: innerGlowColor.a * 0.45),
            ],
            stops: const [0, 0.55, 1],
          ).createShader(bounds),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SpecularRimPainter oldDelegate) =>
      borderRadius != oldDelegate.borderRadius ||
      strokeWidth != oldDelegate.strokeWidth ||
      innerGlowColor != oldDelegate.innerGlowColor ||
      colors[0] != oldDelegate.colors[0] ||
      colors[1] != oldDelegate.colors[1] ||
      colors[2] != oldDelegate.colors[2] ||
      colors[3] != oldDelegate.colors[3];
}

class _GlassPress extends StatefulWidget {
  const _GlassPress({required this.builder, this.onTap});

  final Widget Function(BuildContext context, double highlight) builder;
  final VoidCallback? onTap;

  @override
  State<_GlassPress> createState() => _GlassPressState();
}

class _GlassPressState extends State<_GlassPress>
    with SingleTickerProviderStateMixin {
  late final _press = AnimationController.unbounded(vsync: this);

  void _animateTo(double target) {
    _press.animateWith(
      SpringSimulation(
        AppMotion.dampedSpring,
        _press.value,
        target,
        _press.velocity,
      ),
    );
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = AppMotion.reduced(context)
        ? widget.builder(context, 0)
        : Listener(
            onPointerDown: (_) => _animateTo(1),
            onPointerUp: (_) => _animateTo(0),
            onPointerCancel: (_) => _animateTo(0),
            child: AnimatedBuilder(
              animation: _press,
              builder: (context, _) => Transform.scale(
                scale: 1 + _press.value * 0.02,
                child: widget.builder(context, _press.value.clamp(0, 1)),
              ),
            ),
          );
    return widget.onTap == null
        ? child
        : GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: child,
          );
  }
}
