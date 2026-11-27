import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Lightweight shimmer block for loading skeletons.
class ShimmerBox extends StatefulWidget {
  const ShimmerBox({
    super.key,
    this.width,
    required this.height,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    this.animate = true,
  });

  final double? width;
  final double height;
  final BorderRadius borderRadius;
  final bool animate;

  @override
  State<ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<ShimmerBox>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant ShimmerBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  void _syncTicker() {
    final shouldAnimate =
        widget.animate &&
        TickerMode.valuesOf(context).enabled &&
        !AppMotion.reduced(context);
    if (shouldAnimate) {
      _controller ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1100),
      )..repeat(reverse: true);
    } else {
      _controller?.dispose();
      _controller = null;
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final social = SocialColors.of(context);
    final box = Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: social.surfaceSubtle,
        borderRadius: widget.borderRadius,
      ),
    );
    final controller = _controller;
    if (controller == null) return box;

    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(controller.value);
        return Opacity(opacity: 0.55 + 0.45 * t, child: child);
      },
      child: box,
    );
  }
}

/// Borderless L1 Bento timeline post skeleton matching the PostCard layout.
class PostSkeleton extends StatelessWidget {
  const PostSkeleton({super.key, this.animate = true});

  final bool animate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final social = SocialColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: social.surfaceCard,
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: isDark
            ? const <BoxShadow>[]
            : const <BoxShadow>[
                BoxShadow(
                  color: Color(0x080F172A),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ],
      ),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShimmerBox(
            width: 40,
            height: 40,
            borderRadius: const BorderRadius.all(Radius.circular(999)),
            animate: animate,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ShimmerBox(width: 96, height: 14, animate: animate),
                    const SizedBox(width: 8),
                    ShimmerBox(width: 68, height: 12, animate: animate),
                  ],
                ),
                const SizedBox(height: 10),
                ShimmerBox(
                  width: double.infinity,
                  height: 14,
                  animate: animate,
                ),
                const SizedBox(height: 8),
                FractionallySizedBox(
                  widthFactor: 0.72,
                  child: ShimmerBox(height: 14, animate: animate),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    ShimmerBox(width: 36, height: 12, animate: animate),
                    const SizedBox(width: 20),
                    ShimmerBox(width: 36, height: 12, animate: animate),
                    const SizedBox(width: 20),
                    ShimmerBox(width: 36, height: 12, animate: animate),
                    const Spacer(),
                    ShimmerBox(width: 24, height: 12, animate: animate),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ListTileSkeleton extends StatelessWidget {
  const ListTileSkeleton({super.key, this.animate = true});

  final bool animate;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          ShimmerBox(
            width: 40,
            height: 40,
            borderRadius: const BorderRadius.all(Radius.circular(999)),
            animate: animate,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ShimmerBox(width: 108, height: 13, animate: animate),
                const SizedBox(height: 6),
                ShimmerBox(width: 72, height: 11, animate: animate),
              ],
            ),
          ),
          ShimmerBox(
            width: 56,
            height: 28,
            borderRadius: const BorderRadius.all(Radius.circular(999)),
            animate: animate,
          ),
        ],
      ),
    );
  }
}
