import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/routing/auth_navigation.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/post_models.dart';

class PostCard extends ConsumerStatefulWidget {
  const PostCard({
    super.key,
    required this.post,
    this.onChanged,
    this.onReport,
    this.onDeleted,
  });

  final V2Post post;
  final void Function(V2Post updated)? onChanged;
  final VoidCallback? onReport;
  final VoidCallback? onDeleted;

  @override
  ConsumerState<PostCard> createState() => _PostCardState();
}

class _PostCardState extends ConsumerState<PostCard> {
  late V2Post _post;
  bool _busyLike = false;
  bool _busyBookmark = false;

  @override
  void initState() {
    super.initState();
    _post = widget.post;
  }

  Future<void> _toggleLike() async {
    if (_busyLike) return;
    if (!requireAuthenticatedAction(context, ref)) return;
    setState(() => _busyLike = true);
    final api = ref.read(postsApiProvider);
    final wasLiked = _post.viewerState.isLiked;
    final originalStats = _post.stats;
    setState(() {
      _post = _post.copyWith(
        viewerState: _post.viewerState.copyWith(isLiked: !wasLiked),
        stats: _post.stats.copyWith(
          likesCount: wasLiked
              ? (_post.stats.likesCount - 1).clamp(0, 1 << 30)
              : _post.stats.likesCount + 1,
        ),
      );
    });
    try {
      final newState = wasLiked
          ? await api.unlikePost(_post.postId)
          : await api.likePost(_post.postId);
      if (!mounted) return;
      setState(() {
        _post = _post.copyWith(viewerState: newState);
      });
      widget.onChanged?.call(_post);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _post = _post.copyWith(
          viewerState: _post.viewerState.copyWith(isLiked: wasLiked),
          stats: originalStats,
        );
      });
    } finally {
      if (mounted) setState(() => _busyLike = false);
    }
  }

  Future<void> _toggleBookmark() async {
    if (_busyBookmark) return;
    if (!requireAuthenticatedAction(context, ref)) return;
    setState(() => _busyBookmark = true);
    final api = ref.read(postsApiProvider);
    final wasBookmarked = _post.viewerState.isBookmarked;
    setState(() {
      _post = _post.copyWith(
        viewerState:
            _post.viewerState.copyWith(isBookmarked: !wasBookmarked),
      );
    });
    try {
      final newState = wasBookmarked
          ? await api.unbookmarkPost(_post.postId)
          : await api.bookmarkPost(_post.postId);
      if (!mounted) return;
      setState(() => _post = _post.copyWith(viewerState: newState));
      widget.onChanged?.call(_post);
    } catch (_) {
      if (!mounted) return;
      setState(() => _post = _post.copyWith(
            viewerState:
                _post.viewerState.copyWith(isBookmarked: wasBookmarked),
          ));
    } finally {
      if (mounted) setState(() => _busyBookmark = false);
    }
  }

  Future<void> _deletePost() async {
    if (!requireAuthenticatedAction(context, ref)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete post'),
        content: const Text('This post will be removed from NekoTribe.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(postsApiProvider).deletePost(_post.postId);
      if (!mounted) return;
      widget.onDeleted?.call();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Post deleted')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorView.describe(context, e))),
      );
    }
  }

  Future<void> _quotePost() async {
    if (!requireAuthenticatedAction(context, ref)) return;
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Quote post'),
        content: TextField(
          controller: controller,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'Add your comment',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Post'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null) return;
    try {
      await ref.read(postsApiProvider).createRetweet(
            postId: _post.postId,
            content: text,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Quote posted')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorView.describe(context, e))),
      );
    }
  }

  Future<void> _sendFeedback(String feedback) async {
    if (!requireAuthenticatedAction(context, ref)) return;
    try {
      await ref.read(postsApiProvider).recordRecommendationFeedback(
            postId: _post.postId,
            feedback: feedback,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Feedback saved')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorView.describe(context, e))),
      );
    }
  }

  void _handleMenu(String value) {
    switch (value) {
      case 'edit':
        if (requireAuthenticatedAction(context, ref)) {
          context.push('/posts/${_post.postId}/edit');
        }
        break;
      case 'delete':
        _deletePost();
        break;
      case 'quote':
        _quotePost();
        break;
      case 'not_interested':
      case 'show_less':
        _sendFeedback(value);
        break;
      case 'report':
        if (requireAuthenticatedAction(context, ref)) {
          widget.onReport?.call();
        }
        break;
    }
  }

  String _formatDate(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    final local = dt.toLocal();
    final now = DateTime.now();
    if (now.difference(local).inDays < 1) {
      return DateFormat.Hm().format(local);
    }
    if (local.year == now.year) {
      return DateFormat.Md().format(local);
    }
    return DateFormat.yMd().format(local);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => context.push('/posts/${_post.postId}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () =>
                  context.push('/users/${_post.author.userId}'),
              child: AppAvatar(url: _post.author.avatarUrl, size: 44),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          _post.author.displayName.isEmpty
                              ? _post.author.username
                              : _post.author.displayName,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          '@${_post.author.username}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '· ${_formatDate(_post.createdAt)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                      const Spacer(),
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.more_horiz),
                        onSelected: _handleMenu,
                        itemBuilder: (_) => [
                          if (_post.viewerState.canDelete) ...[
                            PopupMenuItem(
                              value: 'edit',
                              child: Text(l10n.t('common.edit')),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: Text(l10n.t('common.delete')),
                            ),
                          ],
                          const PopupMenuItem(
                            value: 'quote',
                            child: Text('Quote'),
                          ),
                          const PopupMenuItem(
                            value: 'not_interested',
                            child: Text('Not interested'),
                          ),
                          const PopupMenuItem(
                            value: 'show_less',
                            child: Text('Show less like this'),
                          ),
                          PopupMenuItem(
                              value: 'report',
                              child: Text(l10n.t('common.report'))),
                        ],
                      ),
                    ],
                  ),
                  if (_post.content.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(_post.content),
                  ],
                  if (_post.media.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _MediaGrid(media: _post.media),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _ActionButton(
                        icon: Icons.chat_bubble_outline,
                        label: '${_post.stats.commentsCount}',
                        onTap: () =>
                            context.push('/posts/${_post.postId}'),
                      ),
                      const SizedBox(width: 16),
                      _ActionButton(
                        icon: _post.viewerState.isLiked
                            ? Icons.favorite
                            : Icons.favorite_border,
                        label: '${_post.stats.likesCount}',
                        active: _post.viewerState.isLiked,
                        onTap: _toggleLike,
                      ),
                      const SizedBox(width: 16),
                      _ActionButton(
                        icon: _post.viewerState.isBookmarked
                            ? Icons.bookmark
                            : Icons.bookmark_border,
                        label: '',
                        active: _post.viewerState.isBookmarked,
                        onTap: _toggleBookmark,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MediaGrid extends StatelessWidget {
  const _MediaGrid({required this.media});
  final List<V2MediaAsset> media;

  @override
  Widget build(BuildContext context) {
    if (media.isEmpty) return const SizedBox.shrink();
    if (media.length == 1) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: AppMediaImage(url: media.first.publicUrl),
      );
    }
    final count = media.length.clamp(0, 4);
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 4,
      crossAxisSpacing: 4,
      children: [
        for (var i = 0; i < count; i++)
          AppMediaImage(url: media[i].publicUrl),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.outline;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: color),
            if (label.isNotEmpty) ...[
              const SizedBox(width: 4),
              Text(label, style: TextStyle(color: color, fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }
}
