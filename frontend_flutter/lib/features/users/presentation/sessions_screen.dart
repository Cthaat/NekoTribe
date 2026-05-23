import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

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
      setState(() => _items.removeWhere(
          (s) => s.sessionId == session.sessionId));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorView.describe(context, e))),
      );
    }
  }

  Future<void> _revokeOthers() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Revoke other sessions'),
        content: const Text('Sign out from all other devices?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirm'),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorView.describe(context, e))),
      );
    }
  }

  String _formatDate(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return DateFormat.yMd().add_Hm().format(dt.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sessions'),
        actions: [
          IconButton(
            tooltip: 'Revoke others',
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
                  ? const EmptyView(message: 'No active sessions')
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        itemCount: _items.length,
                        separatorBuilder: (_, _) =>
                            const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final s = _items[i];
                          return ListTile(
                            leading: Icon(
                              s.isCurrent
                                  ? Icons.smartphone
                                  : Icons.devices_other,
                              color: s.isCurrent
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                            ),
                            title: Text(
                              s.deviceInfo.isEmpty
                                  ? 'Unknown device'
                                  : s.deviceInfo,
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('IP: ${s.ipAddress}'),
                                Text('Last: ${_formatDate(s.lastAccessedAt)}'),
                              ],
                            ),
                            trailing: s.isCurrent
                                ? const Chip(label: Text('Current'))
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
