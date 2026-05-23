import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/notification_models.dart';

class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  List<V2Notification> _items = [];
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
      final page = await ref.read(notificationsApiProvider).list();
      if (!mounted) return;
      setState(() {
        _items = page.items;
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

  Future<void> _markAllRead() async {
    try {
      await ref.read(notificationsApiProvider).markAllRead();
      if (!mounted) return;
      setState(() => _items = _items
          .map((n) =>
              n.copyWith(isRead: 1, readAt: DateTime.now().toIso8601String()))
          .toList());
    } catch (_) {}
  }

  void _onTap(V2Notification n) {
    if (n.resourceType == 'post' && n.resourceId != null) {
      context.push('/posts/${n.resourceId}');
    } else if (n.resourceType == 'user' && n.actor != null) {
      context.push('/users/${n.actor!.username}');
    }
    if (!n.readFlag) {
      ref
          .read(notificationsApiProvider)
          .markRead([n.notificationId]).catchError((_) {});
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
        title: Text(l10n.t('tab.notifications')),
        actions: [
          IconButton(
            onPressed: _markAllRead,
            icon: const Icon(Icons.done_all),
            tooltip: 'Mark all read',
          ),
        ],
      ),
      body: _loading
          ? const LoadingView()
          : _error != null
              ? ErrorView(error: _error!, onRetry: _load)
              : _items.isEmpty
                  ? EmptyView(message: l10n.t('notification.empty'))
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        itemCount: _items.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final n = _items[i];
                          return ListTile(
                            tileColor: n.readFlag
                                ? null
                                : Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                            leading: const Icon(Icons.notifications),
                            title: Text(n.title.isEmpty ? n.type : n.title),
                            subtitle: Text(n.message),
                            trailing: Text(
                              _formatDate(n.createdAt),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            onTap: () => _onTap(n),
                          );
                        },
                      ),
                    ),
    );
  }
}
