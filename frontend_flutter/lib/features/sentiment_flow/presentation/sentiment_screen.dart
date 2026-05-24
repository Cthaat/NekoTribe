import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
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
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('sentiment.title'))),
      body: _loadingConfig
          ? const LoadingView()
          : _configError != null
          ? ErrorView(error: _configError!, onRetry: _loadConfig)
          : _config == null || !_config!.enabled
          ? const EmptyView(
              message: 'SentimentFlow is not enabled on this server',
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_config!.availableModels.isNotEmpty)
                  DropdownButtonFormField<String>(
                    initialValue: _selectedModel,
                    decoration: const InputDecoration(
                      labelText: 'Model',
                      border: OutlineInputBorder(),
                    ),
                    items: _config!.availableModels
                        .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                        .toList(),
                    onChanged: (v) => setState(() => _selectedModel = v),
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: _textController,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: 'Text to analyze',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  title: const Text('Return probabilities'),
                  value: _returnProbabilities,
                  onChanged: (v) => setState(() => _returnProbabilities = v),
                ),
                SwitchListTile(
                  title: const Text('Include metadata'),
                  value: _includeMetadata,
                  onChanged: (v) => setState(() => _includeMetadata = v),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: _predicting ? null : _predict,
                  child: _predicting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.t('sentiment.predict')),
                ),
                const SizedBox(height: 16),
                if (_predictError != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      ErrorView.describe(context, _predictError!),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (_prediction != null) _PredictionView(p: _prediction!),
              ],
            ),
    );
  }
}

class _PredictionView extends StatelessWidget {
  const _PredictionView({required this.p});
  final V2SentimentPrediction p;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Label: ', style: Theme.of(context).textTheme.titleMedium),
                Chip(label: Text(p.label)),
                const SizedBox(width: 8),
                Text('Confidence: ${(p.confidence * 100).toStringAsFixed(1)}%'),
              ],
            ),
            if (p.probabilities != null) ...[
              const Divider(height: 24),
              Text(
                'Probabilities',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              ...p.probabilities!.entries.map((e) {
                final v = (e.value as num?)?.toDouble() ?? 0;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      SizedBox(width: 80, child: Text(e.key)),
                      Expanded(
                        child: LinearProgressIndicator(
                          value: v.clamp(0.0, 1.0),
                          minHeight: 8,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('${(v * 100).toStringAsFixed(1)}%'),
                    ],
                  ),
                );
              }),
            ],
            if (p.metadata != null) ...[
              const Divider(height: 24),
              Text('Metadata', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              ...p.metadata!.entries.map(
                (e) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('${e.key}: ${e.value}'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
