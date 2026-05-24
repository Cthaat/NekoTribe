import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/i18n/app_localizations.dart';

class ProScreen extends StatelessWidget {
  const ProScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('settings.account.pro'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            l10n.t('pro.workspace'),
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(l10n.t('pro.description')),
          const SizedBox(height: 16),
          _FeatureTile(
            icon: Icons.psychology_outlined,
            title: l10n.t('pro.ai_title'),
            subtitle: l10n.t('pro.ai_subtitle'),
          ),
          _FeatureTile(
            icon: Icons.forum_outlined,
            title: l10n.t('pro.realtime_title'),
            subtitle: l10n.t('pro.realtime_subtitle'),
          ),
          _FeatureTile(
            icon: Icons.shield_outlined,
            title: l10n.t('pro.safety_title'),
            subtitle: l10n.t('pro.safety_subtitle'),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: () => context.push('/settings/billing'),
            icon: const Icon(Icons.credit_card),
            label: Text(l10n.t('pro.view_billing')),
          ),
        ],
      ),
    );
  }
}

class _FeatureTile extends StatelessWidget {
  const _FeatureTile({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
      ),
    );
  }
}
