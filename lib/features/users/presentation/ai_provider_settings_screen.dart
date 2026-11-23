import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/token_store.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/responsive.dart';
import '../../ai/data/ai_user_provider_api.dart';

enum _Action { load, save, test, remove }

class AiProviderSettingsScreen extends ConsumerStatefulWidget {
  const AiProviderSettingsScreen({super.key});

  @override
  ConsumerState<AiProviderSettingsScreen> createState() =>
      _AiProviderSettingsScreenState();
}

class _AiProviderSettingsScreenState
    extends ConsumerState<AiProviderSettingsScreen> {
  final _model = TextEditingController();
  final _key = TextEditingController();
  late final AiUserProviderApi _api;
  late final TokenStore _tokens;
  late final int _sessionRevision;
  late final int _endpointRevision;
  late final VoidCallback _stopSessionListener;
  AiUserProviderSettings? _settings;
  AiProviderPresetId _preset = AiProviderPresetId.defaultService;
  bool _enabled = false;
  bool _expired = false;
  CancelToken? _request;
  String? _notice;

  bool get _current =>
      mounted &&
      !_expired &&
      identical(ref.read(tokenStoreProvider), _tokens) &&
      identical(ref.read(aiUserProviderApiProvider), _api) &&
      !_tokens.isSessionChanging &&
      _tokens.revision == _sessionRevision &&
      _tokens.endpointRevision == _endpointRevision &&
      ref.read(authSessionProvider).isAuthenticated;

  bool get _canEdit => _request == null && _settings?.setupAvailable == true;

  bool get _needsKey {
    final saved = _settings?.config;
    return saved == null ||
        !saved.keyConfigured ||
        saved.reconnectRequired ||
        saved.preset != _preset;
  }

  bool get _canSave =>
      _canEdit &&
      AiUserProviderApi.validModel(_model.text.trim()) &&
      (_key.text.isEmpty ? !_needsKey : AiUserProviderApi.validKey(_key.text));

  bool get _canTest {
    final saved = _settings?.config;
    return _canEdit &&
        saved != null &&
        !_needsKey &&
        _key.text.isEmpty &&
        saved.model == _model.text.trim() &&
        saved.enabled == _enabled;
  }

  @override
  void initState() {
    super.initState();
    _api = ref.read(aiUserProviderApiProvider);
    _tokens = ref.read(tokenStoreProvider);
    _sessionRevision = _tokens.revision;
    _endpointRevision = _tokens.endpointRevision;
    _stopSessionListener = _tokens.listenSessionChanges(() {
      if (_tokens.isSessionChanging ||
          _tokens.revision != _sessionRevision ||
          _tokens.endpointRevision != _endpointRevision) {
        _expire();
      }
    });
    ref.listenManual(aiUserProviderApiProvider, (_, next) {
      if (!identical(next, _api)) _expire();
    });
    ref.listenManual(tokenStoreProvider, (_, next) {
      if (!identical(next, _tokens)) _expire();
    });
    ref.listenManual(authSessionProvider, (_, next) {
      if (next.loading) return;
      if (!next.isAuthenticated) {
        _expire();
      } else if (_settings == null && _notice == null) {
        _run(_Action.load);
      }
    }, fireImmediately: true);
  }

  void _expire() {
    if (!mounted || _expired) return;
    _request?.cancel();
    setState(() {
      _expired = true;
      _request = null;
      _settings = null;
      _notice = null;
      _key.clear();
      _model.clear();
    });
  }

  @override
  void dispose() {
    _stopSessionListener();
    _request?.cancel();
    _key.clear();
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  void _restore(AiUserProviderSettings settings) {
    final config = settings.config;
    _settings = settings;
    _preset =
        config != null &&
            settings.presets.any((preset) => preset.id == config.preset)
        ? config.preset
        : AiProviderPresetId.defaultService;
    _model.text = config?.model ?? '';
    _enabled = config?.enabled ?? false;
    _key.clear();
  }

  Future<void> _run(_Action action) async {
    if (!_current ||
        _request != null ||
        (action == _Action.save && !_canSave) ||
        (action == _Action.test && !_canTest) ||
        (action == _Action.remove && _settings?.config == null)) {
      return;
    }
    final cancel = CancelToken();
    bool current() =>
        _current && identical(_request, cancel) && !cancel.isCancelled;
    final apiKey = action == _Action.save && _key.text.isNotEmpty
        ? _key.text
        : null;
    setState(() {
      _request = cancel;
      _notice = null;
      if (action == _Action.save || action == _Action.remove) _key.clear();
    });
    try {
      switch (action) {
        case _Action.load:
          final settings = await _api.getSettings(cancel);
          if (current()) setState(() => _restore(settings));
        case _Action.save:
          final settings = await _api.saveSettings(
            preset: _preset,
            model: _model.text.trim(),
            enabled: _enabled,
            apiKey: apiKey,
            cancel: cancel,
          );
          if (!current()) return;
          setState(() {
            _restore(settings);
            _notice = 'saved';
          });
          ref.invalidate(aiAvailabilityProvider);
        case _Action.test:
          await _api.testConnection(cancel);
          if (current()) setState(() => _notice = 'verified');
        case _Action.remove:
          final settings = _settings!;
          await _api.removeConnection(cancel);
          if (!current()) return;
          setState(() {
            _restore((
              setupAvailable: settings.setupAvailable,
              presets: settings.presets,
              config: null,
            ));
            _notice = 'removed';
          });
          ref.invalidate(aiAvailabilityProvider);
      }
    } catch (_) {
      if (current()) setState(() => _notice = '${action.name}Failed');
    } finally {
      if (current()) setState(() => _request = null);
    }
  }

  Future<void> _confirmRemoval() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.t('ai.provider.removeTitle')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.t('ai.provider.confirmRemove')),
          ),
        ],
      ),
    );
    if (confirmed == true) await _run(_Action.remove);
  }

  void _edit() => setState(() => _notice = null);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final settings = _settings;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('ai.provider.title')),
        actions: [
          if (!_expired && settings != null)
            IconButton(
              onPressed: _request != null ? null : () => _run(_Action.load),
              tooltip: l10n.t('common.refresh'),
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppBreakpoints.contentMaxWidth,
          ),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(l10n.t('ai.provider.scope')),
              const SizedBox(height: 16),
              if (_expired)
                Text(l10n.t('settings.session_changed'))
              else if (settings != null)
                ..._form(l10n, settings),
              if (_request != null ||
                  (!_expired && settings == null && _notice == null))
                const LinearProgressIndicator(),
              if (_notice case final notice?) ...[
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Text(l10n.t('ai.provider.$notice')),
                ),
                if (settings == null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => _run(_Action.load),
                      child: Text(l10n.t('common.retry')),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _form(AppLocalizations l10n, AiUserProviderSettings settings) {
    final selected = settings.presets.firstWhere(
      (preset) => preset.id == _preset,
    );
    return [
      if (!settings.setupAvailable) ...[
        Text(l10n.t('ai.provider.unavailable')),
        const SizedBox(height: 12),
      ],
      if (settings.config?.reconnectRequired == true) ...[
        Text(l10n.t('ai.provider.reconnect')),
        const SizedBox(height: 12),
      ],
      InputDecorator(
        decoration: InputDecoration(labelText: l10n.t('ai.provider.preset')),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<AiProviderPresetId>(
            isExpanded: true,
            isDense: true,
            value: _preset,
            items: [
              for (final preset in settings.presets)
                DropdownMenuItem(
                  value: preset.id,
                  child: Text(l10n.t('ai.provider.preset.${preset.id.id}')),
                ),
            ],
            onChanged: !_canEdit
                ? null
                : (preset) {
                    if (preset == null || preset == _preset) return;
                    setState(() {
                      _preset = preset;
                      _key.clear();
                      _notice = null;
                    });
                  },
          ),
        ),
      ),
      const SizedBox(height: 8),
      Text(l10n.t('ai.provider.address')),
      SelectableText(selected.baseUrl),
      const SizedBox(height: 16),
      TextField(
        key: const Key('ai-provider-model'),
        controller: _model,
        enabled: _canEdit,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: l10n.t('ai.provider.model'),
          errorText:
              _model.text.trim().isNotEmpty &&
                  !AiUserProviderApi.validModel(_model.text.trim())
              ? l10n.t('ai.provider.invalidModel')
              : null,
        ),
        onChanged: (_) => _edit(),
      ),
      const SizedBox(height: 12),
      TextField(
        key: const Key('ai-provider-api-key'),
        controller: _key,
        enabled: _canEdit,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        decoration: InputDecoration(
          labelText: l10n.t('ai.provider.key'),
          helperText: l10n.t(
            _needsKey ? 'ai.provider.enterKey' : 'ai.provider.keepKey',
          ),
          errorText:
              _key.text.isNotEmpty && !AiUserProviderApi.validKey(_key.text)
              ? l10n.t('ai.provider.invalidKey')
              : null,
        ),
        onChanged: (_) => _edit(),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(l10n.t('ai.provider.enable')),
        value: _enabled,
        onChanged: !_canEdit
            ? null
            : (value) => setState(() {
                _enabled = value;
                _notice = null;
              }),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton(
            onPressed: _canSave ? () => _run(_Action.save) : null,
            child: Text(l10n.t('common.save')),
          ),
          OutlinedButton(
            onPressed: _canTest ? () => _run(_Action.test) : null,
            child: Text(l10n.t('ai.provider.test')),
          ),
          if (settings.config != null)
            TextButton(
              onPressed: _request != null ? null : _confirmRemoval,
              child: Text(l10n.t('ai.provider.remove')),
            ),
        ],
      ),
    ];
  }
}
