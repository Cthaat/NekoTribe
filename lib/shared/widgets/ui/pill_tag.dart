import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

enum PillTagTone { accent, subtle, online }

class PillTag extends StatelessWidget {
  const PillTag({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.tone = PillTagTone.accent,
  });

  const PillTag.online({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
  }) : tone = PillTagTone.online;

  const PillTag.subtle({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
  }) : tone = PillTagTone.subtle;

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final PillTagTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final social = SocialColors.of(context);
    const shape = StadiumBorder();
    final (bg, fg) = switch (tone) {
      PillTagTone.accent => (social.primarySoft, scheme.primary),
      PillTagTone.subtle => (social.surfaceSubtle, scheme.onSurfaceVariant),
      PillTagTone.online => (social.statusOnlineBg, social.statusOnlineFg),
    };
    return Material(
      color: bg,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        customBorder: shape,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon case final value?) ...[
                Icon(value, size: 13, color: fg),
                const SizedBox(width: 4),
              ] else if (tone == PillTagTone.online) ...[
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
                ),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
