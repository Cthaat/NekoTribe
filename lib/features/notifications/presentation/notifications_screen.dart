import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/utils/group_post_link.dart';
import '../../../shared/format/relative_time.dart';
import '../../../shared/format/user_agent.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/motion/entrance.dart';
import '../../../shared/motion/skeleton.dart';
import '../../../shared/widgets/ui/surface_card.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/theme/tokens.dart';
import '../../../shared/widgets/glass/liquid_glass_bars.dart';
import '../../../shared/widgets/glass/liquid_glass_surface.dart';
import '../../../shared/widgets/glass/liquid_glass_tokens.dart';
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
  String _clientCategory = 'all';
  final _collapsing = <int>{};
  final Set<int> _expandedIds = <int>{};
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
    _collapsing.clear();
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
    int? collapse,
  }) async {
    final sameOwner = _captureMailboxOwner();
    if (!sameOwner()) return;
    try {
      await change(ref.read(notificationsApiProvider));
      if (!sameOwner()) return;
      if (collapse != null) {
        setState(() => _collapsing.add(collapse));
        final duration = AppMotion.resolve(context, AppMotion.base);
        if (duration != Duration.zero) await Future<void>.delayed(duration);
      }
      if (sameOwner()) await _load(soft: true);
    } catch (error) {
      if (!sameOwner()) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorView.describe(context, error))),
      );
      if (refreshOnFailure || error is FormatException) await _load(soft: true);
    } finally {
      if (sameOwner() && collapse != null) setState(() => _collapsing.remove(collapse));
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
    collapse: _unreadOnly && isRead ? item.notificationId : null,
  );

  Future<void> _delete(V2Notification item) =>
      _mutate((api) => api.deleteNotification(item.notificationId), collapse: item.notificationId);

  Future<void> _restore(V2Notification item) =>
      _mutate((api) => api.restoreNotification(item.notificationId), collapse: item.notificationId);

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
      return invite == null
          ? '/groups/invites'
          : '/groups/invites?invite=$invite';
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
      _clientCategory = 'all';
      _items = [];
      _loading = true;
      _page = 1;
      _hasNext = false;
    });
    _load();
  }

  void _selectCategoryTab(String tab) {
    if (tab == 'unread') {
      if (_unreadOnly && _type == null && _clientCategory == 'all') return;
      setState(() {
        _clientCategory = 'all';
        _unreadOnly = true;
        _type = null;
        _items = [];
        _loading = true;
        _page = 1;
        _hasNext = false;
      });
      _load();
      return;
    }

    final needsReload = _unreadOnly || _type != null;
    setState(() {
      _clientCategory = tab;
      if (needsReload) {
        _unreadOnly = false;
        _type = null;
        _items = [];
        _loading = true;
        _page = 1;
        _hasNext = false;
      }
    });
    if (needsReload) {
      _load();
    }
  }

  List<V2Notification> get _visibleItems {
    if (_clientCategory == 'mentions') {
      return _items
          .where(
            (n) => const {
              'mention',
              'comment',
              'reply',
              'group_comment',
            }.contains(n.type),
          )
          .toList();
    }
    if (_clientCategory == 'system') {
      return _items
          .where(
            (n) => const {'system', 'login_alert', 'security'}.contains(n.type),
          )
          .toList();
    }
    return _items;
  }

  ({IconData icon, Color color}) _typeBadgeStyle(
    BuildContext context,
    V2Notification n,
  ) {
    final theme = Theme.of(context);
    final social = SocialColors.of(context);
    switch (n.type) {
      case 'like':
        return (icon: Icons.favorite, color: social.like);
      case 'comment':
      case 'reply':
      case 'group_comment':
        return (
          icon: Icons.chat_bubble_rounded,
          color: theme.colorScheme.primary,
        );
      case 'retweet':
      case 'repost':
        return (icon: Icons.repeat_rounded, color: social.repost);
      case 'follow':
        return (icon: Icons.person_add_rounded, color: const Color(0xFF7856FF));
      case 'mention':
        return (
          icon: Icons.alternate_email_rounded,
          color: theme.colorScheme.primary,
        );
      case 'login_alert':
      case 'security':
        return (icon: Icons.shield_outlined, color: theme.colorScheme.primary);
      default:
        if (n.type.startsWith('group')) {
          return (icon: Icons.groups_rounded, color: theme.colorScheme.primary);
        }
        return (
          icon: Icons.notifications_outlined,
          color: theme.colorScheme.onSurfaceVariant,
        );
    }
  }

  double _remoteStatusHeight = 40;

  Widget _buildUnderlineTabs(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(AppRadius.pill);
    final activeTab = _unreadOnly ? 'unread' : _clientCategory;
    final tabs = <({String id, String label, Key? textKey})>[
      (id: 'all', label: l10n.t('notification.tab.all'), textKey: null),
      (
        id: 'unread',
        label: l10n.t('notification.tab.unread'),
        textKey: const Key('notifications-filter-unread'),
      ),
      (
        id: 'mentions',
        label: l10n.t('notification.tab.mentions'),
        textKey: null,
      ),
      (id: 'system', label: l10n.t('notification.tab.system'), textKey: null),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(
            alpha: theme.brightness == Brightness.dark ? 0.22 : 0.06,
          ),
          borderRadius: radius,
        ),
        child: Row(
          children: tabs.map((tab) {
            final selected = activeTab == tab.id && _type == null;
            final label = SizedBox(
              height: 36,
              child: Center(
                child: Text(
                  tab.label,
                  key: tab.textKey,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            );
            return Expanded(
              child: InkWell(
                borderRadius: radius,
                onTap: () => _selectCategoryTab(tab.id),
                child: selected
                    ? LiquidGlassSurface(
                        preset: LiquidGlassPreset.pillIndicator,
                        borderRadius: radius,
                        blurEnabled: false,
                        child: label,
                      )
                    : label,
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  String _formatDate(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return DateFormat.yMd().add_Hm().format(dt.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final social = SocialColors.of(context);
    final locale = Localizations.localeOf(context);
    final visible = _visibleItems;
    const tabsHeight = 58.0;
    final topInset =
        kToolbarHeight + tabsHeight + MediaQuery.paddingOf(context).top;
    final showRemoteStatus =
        _remoteEvents == RemoteEvents.unavailable ||
        _remoteEvents == RemoteEvents.connecting;
    final listInset = topInset + (showRemoteStatus ? _remoteStatusHeight : 0);

    return Scaffold(
      backgroundColor: social.surfaceBase,
      extendBodyBehindAppBar: true,
      appBar: LiquidGlassAppBar(
        automaticallyImplyLeading:
            ModalRoute.of(context)?.impliesAppBarDismissal ?? false,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                l10n.t('tab.notifications'),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if ((_unreadCount ?? 0) > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: const BorderRadius.all(Radius.circular(999)),
                ),
                child: Text(
                  '$_unreadCount',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
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
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(tabsHeight),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppBreakpoints.contentMaxWidth,
              ),
              child: _buildUnderlineTabs(context, l10n),
            ),
          ),
        ),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppBreakpoints.contentMaxWidth,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              SkeletonCrossFade(loading: _loading, child: _loading
                  ? ListView.separated(
                      padding: EdgeInsets.fromLTRB(16, listInset + 8, 16, 108),
                      itemCount: 6,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (_, _) => const SurfaceCard(
                        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        child: ListTileSkeleton(),
                      ),
                    )
                  : _error != null
                  ? ErrorView(error: _error!, onRetry: _load)
                  : visible.isEmpty
                  ? EmptyView(
                      message: l10n.t(
                        _showDeleted
                            ? 'notification.trash_empty'
                            : 'notification.empty',
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: () => _load(soft: true),
                      edgeOffset: listInset,
                      child: NotificationListener<ScrollNotification>(
                        onNotification: (n) {
                          if (n.metrics.pixels >=
                              n.metrics.maxScrollExtent - 200) {
                            unawaited(_loadMore());
                          }
                          return false;
                        },
                        child: ListView.builder(
                          padding: EdgeInsets.fromLTRB(
                            16,
                            listInset + 6,
                            16,
                            108,
                          ),
                          itemCount: visible.length + (_hasNext ? 1 : 0),
                          itemBuilder: (_, i) {
                            if (i >= visible.length) {
                              return const Padding(
                                padding: EdgeInsets.all(24),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              );
                            }
                            final n = visible[i];
                            final badge = _typeBadgeStyle(context, n);
                            final formatted = formatSecurityMessage(n.message);
                            final isExpanded = _expandedIds.contains(
                              n.notificationId,
                            );
                            final rowContent = AnimatedContainer(
                              duration: AppMotion.resolve(
                                context,
                                AppMotion.base,
                              ),
                              decoration: BoxDecoration(
                                color: n.readFlag
                                    ? social.surfaceCard
                                    : Color.alphaBlend(
                                        theme.colorScheme.primary.withValues(
                                          alpha: 0.045,
                                        ),
                                        social.surfaceCard,
                                      ),
                                borderRadius: BorderRadius.circular(
                                  AppRadius.card,
                                ),
                              ),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(
                                  AppRadius.card,
                                ),
                                onTap: n.isDeleted ? null : () => _onTap(n),
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    14,
                                    14,
                                    8,
                                    14,
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        width: 32,
                                        height: 32,
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: badge.color.withValues(
                                            alpha: 0.12,
                                          ),
                                          shape: BoxShape.circle,
                                        ),
                                        child: Icon(
                                          badge.icon,
                                          size: 16,
                                          color: badge.color,
                                        ),
                                      ),
                                      if (n.actor != null) ...[
                                        const SizedBox(width: 10),
                                        AppAvatar(
                                          url: n.actor!.avatarUrl,
                                          name: n.actor!.displayName,
                                          seed: n.actor!.userId,
                                          size: 36,
                                        ),
                                      ],
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                if (!n.readFlag) ...[
                                                  Container(
                                                    width: 6,
                                                    height: 6,
                                                    decoration: BoxDecoration(
                                                      color: theme
                                                          .colorScheme
                                                          .primary,
                                                      shape: BoxShape.circle,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 6),
                                                ],
                                                Expanded(
                                                  child: Text(
                                                    n.title.isEmpty
                                                        ? n.type
                                                        : n.title,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: theme
                                                        .textTheme
                                                        .titleSmall
                                                        ?.copyWith(
                                                          fontWeight: n.readFlag
                                                              ? FontWeight.w500
                                                              : FontWeight.w600,
                                                        ),
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                Tooltip(
                                                  message: _formatDate(
                                                    n.createdAt,
                                                  ),
                                                  child: Text(
                                                    n.isDeleted
                                                        ? l10n.t(
                                                            'notification.deleted',
                                                          )
                                                        : formatRelativeTime(
                                                            n.createdAt,
                                                            locale: locale,
                                                          ),
                                                    style: theme
                                                        .textTheme
                                                        .labelSmall
                                                        ?.copyWith(
                                                          color: theme
                                                              .colorScheme
                                                              .onSurfaceVariant,
                                                        ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              formatted.text,
                                              maxLines: 3,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme.textTheme.bodyMedium
                                                  ?.copyWith(
                                                    color: theme
                                                        .colorScheme
                                                        .onSurfaceVariant,
                                                    height: 1.4,
                                                  ),
                                            ),
                                            if (formatted.rawUserAgent !=
                                                null) ...[
                                              const SizedBox(height: 6),
                                              InkWell(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                onTap: () {
                                                  setState(() {
                                                    if (isExpanded) {
                                                      _expandedIds.remove(
                                                        n.notificationId,
                                                      );
                                                    } else {
                                                      _expandedIds.add(
                                                        n.notificationId,
                                                      );
                                                    }
                                                  });
                                                },
                                                child: Padding(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        vertical: 2,
                                                      ),
                                                  child: Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      Icon(
                                                        isExpanded
                                                            ? Icons
                                                                  .expand_less_rounded
                                                            : Icons
                                                                  .devices_outlined,
                                                        size: 14,
                                                        color: theme
                                                            .colorScheme
                                                            .primary,
                                                      ),
                                                      const SizedBox(width: 4),
                                                      Text(
                                                        l10n.t(
                                                          'notification.device_details',
                                                        ),
                                                        style: theme
                                                            .textTheme
                                                            .labelSmall
                                                            ?.copyWith(
                                                              color: theme
                                                                  .colorScheme
                                                                  .primary,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w600,
                                                            ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                              if (isExpanded) ...[
                                                const SizedBox(height: 6),
                                                Container(
                                                  width: double.infinity,
                                                  padding: const EdgeInsets.all(
                                                    10,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: social.surfaceSubtle,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          12,
                                                        ),
                                                  ),
                                                  child: SelectableText(
                                                    formatted.rawUserAgent!,
                                                    style: theme
                                                        .textTheme
                                                        .bodySmall
                                                        ?.copyWith(
                                                          fontFamily:
                                                              'monospace',
                                                          fontSize: 11,
                                                          color: theme
                                                              .colorScheme
                                                              .onSurfaceVariant,
                                                        ),
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ],
                                        ),
                                      ),
                                      PopupMenuButton<String>(
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
                                                l10n.t('common.mark_unread'),
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
                                    ],
                                  ),
                                ),
                              ),
                            );

                            final swipeable = Dismissible(
                              key: ValueKey(
                                'notification-swipe-${n.notificationId}',
                              ),
                              direction: n.isDeleted
                                  ? DismissDirection.startToEnd
                                  : DismissDirection.horizontal,
                              dismissThresholds: const {
                                DismissDirection.startToEnd: 0.35,
                                DismissDirection.endToStart: 0.35,
                              },
                              background: Container(
                                alignment: Alignment.centerLeft,
                                padding: const EdgeInsets.only(left: 20),
                                color: theme.colorScheme.primary.withValues(
                                  alpha: 0.14,
                                ),
                                child: Icon(
                                  n.isDeleted
                                      ? Icons.restore_from_trash
                                      : (n.readFlag
                                            ? Icons.mark_email_unread
                                            : Icons.mark_email_read),
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                              secondaryBackground: n.isDeleted
                                  ? null
                                  : Container(
                                      alignment: Alignment.centerRight,
                                      padding: const EdgeInsets.only(right: 20),
                                      color: theme.colorScheme.error.withValues(
                                        alpha: 0.14,
                                      ),
                                      child: Icon(
                                        Icons.delete_outline,
                                        color: theme.colorScheme.error,
                                      ),
                                    ),
                              confirmDismiss: (direction) async {
                                if (n.isDeleted) {
                                  unawaited(_restore(n));
                                } else if (direction ==
                                    DismissDirection.startToEnd) {
                                  unawaited(_setRead(n, !n.readFlag));
                                } else {
                                  unawaited(_delete(n));
                                }
                                return false;
                              },
                              child: rowContent,
                            );

                            return AnimatedSize(key: ValueKey(n.notificationId),
                              alignment: Alignment.topCenter,
                              duration: AppMotion.resolve(context, AppMotion.base),
                              child: _collapsing.contains(n.notificationId) ? const SizedBox.shrink() : StaggeredEntrance(
                              index: i,
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(
                                    AppRadius.card,
                                  ),
                                  child: swipeable,
                                ),
                              ),
                            ));
                          },
                        ),
                      ),
                    )),
              if (showRemoteStatus)
                Positioned(
                  top: topInset,
                  left: 0,
                  right: 0,
                  child: measureGlassOverlay(
                    Semantics(
                      liveRegion: true,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerLow,
                          border: Border(
                            bottom: BorderSide(color: social.divider),
                          ),
                        ),
                        child: Text(
                          l10n.t(
                            _remoteEvents == RemoteEvents.unavailable
                                ? 'notification.realtime_unavailable'
                                : 'notification.realtime_connecting',
                          ),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                    (height) {
                      if (_remoteStatusHeight != height) {
                        setState(() => _remoteStatusHeight = height);
                      }
                    },
                  ),
                ),
              if (_refreshing && _items.isNotEmpty)
                Positioned(
                  top: listInset,
                  left: 0,
                  right: 0,
                  child: const LinearProgressIndicator(minHeight: 2),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
