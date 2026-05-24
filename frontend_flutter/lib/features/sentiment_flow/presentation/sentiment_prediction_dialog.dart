import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/status_views.dart';
import '../data/sentiment_flow_api.dart';

Future<void> showSentimentPredictionDialog({
  required BuildContext context,
  required String text,
  int? postId,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => SentimentPredictionDialog(text: text, postId: postId),
  );
}

class SentimentPredictionDialog extends ConsumerStatefulWidget {
  const SentimentPredictionDialog({super.key, required this.text, this.postId});

  final String text;
  final int? postId;

  @override
  ConsumerState<SentimentPredictionDialog> createState() =>
      _SentimentPredictionDialogState();
}

class _SentimentPredictionDialogState
    extends ConsumerState<SentimentPredictionDialog> {
  V2SentimentPrediction? _prediction;
  Object? _error;
  bool _loading = true;
  bool _accountDisabled = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_runPrediction);
  }

  Future<void> _runPrediction() async {
    setState(() {
      _loading = true;
      _error = null;
      _prediction = null;
      _accountDisabled = false;
    });

    try {
      final l10n = AppLocalizations.of(context);
      final settings = await ref.read(usersRepositoryProvider).getSettings();
      if (settings.aiSentimentEnabled != true) {
        if (!mounted) return;
        setState(() {
          _accountDisabled = true;
          _loading = false;
        });
        return;
      }

      final config = await ref.read(sentimentFlowApiProvider).config();
      if (!config.enabled || !config.baseUrlConfigured) {
        throw Exception(l10n.t('sentiment.prediction.integrationDisabled'));
      }

      final text = widget.text.trim();
      if (text.isEmpty) {
        throw Exception(l10n.t('sentiment.prediction.emptyText'));
      }

      final prediction = await ref
          .read(sentimentFlowApiProvider)
          .predict(
            text: text,
            modelId: settings.aiSentimentModelId,
            returnProbabilities:
                settings.aiSentimentReturnProbabilities ?? true,
            includeMetadata: settings.aiSentimentIncludeMetadata ?? false,
            topK: settings.aiSentimentTopK,
          );
      if (!mounted) return;
      setState(() {
        _prediction = prediction;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      title: Row(
        children: [
          Icon(Icons.psychology_alt_outlined, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(l10n.t('sentiment.prediction.title'))),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: _loading
            ? _LoadingBody(message: l10n.t('sentiment.prediction.loading'))
            : _accountDisabled
            ? _InfoBody(
                icon: Icons.settings_outlined,
                title: l10n.t('sentiment.prediction.disabledTitle'),
                message: l10n.t('sentiment.prediction.disabledDescription'),
              )
            : _error != null
            ? _ErrorBody(error: _error!, onRetry: _runPrediction)
            : _prediction != null
            ? _PredictionBody(prediction: _prediction!)
            : const SizedBox.shrink(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.t('common.close')),
        ),
        if (!_loading && !_accountDisabled)
          FilledButton.icon(
            onPressed: _runPrediction,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(l10n.t('sentiment.actions.retryPredict')),
          ),
      ],
    );
  }
}

class _LoadingBody extends StatelessWidget {
  const _LoadingBody({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(message)),
      ],
    );
  }
}

class _InfoBody extends StatelessWidget {
  const _InfoBody({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(message, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.error.withValues(alpha: 0.3)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, color: theme.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.t('sentiment.prediction.failed'),
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(ErrorView.describe(context, error)),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: onRetry,
              child: Text(l10n.t('common.retry')),
            ),
          ),
        ],
      ),
    );
  }
}

class _PredictionBody extends StatelessWidget {
  const _PredictionBody({required this.prediction});

  final V2SentimentPrediction prediction;

  Color _labelColor(BuildContext context) {
    final normalized = prediction.label.toLowerCase();
    if (normalized.contains('positive')) return Colors.green;
    if (normalized.contains('negative')) return Colors.red;
    return Theme.of(context).colorScheme.primary;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final labelColor = _labelColor(context);
    final probabilities = prediction.probabilities?.entries.toList() ?? [];
    probabilities.sort((a, b) => b.value.compareTo(a.value));

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.18),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.t('sentiment.prediction.primaryLabel'),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: labelColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: labelColor.withValues(alpha: 0.45),
                        ),
                      ),
                      child: Text(
                        prediction.label,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: labelColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _MetricRow(
                  icon: Icons.equalizer,
                  label: l10n.t('sentiment.prediction.confidence'),
                  value:
                      '${(prediction.confidence * 100).toStringAsFixed(1)}%',
                ),
                if ((prediction.modelName ?? '').isNotEmpty)
                  _MetricRow(
                    icon: Icons.memory,
                    label: l10n.t('sentiment.prediction.model'),
                    value: prediction.modelName!,
                  ),
                if (prediction.timingMs != null)
                  _MetricRow(
                    icon: Icons.timer_outlined,
                    label: l10n.t('sentiment.prediction.timing'),
                    value: '${prediction.timingMs} ms',
                  ),
              ],
            ),
          ),
          if (probabilities.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              l10n.t('sentiment.probabilities'),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            ...probabilities.map(
              (item) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 110,
                      child: Text(
                        item.key,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: item.value.clamp(0, 1),
                          minHeight: 8,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 54,
                      child: Text(
                        '${(item.value * 100).toStringAsFixed(1)}%',
                        textAlign: TextAlign.right,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({
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
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Icon(icon, size: 15, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '$label: $value',
              style: theme.textTheme.bodyMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
