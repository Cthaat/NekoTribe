import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/endpoint_probe.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/responsive.dart';

class EndpointScreen extends ConsumerStatefulWidget {
  const EndpointScreen({super.key, this.probe = probeDeploymentEndpoints});

  final Future<EndpointChecks> Function(AppConfig config) probe;

  @override
  ConsumerState<EndpointScreen> createState() => _EndpointScreenState();
}

class _EndpointScreenState extends ConsumerState<EndpointScreen> {
  late final TextEditingController _apiCtl;
  late final TextEditingController _wsCtl;
  late final TextEditingController _storageCtl;
  bool _followRealtime = true;
  bool _followStorage = true;
  String? _pendingError;
  bool _saving = false;
  bool _checking = false;
  EndpointChecks? _readiness;
  int _probeVersion = 0;

  @override
  void initState() {
    super.initState();
    final cfg = ref.read(appConfigProvider);
    _apiCtl = TextEditingController(text: cfg.apiBaseUrl);
    _wsCtl = TextEditingController(text: cfg.wsBaseUrl);
    _storageCtl = TextEditingController(text: cfg.storageBaseUrl);
    _updateFollowing(cfg);
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
    _updateFollowing(cfg);
  }

  void _updateFollowing(AppConfig cfg) {
    final shared = _derivedEndpoints(cfg.apiBaseUrl);
    String clean(String address) =>
        address.trim().replaceFirst(RegExp(r'/+$'), '');
    _followRealtime =
        cfg.wsBaseUrl.trim().isEmpty ||
        clean(cfg.wsBaseUrl) == shared?.wsBaseUrl;
    _followStorage =
        cfg.storageBaseUrl.trim().isEmpty ||
        clean(cfg.storageBaseUrl) == shared?.storageBaseUrl;
  }

  AppConfig? _derivedEndpoints(String api) {
    try {
      return AppConfig.fromCustom(apiBaseUrl: api);
    } on FormatException {
      return null;
    }
  }

  void _apiChanged(String api) {
    final derived = _derivedEndpoints(api);
    if (derived != null) {
      if (_followRealtime) _wsCtl.text = derived.wsBaseUrl;
      if (_followStorage) _storageCtl.text = derived.storageBaseUrl;
    }
    setState(() {
      _clearProbe();
      _pendingError = null;
    });
  }

  void _clearProbe() {
    _probeVersion++;
    _readiness = null;
    _checking = false;
  }

  Future<void> _checkEndpoint() async {
    final attempt = ++_probeVersion;
    setState(() {
      _checking = true;
      _readiness = null;
      _pendingError = null;
    });
    try {
      final config = AppConfig.fromCustom(
        apiBaseUrl: _apiCtl.text,
        wsBaseUrl: _followRealtime ? '' : _wsCtl.text,
        storageBaseUrl: _followStorage ? '' : _storageCtl.text,
      );
      final browserPage = ref.read(appConfigProvider.notifier).browserPage;
      if (hasMixedEndpointTransport(config, browserPage)) {
        throw const BrowserEndpointTransportException();
      }
      final result = await widget.probe(config);
      if (!mounted || attempt != _probeVersion) return;
      setState(() => _readiness = result);
    } on BrowserEndpointTransportException {
      if (!mounted || attempt != _probeVersion) return;
      final l10n = AppLocalizations.of(context);
      setState(() => _pendingError = l10n.t('endpoint.mixed_transport'));
    } on FormatException {
      if (!mounted || attempt != _probeVersion) return;
      final l10n = AppLocalizations.of(context);
      setState(() => _pendingError = l10n.t('endpoint.invalid_addresses'));
    } finally {
      if (mounted && attempt == _probeVersion) {
        setState(() => _checking = false);
      }
    }
  }

  Future<void> _applyPreset(String id) => _saveEndpoint(
    () => ref.read(appConfigProvider.notifier).selectPreset(id),
    '已切换到 ${_presetLabel(id)}',
  );

  Future<void> _applyCustom() => _saveEndpoint(
    () => ref
        .read(appConfigProvider.notifier)
        .setCustom(
          apiBaseUrl: _apiCtl.text,
          wsBaseUrl: _followRealtime ? '' : _wsCtl.text,
          storageBaseUrl: _followStorage ? '' : _storageCtl.text,
        ),
    '自定义端点已保存',
  );

  void _useSameOrigin() {
    try {
      final config = AppConfig.fromCustom(apiBaseUrl: _apiCtl.text);
      _syncFieldsFrom(config);
      setState(() {
        _clearProbe();
        _pendingError = null;
      });
    } on FormatException {
      final l10n = AppLocalizations.of(context);
      setState(() => _pendingError = l10n.t('endpoint.invalid_addresses'));
    }
  }

  Future<void> _reset() => _saveEndpoint(
    () => ref.read(appConfigProvider.notifier).resetToDefaults(),
    '已恢复为默认配置',
  );

  Future<void> _saveEndpoint(
    Future<void> Function() save,
    String confirmation,
  ) async {
    setState(() {
      _saving = true;
      _pendingError = null;
      _clearProbe();
    });
    try {
      await save();
      if (!mounted) return;
      _syncFieldsFrom(ref.read(appConfigProvider));
      _toast(confirmation);
    } catch (error) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      setState(
        () => _pendingError = l10n.t(
          switch (error) {
            BrowserEndpointTransportException() => 'endpoint.mixed_transport',
            FormatException() => 'endpoint.invalid_addresses',
            _ => 'endpoint.save_failed',
          },
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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
                                        color:
                                            theme.colorScheme.onSurfaceVariant,
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
                  onChanged: _apiChanged,
                  decoration: const InputDecoration(
                    labelText: 'API Base URL',
                    hintText: 'http://host:port',
                    prefixIcon: Icon(Icons.link),
                  ),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: _useSameOrigin,
                      child: Text(l10n.t('endpoint.use_same_origin')),
                    ),
                    OutlinedButton(
                      onPressed: _checking || _saving ? null : _checkEndpoint,
                      child: Text(l10n.t('endpoint.check_readiness')),
                    ),
                  ],
                ),
                if (_checking)
                  Semantics(
                    liveRegion: true,
                    child: Text(l10n.t('endpoint.readiness.checking')),
                  )
                else if (_readiness case final result?)
                  Semantics(
                    liveRegion: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l10n.t('endpoint.readiness.${result.api.name}')),
                        Text(
                          l10n.t(
                            'endpoint.media_readiness.${result.media.name}',
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: _wsCtl,
                  onChanged: (value) => setState(() {
                    _followRealtime = value.trim().isEmpty;
                    _pendingError = null;
                  }),
                  decoration: InputDecoration(
                    labelText: 'WebSocket Base URL',
                    hintText: 'ws://host:port',
                    helperText: _followRealtime
                        ? l10n.t('endpoint.follows_api')
                        : null,
                    prefixIcon: const Icon(Icons.swap_horiz),
                  ),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _storageCtl,
                  onChanged: (value) => setState(() {
                    _followStorage = value.trim().isEmpty;
                    _clearProbe();
                    _pendingError = null;
                  }),
                  decoration: InputDecoration(
                    labelText: 'Storage Base URL',
                    hintText: 'http://host:port',
                    helperText: _followStorage
                        ? l10n.t('endpoint.follows_api')
                        : null,
                    prefixIcon: const Icon(Icons.storage_outlined),
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
