import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/network/api_exception.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/routing/auth_navigation.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/media_lightbox.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../../posts/presentation/report_dialog.dart';
import '../data/groups_api.dart';
import '../domain/group_models.dart';

typedef _GroupCursor = ({int? nextPage, List<V2GroupPost> pending});

const _pageSize = 20;

int _compareGroupPosts(V2GroupPost a, V2GroupPost b) {
  int rank(V2GroupPost post) =>
      post.isPinned ? 2 : (post.isAnnouncement ? 1 : 0);
  final byRank = rank(b).compareTo(rank(a));
  if (byRank != 0) return byRank;
  final timeA = DateTime.tryParse(a.createdAt);
  final timeB = DateTime.tryParse(b.createdAt);
  final byTime = timeA != null && timeB != null
      ? timeB.compareTo(timeA)
      : b.createdAt.compareTo(a.createdAt);
  return byTime != 0 ? byTime : b.postId.compareTo(a.postId);
}

class GroupPostsScreen extends ConsumerStatefulWidget {
  const GroupPostsScreen({super.key});

  @override
  ConsumerState<GroupPostsScreen> createState() => _GroupPostsScreenState();
}

class _GroupPostsScreenState extends ConsumerState<GroupPostsScreen> {
  List<V2Group> _groups = [];
  List<V2GroupPost> _posts = [];
  Map<int, _GroupCursor> _cursors = {};
  String _groupId = 'all';
  String _type = 'all';
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasNext = false;
  int _page = 1;
  Object? _error;
  final Set<String> _busyPostKeys = <String>{};
  bool _expired = false;
  int _loadRevision = 0;
  late final VoidCallback _stopSession;

  bool get _active => mounted && !_expired;

  String _postKey(V2GroupPost post) => '${post.groupId}:${post.postId}';

  @override
  void initState() {
    super.initState();
    final store = ref.read(tokenStoreProvider);
    _expired = store.isSessionChanging;
    _stopSession = store.listenSessionChanges(_expire);
    ref.listenManual(groupsApiProvider, (previous, next) {
      if (!identical(previous, next)) _expire();
    });
    _load();
  }

  @override
  void dispose() {
    _stopSession();
    super.dispose();
  }

  void _expire() {
    if (!_active) return;
    setState(() {
      _expired = true;
      _groups = [];
      _posts = [];
      _cursors = {};
    });
  }

  Future<List<V2Group>?> _readJoinedGroups(
    GroupsApi api,
    bool Function() valid,
  ) async {
    final groups = <int, V2Group>{};
    for (var index = 1; ; index++) {
      final page = await api.myGroups(page: index, size: 100);
      if (!valid()) return null;
      for (final group in page.items) {
        if (group.groupId > 0) groups[group.groupId] = group;
      }
      if (!page.hasNext) return groups.values.toList();
      if (page.items.isEmpty || index == 10000) {
        throw const FormatException('Invalid group pagination');
      }
    }
  }

  Future<List<V2GroupPost>?> _mergeNext(
    GroupsApi api,
    Map<int, _GroupCursor> cursors,
    String type,
    bool Function() valid,
  ) async {
    final result = <V2GroupPost>[];
    final seen = {..._posts.map(_postKey)};
    while (result.length < _pageSize) {
      V2GroupPost? head;
      for (final id in cursors.keys) {
        var cursor = cursors[id]!;
        final next = cursor.nextPage;
        if (cursor.pending.isEmpty && next != null) {
          final page = await api.posts(
            id,
            page: next,
            size: _pageSize,
            type: type,
          );
          if (!valid()) return null;
          if (page.items.any(
                (post) => post.groupId != id || post.postId <= 0,
              ) ||
              (page.hasNext && (page.items.isEmpty || next == 10000))) {
            throw const FormatException('Invalid group post page');
          }
          cursor = (
            nextPage: page.hasNext ? next + 1 : null,
            pending: page.items,
          );
          cursors[id] = cursor;
        }
        if (cursor.pending.isEmpty) continue;
        final candidate = cursor.pending.first;
        if (head == null || _compareGroupPosts(candidate, head) < 0) {
          head = candidate;
        }
      }
      if (head == null) break;
      final cursor = cursors[head.groupId]!;
      cursors[head.groupId] = (
        nextPage: cursor.nextPage,
        pending: cursor.pending.sublist(1),
      );
      if (seen.add(_postKey(head))) result.add(head);
    }
    return result;
  }

  bool _moreAcrossGroups(Map<int, _GroupCursor> cursors) => cursors.values.any(
    (cursor) => cursor.pending.isNotEmpty || cursor.nextPage != null,
  );

  Future<void> _load() async {
    if (!_active) return;
    final revision = ++_loadRevision;
    bool valid() => _active && revision == _loadRevision;
    final selectedId = int.tryParse(_groupId);
    final type = _type;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _posts = [];
      _cursors = {};
      _error = null;
      _page = 1;
      _hasNext = false;
    });
    try {
      final api = ref.read(groupsApiProvider);
      final groups = await _readJoinedGroups(api, valid);
      if (!valid() || groups == null) return;
      List<V2GroupPost> posts;
      final cursors = <int, _GroupCursor>{};
      var hasNext = false;
      if (selectedId == null) {
        for (final group in groups) {
          cursors[group.groupId] = (nextPage: 1, pending: const []);
        }
        final merged = await _mergeNext(api, cursors, type, valid);
        if (merged == null) return;
        posts = merged;
        hasNext = _moreAcrossGroups(cursors);
      } else if (!groups.any((group) => group.groupId == selectedId)) {
        posts = [];
      } else {
        final page = await api.posts(
          selectedId,
          page: 1,
          size: _pageSize,
          type: type,
        );
        posts = page.items;
        hasNext = page.hasNext;
      }
      if (!valid()) return;
      setState(() {
        _groups = groups;
        _cursors = cursors;
        _posts = _filterPosts(posts);
        _page = 1;
        _hasNext = hasNext;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!valid()) return;
      setState(() {
        _error = e;
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (!_active) return;
    final revision = _loadRevision;
    bool valid() => _active && revision == _loadRevision;
    final selectedId = int.tryParse(_groupId);
    if (_loadingMore || !_hasNext || _loading) return;
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final api = ref.read(groupsApiProvider);
      final cursors = {..._cursors};
      final List<V2GroupPost> items;
      final bool hasNext;
      if (selectedId == null) {
        final merged = await _mergeNext(api, cursors, _type, valid);
        if (merged == null) return;
        items = merged;
        hasNext = _moreAcrossGroups(cursors);
      } else {
        final page = await api.posts(
          selectedId,
          page: next,
          size: _pageSize,
          type: _type,
        );
        items = page.items;
        hasNext = page.hasNext;
      }
      if (!valid()) return;
      setState(() {
        _cursors = cursors;
        _posts = _filterPosts(
          {
            for (final post in [..._posts, ...items]) _postKey(post): post,
          }.values.toList(),
        );
        _page = next;
        _hasNext = hasNext;
        _loadingMore = false;
      });
    } catch (e) {
      if (!valid()) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  List<V2GroupPost> _filterPosts(List<V2GroupPost> posts) {
    return switch (_type) {
      'pinned' => posts.where((p) => p.isPinned).toList(),
      'announcement' => posts.where((p) => p.isAnnouncement).toList(),
      _ => posts,
    };
  }

  V2Group? _groupFor(int groupId) {
    for (final group in _groups) {
      if (group.groupId == groupId) return group;
    }
    return null;
  }

  Future<void> _toggleLike(V2GroupPost post) => _updatePost(post, () async {
    final state = await ref
        .read(groupsApiProvider)
        .setGroupPostLikeStatus(
          groupId: post.groupId,
          postId: post.postId,
          liked: !post.isLikedByMe,
        );
    return (V2GroupPost current) =>
        current.copyWith(isLikedByMe: state.liked, likesCount: state.count);
  });

  Future<void> _togglePin(V2GroupPost post) => _updatePost(post, () async {
    await ref
        .read(groupsApiProvider)
        .setGroupPostPinStatus(
          groupId: post.groupId,
          postId: post.postId,
          isPinned: !post.isPinned,
        );
    return null;
  }, reload: true);

  Future<void> _updatePost(
    V2GroupPost post,
    Future<V2GroupPost Function(V2GroupPost)?> Function() mutate, {
    bool reload = false,
  }) async {
    if (!_active || !requireAuthenticatedAction(context, ref)) return;
    final key = _postKey(post);
    if (_busyPostKeys.contains(key)) return;
    final revision = _loadRevision;
    bool valid() => _active && revision == _loadRevision;
    setState(() => _busyPostKeys.add(key));
    try {
      final update = await mutate();
      if (!valid()) return;
      if (reload) {
        await _load();
        return;
      }
      setState(() {
        _posts = _filterPosts([
          for (final current in _posts)
            if (_postKey(current) != key)
              current
            else if (update != null)
              update(current),
        ]);
      });
    } catch (error) {
      if (!valid()) return;
      if (error is ApiException && error.isNotFound) {
        setState(
          () => _posts = _posts
              .where((current) => _postKey(current) != key)
              .toList(),
        );
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorView.describe(context, error))),
      );
    } finally {
      if (_active) setState(() => _busyPostKeys.remove(key));
    }
  }

  Future<void> _deletePost(V2GroupPost post) async {
    await _updatePost(post, () async {
      await ref
          .read(groupsApiProvider)
          .deleteGroupPost(groupId: post.groupId, postId: post.postId);
      return null;
    }, reload: true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_expired) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.t('group.posts_title'))),
        body: Center(child: Text(l10n.t('visibility.sessionChanged'))),
      );
    }
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('group.posts_title'))),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppBreakpoints.contentMaxWidth,
          ),
          child: Column(
            children: [
              _Filters(
                groups: _groups,
                groupId: _groupId,
                type: _type,
                onGroupChanged: (value) {
                  setState(() => _groupId = value);
                  _load();
                },
                onTypeChanged: (value) {
                  setState(() => _type = value);
                  _load();
                },
              ),
              Divider(height: 1, color: theme.dividerColor),
              Expanded(
                child: _loading
                    ? const LoadingView()
                    : _error != null
                    ? ErrorView(error: _error!, onRetry: _load)
                    : _posts.isEmpty && !_hasNext
                    ? EmptyView(message: l10n.t('group.no_posts'))
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.separated(
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: _posts.length + (_hasNext ? 1 : 0),
                          separatorBuilder: (_, _) =>
                              Divider(height: 1, color: theme.dividerColor),
                          itemBuilder: (_, i) {
                            if (i >= _posts.length) {
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                child: Center(
                                  child: _loadingMore
                                      ? const CircularProgressIndicator()
                                      : OutlinedButton(
                                          onPressed: _loadMore,
                                          child: Text(
                                            l10n.t('group.posts_load_more'),
                                          ),
                                        ),
                                ),
                              );
                            }
                            final post = _posts[i];
                            final pending = _busyPostKeys.contains(
                              _postKey(post),
                            );
                            return _GroupFeedPostTile(
                              post: post,
                              group: _groupFor(post.groupId),
                              onTap: () {
                                final group = _groupFor(post.groupId);
                                if (group == null) return;
                                context.push(
                                  '/groups/${group.slug}/posts/${post.postId}',
                                );
                              },
                              onLike: pending ? null : () => _toggleLike(post),
                              onPin: pending ? null : () => _togglePin(post),
                              onDelete: pending
                                  ? null
                                  : () => _deletePost(post),
                              onReport: () => showReportDialog(
                                context,
                                ref,
                                targetType: 'group_post',
                                targetId: post.postId,
                              ),
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

class _Filters extends StatelessWidget {
  const _Filters({
    required this.groups,
    required this.groupId,
    required this.type,
    required this.onGroupChanged,
    required this.onTypeChanged,
  });

  final List<V2Group> groups;
  final String groupId;
  final String type;
  final ValueChanged<String> onGroupChanged;
  final ValueChanged<String> onTypeChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              // Controlled by parent rebuild after filter changes.
              // ignore: deprecated_member_use
              value: groupId,
              decoration: InputDecoration(
                labelText: l10n.t('group.group'),
                isDense: true,
              ),
              items: [
                DropdownMenuItem(
                  value: 'all',
                  child: Text(l10n.t('group.filter_all_groups')),
                ),
                for (final group in groups)
                  DropdownMenuItem(
                    value: '${group.groupId}',
                    child: Text(group.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (value) {
                if (value != null) onGroupChanged(value);
              },
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<String>(
              // Controlled by parent rebuild after filter changes.
              // ignore: deprecated_member_use
              value: type,
              decoration: InputDecoration(
                labelText: l10n.t('common.details'),
                isDense: true,
              ),
              items: [
                DropdownMenuItem(
                  value: 'all',
                  child: Text(l10n.t('group.type_all')),
                ),
                DropdownMenuItem(
                  value: 'pinned',
                  child: Text(l10n.t('group.type_pinned')),
                ),
                DropdownMenuItem(
                  value: 'announcement',
                  child: Text(l10n.t('group.type_announcement')),
                ),
              ],
              onChanged: (value) {
                if (value != null) onTypeChanged(value);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupFeedPostTile extends StatelessWidget {
  const _GroupFeedPostTile({
    required this.post,
    required this.group,
    required this.onTap,
    required this.onLike,
    required this.onPin,
    required this.onDelete,
    required this.onReport,
  });

  final V2GroupPost post;
  final V2Group? group;
  final VoidCallback onTap;
  final VoidCallback? onLike;
  final VoidCallback? onPin;
  final VoidCallback? onDelete;
  final VoidCallback onReport;

  String _formatDate(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return DateFormat.MMMd().add_Hm().format(dt.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AppAvatar(url: post.author.avatarUrl, size: 36),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        post.author.displayName.isEmpty
                            ? post.author.username
                            : post.author.displayName,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        [
                          if (group != null) group!.name,
                          _formatDate(post.createdAt),
                        ].join(' · '),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (post.isPinned)
                  Icon(
                    Icons.push_pin,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                if (post.isAnnouncement)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Icon(
                      Icons.campaign,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(post.content, style: theme.textTheme.bodyMedium),
            if (post.mediaUrls.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < post.mediaUrls.length; i++)
                    Tooltip(
                      message: l10n.t('media.open'),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => showMediaLightbox(
                          context: context,
                          items: post.mediaUrls
                              .map((url) => MediaLightboxItem(url: url))
                              .toList(growable: false),
                          initialIndex: i,
                        ),
                        child: AppMediaImage(
                          url: post.mediaUrls[i],
                          width: 108,
                          height: 108,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 6),
            Row(
              children: [
                TextButton.icon(
                  onPressed: onLike,
                  icon: Icon(
                    post.isLikedByMe ? Icons.favorite : Icons.favorite_border,
                    size: 18,
                  ),
                  label: Text('${post.likesCount}'),
                ),
                TextButton.icon(
                  onPressed: null,
                  icon: const Icon(Icons.mode_comment_outlined, size: 18),
                  label: Text('${post.commentsCount}'),
                ),
                const Spacer(),
                IconButton(
                  tooltip: post.isPinned
                      ? l10n.t('group.unpin')
                      : l10n.t('group.pin'),
                  onPressed: onPin,
                  icon: Icon(
                    post.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                  ),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_horiz),
                  onSelected: (value) {
                    if (value == 'delete') onDelete?.call();
                    if (value == 'report') onReport();
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'report',
                      child: Text(l10n.t('common.report')),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      enabled: onDelete != null,
                      child: Text(l10n.t('common.delete')),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
