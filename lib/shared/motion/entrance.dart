import 'dart:async';

import 'package:flutter/material.dart';

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
  Timer? _delay;

  bool get _eligible => widget.index >= 0 && widget.index < AppMotion.staggerMaxItems;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_eligible || AppMotion.reduced(context)) {
      _delay?.cancel();
      _controller?.dispose();
      _controller = null;
      return;
    }
    if (_controller == null) {
      _controller = AnimationController(
        vsync: this,
        duration: AppMotion.base,
      );
      final wait = AppMotion.staggerStep * widget.index;
      if (wait == Duration.zero) {
        _controller!.forward();
      } else {
        _delay = Timer(wait, () {
          if (mounted) _controller?.forward();
        });
      }
    }
  }

  @override
  void dispose() {
    _delay?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return widget.child;
    final curved = CurvedAnimation(
      parent: controller,
      curve: AppMotion.emphasizedDecelerate,
    );
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
