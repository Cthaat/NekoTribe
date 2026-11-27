import 'package:flutter/material.dart';
import '../../theme/tokens.dart';
import 'info_header.dart';
import 'surface_card.dart';

class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.nested = false,
    this.radius,
    this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool nested;
  final double? radius;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final social = SocialColors.of(context);
    return SurfaceCard(
      radius: radius ?? (nested ? AppRadius.tile : AppRadius.card),
      color: color ?? (nested ? social.surfaceSubtle : null),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InfoHeader(icon: icon, title: label),
          const SizedBox(height: AppGap.md),
          Text(
            value,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
