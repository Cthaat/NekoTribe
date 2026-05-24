import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/i18n/app_localizations.dart';

class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('terms.title')),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/feed'),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(l10n.t('terms.heading'), style: theme.textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(l10n.t('terms.updated'), style: theme.textTheme.bodySmall),
          const SizedBox(height: 20),
          _Section(
            title: l10n.t('terms.acceptance.title'),
            body: l10n.t('terms.acceptance.body'),
          ),
          _Section(
            title: l10n.t('terms.accounts.title'),
            body: l10n.t('terms.accounts.body'),
          ),
          _Section(
            title: l10n.t('terms.conduct.title'),
            body: l10n.t('terms.conduct.body'),
          ),
          _Section(
            title: l10n.t('terms.termination.title'),
            body: l10n.t('terms.termination.body'),
          ),
          _Section(
            title: l10n.t('terms.questions.title'),
            body: l10n.t('terms.questions.body'),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(body),
        ],
      ),
    );
  }
}
