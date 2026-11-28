import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Rolling numeric counter with tabular figures and directional vertical slide.
class AnimatedCount extends StatefulWidget {
  const AnimatedCount({
    super.key,
    required this.count,
    this.style,
    this.hideZero = false,
    this.format,
  });

  final int count;
  final String Function(int)? format;
  final TextStyle? style;
  final bool hideZero;

  @override
  State<AnimatedCount> createState() => _AnimatedCountState();
}

class _AnimatedCountState extends State<AnimatedCount> {
  late int _previous;

  @override
  void initState() {
    super.initState();
    _previous = widget.count;
  }

  @override
  void didUpdateWidget(covariant AnimatedCount oldWidget) {
    super.didUpdateWidget(oldWidget);
    _previous = oldWidget.count;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.hideZero && widget.count <= 0) {
      return const SizedBox.shrink();
    }
    final reduced = AppMotion.reduced(context);
    final effectiveStyle = (widget.style ?? const TextStyle()).copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final increasing = widget.count >= _previous;

    return AnimatedSwitcher(
      duration: reduced ? Duration.zero : AppMotion.fast,
      switchInCurve: AppMotion.emphasizedDecelerate,
      switchOutCurve: AppMotion.standardCurve,
      transitionBuilder: (child, animation) {
        if (reduced) return FadeTransition(opacity: animation, child: child);
        final isIncoming = child.key == ValueKey<int>(widget.count);
        final offset = isIncoming
            ? Offset(0, increasing ? 0.35 : -0.35)
            : Offset(0, increasing ? -0.35 : 0.35);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: offset,
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        );
      },
      child: Text(
        widget.format?.call(widget.count) ?? '${widget.count}',
        key: ValueKey<int>(widget.count),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: effectiveStyle,
      ),
    );
  }
}
