import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../theme/tokens.dart';

/// Staggered fade + subtle upward slide for the first screen of feed items.
/// Items beyond [AppMotion.staggerMaxItems] render immediately with zero cost.
class StaggeredEntrance extends StatefulWidget {
  const StaggeredEntrance({
    super.key,
    required this.index,
    required this.child,
  });

  final int index;
  final Widget child;

  @override
  State<StaggeredEntrance> createState() => _StaggeredEntranceState();
}

class _StaggeredEntranceState extends State<StaggeredEntrance>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  static final _seenByList = Expando<Set<int>>();
  bool _started = false;
  late Interval _interval;

  bool get _eligible => widget.index >= 0 && widget.index < AppMotion.staggerMaxItems;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context) || !_eligible) {
      _started = true;
      _controller?.value = 1;
      return;
    }
    if (_started) return;
    _started = true;
    final list = Scrollable.maybeOf(context);
    if (list != null && !(_seenByList[list] ??= <int>{}).add(widget.index)) return;
    final wait = AppMotion.staggerStep * widget.index;
    final duration = AppMotion.base + wait;
    _interval = Interval(wait.inMicroseconds / duration.inMicroseconds, 1, curve: AppMotion.emphasizedDecelerate);
    _controller = AnimationController(vsync: this, duration: duration)..forward();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return widget.child;
    final curved = controller.drive(CurveTween(curve: _interval));
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.04),
          end: Offset.zero,
        ).animate(curved),
        child: widget.child,
      ),
    );
  }
}

/// A confirmed change briefly compresses its icon, preserving child state.
class SpringPop extends StatefulWidget {
  const SpringPop({super.key, required this.value, required this.child, this.from = .86});
  final Object value;
  final Widget child;
  final double from;
  @override
  State<SpringPop> createState() => _SpringPopState();
}

class _SpringPopState extends State<SpringPop> with SingleTickerProviderStateMixin {
  late final _scale = AnimationController.unbounded(vsync: this, value: 1);
  @override
  void didUpdateWidget(SpringPop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value && !AppMotion.reduced(context)) {
      _scale.animateWith(SpringSimulation(AppMotion.liquidSnapSpring, widget.from, 1, 0));
    }
  }

  @override
  void dispose() {
    _scale.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppMotion.reduced(context)
      ? widget.child : ScaleTransition(scale: _scale, child: widget.child);
}

class LiquidSnapCurve extends Curve {
  const LiquidSnapCurve();
  static final _spring = SpringSimulation(AppMotion.liquidSnapSpring, 0, 1, 0);
  @override
  double transformInternal(double t) => _spring.x(t * .48);
}
