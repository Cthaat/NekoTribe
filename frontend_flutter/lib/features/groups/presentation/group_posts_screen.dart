import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/app_media_image.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
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
      final api = ref.read(groupsApiProvider);
      final groupPage = await api.myGroups(size: 100);
      final groups = groupPage.items;
      final selectedId = int.tryParse(_groupId);
      final sourceGroups = selectedId == null
          ? groups
          : groups.where((g) => g.groupId == selectedId).toList();
      final posts = <V2GroupPost>[];
      for (final group in sourceGroups) {
        final page = await api.posts(group.groupId, size: 20, type: _type);
        posts.addAll(page.items);
      }
      posts.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _posts = _filterPosts(posts);
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
    final nextLiked = !post.isLikedByMe;
    await ref.read(groupsApiProvider).setGroupPostLikeStatus(
          groupId: post.groupId,
          postId: post.postId,
          liked: nextLiked,
        );
    await _load();
  }

  Future<void> _togglePin(V2GroupPost post) async {
    await ref.read(groupsApiProvider).setGroupPostPinStatus(
          groupId: post.groupId,
          postId: post.postId,
          isPinned: !post.isPinned,
        );
    await _load();
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
                          itemCount: _posts.length,
                          separatorBuilder: (_, _) =>
                              Divider(height: 1, color: theme.dividerColor),
                          itemBuilder: (_, i) {
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
  });

  final V2GroupPost post;
  final V2Group? group;
  final VoidCallback onTap;
  final VoidCallback onLike;
  final VoidCallback onPin;

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
                children: post.mediaUrls
                    .map(
                      (url) => AppMediaImage(
                        url: url,
                        width: 108,
                        height: 108,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    )
                    .toList(),
              ),
            ],
            const SizedBox(height: 6),
            Row(
              children: [
                TextButton.icon(
                  onPressed: onLike,
                  icon: Icon(
                    post.isLikedByMe
                        ? Icons.favorite
                        : Icons.favorite_border,
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
              ],
            ),
          ],
        ),
      ),
    );
  }
}
