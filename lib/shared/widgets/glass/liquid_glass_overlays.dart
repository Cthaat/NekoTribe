import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../motion/pressable.dart';
import '../../theme/tokens.dart';
import 'liquid_glass_surface.dart';
import 'liquid_glass_tokens.dart';

class LiquidGlassFab extends StatelessWidget {
  const LiquidGlassFab({super.key, required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    excludeFromSemantics: true,
    child: Semantics(
      label: label, button: true,
      child: Pressable(
        onTap: onPressed, scale: 0.94,
        child: LiquidGlassSurface(
          preset: LiquidGlassPreset.iconButton,
          borderRadius: BorderRadius.circular(28),
          child: SizedBox.square(dimension: 56, child: Icon(icon, color: Theme.of(context).colorScheme.onSurface)),
        ),
      ),
    ),
  );
}

class _SpringCurve extends Curve {
  const _SpringCurve();
  static final _spring = SpringSimulation(AppMotion.liquidSnapSpring, 0, 1, 0);
  @override
  double transformInternal(double t) => _spring.x(t * 0.52);
}

Future<T?> showLiquidGlassDialog<T>({
  required BuildContext context, required WidgetBuilder builder, bool barrierDismissible = true,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  return navigator.push(RawDialogRoute<T>(
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierDismissible: barrierDismissible,
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
    barrierColor: Colors.black38,
    transitionDuration: AppMotion.resolve(context, const Duration(milliseconds: 360)),
    pageBuilder: (_, _, _) => themes.wrap(SafeArea(child: Dialog(
      backgroundColor: Colors.transparent,
      child: LiquidGlassSurface(
        preset: LiquidGlassPreset.popover,
        borderRadius: BorderRadius.circular(AppRadius.canvas),
        child: Builder(builder: builder),
      ),
    ))),
    transitionBuilder: (context, animation, _, child) {
      final scale = Tween(begin: 0.94, end: 1.0).chain(CurveTween(curve: const _SpringCurve()));
      return Stack(children: [
        Positioned.fill(child: IgnorePointer(child: _SoftBackdrop(progress: animation.value))),
        FadeTransition(opacity: animation, child: ScaleTransition(scale: animation.drive(scale), child: child)),
      ]);
    },
  ));
}

class _SoftBackdrop extends StatelessWidget {
  const _SoftBackdrop({required this.progress});
  final double progress;
  @override
  Widget build(BuildContext context) => MediaQuery.highContrastOf(context)
      ? const SizedBox.shrink()
      : BackdropFilter(filter: ui.ImageFilter.blur(sigmaX: 4 * progress, sigmaY: 4 * progress), child: const SizedBox.expand());
}

/// Dialog content owns its scroll view so the actions stay reachable above the keyboard.
class LiquidGlassAlertContent extends StatelessWidget {
  const LiquidGlassAlertContent({super.key, required this.title, required this.content, this.actions = const []});
  final Widget title, content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 560),
    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.fromLTRB(24, 24, 24, 12), child: Semantics(header: true, namesRoute: true,
        child: DefaultTextStyle(style: Theme.of(context).textTheme.titleLarge!, child: title))),
      Flexible(child: SingleChildScrollView(padding: const EdgeInsets.symmetric(horizontal: 24), child: content)),
      Padding(padding: const EdgeInsets.all(12), child: OverflowBar(alignment: MainAxisAlignment.end, children: actions)),
    ]),
  );
}

Future<T?> showLiquidGlassBottomSheet<T>({required BuildContext context, required WidgetBuilder builder}) {
  final navigator = Navigator.of(context);
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  return navigator.push(RawDialogRoute<T>(
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    transitionDuration: AppMotion.resolve(context, const Duration(milliseconds: 300)),
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
    pageBuilder: (context, _, _) => themes.wrap(SafeArea(
      bottom: false,
      child: Align(alignment: Alignment.bottomCenter,
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640),
          child: _DraggableSheet(builder: builder))),
    )),
    transitionBuilder: (context, animation, _, child) => Stack(children: [
      Positioned.fill(child: IgnorePointer(child: _SoftBackdrop(progress: animation.value))),
      child,
    ]),
  ));
}

class _DraggableSheet extends StatefulWidget {
  const _DraggableSheet({required this.builder});
  final WidgetBuilder builder;

  @override
  State<_DraggableSheet> createState() => _DraggableSheetState();
}

class _DraggableSheetState extends State<_DraggableSheet> with SingleTickerProviderStateMixin {
  late final _offset = AnimationController.unbounded(vsync: this);
  static const curve = Cubic(0.22, 1, 0.36, 1);

  @override
  void dispose() {
    _offset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context)!;
    return SlideTransition(
      position: route.animation!.drive(Tween(begin: const Offset(0, 1), end: Offset.zero)
          .chain(CurveTween(curve: curve))),
      child: AnimatedBuilder(animation: _offset,
        builder: (_, child) => Transform.translate(offset: Offset(0, _offset.value), child: child),
        child: GestureDetector(
          onVerticalDragStart: (_) => _offset.stop(),
          onVerticalDragUpdate: (drag) => _offset.value = (_offset.value + drag.delta.dy * 0.72).clamp(0, double.infinity),
          onVerticalDragEnd: (drag) {
            if (_offset.value > context.size!.height * 0.32 || drag.velocity.pixelsPerSecond.dy > 750) {
              Navigator.pop(context);
            } else {
              _restore();
            }
          },
          onVerticalDragCancel: _restore,
          child: Material(type: MaterialType.transparency, child: LiquidGlassSurface(
            preset: LiquidGlassPreset.popover,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(AppRadius.canvas)),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 36, height: 4, margin: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(color: Theme.of(context).colorScheme.onSurfaceVariant, borderRadius: BorderRadius.circular(2))),
              Flexible(child: Builder(builder: widget.builder)),
            ]),
          )),
        ),
      ),
    );
  }

  void _restore() {
    if (AppMotion.reduced(context)) {
      _offset.value = 0;
    } else {
      _offset.animateWith(SpringSimulation(AppMotion.liquidSnapSpring, _offset.value, 0, 0, snapToEnd: true));
    }
  }
}

SnackBar liquidGlassSnackBar(BuildContext context, String message) {
  final scheme = Theme.of(context).colorScheme;
  return SnackBar(backgroundColor: Colors.transparent, elevation: 0, padding: EdgeInsets.zero,
    behavior: SnackBarBehavior.floating,
    content: LiquidGlassSurface(
      preset: LiquidGlassPreset.popover, borderRadius: BorderRadius.circular(AppRadius.tile),
      child: ColoredBox(color: scheme.surface.withValues(alpha: 0.64),
        child: Padding(padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
          child: Text(message, style: TextStyle(color: scheme.onSurface)))),
    ),
  );
}
