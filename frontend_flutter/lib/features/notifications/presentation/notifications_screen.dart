import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/responsive.dart';
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
  bool _unreadOnly = false;
  String? _type;
  int? _unreadCount;

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
      final api = ref.read(notificationsApiProvider);
      final page = await api.list(type: _type, unreadOnly: _unreadOnly);
      final unreadCount = await api.unreadCount();
      if (!mounted) return;
      setState(() {
        _items = page.items;
        _unreadCount = unreadCount;
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
      setState(
        () => _items = _items
            .map(
              (n) => n.copyWith(
                isRead: 1,
                readAt: DateTime.now().toIso8601String(),
              ),
            )
            .toList(),
      );
      _unreadCount = 0;
    } catch (_) {}
  }

  Future<void> _setRead(V2Notification n, bool isRead) async {
    try {
      await ref
          .read(notificationsApiProvider)
          .setReadStatus(notificationId: n.notificationId, isRead: isRead);
      if (!mounted) return;
      setState(() {
        _items = _items
            .map(
              (item) => item.notificationId == n.notificationId
                  ? item.copyWith(
                      isRead: isRead ? 1 : 0,
                      readAt: isRead ? DateTime.now().toIso8601String() : '',
                    )
                  : item,
            )
            .toList();
        final current = _unreadCount ?? 0;
        _unreadCount = isRead ? (current - 1).clamp(0, 1 << 30) : current + 1;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _delete(V2Notification n) async {
    try {
      await ref
          .read(notificationsApiProvider)
          .deleteNotification(n.notificationId);
      if (!mounted) return;
      setState(() {
        _items = _items
            .map(
              (item) => item.notificationId == n.notificationId
                  ? item.copyWith(deletedAt: DateTime.now().toIso8601String())
                  : item,
            )
            .toList();
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _restore(V2Notification n) async {
    try {
      await ref
          .read(notificationsApiProvider)
          .restoreNotification(n.notificationId);
      if (!mounted) return;
      setState(() {
        _items = _items
            .map(
              (item) => item.notificationId == n.notificationId
                  ? item.copyWith(deletedAt: '')
                  : item,
            )
            .toList();
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  void _onTap(V2Notification n) {
    if (n.isDeleted) return;
    if (n.resourceType == 'post' && n.resourceId != null) {
      context.push('/posts/${n.resourceId}');
    } else if (n.resourceType == 'user' && n.actor != null) {
      context.push('/users/${n.actor!.userId}');
    } else if (n.resourceType == 'group' && n.metadata is Map) {
      final slug = (n.metadata as Map)['group_slug'];
      if (slug is String && slug.isNotEmpty) context.push('/groups/$slug');
    }
    if (!n.readFlag) {
      _setRead(n, true);
    }
  }

  void _setType(String? type) {
    setState(() {
      _type = type;
      _items = [];
      _loading = true;
    });
    _load();
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
        title: Text(
          _unreadCount == null
              ? l10n.t('tab.notifications')
              : '${l10n.t('tab.notifications')} ($_unreadCount)',
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: l10n.t('notification.filter'),
            icon: const Icon(Icons.filter_list),
            onSelected: (value) {
              if (value == 'all') {
                _setType(null);
              } else {
                _setType(value);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'all',
                child: Text(l10n.t('notification.filter.all_types')),
              ),
              PopupMenuItem(
                value: 'follow',
                child: Text(l10n.t('notification.filter.follows')),
              ),
              PopupMenuItem(
                value: 'like',
                child: Text(l10n.t('notification.filter.likes')),
              ),
              PopupMenuItem(
                value: 'comment',
                child: Text(l10n.t('notification.filter.comments')),
              ),
              PopupMenuItem(
                value: 'mention',
                child: Text(l10n.t('notification.filter.mentions')),
              ),
              PopupMenuItem(
                value: 'group',
                child: Text(l10n.t('notification.filter.groups')),
              ),
              PopupMenuItem(
                value: 'system',
                child: Text(l10n.t('notification.filter.system')),
              ),
            ],
          ),
          IconButton(
            onPressed: _markAllRead,
            icon: const Icon(Icons.done_all),
            tooltip: l10n.t('notification.mark_all_read'),
          ),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppBreakpoints.contentMaxWidth,
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(
                      value: false,
                      label: Text(l10n.t('common.all')),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text(l10n.t('common.unread')),
                    ),
                  ],
                  selected: {_unreadOnly},
                  onSelectionChanged: (value) {
                    setState(() {
                      _unreadOnly = value.first;
                      _items = [];
                      _loading = true;
                    });
                    _load();
                  },
                ),
              ),
              Expanded(
                child: _loading
                    ? const LoadingView()
                    : _error != null
                    ? ErrorView(error: _error!, onRetry: _load)
                    : _items.isEmpty
                    ? EmptyView(message: l10n.t('notification.empty'))
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.separated(
                          itemCount: _items.length,
                          separatorBuilder: (_, _) => Divider(
                            height: 1,
                            color: Theme.of(context).dividerColor,
                          ),
                          itemBuilder: (_, i) {
                            final n = _items[i];
                            return ListTile(
                              enabled: !n.isDeleted,
                              tileColor: n.readFlag
                                  ? null
                                  : Theme.of(context).colorScheme.primary
                                        .withValues(alpha: 0.05),
                              leading: Icon(
                                Icons.notifications_outlined,
                                color: n.readFlag
                                    ? Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant
                                    : Theme.of(context).colorScheme.primary,
                              ),
                              title: Text(
                                n.title.isEmpty ? n.type : n.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                n.message,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    n.isDeleted
                                        ? l10n.t('notification.deleted')
                                        : _formatDate(n.createdAt),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                  PopupMenuButton<String>(
                                    onSelected: (value) {
                                      if (value == 'read') _setRead(n, true);
                                      if (value == 'unread') _setRead(n, false);
                                      if (value == 'delete') _delete(n);
                                      if (value == 'restore') _restore(n);
                                    },
                                    itemBuilder: (_) => [
                                      if (!n.readFlag && !n.isDeleted)
                                        PopupMenuItem(
                                          value: 'read',
                                          child: Text(
                                            l10n.t('common.mark_read'),
                                          ),
                                        ),
                                      if (n.readFlag && !n.isDeleted)
                                        PopupMenuItem(
                                          value: 'unread',
                                          child: Text(
                                            l10n.t('common.mark_unread'),
                                          ),
                                        ),
                                      if (!n.isDeleted)
                                        PopupMenuItem(
                                          value: 'delete',
                                          child: Text(l10n.t('common.delete')),
                                        ),
                                      if (n.isDeleted)
                                        PopupMenuItem(
                                          value: 'restore',
                                          child: Text(l10n.t('common.restore')),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                              onTap: () => _onTap(n),
                            );
                          },
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
