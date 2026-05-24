import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/i18n/app_localizations.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('about.title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('NekoTribe', style: theme.textTheme.headlineMedium),
          const SizedBox(height: 8),
          Text(l10n.t('about.description'), style: theme.textTheme.bodyLarge),
          const SizedBox(height: 20),
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
          _ActionTile(
            icon: Icons.explore_outlined,
            title: l10n.t('about.explore_posts'),
            subtitle: l10n.t('about.explore_posts_subtitle'),
            onTap: () => context.go('/discover'),
          ),
          _ActionTile(
            icon: Icons.group_outlined,
            title: l10n.t('about.groups'),
            subtitle: l10n.t('about.groups_subtitle'),
            onTap: () => context.go('/groups'),
          ),
          _ActionTile(
            icon: Icons.article_outlined,
            title: l10n.t('about.terms'),
            subtitle: l10n.t('about.terms_subtitle'),
            onTap: () => context.push('/auth/terms'),
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
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
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
