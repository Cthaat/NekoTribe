import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/utils/group_post_link.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../../realtime/data/realtime_service.dart';
import '../data/notifications_api.dart';
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
  bool _refreshing = false;
  bool _loadingMore = false;
  bool _hasNext = false;
  int _page = 1;
  Object? _error;
  bool _unreadOnly = false;
  bool _showDeleted = false;
  bool _markingListed = false;
  String? _type;
  int? _unreadCount;
  int _loadGen = 0;
  int _openRevision = 0;
  late RealtimeService _realtime;
  StreamSubscription<RemoteEvents>? _statusSub;
  StreamSubscription<int>? _recoverySub;
  late final void Function() _stopSessionListener;
  RemoteEvents _remoteEvents = RemoteEvents.unknown;

  @override
  void initState() {
    super.initState();
    _attachRealtime(ref.read(realtimeServiceProvider));
    final store = ref.read(tokenStoreProvider);
    var sessionRevision = store.revision;
    _stopSessionListener = store.listenSessionChanges(() {
      if (!mounted) return;
      if (sessionRevision != store.revision) {
        sessionRevision = store.revision;
        _resetMailbox();
      }
      if (!store.isSessionChanging) {
        scheduleMicrotask(() {
          if (mounted &&
              !store.isSessionChanging &&
              ref.read(authSessionProvider).isAuthenticated) {
            unawaited(_load());
          }
        });
      }
    });
    ref.listenManual(realtimeServiceProvider, (_, next) {
      _detachRealtime();
      _resetMailbox();
      _attachRealtime(next);
      unawaited(_load());
    });
    _load();
  }

  void _resetMailbox() {
    _loadGen++;
    setState(() {
      _items = [];
      _unreadCount = null;
      _remoteEvents = RemoteEvents.unknown;
      _page = 1;
      _hasNext = false;
      _error = null;
      _loading = true;
      _refreshing = false;
      _loadingMore = false;
    });
  }

  void _attachRealtime(RealtimeService service) {
    _realtime = service;
    _remoteEvents = service.remoteEvents;
    service.addListener(_onRealtimeEvent);
    _statusSub = service.remoteStatus.listen((state) {
      if (!mounted ||
          !identical(_realtime, service) ||
          state != service.remoteEvents) {
        return;
      }
      setState(() => _remoteEvents = state);
    });
    _recoverySub = service.recovery.listen((_) {
      if (!mounted ||
          !identical(_realtime, service) ||
          service.remoteEvents != RemoteEvents.connected) {
        return;
      }
      unawaited(_load());
    });
    unawaited(service.connect());
  }

  void _detachRealtime() {
    _realtime.removeListener(_onRealtimeEvent);
    unawaited(_statusSub?.cancel());
    unawaited(_recoverySub?.cancel());
  }

  @override
  void dispose() {
    _stopSessionListener();
    _detachRealtime();
    super.dispose();
  }

  void _onRealtimeEvent(Map<String, dynamic> event) {
    if (!isNotificationRealtimeEvent(event['type'])) {
      return;
    }
    if (!mounted) return;
    unawaited(_load(soft: true));
  }

  bool Function() _captureMailboxOwner() {
    final store = ref.read(tokenStoreProvider);
    final revision = store.revision;
    final realtime = _realtime;
    return () =>
        mounted &&
        identical(_realtime, realtime) &&
        revision == store.revision &&
        !store.isSessionChanging;
  }

  Future<void> _load({bool soft = false}) async {
    final gen = ++_loadGen;
    final sameOwner = _captureMailboxOwner();
    if (!sameOwner()) return;
    bool current() => gen == _loadGen && sameOwner();
    if (!soft) {
      setState(() {
        _loading = true;
        _error = null;
        _page = 1;
        _hasNext = false;
      });
    } else if (mounted) {
      setState(() => _refreshing = true);
    }
    try {
      final api = ref.read(notificationsApiProvider);
      final page = await api.list(
        page: 1,
        type: _type,
        unreadOnly: _unreadOnly,
        showDeleted: _showDeleted,
      );
      if (!current()) return;
      final unreadCount = await api.unreadCount();
      if (!current()) return;
      setState(() {
        _items = page.items;
        _page = 1;
        _hasNext = page.hasNext;
        _unreadCount = unreadCount;
        _loading = false;
        _refreshing = false;
        _loadingMore = false;
        _error = null;
      });
      ref.read(notificationsUnreadProvider.notifier).set(unreadCount);
    } catch (e) {
      if (!current()) return;
      setState(() {
        if (!soft) {
          _error = e;
        }
        _loading = false;
        _refreshing = false;
        _loadingMore = false;
      });
      if (soft) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
      }
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasNext || _loading || _refreshing) return;
    final gen = _loadGen;
    final sameOwner = _captureMailboxOwner();
    if (!sameOwner()) return;
    bool current() => gen == _loadGen && sameOwner();
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final page = await ref
          .read(notificationsApiProvider)
          .list(
            page: next,
            type: _type,
            unreadOnly: _unreadOnly,
            showDeleted: _showDeleted,
          );
      if (!current()) return;
      setState(() {
        final seen = _items.map((item) => item.notificationId).toSet();
        _items = [
          ..._items,
          ...page.items.where((item) => seen.add(item.notificationId)),
        ];
        _page = next;
        _hasNext = page.hasNext;
        _loadingMore = false;
      });
    } catch (e) {
      if (!current()) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _mutate(
    Future<void> Function(NotificationsApi) change, {
    bool refreshOnFailure = false,
  }) async {
    final sameOwner = _captureMailboxOwner();
    if (!sameOwner()) return;
    try {
      await change(ref.read(notificationsApiProvider));
      if (sameOwner()) await _load(soft: true);
    } catch (error) {
      if (!sameOwner()) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorView.describe(context, error))),
      );
      if (refreshOnFailure || error is FormatException) await _load(soft: true);
    }
  }

  Future<void> _markAllRead() => _mutate((api) => api.markAllRead());

  bool get _canMarkListed =>
      !_showDeleted &&
      !_loading &&
      !_refreshing &&
      !_markingListed &&
      _items.any(
        (item) => !item.readFlag && !item.isDeleted && item.notificationId > 0,
      );

  Future<void> _markListedRead() async {
    if (!_canMarkListed) return;
    final ids = _items
        .where((item) => !item.readFlag && !item.isDeleted)
        .map((item) => item.notificationId)
        .where((id) => id > 0 && id <= 9007199254740991)
        .toSet()
        .toList();
    final sameOwner = _captureMailboxOwner();
    if (ids.isEmpty || !sameOwner()) return;
    setState(() => _markingListed = true);
    try {
      await _mutate((api) async {
        for (var start = 0; start < ids.length && sameOwner(); start += 1000) {
          final end = start + 1000 < ids.length ? start + 1000 : ids.length;
          await api.markRead(ids.sublist(start, end));
        }
      }, refreshOnFailure: true);
    } finally {
      if (mounted) setState(() => _markingListed = false);
    }
  }

  Future<void> _setRead(V2Notification item, bool isRead) => _mutate(
    (api) =>
        api.setReadStatus(notificationId: item.notificationId, isRead: isRead),
  );

  Future<void> _delete(V2Notification item) =>
      _mutate((api) => api.deleteNotification(item.notificationId));

  Future<void> _restore(V2Notification item) =>
      _mutate((api) => api.restoreNotification(item.notificationId));

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
    if (n.type == 'group_invite' || n.resourceType == 'group_invite') {
      final cited = notificationTargetId(metadata['invite_id']);
      final resource = n.resourceType == 'group_invite'
          ? notificationTargetId(n.resourceId)
          : null;
      final invite = cited != null && resource != null && cited != resource
          ? null
          : cited ?? resource;
      return invite == null ? '/groups/invites' : '/groups/invites?invite=$invite';
    }
    if (n.type == 'login_alert') return '/account/active';
    if (_isGroupPostNotification(n)) {
      final target = groupPostFromNotification(
        isComment:
            n.type == 'group_comment' || n.resourceType == 'group_comment',
        resourceType: n.resourceType,
        resourceId: n.resourceId,
        metadata: metadata,
      );
      return target == null ? null : groupPostLocation(target);
    }

    final postId =
        notificationTargetId(metadata['target_post_id']) ??
        notificationTargetId(metadata['post_id']) ??
        notificationTargetId(metadata['source_post_id']) ??
        (n.resourceType == 'post' ? notificationTargetId(n.resourceId) : null);
    if (postId != null) {
      final cited = notificationTargetId(metadata['comment_id']);
      final resource = n.resourceType == 'comment'
          ? notificationTargetId(n.resourceId)
          : null;
      final commentId = cited != null && resource != null && cited != resource
          ? null
          : cited ?? resource;
      return commentId == null
          ? '/posts/$postId'
          : '/posts/$postId?comment=$commentId';
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
    final sameOwner = _captureMailboxOwner();
    if (!sameOwner()) return;
    final revision = ++_openRevision;
    bool current() =>
        sameOwner() &&
        revision == _openRevision &&
        ModalRoute.of(context)?.isCurrent == true;

    if (n.type == 'direct_message' || n.resourceType == 'direct_message') {
      final conversationId = notificationTargetId(
        _metadataRecord(n)['conversation_id'],
      );
      try {
        final conversation = conversationId == null
            ? null
            : await ref
                  .read(chatApiProvider)
                  .getDirectConversation(conversationId);
        if (!current()) return;
        if (conversation == null) {
          final message = AppLocalizations.of(
            context,
          ).t('notification.direct_unavailable');
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
          return;
        }
        final participant = conversation.participant;
        final title = participant.displayName.isNotEmpty
            ? participant.displayName
            : participant.username;
        unawaited(
          context.push(
            '/chat/conversation/${conversation.conversationId}',
            extra: {'title': title},
          ),
        );
        if (!n.readFlag) unawaited(_setRead(n, true));
      } catch (error) {
        if (!current()) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorView.describe(context, error))),
        );
      }
      return;
    }

    final route = await _detailRouteFor(n);
    if (!current()) return;
    if (route != null) {
      unawaited(context.push(route));
    }
    if (!n.readFlag) {
      unawaited(_setRead(n, true));
    }
  }

  void _setType(String? type) {
    setState(() {
      _type = type;
      _items = [];
      _loading = true;
      _page = 1;
      _hasNext = false;
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
            key: const Key('notifications-toggle-trash'),
            onPressed: () {
              setState(() {
                _showDeleted = !_showDeleted;
                _items = [];
              });
              unawaited(_load());
            },
            icon: Icon(
              _showDeleted ? Icons.inbox_outlined : Icons.delete_outline,
            ),
            tooltip: l10n.t(
              _showDeleted ? 'notification.inbox' : 'notification.trash',
            ),
          ),
          if (!_showDeleted)
            IconButton(
              key: const Key('notifications-mark-listed-read'),
              onPressed: _canMarkListed ? _markListedRead : null,
              icon: const Icon(Icons.playlist_add_check),
              tooltip: l10n.t('notification.mark_listed_read'),
            ),
          if (!_showDeleted)
            IconButton(
              key: const Key('notifications-mark-all-read'),
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
              if (_remoteEvents == RemoteEvents.unavailable ||
                  _remoteEvents == RemoteEvents.connecting)
                Semantics(
                  liveRegion: true,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text(
                      l10n.t(
                        _remoteEvents == RemoteEvents.unavailable
                            ? 'notification.realtime_unavailable'
                            : 'notification.realtime_connecting',
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: SegmentedButton<bool>(
                  key: const Key('notifications-unread-segments'),
                  segments: [
                    ButtonSegment(
                      value: false,
                      label: Text(l10n.t('common.all')),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text(
                        l10n.t('common.unread'),
                        key: const Key('notifications-filter-unread'),
                      ),
                    ),
                  ],
                  selected: {_unreadOnly},
                  onSelectionChanged: (value) {
                    setState(() {
                      _unreadOnly = value.first;
                      _items = [];
                      _loading = true;
                      _page = 1;
                      _hasNext = false;
                    });
                    _load();
                  },
                ),
              ),
              Expanded(
                child: Column(
                  children: [
                    if (_refreshing && _items.isNotEmpty)
                      const LinearProgressIndicator(minHeight: 2),
                    Expanded(
                      child: _loading
                          ? const LoadingView()
                          : _error != null
                          ? ErrorView(error: _error!, onRetry: _load)
                          : _items.isEmpty
                          ? EmptyView(
                              message: l10n.t(
                                _showDeleted
                                    ? 'notification.trash_empty'
                                    : 'notification.empty',
                              ),
                            )
                          : RefreshIndicator(
                              onRefresh: () => _load(soft: true),
                              child: NotificationListener<ScrollNotification>(
                                onNotification: (n) {
                                  if (n.metrics.pixels >=
                                      n.metrics.maxScrollExtent - 200) {
                                    unawaited(_loadMore());
                                  }
                                  return false;
                                },
                                child: ListView.builder(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    8,
                                    12,
                                    24,
                                  ),
                                  itemCount: _items.length + (_hasNext ? 1 : 0),
                                  itemBuilder: (_, i) {
                                    if (i >= _items.length) {
                                      return const Padding(
                                        padding: EdgeInsets.all(24),
                                        child: Center(
                                          child: CircularProgressIndicator(),
                                        ),
                                      );
                                    }
                                    final n = _items[i];
                                    final theme = Theme.of(context);
                                    final unreadTint = theme.colorScheme.primary
                                        .withValues(alpha: 0.06);
                                    final borderColor = n.readFlag
                                        ? theme.colorScheme.outlineVariant
                                              .withValues(alpha: 0.45)
                                        : theme.colorScheme.primary.withValues(
                                            alpha: 0.22,
                                          );
                                    return Padding(
                                      padding: const EdgeInsets.only(bottom: 8),
                                      child: Material(
                                        color: n.readFlag
                                            ? theme.colorScheme.surface
                                            : unreadTint,
                                        elevation: 0,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                          side: BorderSide(color: borderColor),
                                        ),
                                        clipBehavior: Clip.antiAlias,
                                        child: ListTile(
                                          enabled: !n.isDeleted,
                                          isThreeLine: true,
                                          contentPadding:
                                              const EdgeInsets.fromLTRB(
                                                12,
                                                6,
                                                4,
                                                6,
                                              ),
                                          leading: n.actor != null
                                              ? AppAvatar(
                                                  url: n.actor!.avatarUrl,
                                                  size: 40,
                                                )
                                              : CircleAvatar(
                                                  radius: 20,
                                                  backgroundColor: n.readFlag
                                                      ? theme
                                                            .colorScheme
                                                            .surfaceContainerHighest
                                                      : theme
                                                            .colorScheme
                                                            .primary
                                                            .withValues(
                                                              alpha: 0.12,
                                                            ),
                                                  child: Icon(
                                                    Icons
                                                        .notifications_outlined,
                                                    size: 20,
                                                    color: n.readFlag
                                                        ? theme
                                                              .colorScheme
                                                              .onSurfaceVariant
                                                        : theme
                                                              .colorScheme
                                                              .primary,
                                                  ),
                                                ),
                                          title: Text(
                                            n.title.isEmpty ? n.type : n.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.titleSmall
                                                ?.copyWith(
                                                  fontWeight: n.readFlag
                                                      ? FontWeight.w500
                                                      : FontWeight.w700,
                                                ),
                                          ),
                                          subtitle: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                n.message,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                n.isDeleted
                                                    ? l10n.t(
                                                        'notification.deleted',
                                                      )
                                                    : _formatDate(n.createdAt),
                                                style: theme
                                                    .textTheme
                                                    .labelSmall
                                                    ?.copyWith(
                                                      color: theme
                                                          .colorScheme
                                                          .onSurfaceVariant,
                                                    ),
                                              ),
                                            ],
                                          ),
                                          trailing: PopupMenuButton<String>(
                                            key: ValueKey(
                                              'notification-actions-${n.notificationId}',
                                            ),
                                            onSelected: (value) {
                                              if (value == 'read') {
                                                _setRead(n, true);
                                              }
                                              if (value == 'unread') {
                                                _setRead(n, false);
                                              }
                                              if (value == 'delete') {
                                                _delete(n);
                                              }
                                              if (value == 'restore') {
                                                _restore(n);
                                              }
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
                                                    l10n.t(
                                                      'common.mark_unread',
                                                    ),
                                                  ),
                                                ),
                                              if (!n.isDeleted)
                                                PopupMenuItem(
                                                  value: 'delete',
                                                  child: Text(
                                                    l10n.t('common.delete'),
                                                  ),
                                                ),
                                              if (n.isDeleted)
                                                PopupMenuItem(
                                                  value: 'restore',
                                                  child: Text(
                                                    l10n.t('common.restore'),
                                                  ),
                                                ),
                                            ],
                                          ),
                                          onTap: () => _onTap(n),
                                        ),
                                      ),
                                    );
                                  },
                                ),
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
  }
}
