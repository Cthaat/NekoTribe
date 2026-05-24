import 'package:flutter/material.dart';

import '../../../shared/i18n/app_localizations.dart';

class BillingScreen extends StatelessWidget {
  const BillingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('settings.account.billing'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _MetricTile(
            icon: Icons.wallet_outlined,
            label: l10n.t('billing.current_plan'),
            value: l10n.t('billing.free'),
          ),
          _MetricTile(
            icon: Icons.event_outlined,
            label: l10n.t('billing.next_date'),
            value: '2026-06-18',
          ),
          _MetricTile(
            icon: Icons.verified_user_outlined,
            label: l10n.t('billing.status'),
            value: l10n.t('billing.active'),
          ),
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: const Text('NT-2026-005'),
              subtitle: const Text('2026-05-18'),
              trailing: Text(l10n.t('billing.pending')),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: const Text('NT-2026-004'),
              subtitle: const Text('2026-04-18'),
              trailing: Text(l10n.t('billing.paid')),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(label),
        trailing: Text(value),
      ),
    );
  }
}
