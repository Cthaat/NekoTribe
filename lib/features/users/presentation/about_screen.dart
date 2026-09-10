import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/widgets/responsive.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('about.title'))),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppBreakpoints.contentMaxWidth,
          ),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.2),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.pets,
                          size: 32,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'NekoTribe',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l10n.t('about.description'),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  Chip(label: Text(l10n.t('about.social_feed'))),
                  Chip(label: Text(l10n.t('about.groups'))),
                  Chip(label: Text(l10n.t('about.chat'))),
                  Chip(label: Text(l10n.t('about.safety'))),
                  const Chip(label: Text('SentimentFlow')),
                ],
              ),
              const SizedBox(height: 24),
              Container(
                decoration: BoxDecoration(
                  color: theme.cardTheme.color,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: theme.dividerColor),
                ),
                child: Column(
                  children: [
                    _ActionRow(
                      icon: Icons.explore_outlined,
                      title: l10n.t('about.explore_posts'),
                      subtitle: l10n.t('about.explore_posts_subtitle'),
                      onTap: () => context.push('/discover'),
                    ),
                    Divider(
                      height: 1,
                      indent: 56,
                      color: theme.dividerColor,
                    ),
                    _ActionRow(
                      icon: Icons.group_outlined,
                      title: l10n.t('about.groups'),
                      subtitle: l10n.t('about.groups_subtitle'),
                      onTap: () => context.go('/groups'),
                    ),
                    Divider(
                      height: 1,
                      indent: 56,
                      color: theme.dividerColor,
                    ),
                    _ActionRow(
                      icon: Icons.article_outlined,
                      title: l10n.t('about.terms'),
                      subtitle: l10n.t('about.terms_subtitle'),
                      onTap: () => context.push('/auth/terms'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: theme.colorScheme.outline,
            ),
          ],
        ),
      ),
    );
  }
}
