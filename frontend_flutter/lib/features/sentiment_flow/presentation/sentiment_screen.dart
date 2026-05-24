import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../data/sentiment_flow_api.dart';

class SentimentScreen extends ConsumerStatefulWidget {
  const SentimentScreen({super.key});

  @override
  ConsumerState<SentimentScreen> createState() => _SentimentScreenState();
}

class _SentimentScreenState extends ConsumerState<SentimentScreen> {
  final _textController = TextEditingController();
  V2SentimentFlowConfig? _config;
  V2SentimentPrediction? _prediction;
  bool _loadingConfig = true;
  bool _predicting = false;
  Object? _configError;
  Object? _predictError;
  String? _selectedModel;
  bool _returnProbabilities = true;
  bool _includeMetadata = false;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    setState(() {
      _loadingConfig = true;
      _configError = null;
    });
    try {
      final c = await ref.read(sentimentFlowApiProvider).config();
      if (!mounted) return;
      setState(() {
        _config = c;
        _selectedModel = c.defaultModel.isNotEmpty
            ? c.defaultModel
            : (c.availableModels.isNotEmpty ? c.availableModels.first : null);
        _loadingConfig = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _configError = e;
        _loadingConfig = false;
      });
    }
  }

  Future<void> _predict() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _predicting) return;
    setState(() {
      _predicting = true;
      _predictError = null;
      _prediction = null;
    });
    try {
      final p = await ref
          .read(sentimentFlowApiProvider)
          .predict(
            text: text,
            modelId: _selectedModel,
            returnProbabilities: _returnProbabilities,
            includeMetadata: _includeMetadata,
          );
      if (!mounted) return;
      setState(() {
        _prediction = p;
        _predicting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _predictError = e;
        _predicting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('sentiment.title'))),
      body: _loadingConfig
          ? const LoadingView()
          : _configError != null
          ? ErrorView(error: _configError!, onRetry: _loadConfig)
          : _config == null || !_config!.enabled || !_config!.baseUrlConfigured
          ? EmptyView(message: l10n.t('sentiment.disabled'))
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppBreakpoints.contentMaxWidth,
                ),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.2,
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.psychology_outlined,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              l10n.t('sentiment.intro'),
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (_config!.availableModels.isNotEmpty) ...[
                      DropdownButtonFormField<String>(
                        initialValue: _selectedModel,
                        decoration: InputDecoration(
                          labelText: l10n.t('sentiment.model'),
                          prefixIcon: const Icon(Icons.memory),
                        ),
                        items: _config!.availableModels
                            .map(
                              (m) =>
                                  DropdownMenuItem(value: m, child: Text(m)),
                            )
                            .toList(),
                        onChanged: (v) => setState(() => _selectedModel = v),
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextField(
                      controller: _textController,
                      minLines: 5,
                      maxLines: 8,
                      decoration: InputDecoration(
                        labelText: l10n.t('sentiment.text_to_analyze'),
                        hintText: l10n.t('sentiment.text_hint'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      decoration: BoxDecoration(
                        color: theme.cardTheme.color,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: theme.dividerColor),
                      ),
                      child: Column(
                        children: [
                          SwitchListTile(
                            title: Text(l10n.t('sentiment.return_probs')),
                            subtitle: Text(l10n.t('sentiment.return_probs_hint')),
                            value: _returnProbabilities,
                            onChanged: (v) =>
                                setState(() => _returnProbabilities = v),
                          ),
                          Divider(
                            height: 1,
                            indent: 16,
                            color: theme.dividerColor,
                          ),
                          SwitchListTile(
                            title: Text(l10n.t('sentiment.include_metadata')),
                            subtitle: Text(
                              l10n.t('sentiment.include_metadata_hint'),
                            ),
                            value: _includeMetadata,
                            onChanged: (v) =>
                                setState(() => _includeMetadata = v),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _predicting ? null : _predict,
                        icon: _predicting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.play_arrow_rounded),
                        label: Text(l10n.t('sentiment.predict')),
                      ),
                    ),
                    if (_predictError != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.error.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.error_outline,
                              size: 18,
                              color: theme.colorScheme.error,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                ErrorView.describe(context, _predictError!),
                                style: TextStyle(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (_prediction != null) ...[
                      const SizedBox(height: 16),
                      _PredictionView(p: _prediction!),
                    ],
                  ],
                ),
              ),
            ),
    );
  }
}

class _PredictionView extends StatelessWidget {
  const _PredictionView({required this.p});
  final V2SentimentPrediction p;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                l10n.t('sentiment.result'),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  p.label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.equalizer,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                '${l10n.t('sentiment.confidence')}: ${(p.confidence * 100).toStringAsFixed(1)}%',
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
          if (p.probabilities != null) ...[
            const SizedBox(height: 16),
            Text(
              l10n.t('sentiment.probabilities'),
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            ...p.probabilities!.entries.map((e) {
              final v = (e.value as num?)?.toDouble() ?? 0;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 80,
                      child: Text(
                        e.key,
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: v.clamp(0.0, 1.0),
                          minHeight: 8,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 48,
                      child: Text(
                        '${(v * 100).toStringAsFixed(1)}%',
                        style: theme.textTheme.bodySmall,
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
          if (p.metadata != null) ...[
            const SizedBox(height: 16),
            Text(
              l10n.t('sentiment.metadata'),
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            ...p.metadata!.entries.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '${e.key}: ${e.value}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
