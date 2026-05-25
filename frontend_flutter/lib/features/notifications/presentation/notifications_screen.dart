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

  Map<String, dynamic> _metadataRecord(V2Notification n) {
    final metadata = n.metadata;
    if (metadata is Map) {
      return {
        for (final entry in metadata.entries) '${entry.key}': entry.value,
      };
    }
    return const {};
  }

  int? _metadataNumber(Map<String, dynamic> metadata, String key) {
    final value = metadata[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  int? _firstMetadataNumber(Map<String, dynamic> metadata, List<String> keys) {
    for (final key in keys) {
      final value = _metadataNumber(metadata, key);
      if (value != null) return value;
    }
    return null;
  }

  String? _metadataString(Map<String, dynamic> metadata, String key) {
    final value = metadata[key];
    if (value is String && value.isNotEmpty) return value;
    if (value is num || value is bool) return '$value';
    return null;
  }

  bool _isGroupPostNotification(V2Notification n) {
    return n.resourceType == 'group_post' ||
        n.resourceType == 'group_comment' ||
        n.type == 'group_post' ||
        n.type == 'group_comment';
  }

  Future<String?> _groupSlugFor(
    V2Notification n,
    Map<String, dynamic> metadata,
  ) async {
    final groupSlug = _metadataString(metadata, 'group_slug');
    if (groupSlug != null && groupSlug.isNotEmpty) return groupSlug;

    final groupId =
        _metadataNumber(metadata, 'group_id') ??
        (n.resourceType == 'group' ? n.resourceId : null);
    if (groupId == null || groupId <= 0) return null;

    try {
      final groups = await ref.read(groupsApiProvider).myGroups(size: 100);
      for (final group in groups.items) {
        if (group.groupId == groupId) return group.slug;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  Future<String?> _detailRouteFor(V2Notification n) async {
    final metadata = _metadataRecord(n);
    if (n.type == 'group_invite') return '/groups/invites';
    if (n.type == 'login_alert') return '/account/active';

    final conversationId = _metadataNumber(metadata, 'conversation_id');
    if ((n.type == 'direct_message' || n.resourceType == 'direct_message') &&
        conversationId != null &&
        conversationId > 0) {
      return '/chat/conversation/$conversationId';
    }

    final postId =
        _firstMetadataNumber(metadata, [
          'target_post_id',
          'post_id',
          'source_post_id',
        ]) ??
        (n.resourceType == 'post' || n.resourceType == 'group_post'
            ? n.resourceId
            : null);
    if (postId != null && postId > 0) {
      if (_isGroupPostNotification(n)) {
        final groupSlug = await _groupSlugFor(n, metadata);
        if (groupSlug == null || groupSlug.isEmpty) return null;
        return '/groups/$groupSlug/posts/$postId';
      }
      return '/posts/$postId';
    }

    if (n.resourceType == 'user' && n.resourceId != null) {
      return '/users/${n.resourceId}';
    }
    final targetUserId = _metadataNumber(metadata, 'target_user_id');
    if (targetUserId != null && targetUserId > 0) {
      return '/users/$targetUserId';
    }

    if (n.resourceType == 'group') {
      final groupSlug = await _groupSlugFor(n, metadata);
      if (groupSlug == null || groupSlug.isEmpty) return null;
      return '/groups/$groupSlug';
    }
    return null;
  }

  Future<void> _onTap(V2Notification n) async {
    if (n.isDeleted) return;
    final route = await _detailRouteFor(n);
    if (!mounted) return;
    if (route != null) context.push(route);
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
