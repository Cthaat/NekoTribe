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
      return StatefulBuilder(builder: (ctx, setLocal) {
        return AlertDialog(
          title: Text(l10n.t('common.report')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: selectedReason,
                  items: const [
                    DropdownMenuItem(value: 'spam', child: Text('Spam')),
                    DropdownMenuItem(
                        value: 'abuse', child: Text('Abuse / Harassment')),
                    DropdownMenuItem(
                        value: 'hate', child: Text('Hate speech')),
                    DropdownMenuItem(
                        value: 'sexual', child: Text('Sexual content')),
                    DropdownMenuItem(
                        value: 'violence', child: Text('Violence')),
                    DropdownMenuItem(
                        value: 'misinformation',
                        child: Text('Misinformation')),
                    DropdownMenuItem(value: 'other', child: Text('Other')),
                  ],
                  onChanged: (v) => setLocal(() => selectedReason = v),
                  decoration: const InputDecoration(labelText: 'Reason'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: descController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Details',
                    border: OutlineInputBorder(),
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
                  await ref.read(postsApiProvider).reportContent(
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
                    SnackBar(
                      content:
                          Text(ErrorView.describe(ctx, e)),
                    ),
                  );
                }
              },
              child: Text(l10n.t('common.confirm')),
            ),
          ],
        );
      });
    },
  );
  if (saved == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Report submitted')),
    );
  }
  reasonController.dispose();
  descController.dispose();
}
