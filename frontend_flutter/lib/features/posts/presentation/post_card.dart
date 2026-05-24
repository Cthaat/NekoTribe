import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../domain/post_models.dart';

class PostCard extends ConsumerStatefulWidget {
  const PostCard({
    super.key,
    required this.post,
    this.onChanged,
    this.onReport,
  });

  final V2Post post;
  final void Function(V2Post updated)? onChanged;
  final VoidCallback? onReport;

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
                        onSelected: (v) {
                          if (v == 'report') widget.onReport?.call();
                        },
                        itemBuilder: (_) => [
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
