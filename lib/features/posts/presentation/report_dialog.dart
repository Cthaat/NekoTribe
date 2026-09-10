import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/status_views.dart';

Future<void> showReportDialog(
  BuildContext context,
  WidgetRef ref, {
  required String targetType,
  required int targetId,
}) async {
  final reasonController = TextEditingController();
  final descController = TextEditingController();
  String? selectedReason = 'spam';
  final l10n = AppLocalizations.of(context);
  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setLocal) {
          return AlertDialog(
            title: Text(l10n.t('common.report')),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: selectedReason,
                    items: [
                      DropdownMenuItem(
                        value: 'spam',
                        child: Text(l10n.t('report.reason.spam')),
                      ),
                      DropdownMenuItem(
                        value: 'abuse',
                        child: Text(l10n.t('report.reason.abuse')),
                      ),
                      DropdownMenuItem(
                        value: 'hate',
                        child: Text(l10n.t('report.reason.hate')),
                      ),
                      DropdownMenuItem(
                        value: 'sexual',
                        child: Text(l10n.t('report.reason.sexual')),
                      ),
                      DropdownMenuItem(
                        value: 'violence',
                        child: Text(l10n.t('report.reason.violence')),
                      ),
                      DropdownMenuItem(
                        value: 'misinformation',
                        child: Text(l10n.t('report.reason.misinformation')),
                      ),
                      DropdownMenuItem(
                        value: 'other',
                        child: Text(l10n.t('report.reason.other')),
                      ),
                    ],
                    onChanged: (v) => setLocal(() => selectedReason = v),
                    decoration: InputDecoration(
                      labelText: l10n.t('common.reason'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: descController,
                    maxLines: 3,
                    decoration: InputDecoration(
                      labelText: l10n.t('report.details'),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(l10n.t('common.cancel')),
              ),
              FilledButton(
                onPressed: () async {
                  try {
                    await ref
                        .read(postsApiProvider)
                        .reportContent(
                          targetType: targetType,
                          targetId: targetId,
                          reason: selectedReason ?? 'other',
                          description: descController.text.trim().isEmpty
                              ? null
                              : descController.text.trim(),
                        );
                    if (ctx.mounted) Navigator.of(ctx).pop(true);
                  } catch (e) {
                    if (!ctx.mounted) return;
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(content: Text(ErrorView.describe(ctx, e))),
                    );
                  }
                },
                child: Text(l10n.t('common.confirm')),
              ),
            ],
          );
        },
      );
    },
  );
  if (saved == true && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.t('report.submitted'))));
  }
  reasonController.dispose();
  descController.dispose();
}
