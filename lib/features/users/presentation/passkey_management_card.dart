import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/passkey_models.dart';
import '../../auth/presentation/passkey_feedback.dart';

class PasskeyManagementCard extends ConsumerStatefulWidget {
  const PasskeyManagementCard({
    super.key,
    required this.repository,
    required this.isCurrent,
  });

  final AuthRepository repository;
  final bool Function() isCurrent;

  @override
  ConsumerState<PasskeyManagementCard> createState() =>
      _PasskeyManagementCardState();
}

class _PasskeyManagementCardState extends ConsumerState<PasskeyManagementCard> {
  List<PasskeyCredential>? _credentials;
  bool _busy = false;
  String? _error;

  bool _isCurrent() => mounted && widget.isCurrent();

  Future<void> _run(Future<List<PasskeyCredential>> Function() action) async {
    if (_busy || !_isCurrent()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final credentials = await action();
      if (_isCurrent()) setState(() => _credentials = credentials);
    } catch (error) {
      if (_isCurrent()) {
        setState(() => _error = passkeyError(context, error));
      }
    } finally {
      if (_isCurrent()) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    if (_busy || !_isCurrent()) return;
    final l10n = AppLocalizations.of(context);
    var name = '';
    final label = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final tooLong = name.trim().runes.length > 80;
          return AlertDialog(
            title: Text(l10n.t('passkeys.add')),
            content: TextField(
              autofocus: true,
              maxLength: 80,
              onChanged: (value) => setDialogState(() => name = value),
              decoration: InputDecoration(
                labelText: l10n.t('passkeys.name'),
                hintText: 'Passkey',
                errorText: tooLong ? l10n.t('passkeys.name_too_long') : null,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(l10n.t('common.cancel')),
              ),
              FilledButton(
                onPressed: tooLong
                    ? null
                    : () => Navigator.pop(context, name.trim()),
                child: Text(l10n.t('passkeys.add')),
              ),
            ],
          );
        },
      ),
    );
    if (label == null || !_isCurrent()) return;
    final client = ref.read(passkeyClientProvider);
    if (!client.isSupported) return;
    await _run(() async {
      final credential = await widget.repository.registerPasskey(
        create: client.create,
        label: label,
        isActive: _isCurrent,
      );
      return [
        credential,
        ...?_credentials?.where((entry) => entry.id != credential.id),
      ];
    });
  }

  Future<void> _remove(PasskeyCredential credential) async {
    if (_busy || !_isCurrent()) return;
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.t('passkeys.remove')),
        content: Text(credential.label),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.t('passkeys.remove')),
          ),
        ],
      ),
    );
    if (confirmed != true || !_isCurrent()) return;
    await _run(() async {
      await widget.repository.removePasskey(credential.id);
      return [...?_credentials?.where((entry) => entry.id != credential.id)];
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final dates = MaterialLocalizations.of(context);
    final supportsPasskeys = ref.watch(passkeyClientProvider).isSupported;
    final credentials = _credentials;
    return Card(
      child: ExpansionTile(
        leading: const Icon(Icons.key_outlined),
        title: Text(l10n.t('passkeys.title')),
        onExpansionChanged: (open) {
          if (open) {
            _run(widget.repository.listPasskeys);
          }
        },
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (credentials == null && _error != null)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(widget.repository.listPasskeys),
              child: Text(l10n.t('common.retry')),
            ),
          if (credentials != null) ...[
            if (credentials.isEmpty) Text(l10n.t('passkeys.empty')),
            for (final credential in credentials)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(credential.label),
                subtitle: Text(
                  [
                    '${l10n.t('passkeys.created')} ${dates.formatShortDate(credential.createdAt.toLocal())}',
                    if (credential.lastUsedAt case final lastUsed?)
                      '${l10n.t('passkeys.last_used')} ${dates.formatShortDate(lastUsed.toLocal())}',
                  ].join('\n'),
                ),
                trailing: IconButton(
                  tooltip: l10n.t('passkeys.remove'),
                  onPressed: _busy ? null : () => _remove(credential),
                  icon: const Icon(Icons.delete_outline),
                ),
              ),
            if (supportsPasskeys)
              OutlinedButton(
                onPressed: _busy ? null : _add,
                child: Text(l10n.t('passkeys.add')),
              )
            else
              Text(l10n.t('passkeys.device_unavailable')),
          ],
        ],
      ),
    );
  }
}
