import '../../motion/pressable.dart';
import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// Borderless L1 tonal Bento container with subtle light-mode ambient lift,
/// a hairline dark-mode edge (`0.055` white) and zero dark outer shadow.
class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    super.key,
    required this.child,
    this.onTap,
    this.selected = false,
    this.padding = const EdgeInsets.all(AppGap.lg),
    this.radius = AppRadius.card,
    this.color,
    this.margin,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool selected;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? color;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final social = SocialColors.of(context);
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(radius),
      side: selected
          ? BorderSide(
              color: theme.colorScheme.primary.withValues(alpha: 0.45),
              width: 1.5,
            )
          : isDark
          ? BorderSide(
              color: Colors.white.withValues(alpha: 0.055),
              width: 0.8,
            )
          : BorderSide.none,
    );
    final resolvedColor =
        color ?? (selected ? social.primarySoft : social.surfaceCard);

    final shadows = isDark
        ? const <BoxShadow>[]
        : const <BoxShadow>[
            BoxShadow(
              color: Color(0x080F172A),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
            BoxShadow(
              color: Color(0x050F172A),
              blurRadius: 1,
              offset: Offset(0, 1),
            ),
          ];

    final card = Container(
      decoration: ShapeDecoration(
        color: resolvedColor,
        shape: shape,
        shadows: shadows,
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    );
    final interactive = onTap == null ? card : Pressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(radius),
      hoverColor: theme.colorScheme.primary.withValues(alpha: 0.045),
      child: card,
    );
    return margin == null ? interactive : Padding(padding: margin!, child: interactive);
  }
}
