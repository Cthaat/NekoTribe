import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/user_models.dart';

class SessionsScreen extends ConsumerStatefulWidget {
  const SessionsScreen({super.key});

  @override
  ConsumerState<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends ConsumerState<SessionsScreen> {
  List<V2SessionItem> _items = [];
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await ref.read(authApiProvider).listSessions();
      if (!mounted) return;
      setState(() {
        _items = list;
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

  Future<void> _revoke(V2SessionItem session) async {
    try {
      await ref.read(authApiProvider).revokeSession(session.sessionId);
      if (!mounted) return;
      setState(
        () => _items.removeWhere((s) => s.sessionId == session.sessionId),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _revokeOthers() async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.t('account.sessions.revoke_others')),
        content: Text(l10n.t('account.sessions.revoke_others_body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.t('common.confirm')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(authApiProvider).revokeOtherSessions();
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  String _formatDate(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return DateFormat.yMd().add_Hm().format(dt.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('account.sessions.title')),
        actions: [
          IconButton(
            tooltip: l10n.t('account.sessions.revoke_others'),
            icon: const Icon(Icons.logout),
            onPressed: _items.length > 1 ? _revokeOthers : null,
          ),
        ],
      ),
      body: _loading
          ? const LoadingView()
          : _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : _items.isEmpty
          ? EmptyView(message: l10n.t('account.sessions.empty'))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                itemCount: _items.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final s = _items[i];
                  return ListTile(
                    leading: Icon(
                      s.isCurrent ? Icons.smartphone : Icons.devices_other,
                      color: s.isCurrent
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                    title: Text(
                      s.deviceInfo.isEmpty
                          ? l10n.t('account.sessions.unknown_device')
                          : s.deviceInfo,
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${l10n.t('account.sessions.ip')}: ${s.ipAddress}',
                        ),
                        Text(
                          '${l10n.t('account.sessions.last')}: ${_formatDate(s.lastAccessedAt)}',
                        ),
                      ],
                    ),
                    trailing: s.isCurrent
                        ? Chip(label: Text(l10n.t('common.current')))
                        : IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _revoke(s),
                          ),
                    isThreeLine: true,
                  );
                },
              ),
            ),
    );
  }
}
