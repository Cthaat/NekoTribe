import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/responsive.dart';

class EndpointScreen extends ConsumerStatefulWidget {
  const EndpointScreen({super.key});

  @override
  ConsumerState<EndpointScreen> createState() => _EndpointScreenState();
}

class _EndpointScreenState extends ConsumerState<EndpointScreen> {
  late final TextEditingController _apiCtl;
  late final TextEditingController _wsCtl;
  late final TextEditingController _storageCtl;
  String? _pendingError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final cfg = ref.read(appConfigProvider);
    _apiCtl = TextEditingController(text: cfg.apiBaseUrl);
    _wsCtl = TextEditingController(text: cfg.wsBaseUrl);
    _storageCtl = TextEditingController(text: cfg.storageBaseUrl);
  }

  @override
  void dispose() {
    _apiCtl.dispose();
    _wsCtl.dispose();
    _storageCtl.dispose();
    super.dispose();
  }

  void _syncFieldsFrom(AppConfig cfg) {
    _apiCtl.text = cfg.apiBaseUrl;
    _wsCtl.text = cfg.wsBaseUrl;
    _storageCtl.text = cfg.storageBaseUrl;
  }

  bool _validate() {
    bool ok(String s) {
      final t = s.trim();
      if (t.isEmpty) return false;
      final u = Uri.tryParse(t);
      if (u == null) return false;
      return u.hasScheme && u.host.isNotEmpty;
    }

    if (!ok(_apiCtl.text) || !ok(_wsCtl.text) || !ok(_storageCtl.text)) {
      setState(() {
        _pendingError = '请填写完整的 URL（包含 scheme + host），例如 http://host:port';
      });
      return false;
    }
    setState(() => _pendingError = null);
    return true;
  }

  Future<void> _applyPreset(String id) async {
    setState(() => _saving = true);
    await ref.read(appConfigProvider.notifier).selectPreset(id);
    if (!mounted) return;
    final cfg = ref.read(appConfigProvider);
    _syncFieldsFrom(cfg);
    setState(() => _saving = false);
    _toast('已切换到 ${_presetLabel(id)}');
  }

  Future<void> _applyCustom() async {
    if (!_validate()) return;
    setState(() => _saving = true);
    await ref
        .read(appConfigProvider.notifier)
        .setCustom(
          apiBaseUrl: _apiCtl.text,
          wsBaseUrl: _wsCtl.text,
          storageBaseUrl: _storageCtl.text,
        );
    if (!mounted) return;
    setState(() => _saving = false);
    _toast('自定义端点已保存');
  }

  Future<void> _reset() async {
    setState(() => _saving = true);
    await ref.read(appConfigProvider.notifier).resetToDefaults();
    if (!mounted) return;
    final cfg = ref.read(appConfigProvider);
    _syncFieldsFrom(cfg);
    setState(() {
      _saving = false;
      _pendingError = null;
    });
    _toast('已恢复为默认配置');
  }

  String _presetLabel(String id) {
    final ctl = ref.read(appConfigProvider.notifier);
    return ctl.presetById(id)?.label ?? id;
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cfg = ref.watch(appConfigProvider);
    final controller = ref.read(appConfigProvider.notifier);
    final presets = controller.presets;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('endpoint.title'))),
      body: AbsorbPointer(
        absorbing: _saving,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.t('endpoint.current'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    _KvRow(label: 'API', value: cfg.apiBaseUrl),
                    _KvRow(label: 'WS', value: cfg.wsBaseUrl),
                    _KvRow(label: 'Storage', value: cfg.storageBaseUrl),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Icon(Icons.label_outline, size: 16),
                        const SizedBox(width: 6),
                        Text(
                          cfg.isCustom
                              ? l10n.t('endpoint.custom')
                              : (controller
                                        .presetById(cfg.presetId ?? '')
                                        ?.label ??
                                    cfg.presetId ??
                                    ''),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.t('endpoint.presets'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            ...presets.map((p) {
              final selected = p.id == cfg.presetId;
              return Card(
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: _saving ? null : () => _applyPreset(p.id),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2, right: 8),
                          child: Icon(
                            selected
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            color: selected
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.outline,
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                p.label,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              if (p.description != null &&
                                  p.description!.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(p.description!),
                                ),
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  'API: ${p.apiBaseUrl}\nWS:  ${p.wsBaseUrl}\nFile: ${p.storageBaseUrl}',
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (selected)
                          Icon(
                            Icons.check_circle,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                      ],
                    ),
                  ),
                ),
              );
            }),
            const SizedBox(height: 16),
            Text(
              l10n.t('endpoint.custom_section'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _apiCtl,
              decoration: const InputDecoration(
                labelText: 'API Base URL',
                hintText: 'http://host:port',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _wsCtl,
              decoration: const InputDecoration(
                labelText: 'WebSocket Base URL',
                hintText: 'ws://host:port',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _storageCtl,
              decoration: const InputDecoration(
                labelText: 'Storage Base URL',
                hintText: 'http://host:port',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
            ),
            if (_pendingError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _pendingError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _applyCustom,
                    icon: const Icon(Icons.save_outlined),
                    label: Text(l10n.t('endpoint.apply_custom')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _saving ? null : _reset,
                    icon: const Icon(Icons.restore),
                    label: Text(l10n.t('endpoint.reset')),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Card(
              color: Theme.of(context).colorScheme.tertiaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline,
                      color: Theme.of(context).colorScheme.tertiary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(l10n.t('endpoint.hint'))),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _KvRow extends StatelessWidget {
  const _KvRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(label, style: Theme.of(context).textTheme.labelMedium),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }
}
