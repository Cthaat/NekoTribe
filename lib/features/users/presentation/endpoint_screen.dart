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

    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('endpoint.title'))),
      body: AbsorbPointer(
        absorbing: _saving,
        child: Align(
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
                      color: theme.colorScheme.primary.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.dns_outlined,
                            size: 18,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            l10n.t('endpoint.current'),
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              cfg.isCustom
                                  ? l10n.t('endpoint.custom')
                                  : (controller
                                            .presetById(cfg.presetId ?? '')
                                            ?.label ??
                                        cfg.presetId ??
                                        ''),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      _KvRow(label: 'API', value: cfg.apiBaseUrl),
                      _KvRow(label: 'WS', value: cfg.wsBaseUrl),
                      _KvRow(label: 'Storage', value: cfg.storageBaseUrl),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  l10n.t('endpoint.presets'),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                ...presets.map((p) {
                  final selected = p.id == cfg.presetId;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: InkWell(
                      onTap: _saving ? null : () => _applyPreset(p.id),
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: theme.cardTheme.color,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: selected
                                ? theme.colorScheme.primary
                                : theme.dividerColor,
                            width: selected ? 2 : 1,
                          ),
                        ),
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
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.outline,
                              ),
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    p.label,
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  if (p.description != null &&
                                      p.description!.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text(
                                        p.description!,
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                      ),
                                    ),
                                  Padding(
                                    padding: const EdgeInsets.only(top: 6),
                                    child: Text(
                                      'API: ${p.apiBaseUrl}\nWS:  ${p.wsBaseUrl}\nFile: ${p.storageBaseUrl}',
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 12,
                                        color: theme
                                            .colorScheme
                                            .onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
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
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _apiCtl,
                  decoration: const InputDecoration(
                    labelText: 'API Base URL',
                    hintText: 'http://host:port',
                    prefixIcon: Icon(Icons.link),
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
                    prefixIcon: Icon(Icons.swap_horiz),
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
                    prefixIcon: Icon(Icons.storage_outlined),
                  ),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                ),
                if (_pendingError != null) ...[
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
                            _pendingError!,
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
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
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.tertiary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.info_outline,
                        color: theme.colorScheme.tertiary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          l10n.t('endpoint.hint'),
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
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
