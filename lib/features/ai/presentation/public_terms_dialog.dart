import 'package:flutter/material.dart';

import '../../../shared/i18n/app_localizations.dart';

class PublicTermsDialog extends StatelessWidget {
  const PublicTermsDialog({
    super.key,
    required this.title,
    required this.document,
  });

  final String title;
  final Future<({String title, List<String> blocks})?> document;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      scrollable: true,
      title: Text(title),
      content: FutureBuilder(
        future: document,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return Text(l10n.t('moderation.advice.loadingRule'));
          }
          final data = snapshot.data;
          if (data == null) {
            return Text(l10n.t('moderation.advice.ruleUnavailable'));
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(data.title, style: Theme.of(context).textTheme.titleMedium),
              for (final block in data.blocks)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(block),
                ),
            ],
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.t('common.close')),
        ),
      ],
    );
  }
}
