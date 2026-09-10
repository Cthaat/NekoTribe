import 'package:flutter/material.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/widgets/responsive.dart';

class BillingScreen extends StatelessWidget {
  const BillingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('settings.account.billing'))),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppBreakpoints.contentMaxWidth,
          ),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                color: theme.colorScheme.secondaryContainer.withValues(
                  alpha: 0.45,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.info_outline,
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          l10n.t('billing.demo_notice'),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSecondaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
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
                          Icons.wallet_outlined,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          l10n.t('billing.current_plan'),
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l10n.t('billing.free'),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _MiniMeta(
                            icon: Icons.event_outlined,
                            label: l10n.t('billing.next_date'),
                            value: '2026-06-18',
                          ),
                        ),
                        Expanded(
                          child: _MiniMeta(
                            icon: Icons.verified_user_outlined,
                            label: l10n.t('billing.status'),
                            value: l10n.t('billing.active'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Text(
                l10n.t('billing.history'),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: theme.cardTheme.color,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: theme.dividerColor),
                ),
                child: Column(
                  children: [
                    _InvoiceRow(
                      number: 'NT-2026-005',
                      date: '2026-05-18',
                      status: l10n.t('billing.pending'),
                      pending: true,
                    ),
                    Divider(
                      height: 1,
                      indent: 56,
                      color: theme.dividerColor,
                    ),
                    _InvoiceRow(
                      number: 'NT-2026-004',
                      date: '2026-04-18',
                      status: l10n.t('billing.paid'),
                      pending: false,
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

class _MiniMeta extends StatelessWidget {
  const _MiniMeta({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _InvoiceRow extends StatelessWidget {
  const _InvoiceRow({
    required this.number,
    required this.date,
    required this.status,
    required this.pending,
  });
  final String number;
  final String date;
  final String status;
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tintColor = pending
        ? theme.colorScheme.tertiary
        : theme.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Icon(
            Icons.receipt_long_outlined,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  number,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  date,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: tintColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              status,
              style: theme.textTheme.bodySmall?.copyWith(
                color: tintColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
