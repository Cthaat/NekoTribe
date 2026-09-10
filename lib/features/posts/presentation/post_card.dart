import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/routing/auth_navigation.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/media_lightbox.dart';
import '../../../shared/widgets/status_views.dart';
import '../../sentiment_flow/presentation/sentiment_prediction_dialog.dart';
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
  bool _busyRetweet = false;

  @override
  void initState() {
    super.initState();
    _post = widget.post;
  }

  @override
  void didUpdateWidget(PostCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.post.postId != widget.post.postId) {
      _post = widget.post;
      return;
    }
    // Prefer syncing stats/content when parent refreshes, but avoid clobbering
    // in-flight optimistic like/bookmark/retweet updates.
    if (!_busyLike && !_busyBookmark && !_busyRetweet) {
      _post = widget.post;
    }
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
        _post = _post.copyWith(
          viewerState: _post.viewerState.copyWith(isLiked: newState.isLiked),
        );
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
        viewerState: _post.viewerState.copyWith(isBookmarked: !wasBookmarked),
      );
    });
    try {
      final newState = wasBookmarked
          ? await api.unbookmarkPost(_post.postId)
          : await api.bookmarkPost(_post.postId);
      if (!mounted) return;
      setState(
        () => _post = _post.copyWith(
          viewerState: _post.viewerState.copyWith(
            isBookmarked: newState.isBookmarked,
          ),
        ),
      );
      widget.onChanged?.call(_post);
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _post = _post.copyWith(
          viewerState: _post.viewerState.copyWith(isBookmarked: wasBookmarked),
        ),
      );
    } finally {
      if (mounted) setState(() => _busyBookmark = false);
    }
  }

  Future<void> _deletePost() async {
    if (!requireAuthenticatedAction(context, ref)) return;
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.t('post.delete.title')),
        content: Text(l10n.t('post.delete.body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.t('common.delete')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(postsApiProvider).deletePost(_post.postId);
      if (!mounted) return;
      widget.onDeleted?.call();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.t('post.deleted'))));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _quotePost() async {
    if (_busyRetweet) return;
    if (!requireAuthenticatedAction(context, ref)) return;
    final l10n = AppLocalizations.of(context);
    final text = await showDialog<String>(
      context: context,
      builder: (_) => _QuotePostDialog(l10n: l10n),
    );
    if (text == null) return;
    setState(() => _busyRetweet = true);
    try {
      await ref
          .read(postsApiProvider)
          .createRetweet(postId: _post.postId, content: text);
      if (!mounted) return;
      setState(() {
        _post = _post.copyWith(
          stats: _post.stats.copyWith(
            retweetsCount: _post.stats.retweetsCount + 1,
          ),
        );
      });
      widget.onChanged?.call(_post);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.t('post.quote.posted'))));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      if (mounted) setState(() => _busyRetweet = false);
    }
  }

  Future<void> _sendFeedback(String feedback) async {
    if (!requireAuthenticatedAction(context, ref)) return;
    final l10n = AppLocalizations.of(context);
    try {
      await ref
          .read(postsApiProvider)
          .recordRecommendationFeedback(
            postId: _post.postId,
            feedback: feedback,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.t('post.feedback.saved'))));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _showSentimentPrediction() async {
    if (!requireAuthenticatedAction(context, ref)) return;
    await showSentimentPredictionDialog(
      context: context,
      text: _post.content,
      postId: _post.postId,
    );
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
      case 'sentiment':
        _showSentimentPrediction();
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
    final muted = theme.colorScheme.onSurfaceVariant;
    final displayName = _post.author.displayName.isEmpty
        ? _post.author.username
        : _post.author.displayName;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      elevation: 0,
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/posts/${_post.postId}'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 8, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: () => context.push('/users/${_post.author.userId}'),
                child: AppAvatar(url: _post.author.avatarUrl, size: 42),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              Flexible(
                                flex: 3,
                                child: Text(
                                  displayName,
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    height: 1.2,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                flex: 2,
                                child: Text(
                                  '@${_post.author.username}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: muted,
                                    height: 1.2,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _formatDate(_post.createdAt),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: muted,
                          ),
                        ),
                      ],
                    ),
                    if (_post.content.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      SelectableText(
                        _post.content,
                        style: theme.textTheme.bodyLarge?.copyWith(height: 1.35),
                      ),
                    ],
                    if (_post.media.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      _MediaGrid(media: _post.media),
                    ],
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: _ActionButton(
                              icon: Icons.chat_bubble_outline,
                              label: '${_post.stats.commentsCount}',
                              onTap: () =>
                                  context.push('/posts/${_post.postId}'),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Align(
                            alignment: Alignment.center,
                            child: _ActionButton(
                              key: Key('post-retweet-button-${_post.postId}'),
                              icon: Icons.repeat_rounded,
                              label: '${_post.stats.retweetsCount}',
                              activeColor: theme.colorScheme.primary,
                              onTap: _quotePost,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Align(
                            alignment: Alignment.center,
                            child: _ActionButton(
                              icon: _post.viewerState.isLiked
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              label: '${_post.stats.likesCount}',
                              active: _post.viewerState.isLiked,
                              activeColor: const Color(0xFFE0245E),
                              onTap: _toggleLike,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: _ActionButton(
                              icon: _post.viewerState.isBookmarked
                                  ? Icons.bookmark
                                  : Icons.bookmark_border,
                              label: '',
                              active: _post.viewerState.isBookmarked,
                              activeColor: theme.colorScheme.primary,
                              onTap: _toggleBookmark,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 28,
                width: 28,
                child: PopupMenuButton<String>(
                  key: Key('post-more-button-${_post.postId}'),
                  padding: EdgeInsets.zero,
                  tooltip: l10n.t('common.more'),
                  icon: Icon(Icons.more_horiz, size: 18, color: muted),
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
                    PopupMenuItem(
                      value: 'quote',
                      child: Text(l10n.t('post.quote.menu')),
                    ),
                    PopupMenuItem(
                      value: 'not_interested',
                      child: Text(l10n.t('post.feedback.not_interested')),
                    ),
                    PopupMenuItem(
                      value: 'show_less',
                      child: Text(l10n.t('post.feedback.show_less')),
                    ),
                    PopupMenuItem(
                      value: 'sentiment',
                      child: Text(l10n.t('sentiment.actions.predict')),
                    ),
                    PopupMenuItem(
                      value: 'report',
                      child: Text(l10n.t('common.report')),
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

class _QuotePostDialog extends StatefulWidget {
  const _QuotePostDialog({required this.l10n});

  final AppLocalizations l10n;

  @override
  State<_QuotePostDialog> createState() => _QuotePostDialogState();
}

class _QuotePostDialogState extends State<_QuotePostDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    return AlertDialog(
      title: Text(l10n.t('post.quote.title')),
      content: TextField(
        controller: _controller,
        minLines: 3,
        maxLines: 6,
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          hintText: l10n.t('post.quote.hint'),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.t('common.cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: Text(l10n.t('common.post')),
        ),
      ],
    );
  }
}

class _MediaGrid extends StatelessWidget {
  const _MediaGrid({required this.media});
  final List<V2MediaAsset> media;

  void _open(BuildContext context, int index) {
    showMediaLightbox(
      context: context,
      items: media
          .map(
            (m) => MediaLightboxItem(
              url: m.publicUrl,
              altText: m.altText,
              description: m.description,
            ),
          )
          .toList(growable: false),
      initialIndex: index,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (media.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final radius = BorderRadius.circular(14);
    if (media.length == 1) {
      return Tooltip(
        message: l10n.t('media.open'),
        child: InkWell(
          onTap: () => _open(context, 0),
          borderRadius: radius,
          child: ClipRRect(
            borderRadius: radius,
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: AppMediaImage(
                url: media.first.publicUrl,
                borderRadius: BorderRadius.zero,
              ),
            ),
          ),
        ),
      );
    }
    final count = media.length.clamp(0, 4);
    return ClipRRect(
      borderRadius: radius,
      child: GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 3,
        crossAxisSpacing: 3,
        children: [
          for (var i = 0; i < count; i++)
            Tooltip(
              message: l10n.t('media.open'),
              child: InkWell(
                onTap: () => _open(context, i),
                child: AppMediaImage(
                  url: media[i].publicUrl,
                  borderRadius: BorderRadius.zero,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.activeColor,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = active
        ? (activeColor ?? theme.colorScheme.primary)
        : theme.colorScheme.onSurfaceVariant;
    final hoverColor = (activeColor ?? theme.colorScheme.primary).withValues(
      alpha: 0.08,
    );
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      hoverColor: hoverColor,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: color),
            if (label.isNotEmpty) ...[
              const SizedBox(width: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(color: color),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
