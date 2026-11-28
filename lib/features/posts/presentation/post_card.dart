import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/ai_conversation_link.dart';
import '../../../shared/format/relative_time.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/motion/animated_count.dart';
import '../../../shared/motion/entrance.dart';
import '../../../shared/motion/like_button.dart';
import '../../../shared/motion/pressable.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/routing/auth_navigation.dart';
import '../../../shared/theme/tokens.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/media_lightbox.dart';
import '../../../shared/widgets/status_views.dart';
import '../../../shared/widgets/ui/pill_tag.dart';
import '../../../shared/widgets/ui/surface_card.dart';
import '../../links/presentation/content_link_preview.dart';
import '../../media/presentation/private_attachment_button.dart';
import '../../media/presentation/public_video_player_native.dart'
    if (dart.library.js_interop) '../../media/presentation/public_video_player_web.dart';
import '../data/posts_api.dart';
import '../domain/post_models.dart';
import 'post_poll_card.dart';
import 'post_markdown_body.dart';

class PostCard extends ConsumerStatefulWidget {
  const PostCard({
    super.key,
    required this.post,
    this.onChanged,
    this.onBookmarkChanged,
    this.onEdited,
    this.onReport,
    this.onDeleted,
    this.onRetweeted,
    this.onRecommendationFeedback,
    this.profilePinned = false,
    this.onChangeProfilePin,
    this.avatarHeroTag,
    this.focused = false,
    this.onOpenLikers,
  });

  final V2Post post;
  final void Function(V2Post updated)? onChanged;
  final ValueChanged<bool>? onBookmarkChanged;
  final void Function(V2Post updated)? onEdited;
  final VoidCallback? onReport;
  final VoidCallback? onDeleted;
  final VoidCallback? onRetweeted;
  final VoidCallback? onRecommendationFeedback;
  final bool profilePinned;
  final ValueChanged<bool>? onChangeProfilePin;
  final String? avatarHeroTag;
  final bool focused;
  final VoidCallback? onOpenLikers;

  @override
  ConsumerState<PostCard> createState() => _PostCardState();
}

class _PostCardState extends ConsumerState<PostCard> {
  late V2Post _post;
  bool _busyLike = false;
  bool _busyBookmark = false;
  bool _busyRetweet = false;
  bool _busyDelete = false;
  bool _expandedText = false;

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
    // Keep parent refreshes available while likes and bookmarks await a receipt.
    if (!_busyRetweet) {
      _post = widget.post;
    }
  }

  bool Function() _captureInteraction(PostsApi api, int postId) {
    final session = ref.read(tokenStoreProvider);
    final revision = session.revision;
    return () =>
        mounted &&
        _post.postId == postId &&
        session.revision == revision &&
        !session.isSessionChanging &&
        identical(ref.read(postsApiProvider), api);
  }

  Future<void> _toggleLike() async {
    if (_busyLike) return;
    if (!requireAuthenticatedAction(context, ref)) return;
    setState(() => _busyLike = true);
    final api = ref.read(postsApiProvider);
    final postId = _post.postId;
    final current = _captureInteraction(api, postId);
    final wasLiked = _post.viewerState.isLiked;
    try {
      final newState = wasLiked
          ? await api.unlikePost(postId)
          : await api.likePost(postId);
      if (!current()) return;
      setState(() {
        _post = _post.copyWith(
          viewerState: _post.viewerState.copyWith(isLiked: newState.isLiked),
          stats: _post.stats.copyWith(likesCount: newState.likesCount),
        );
      });
      widget.onChanged?.call(_post);
    } catch (error) {
      if (current()) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorView.describe(context, error))),
        );
      }
    } finally {
      if (mounted) setState(() => _busyLike = false);
    }
  }

  Future<void> _toggleBookmark() async {
    if (_busyBookmark) return;
    if (!requireAuthenticatedAction(context, ref)) return;
    setState(() => _busyBookmark = true);
    final api = ref.read(postsApiProvider);
    final postId = _post.postId;
    final current = _captureInteraction(api, postId);
    final wasBookmarked = _post.viewerState.isBookmarked;
    try {
      final newState = wasBookmarked
          ? await api.unbookmarkPost(postId)
          : await api.bookmarkPost(postId);
      if (!current()) return;
      setState(
        () => _post = _post.copyWith(
          viewerState: _post.viewerState.copyWith(
            isBookmarked: newState.isBookmarked,
          ),
        ),
      );
      widget.onChanged?.call(_post);
      widget.onBookmarkChanged?.call(newState.isBookmarked);
    } catch (error) {
      if (current()) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorView.describe(context, error))),
        );
      }
    } finally {
      if (mounted) setState(() => _busyBookmark = false);
    }
  }

  Future<void> _deletePost() async {
    if (_busyDelete || !_post.viewerState.canDelete) return;
    if (!requireAuthenticatedAction(context, ref)) return;
    final l10n = AppLocalizations.of(context);
    final api = ref.read(postsApiProvider);
    final tokens = ref.read(tokenStoreProvider);
    final revision = tokens.revision;
    final postId = _post.postId;
    bool current() =>
        mounted &&
        tokens.revision == revision &&
        !tokens.isSessionChanging &&
        identical(ref.read(postsApiProvider), api) &&
        _post.postId == postId;
    _busyDelete = true;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(l10n.t('post.delete.title')),
          content: Text(l10n.t('post.delete.body')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(l10n.t('common.cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(l10n.t('common.delete')),
            ),
          ],
        ),
      );
      if (confirmed != true || !current() || !_post.viewerState.canDelete) {
        return;
      }
      await api.deletePost(postId);
      if (!current()) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.t('post.deleted'))));
      widget.onDeleted?.call();
    } catch (e) {
      if (!current()) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      _busyDelete = false;
    }
  }

  Future<void> _quotePost() async {
    if (_busyRetweet) return;
    if (!requireAuthenticatedAction(context, ref)) return;
    final l10n = AppLocalizations.of(context);
    final api = ref.read(postsApiProvider);
    final session = ref.read(tokenStoreProvider);
    final revision = session.revision;
    final postId = _post.postId;
    bool valid() =>
        mounted &&
        _post.postId == postId &&
        session.revision == revision &&
        !session.isSessionChanging &&
        identical(api, ref.read(postsApiProvider));
    setState(() => _busyRetweet = true);
    try {
      final text = await showDialog<String>(
        context: context,
        builder: (_) => _QuotePostDialog(l10n: l10n),
      );
      if (text == null || !valid()) return;
      await api.createRetweet(postId: postId, content: text);
      if (!valid()) return;
      setState(() {
        _post = _post.copyWith(
          stats: _post.stats.copyWith(
            retweetsCount: _post.stats.retweetsCount + 1,
          ),
        );
      });
      widget.onChanged?.call(_post);
      widget.onRetweeted?.call();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.t('post.quote.posted'))));
    } catch (e) {
      if (!valid()) return;
      final message = e is UnconfirmedRetweetError
          ? l10n.t('post.quote.unconfirmed')
          : ErrorView.describe(context, e);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _busyRetweet = false);
    }
  }

  Future<void> _sendFeedback(String feedback) async {
    if (!requireAuthenticatedAction(context, ref)) return;
    final l10n = AppLocalizations.of(context);
    final api = ref.read(postsApiProvider);
    final id = _post.postId;
    final current = _captureInteraction(api, id);
    try {
      await api.recordRecommendationFeedback(postId: id, feedback: feedback);
      if (!current()) return;
      widget.onRecommendationFeedback?.call();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.t('post.feedback.saved'))));
    } catch (e) {
      if (!current()) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _openPost() async {
    final id = _post.postId;
    final current = _captureInteraction(ref.read(postsApiProvider), id);
    V2Post? saved;
    final receipt = ref.listenManual(savedPostProvider(id), (_, updated) {
      if (current() && updated?.postId == id) saved = updated;
    });
    try {
      final deletedId = await context.push<int>('/posts/$id');
      if (!current()) return;
      if (deletedId == id) {
        widget.onDeleted?.call();
      } else if (saved case final updated?) {
        _applyEdit(updated);
      }
    } finally {
      receipt.close();
    }
  }

  Future<void> _editPost() async {
    if (!requireAuthenticatedAction(context, ref)) return;
    final tokens = ref.read(tokenStoreProvider);
    if (tokens.isSessionChanging) return;
    final revision = tokens.revision;
    final api = ref.read(postsApiProvider);
    final id = _post.postId;
    final updated = await context.push<V2Post>('/posts/$id/edit');
    if (!mounted ||
        tokens.revision != revision ||
        tokens.isSessionChanging ||
        !identical(api, ref.read(postsApiProvider)) ||
        _post.postId != id ||
        updated == null ||
        updated.postId != id) {
      return;
    }
    _applyEdit(updated);
  }

  void _applyEdit(V2Post updated) {
    setState(() => _post = updated);
    (widget.onEdited ?? widget.onChanged)?.call(updated);
  }

  void _handleMenu(String value) {
    switch (value) {
      case 'edit':
        _editPost();
        break;
      case 'delete':
        _deletePost();
        break;
      case 'quote':
        _quotePost();
        break;
      case 'profile_pin':
      case 'profile_unpin':
        widget.onChangeProfilePin?.call(value == 'profile_pin');
        break;
      case 'not_interested':
      case 'show_less':
        _sendFeedback(value);
        break;
      case 'knowledge':
        if (requireAuthenticatedAction(context, ref)) {
          openAiConversation(context, knowledge: true);
        }
        break;
      case 'report':
        if (requireAuthenticatedAction(context, ref)) {
          widget.onReport?.call();
        }
        break;
    }
  }

  String _formatDate(BuildContext context, String iso) {
    return formatRelativeTime(iso, locale: Localizations.localeOf(context));
  }

  String _fullDate(BuildContext context, String iso) {
    return formatFullTimestamp(iso, locale: Localizations.localeOf(context));
  }

  bool get _isLongPlainText {
    if (_post.content.length > 320) return true;
    return '\n'.allMatches(_post.content).length >= 7;
  }

  Widget _buildPopupMenu(AppLocalizations l10n, Color muted) {
    return SizedBox(
      height: 28,
      width: 28,
      child: PopupMenuButton<String>(
        key: Key('post-more-button-${_post.postId}'),
        padding: EdgeInsets.zero,
        tooltip: l10n.t('common.more'),
        icon: Icon(Icons.more_horiz, size: 18, color: muted),
        onSelected: _handleMenu,
        itemBuilder: (_) => [
          if (widget.onChangeProfilePin != null)
            PopupMenuItem(
              value: widget.profilePinned ? 'profile_unpin' : 'profile_pin',
              child: Text(
                l10n.t(
                  widget.profilePinned
                      ? 'profile.pin.clear'
                      : 'profile.pin.set',
                ),
              ),
            ),
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
            value: 'knowledge',
            child: Text(l10n.t('ai.knowledge.title')),
          ),
          PopupMenuItem(
            value: 'report',
            child: Text(l10n.t('common.report')),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildBodyAndExtras(
    BuildContext context,
    ThemeData theme,
    ColorScheme scheme,
    AppLocalizations l10n, {
    required bool expandPlainText,
    required double bodyFontSize,
  }) {
    return [
      if (_post.markdown case final source?) ...[
        const SizedBox(height: 8),
        PostMarkdownBody(source: source),
      ] else if (_post.content.isNotEmpty) ...[
        const SizedBox(height: 8),
        AnimatedSize(
          duration: AppMotion.resolve(context, AppMotion.base),
          curve: AppMotion.emphasizedDecelerate,
          alignment: Alignment.topLeft,
          child: (!expandPlainText && _isLongPlainText && !_expandedText)
              ? Text(
                  _post.content,
                  maxLines: 8,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontSize: bodyFontSize,
                    height: expandPlainText ? 1.65 : 1.62,
                  ),
                )
              : SelectableText(
                  _post.content,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontSize: bodyFontSize,
                    height: expandPlainText ? 1.65 : 1.62,
                  ),
                ),
        ),
        if (!expandPlainText && _isLongPlainText)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: GestureDetector(
              onTap: () => setState(() => _expandedText = !_expandedText),
              child: Text(
                l10n.t(_expandedText ? 'post.show_less' : 'post.show_more'),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
      ],
      if (_post.tags.isNotEmpty || _post.location.isNotEmpty) ...[
        const SizedBox(height: AppGap.sm),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            if (_post.location.isNotEmpty)
              PillTag(icon: Icons.place_outlined, label: _post.location),
            for (final tag in _post.tags) PillTag(label: '#$tag'),
          ],
        ),
      ],
      ContentLinkPreview(content: _post.content, markdown: _post.markdown),
      if (_post.media.isNotEmpty) ...[
        const SizedBox(height: 10),
        _MediaGrid(media: _post.media),
      ],
      if (_post.poll case final poll?)
        PostPollCard(
          key: ValueKey((_post.postId, poll.pollId)),
          postId: _post.postId,
          poll: poll,
        ),
    ];
  }

  Widget _buildActionBar(
    AppLocalizations l10n,
    ColorScheme scheme,
    SocialColors social, {
    required bool fullWidth,
    required double iconSize,
  }) {
    final bookmarkLabel = l10n.t(
      _post.viewerState.isBookmarked ? 'common.unbookmark' : 'common.bookmark',
    );
    if (fullWidth) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _ActionButton(
            icon: Icons.chat_bubble_outline,
            label: l10n.t('common.comment'),
            iconSize: iconSize,
            count: null,
            activeColor: scheme.primary,
            onTap: _openPost,
          ),
          _ActionButton(
            key: Key('post-retweet-button-${_post.postId}'),
            icon: Icons.repeat_rounded,
            label: l10n.t('post.quote.menu'),
            iconSize: iconSize,
            count: null,
            activeColor: social.repost,
            onTap: _quotePost,
          ),
          Semantics(
            button: true,
            label: l10n.t(
              _post.viewerState.isLiked ? 'common.unlike' : 'common.like',
            ),
            child: SocialLikeButton(
              liked: _post.viewerState.isLiked,
              count: _post.stats.likesCount,
              iconSize: iconSize,
              showZero: false,
              onTap: _toggleLike,
            ),
          ),
          _ActionButton(
            icon: _post.viewerState.isBookmarked
                ? Icons.bookmark
                : Icons.bookmark_border,
            label: bookmarkLabel,
            iconSize: iconSize,
            count: null,
            active: _post.viewerState.isBookmarked,
            activeColor: social.bookmark,
            onTap: _toggleBookmark,
          ),
        ],
      );
    }

    return Row(
      children: [
        _ActionButton(
          icon: Icons.chat_bubble_outline,
          label: l10n.t('common.comment'),
          iconSize: iconSize,
          count: _post.stats.commentsCount,
          hideZero: true,
          activeColor: scheme.primary,
          onTap: _openPost,
        ),
        const SizedBox(width: 20),
        _ActionButton(
          key: Key('post-retweet-button-${_post.postId}'),
          icon: Icons.repeat_rounded,
          label: l10n.t('post.quote.menu'),
          iconSize: iconSize,
          count: _post.stats.retweetsCount,
          hideZero: true,
          activeColor: social.repost,
          onTap: _quotePost,
        ),
        const SizedBox(width: 20),
        Semantics(
          button: true,
          label: l10n.t(
            _post.viewerState.isLiked ? 'common.unlike' : 'common.like',
          ),
          child: SocialLikeButton(
            liked: _post.viewerState.isLiked,
            count: _post.stats.likesCount,
            iconSize: iconSize,
            showZero: false,
            onTap: _toggleLike,
          ),
        ),
        const Spacer(),
        _ActionButton(
          icon: _post.viewerState.isBookmarked
              ? Icons.bookmark
              : Icons.bookmark_border,
          label: bookmarkLabel,
          iconSize: iconSize,
          count: null,
          active: _post.viewerState.isBookmarked,
          activeColor: social.bookmark,
          onTap: _toggleBookmark,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final social = SocialColors.of(context);
    final muted = scheme.onSurfaceVariant;
    final displayName = _post.author.displayName.isEmpty
        ? _post.author.username
        : _post.author.displayName;

    Widget avatar = Pressable(
      onTap: () => context.push('/users/${_post.author.userId}'),
      child: AppAvatar(
        url: _post.author.avatarUrl,
        size: widget.focused ? 46 : 40,
        name: displayName,
        seed: _post.author.userId,
      ),
    );
    if (widget.avatarHeroTag != null) {
      avatar = Hero(tag: widget.avatarHeroTag!, child: avatar);
    }

    if (widget.focused) {
      return SurfaceCard(
        radius: AppRadius.card,
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                avatar,
                const SizedBox(width: 12),
                Expanded(
                  child: GestureDetector(
                    onTap: () =>
                        context.push('/users/${_post.author.userId}'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (_post.author.verified) ...[
                              const SizedBox(width: 4),
                              Icon(
                                Icons.verified,
                                size: 16,
                                color: scheme.primary,
                              ),
                            ],
                          ],
                        ),
                        Text(
                          '@${_post.author.username}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: social.inkTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                _buildPopupMenu(l10n, muted),
              ],
            ),
            const SizedBox(height: 4),
            ..._buildBodyAndExtras(
              context,
              theme,
              scheme,
              l10n,
              expandPlainText: true,
              bodyFontSize: 17,
            ),
            const SizedBox(height: 12),
            Text(
              _fullDate(context, _post.createdAt),
              style: theme.textTheme.bodySmall?.copyWith(
                color: social.inkTertiary,
              ),
            ),
            const SizedBox(height: 12),
            Divider(height: 1, thickness: 1, color: social.divider),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Wrap(
                spacing: 18,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _StatCountItem(
                    count: _post.stats.retweetsCount,
                    label: l10n.t('post.stats.reposts'),
                  ),
                  Tooltip(
                    message: l10n.t('post.likers.title'),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: widget.onOpenLikers,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 2,
                          vertical: 2,
                        ),
                        child: _StatCountItem(
                          count: _post.stats.likesCount,
                          label: l10n.t('post.stats.likes'),
                        ),
                      ),
                    ),
                  ),
                  _StatCountItem(
                    count: _post.stats.commentsCount,
                    label: l10n.t('post.stats.comments'),
                  ),
                ],
              ),
            ),
            Divider(height: 1, thickness: 1, color: social.divider),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: _buildActionBar(
                l10n,
                scheme,
                social,
                fullWidth: true,
                iconSize: 21,
              ),
            ),
          ],
        ),
      );
    }

    final tertiaryInk = social.inkTertiary;
    return SurfaceCard(
      radius: AppRadius.card,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      onTap: _openPost,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          avatar,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.profilePinned)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        Icon(Icons.push_pin_rounded, size: 13, color: muted),
                        const SizedBox(width: 4),
                        Text(
                          l10n.t('profile.pin.label'),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: muted,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              displayName,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                height: 1.25,
                              ),
                            ),
                          ),
                          if (_post.author.verified) ...[
                            const SizedBox(width: 3),
                            Icon(
                              Icons.verified,
                              size: 15,
                              color: scheme.primary,
                            ),
                          ],
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              '@${_post.author.username}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontSize: 13,
                                color: tertiaryInk,
                                height: 1.25,
                              ),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                          Text(
                            ' · ',
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 13,
                              color: tertiaryInk,
                            ),
                          ),
                          Tooltip(
                            message: _fullDate(
                              context,
                              _post.createdAt,
                            ),
                            child: Text(
                              _formatDate(context, _post.createdAt),
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontSize: 13,
                                color: tertiaryInk,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    _buildPopupMenu(l10n, muted),
                  ],
                ),
                ..._buildBodyAndExtras(
                  context,
                  theme,
                  scheme,
                  l10n,
                  expandPlainText: false,
                  bodyFontSize: 15.5,
                ),
                const SizedBox(height: 8),
                _buildActionBar(
                  l10n,
                  scheme,
                  social,
                  fullWidth: false,
                  iconSize: 18,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatCountItem extends StatelessWidget {
  const _StatCountItem({required this.count, required this.label});

  final int count;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedCount(
          count: count,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
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

class _MediaGrid extends ConsumerWidget {
  const _MediaGrid({required this.media});
  final List<V2MediaAsset> media;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final publicImages = media
        .where((asset) => !asset.usesContentRoute && !asset.isVideo)
        .toList();
    final attachments = media.where(
      (asset) => asset.usesContentRoute || asset.isVideo,
    );
    if (attachments.isEmpty) return _PublicMediaGrid(media: publicImages);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (publicImages.isNotEmpty) _PublicMediaGrid(media: publicImages),
        for (final asset in attachments)
          Padding(
            key: ValueKey(asset.mediaId),
            padding: const EdgeInsets.only(top: 4),
            child: asset.usesContentRoute
                ? PrivateAttachmentButton(asset: asset)
                : _publicVideo(context, ref, asset),
          ),
      ],
    );
  }

  Widget _publicVideo(BuildContext context, WidgetRef ref, V2MediaAsset asset) {
    final l10n = AppLocalizations.of(context);
    final label = l10n.t('media.copy_video_link');
    final url = asset.publicUrl.trim().isEmpty
        ? null
        : Uri.tryParse(
            ref.watch(assetUrlResolverProvider).resolve(asset.publicUrl),
          );
    final canCopy =
        url != null &&
        (url.scheme == 'http' || url.scheme == 'https') &&
        url.host.isNotEmpty &&
        url.userInfo.isEmpty;
    final copyLink = Tooltip(
      message: label,
      child: OutlinedButton.icon(
        onPressed: canCopy
            ? () async {
                try {
                  await Clipboard.setData(ClipboardData(text: url.toString()));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.t('media.video_link_copied'))),
                  );
                } on PlatformException catch (error) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(ErrorView.describe(context, error))),
                  );
                }
              }
            : null,
        icon: const Icon(Icons.video_file_outlined),
        label: Text(
          asset.fileName.isEmpty ? label : asset.fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
    if (!canCopy) return copyLink;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PublicVideoPlayer(
          key: ValueKey(url),
          url: url,
          label: asset.fileName.isEmpty
              ? l10n.t('media.open_video')
              : asset.fileName,
        ),
        copyLink,
      ],
    );
  }
}

class _PublicMediaGrid extends StatelessWidget {
  const _PublicMediaGrid({required this.media});
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
    final radius = BorderRadius.circular(AppRadius.tile);
    Widget frame(Widget child) =>
        ClipRSuperellipse(borderRadius: radius, child: child);

    if (media.length == 1) {
      return frame(
        Tooltip(
          message: l10n.t('media.open'),
          child: InkWell(
            onTap: () => _open(context, 0),
            child: AspectRatio(
              aspectRatio: 16 / 10,
              child: AppMediaImage(
                url: media.first.publicUrl,
                borderRadius: BorderRadius.zero,
              ),
            ),
          ),
        ),
      );
    }

    if (media.length == 2) {
      final cellRadius = BorderRadius.circular(4);
      return frame(
        AspectRatio(
          aspectRatio: 16 / 9,
          child: Row(
            children: [
              for (var i = 0; i < 2; i++) ...[
                if (i > 0) const SizedBox(width: 3),
                Expanded(
                  child: InkWell(
                    onTap: () => _open(context, i),
                    child: AppMediaImage(
                      url: media[i].publicUrl,
                      height: double.infinity,
                      borderRadius: cellRadius,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    if (media.length == 3) {
      final cellRadius = BorderRadius.circular(4);
      return frame(
        AspectRatio(
          aspectRatio: 16 / 10,
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => _open(context, 0),
                  child: AppMediaImage(
                    url: media[0].publicUrl,
                    height: double.infinity,
                    borderRadius: cellRadius,
                  ),
                ),
              ),
              const SizedBox(width: 3),
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () => _open(context, 1),
                        child: AppMediaImage(
                          url: media[1].publicUrl,
                          width: double.infinity,
                          height: double.infinity,
                          borderRadius: cellRadius,
                        ),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Expanded(
                      child: InkWell(
                        onTap: () => _open(context, 2),
                        child: AppMediaImage(
                          url: media[2].publicUrl,
                          width: double.infinity,
                          height: double.infinity,
                          borderRadius: cellRadius,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    final count = media.length.clamp(0, 4);
    final cellRadius = BorderRadius.circular(4);
    return frame(
      GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 3,
        crossAxisSpacing: 3,
        childAspectRatio: 1.35,
        children: [
          for (var i = 0; i < count; i++)
            Tooltip(
              message: l10n.t('media.open'),
              child: InkWell(
                onTap: () => _open(context, i),
                child: AppMediaImage(
                  url: media[i].publicUrl,
                  borderRadius: cellRadius,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatefulWidget {
  const _ActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.count,
    required this.onTap,
    this.active = false,
    this.activeColor,
    this.iconSize = 18,
    this.hideZero = false,
  });

  final IconData icon;
  final String label;
  final int? count;
  final VoidCallback onTap;
  final bool active;
  final Color? activeColor;
  final double iconSize;
  final bool hideZero;

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = widget.activeColor ?? theme.colorScheme.primary;
    final color = widget.active
        ? accent
        : (_hovered ? accent : theme.colorScheme.onSurfaceVariant);
    final count = widget.count;
    final showCount = count != null && !(widget.hideZero && count <= 0);

    return Tooltip(
      message: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Pressable(
          scale: 0.92,
          haptic: HapticKind.selection,
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: AppMotion.fast,
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _hovered
                        ? accent.withValues(alpha: 0.10)
                        : Colors.transparent,
                  ),
                  alignment: Alignment.center,
                  child: SpringPop(
                    value: widget.active,
                    child: Icon(widget.icon, size: widget.iconSize, color: color),
                  ),
                ),
                if (showCount) ...[
                  const SizedBox(width: 2),
                  AnimatedCount(
                    count: count,
                    hideZero: widget.hideZero,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: color,
                      fontWeight: widget.active
                          ? FontWeight.w600
                          : FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
