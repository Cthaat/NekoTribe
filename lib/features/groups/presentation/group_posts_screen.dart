import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/routing/auth_navigation.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/media_lightbox.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../../posts/presentation/report_dialog.dart';
import '../domain/group_models.dart';

class GroupPostsScreen extends ConsumerStatefulWidget {
  const GroupPostsScreen({super.key});

  @override
  ConsumerState<GroupPostsScreen> createState() => _GroupPostsScreenState();
}

class _GroupPostsScreenState extends ConsumerState<GroupPostsScreen> {
  List<V2Group> _groups = [];
  List<V2GroupPost> _posts = [];
  String _groupId = 'all';
  String _type = 'all';
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasNext = false;
  int _page = 1;
  Object? _error;
  final Set<String> _busyPostKeys = <String>{};

  String _postKey(V2GroupPost post) => '${post.groupId}:${post.postId}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _page = 1;
      _hasNext = false;
    });
    try {
      final api = ref.read(groupsApiProvider);
      final groupPage = await api.myGroups(size: 100);
      final groups = groupPage.items;
      final selectedId = int.tryParse(_groupId);
      List<V2GroupPost> posts;
      var hasNext = false;
      if (selectedId == null) {
        // Fan-in first page across groups; larger page size for all view.
        posts = <V2GroupPost>[];
        for (final group in groups) {
          final page = await api.posts(group.groupId, size: 50, type: _type);
          posts.addAll(page.items);
        }
        posts.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        hasNext = false;
      } else {
        final page = await api.posts(selectedId, page: 1, size: 20, type: _type);
        posts = page.items;
        hasNext = page.hasNext;
      }
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _posts = _filterPosts(posts);
        _page = 1;
        _hasNext = hasNext;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _loadMore() async {
    final selectedId = int.tryParse(_groupId);
    if (selectedId == null || _loadingMore || !_hasNext || _loading) return;
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final page = await ref
          .read(groupsApiProvider)
          .posts(selectedId, page: next, size: 20, type: _type);
      if (!mounted) return;
      setState(() {
        _posts = _filterPosts([..._posts, ...page.items]);
        _page = next;
        _hasNext = page.hasNext;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
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

  Future<void> _toggleLike(V2GroupPost post) async {
    if (!requireAuthenticatedAction(context, ref)) return;
    final key = _postKey(post);
    if (_busyPostKeys.contains(key)) return;
    final nextLiked = !post.isLikedByMe;
    final nextCount = nextLiked
        ? post.likesCount + 1
        : (post.likesCount - 1).clamp(0, 1 << 30);
    // Optimistic local update — avoid full multi-group fan-in reload.
    setState(() {
      _busyPostKeys.add(key);
      _posts = [
        for (final p in _posts)
          if (p.postId == post.postId && p.groupId == post.groupId)
            p.copyWith(isLikedByMe: nextLiked, likesCount: nextCount)
          else
            p,
      ];
    });
    try {
      await ref
          .read(groupsApiProvider)
          .setGroupPostLikeStatus(
            groupId: post.groupId,
            postId: post.postId,
            liked: nextLiked,
          );
    } catch (e) {
      if (!mounted) return;
      // Revert on failure.
      setState(() {
        _posts = [
          for (final p in _posts)
            if (p.postId == post.postId && p.groupId == post.groupId)
              p.copyWith(
                isLikedByMe: post.isLikedByMe,
                likesCount: post.likesCount,
              )
            else
              p,
        ];
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      if (mounted) {
        setState(() => _busyPostKeys.remove(key));
      }
    }
  }

  Future<void> _togglePin(V2GroupPost post) async {
    if (!requireAuthenticatedAction(context, ref)) return;
    final key = _postKey(post);
    if (_busyPostKeys.contains(key)) return;
    final nextPinned = !post.isPinned;
    setState(() {
      _busyPostKeys.add(key);
      _posts = [
        for (final p in _posts)
          if (p.postId == post.postId && p.groupId == post.groupId)
            p.copyWith(isPinned: nextPinned)
          else
            p,
      ];
    });
    try {
      await ref
          .read(groupsApiProvider)
          .setGroupPostPinStatus(
            groupId: post.groupId,
            postId: post.postId,
            isPinned: nextPinned,
          );
      if (!mounted) return;
      // If filtering by pinned, drop unpinned posts from the visible list.
      if (_type == 'pinned' && !nextPinned) {
        setState(() {
          _posts = _posts
              .where(
                (p) =>
                    !(p.postId == post.postId && p.groupId == post.groupId),
              )
              .toList();
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _posts = [
          for (final p in _posts)
            if (p.postId == post.postId && p.groupId == post.groupId)
              p.copyWith(isPinned: post.isPinned)
            else
              p,
        ];
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      if (mounted) {
        setState(() => _busyPostKeys.remove(key));
      }
    }
  }

  Future<void> _deletePost(V2GroupPost post) async {
    if (!requireAuthenticatedAction(context, ref)) return;
    try {
      await ref
          .read(groupsApiProvider)
          .deleteGroupPost(groupId: post.groupId, postId: post.postId);
      if (!mounted) return;
      setState(() {
        _posts.removeWhere(
          (item) => item.postId == post.postId && item.groupId == post.groupId,
        );
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
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
              if (_groupId == 'all' && !_loading && _error == null && _posts.isNotEmpty)
                Material(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.55),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 16,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l10n.t('group.posts_all_limited'),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              Divider(height: 1, color: theme.dividerColor),
              Expanded(
                child: _loading
                    ? const LoadingView()
                    : _error != null
                    ? ErrorView(error: _error!, onRetry: _load)
                    : _posts.isEmpty
                    ? EmptyView(message: l10n.t('group.no_posts'))
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.separated(
                          itemCount: _posts.length + (_hasNext ? 1 : 0),
                          separatorBuilder: (_, _) =>
                              Divider(height: 1, color: theme.dividerColor),
                          itemBuilder: (_, i) {
                            if (i >= _posts.length) {
                              if (!_loadingMore) {
                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) {
                                  _loadMore();
                                });
                              }
                              return const Padding(
                                padding: EdgeInsets.symmetric(vertical: 16),
                                child: Center(
                                  child: SizedBox.square(
                                    dimension: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                ),
                              );
                            }
                            final post = _posts[i];
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
                              onLike: () => _toggleLike(post),
                              onPin: () => _togglePin(post),
                              onDelete: () => _deletePost(post),
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
  final VoidCallback onLike;
  final VoidCallback onPin;
  final VoidCallback onDelete;
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
                    if (value == 'delete') onDelete();
                    if (value == 'report') onReport();
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'report',
                      child: Text(l10n.t('common.report')),
                    ),
                    PopupMenuItem(
                      value: 'delete',
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
