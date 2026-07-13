import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/group_models.dart';

class GroupDetailScreen extends ConsumerStatefulWidget {
  const GroupDetailScreen({super.key, required this.slug});
  final String slug;

  @override
  ConsumerState<GroupDetailScreen> createState() => _GroupDetailScreenState();
}

class _GroupDetailScreenState extends ConsumerState<GroupDetailScreen> {
  V2Group? _group;
  List<V2GroupPost> _posts = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasNext = false;
  int _page = 1;
  Object? _error;
  bool _busy = false;

  static const _pageSize = 20;

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
      _loadingMore = false;
    });
    try {
      final api = ref.read(groupsApiProvider);
      final group = await api.getGroup(widget.slug);
      final posts = await api.posts(group.groupId, page: 1, size: _pageSize);
      if (!mounted) return;
      setState(() {
        _group = group;
        _posts = posts.items;
        _page = 1;
        _hasNext = posts.hasNext;
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

  Future<void> _loadMorePosts() async {
    if (_loadingMore || !_hasNext || _loading || _group == null) return;
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final page = await ref
          .read(groupsApiProvider)
          .posts(_group!.groupId, page: next, size: _pageSize);
      if (!mounted) return;
      setState(() {
        _posts = [..._posts, ...page.items];
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

  Future<void> _toggleMembership() async {
    if (_group == null || _busy) return;
    setState(() => _busy = true);
    try {
      final api = ref.read(groupsApiProvider);
      if (_group!.membership.isMember) {
        await api.leaveGroup(_group!.groupId);
      } else {
        await api.joinGroup(_group!.groupId);
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _composePost() async {
    final controller = TextEditingController();
    final l10n = AppLocalizations.of(context);
    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.t('group.new_post')),
        content: TextField(
          controller: controller,
          maxLines: 5,
          minLines: 3,
          decoration: InputDecoration(hintText: l10n.t('group.compose_hint')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(l10n.t('common.post')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || result.isEmpty) return;
    try {
      final created = await ref
          .read(groupsApiProvider)
          .createPost(groupId: _group!.groupId, content: result);
      if (!mounted) return;
      // Local prepend keeps scroll/history; avoid full page reload flash.
      setState(() {
        _posts = [created, ..._posts];
        final group = _group;
        if (group != null) {
          // Keep membership/meta; only post list is updated.
          _group = group;
        }
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
      appBar: AppBar(
        title: Text(
          _group?.name ?? l10n.t('group.group'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          // Manage is owner/admin/moderator only — not every member.
          if (_group != null && _canManageGroup(_group!.membership.role))
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: l10n.t('common.settings'),
              onPressed: () => context.push('/groups/${widget.slug}/manage'),
            ),
        ],
      ),
      floatingActionButton: _group != null && _group!.membership.isMember
          ? FloatingActionButton.extended(
              onPressed: _composePost,
              icon: const Icon(Icons.edit),
              label: Text(l10n.t('group.new_post')),
            )
          : null,
      body: _loading
          ? const LoadingView()
          : _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : _group == null
          ? const SizedBox.shrink()
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppBreakpoints.contentMaxWidth,
                ),
                child: RefreshIndicator(
                  onRefresh: _load,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n.metrics.pixels >=
                          n.metrics.maxScrollExtent - 200) {
                        _loadMorePosts();
                      }
                      return false;
                    },
                    child: ListView(
                      children: [
                        if (_group!.coverUrl != null)
                          AppMediaImage(
                            url: _group!.coverUrl!,
                            height: 180,
                            borderRadius: BorderRadius.zero,
                          ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                          child: Row(
                            children: [
                              AppAvatar(url: _group!.avatarUrl, size: 64),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _group!.name,
                                      style: theme.textTheme.titleLarge
                                          ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 4),
                                    Wrap(
                                      spacing: 12,
                                      runSpacing: 4,
                                      children: [
                                        _MetaPiece(
                                          icon: Icons.people_outline,
                                          text:
                                              '${_group!.memberCount} ${l10n.t('group.members')}',
                                        ),
                                        _MetaPiece(
                                          icon: Icons.lock_outline,
                                          text: _group!.privacyDesc.isEmpty
                                              ? _group!.privacy
                                              : _group!.privacyDesc,
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                          child: SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              onPressed: _busy ? null : _toggleMembership,
                              style: _group!.membership.isMember
                                  ? FilledButton.styleFrom(
                                      backgroundColor: theme
                                          .colorScheme
                                          .surfaceContainerHighest,
                                      foregroundColor:
                                          theme.colorScheme.onSurface,
                                    )
                                  : null,
                              child: _busy
                                  ? const SizedBox(
                                      height: 16,
                                      width: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Text(
                                      _group!.membership.isMember
                                          ? l10n.t('group.leave')
                                          : l10n.t('group.join'),
                                    ),
                            ),
                          ),
                        ),
                        if (_group!.description.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                            child: Text(
                              _group!.description,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                        if (_group!.tags.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: _group!.tags
                                  .map((t) => Chip(label: Text('#$t')))
                                  .toList(),
                            ),
                          ),
                        Divider(height: 1, color: theme.dividerColor),
                        if (_posts.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(32),
                            child: Center(
                              child: Text(l10n.t('group.no_posts')),
                            ),
                          )
                        else
                          ..._posts.map(
                            (p) => _GroupPostTile(
                              post: p,
                              onTap: () => context.push(
                                '/groups/${widget.slug}/posts/${p.postId}',
                              ),
                            ),
                          ),
                        if (_hasNext)
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(child: CircularProgressIndicator()),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

bool _canManageGroup(String? role) {
  return role == 'owner' || role == 'admin' || role == 'moderator';
}

class _MetaPiece extends StatelessWidget {
  const _MetaPiece({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _GroupPostTile extends StatelessWidget {
  const _GroupPostTile({required this.post, required this.onTap});
  final V2GroupPost post;
  final VoidCallback onTap;

  String _formatDate(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return DateFormat.MMMd().add_Hm().format(dt.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
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
                        _formatDate(post.createdAt),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (post.isPinned)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Icon(
                      Icons.push_pin,
                      size: 14,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                if (post.isAnnouncement)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Icon(
                      Icons.campaign,
                      size: 14,
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
                      (url) => ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: AppMediaImage(
                          url: url,
                          width: 120,
                          height: 120,
                          borderRadius: BorderRadius.zero,
                        ),
                      ),
                    )
                    .toList(),
              ),
            ],
            const SizedBox(height: 8),
            DefaultTextStyle(
              style: theme.textTheme.bodySmall!.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.favorite_border,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text('${post.likesCount}'),
                  const SizedBox(width: 14),
                  Icon(
                    Icons.mode_comment_outlined,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text('${post.commentsCount}'),
                  const SizedBox(width: 14),
                  Icon(
                    Icons.visibility_outlined,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text('${post.viewsCount}'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
