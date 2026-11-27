import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';
import 'animated_count.dart';

/// Calm critical-damping like button without radial burst particles.
class SocialLikeButton extends StatefulWidget {
  const SocialLikeButton({
    super.key,
    required this.liked,
    required this.count,
    required this.onTap,
    this.iconSize = 18,
    this.showZero = false,
  });

  final bool liked;
  final int count;
  final VoidCallback onTap;
  final double iconSize;
  final bool showZero;

  @override
  State<SocialLikeButton> createState() => _SocialLikeButtonState();
}

class _SocialLikeButtonState extends State<SocialLikeButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _hovered = false;
  bool _bursting = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: AppMotion.likeBurst,
    );
  }

  @override
  void didUpdateWidget(covariant SocialLikeButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.liked != widget.liked) {
      if (widget.liked) {
        _playBurst();
      } else {
        _playUnlike();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _playBurst() {
    if (!mounted || AppMotion.reduced(context)) return;
    _bursting = true;
    _controller.duration = AppMotion.likeBurst;
    _controller.forward(from: 0);
  }

  void _playUnlike() {
    if (!mounted || AppMotion.reduced(context)) return;
    _bursting = false;
    _controller.duration = AppMotion.fast;
    _controller.forward(from: 0);
  }

  void _handleTap() {
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android)) {
      HapticFeedback.lightImpact();
    }
    widget.onTap();
  }

  double _heartScale(double t) {
    if (!_controller.isAnimating && t == 0) return 1.0;
    if (!_bursting) {
      final p = AppMotion.curve.transform(t);
      return p <= 0.5 ? 1.0 - 0.08 * (p / 0.5) : 0.92 + 0.08 * ((p - 0.5) / 0.5);
    }
    // Critical-damping nudge (1.0 -> 0.86 -> 1.06 -> 1.0) without particles
    if (t < 0.30) {
      final p = AppMotion.curve.transform((t / 0.30).clamp(0, 1));
      return 1.0 - 0.14 * p;
    }
    if (t < 0.68) {
      final p = AppMotion.glideCurve.transform(((t - 0.30) / 0.38).clamp(0, 1));
      return 0.86 + 0.20 * p;
    }
    final p = AppMotion.glideCurve.transform(((t - 0.68) / 0.32).clamp(0, 1));
    return 1.06 - 0.06 * p;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final social = SocialColors.of(context);
    final likeColor = social.like;
    final fgColor = widget.liked
        ? likeColor
        : (_hovered ? likeColor : theme.colorScheme.onSurfaceVariant);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        hoverColor: Colors.transparent,
        splashColor: likeColor.withValues(alpha: 0.10),
        onTap: _handleTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 28,
                height: 28,
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) {
                    final scale = _heartScale(_controller.value);
                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        AnimatedContainer(
                          duration: AppMotion.fast,
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _hovered
                                ? likeColor.withValues(alpha: 0.10)
                                : Colors.transparent,
                          ),
                        ),
                        Transform.scale(
                          scale: scale,
                          child: Icon(
                            widget.liked
                                ? Icons.favorite
                                : Icons.favorite_border,
                            size: widget.iconSize,
                            color: fgColor,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              if (widget.showZero || widget.count > 0) ...[
                const SizedBox(width: 2),
                AnimatedCount(
                  count: widget.count,
                  hideZero: !widget.showZero,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: fgColor,
                    fontWeight: widget.liked
                        ? FontWeight.w600
                        : FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
