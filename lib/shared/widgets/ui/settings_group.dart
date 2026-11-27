import 'package:flutter/material.dart';
import '../../theme/tokens.dart';

class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final social = SocialColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, AppGap.xl, 4, AppGap.sm),
          child: Text(
            title,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.1,
            ),
          ),
        ),
        Container(
          decoration: ShapeDecoration(
            color: social.surfaceCard,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(AppRadius.card),
              side: isDark
                  ? BorderSide(
                      color: Colors.white.withValues(alpha: 0.055),
                      width: 0.8,
                    )
                  : BorderSide.none,
            ),
            shadows: isDark
                ? const <BoxShadow>[]
                : const <BoxShadow>[
                    BoxShadow(
                      color: Color(0x080F172A),
                      blurRadius: 8,
                      offset: Offset(0, 2),
                    ),
                  ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0)
                  Divider(
                    indent: 52,
                    endIndent: 16,
                    height: 1,
                    thickness: 1,
                    color: social.divider,
                  ),
                children[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.leadingColor,
    this.onTap,
  });

  final IconData icon;
  final Widget title;
  final Widget? subtitle;
  final Widget? trailing;
  final Color? leadingColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      shape: const RoundedRectangleBorder(),
      minTileHeight: 52,
      leading: Icon(
        icon,
        size: 20,
        color: leadingColor ?? scheme.onSurfaceVariant,
      ),
      title: title,
      subtitle: subtitle,
      trailing: trailing,
      onTap: onTap,
    );
  }
}
