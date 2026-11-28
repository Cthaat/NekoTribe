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
    with TickerProviderStateMixin {
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
      )..repeat();
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
    Widget box([Gradient? gradient]) => Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: social.surfaceSubtle,
        gradient: gradient,
        borderRadius: widget.borderRadius,
      ),
    );
    final controller = _controller;
    if (controller == null) return box();

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final x = controller.value * 4 - 2;
        return box(LinearGradient(
          begin: Alignment(x - 0.8, -0.55),
          end: Alignment(x + 0.8, 0.55),
          colors: [social.surfaceSubtle, social.surfaceHover, social.surfaceSubtle],
        ));
      },
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

/// Keep the outgoing skeleton visible while the next state dissolves in.
/// Mounted data is discarded immediately when a screen re-enters loading.
class SkeletonCrossFade extends StatelessWidget {
  const SkeletonCrossFade({super.key, required this.loading, required this.child});
  static const _loadingKey = ValueKey<Object>(true);
  final bool loading;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduced(context)) return child;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topCenter, fit: StackFit.passthrough,
        children: [...previous, ?current],
      ),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: AnimatedBuilder(animation: animation, child: child, builder: (_, inner) {
          if (animation.status == AnimationStatus.reverse && child.key != _loadingKey) {
            return const SizedBox.shrink();
          }
          return IgnorePointer(ignoring: animation.status == AnimationStatus.reverse, child: inner);
        }),
      ),
      child: KeyedSubtree(key: loading ? _loadingKey : ValueKey(child.runtimeType), child: child),
    );
  }
}
