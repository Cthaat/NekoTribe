import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';

enum HapticKind { none, light, selection, medium }

/// Interruptible spring feedback for custom button content.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.985,
    this.hoverColor,
    this.borderRadius,
    this.haptic = HapticKind.light,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;
  final Color? hoverColor;
  final BorderRadius? borderRadius;
  final HapticKind haptic;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _hovered = false;
  bool _focusVisible = false;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController.unbounded(vsync: this, value: 1.0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _setPressed(bool pressed) {
    if (!mounted) return;
    setState(() => _pressed = pressed);
    if (AppMotion.reduced(context)) {
      _controller.value = 1.0;
      return;
    }
    final velocity = _controller.velocity;
    _controller.animateWith(
      SpringSimulation(
        AppMotion.liquidSnapSpring,
        _controller.value,
        pressed ? widget.scale : 1.0,
        velocity,
      ),
    );
  }

  void _triggerHaptic() {
    if (kIsWeb || widget.haptic == HapticKind.none) return;
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
      case TargetPlatform.android:
        switch (widget.haptic) {
          case HapticKind.light:
            HapticFeedback.lightImpact();
          case HapticKind.selection:
            HapticFeedback.selectionClick();
          case HapticKind.medium:
            HapticFeedback.mediumImpact();
          case HapticKind.none:
            break;
        }
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        break;
    }
  }

  void _activate() {
    _triggerHaptic();
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    final tap = widget.onTap == null ? null : _activate;
    if (tap == null && widget.onLongPress == null) return widget.child;
    final theme = Theme.of(context);
    return FocusableActionDetector(
      enabled: tap != null,
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: widget.hoverColor == null ? null : (value) => setState(() => _hovered = value),
      onShowFocusHighlight: (visible) =>
          setState(() => _focusVisible = visible),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            tap?.call();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        onTap: tap,
        onLongPress: widget.onLongPress,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) =>
              Transform.scale(scale: _controller.value, child: child),
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              color: _pressed && AppMotion.reduced(context)
                  ? theme.highlightColor
                  : _hovered ? widget.hoverColor : null,
              border: _focusVisible
                  ? Border.all(color: theme.colorScheme.primary, width: 2)
                  : null,
              borderRadius: widget.borderRadius ?? BorderRadius.circular(AppRadius.inner),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
