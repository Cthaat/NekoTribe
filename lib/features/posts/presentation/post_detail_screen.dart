import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_exception.dart';
import '../../../shared/format/relative_time.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/motion/animated_count.dart';
import '../../../shared/motion/entrance.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/routing/auth_navigation.dart';
import '../../../shared/theme/tokens.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/glass/liquid_glass_bars.dart';
import '../../../shared/widgets/glass/liquid_glass_surface.dart';
import '../../../shared/widgets/glass/liquid_glass_tokens.dart';
import '../../../shared/widgets/safe_back_button.dart';
import '../../../shared/widgets/status_views.dart';
import '../../../shared/widgets/ui/surface_card.dart';
import '../../ai/presentation/ai_writing_screen.dart';
import '../domain/post_draft_metadata.dart';
import '../domain/post_models.dart';
import 'post_card.dart';
import 'post_likers_screen.dart';
import 'compose_post_screen.dart';
import 'report_dialog.dart';

class PostDetailScreen extends ConsumerStatefulWidget {
  const PostDetailScreen({super.key, required this.postId, this.commentId});
  final int postId;
  final int? commentId;

  @override
  ConsumerState<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends ConsumerState<PostDetailScreen> {
  V2Post? _post;
  bool _showRetweets = false;
  bool _relatedSelected = false;
  List<V2Comment> _comments = [];
  List<V2Post> _relatedPosts = [];
  int _relatedPage = 0;
  int _relatedRevision = 0;
  bool _relatedPending = false;
  bool _relatedHasNext = false;
  Object? _relatedError;
  bool _loading = true;
  bool _loadingMore = false;
  bool _commentsPending = false;
  bool _summaryPending = false;
  Object? _commentsError;
  bool _hasNext = false;
  int _page = 1;
  int _loadRevision = 0;
  bool _expired = false;
  Object? _error;
  VoidCallback? _stopSession;
  final _pendingCommentLikes = <int>{};
  bool _deletingComment = false;
  V2Comment? _replyTarget;
  bool _sendingComment = false;
  double _composerHeight = 108;
  final _replyController = TextEditingController();
  bool get _active => mounted && !_expired;

  @override
  void initState() {
    super.initState();
    final store = ref.read(tokenStoreProvider);
    _expired = store.isSessionChanging;
    _stopSession = store.listenSessionChanges(_expire);
    ref.listenManual(postsApiProvider, (previous, next) {
      if (!identical(previous, next)) _expire();
    });
    ref.listenManual(
      authSessionProvider.select((session) => session.isAuthenticated),
      (_, signedIn) {
        if (!_active) return;
        if (signedIn) {
          _loadRelatedPosts(reset: true);
        } else {
          _relatedRevision++;
          setState(() {
            _relatedPosts = [];
            _relatedPage = 0;
            _relatedError = null;
            _relatedPending = false;
            _relatedHasNext = false;
          });
        }
      },
    );
    _load();
  }

  @override
  void dispose() {
    _stopSession?.call();
    _replyController.dispose();
    super.dispose();
  }

  void _expire() {
    if (!_active) return;
    _replyController.clear();
    setState(() {
      _expired = true;
      _post = null;
      _comments = [];
      _relatedPosts = [];
      _replyTarget = null;
      _error = null;
    });
  }

  void _leaveDeletedPost() {
    if (!_active) return;
    if (context.canPop()) {
      context.pop(widget.postId);
    } else {
      context.go('/feed');
    }
  }

  Future<void> _openDiscussionSummary() async {
    final post = _post;
    if (!_active ||
        post == null ||
        post.postId != widget.postId ||
        post.visibility != 'public' ||
        _summaryPending ||
        widget.commentId != null ||
        !requireAuthenticatedAction(context, ref)) {
      return;
    }
    final store = ref.read(tokenStoreProvider);
    final revision = store.revision;
    final load = _loadRevision;
    final api = ref.read(postsApiProvider);
    bool sameSource() =>
        _active &&
        _loadRevision == load &&
        widget.postId == post.postId &&
        widget.commentId == null &&
        !store.isSessionChanging &&
        store.revision == revision &&
        identical(api, ref.read(postsApiProvider));
    bool current() => sameSource() && ModalRoute.of(context)?.isCurrent == true;
    if (!current()) return;
    final seen = _comments
        .where((comment) => comment.postId == post.postId)
        .map((comment) => comment.commentId)
        .toSet();
    setState(() => _summaryPending = true);
    try {
      final confirmed = seen.isEmpty
          ? const <V2Comment>[]
          : (await api.getComments(post.postId, page: 1, size: 20)).items
                .where(
                  (comment) =>
                      comment.postId == post.postId &&
                      seen.remove(comment.commentId),
                )
                .toList();
      if (!current()) return;
      final updated = await api.getPost(post.postId);
      if (!current()) return;
      final draft = updated.postId == post.postId
          ? discussionSummaryDraft(updated, confirmed)
          : '';
      if (draft.isEmpty) {
        throw const FormatException('Post discussion is unavailable');
      }
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) =>
              AiWritingScreen(initialDiscussion: sameSource() ? draft : null),
        ),
      );
    } catch (_) {
      if (!current()) return;
      final message = AppLocalizations.of(
        context,
      ).t('ai.writing.summary_unavailable');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _summaryPending = false);
    }
  }

  Future<void> _load() async {
    if (!_active) return;
    final revision = ++_loadRevision;
    bool valid() => _active && revision == _loadRevision;
    setState(() {
      _loading = true;
      _error = null;
      _comments = [];
      _commentsPending = false;
      _commentsError = null;
      _page = 1;
      _hasNext = false;
      _loadingMore = false;
    });
    try {
      final post = await ref.read(postsApiProvider).getPost(widget.postId);
      if (!valid()) return;
      setState(() {
        _post = post;
        _loading = false;
      });
      _loadRelatedPosts(reset: true);
      await _loadComments();
    } catch (e) {
      if (!valid()) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _loadComments() async {
    if (!_active || _commentsPending || _post == null) return;
    final revision = _loadRevision;
    bool valid() => _active && revision == _loadRevision;
    setState(() {
      _commentsPending = true;
      _commentsError = null;
    });
    try {
      final api = ref.read(postsApiProvider);
      final commentId = widget.commentId;
      final page = commentId == null
          ? await api.getComments(widget.postId, page: 1, size: 20)
          : null;
      final comment = commentId == null
          ? null
          : await api.getComment(widget.postId, commentId);
      if (!valid()) return;
      setState(() {
        _comments = page?.items ?? [if (comment != null) comment];
        _page = 1;
        _hasNext = page?.hasNext ?? false;
        _commentsPending = false;
      });
    } catch (e) {
      if (!valid()) return;
      setState(() {
        _commentsError = e;
        _commentsPending = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (!_active || _loadingMore || !_hasNext || _loading) return;
    final revision = _loadRevision;
    bool valid() => _active && revision == _loadRevision;
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final page = await ref
          .read(postsApiProvider)
          .getComments(widget.postId, page: next, size: 20);
      if (!valid()) return;
      setState(() {
        _comments = [..._comments, ...page.items];
        _page = next;
        _hasNext = page.hasNext;
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

  Future<void> _loadRelatedPosts({bool reset = false}) async {
    if (!_active ||
        widget.commentId != null ||
        _post == null ||
        !ref.read(authSessionProvider).isAuthenticated ||
        (!reset && (_relatedPending || !_relatedHasNext))) {
      return;
    }
    final revision = ++_relatedRevision;
    final retweets = _showRetweets;
    bool valid() => _active && revision == _relatedRevision;
    final page = reset ? 1 : _relatedPage + 1;
    setState(() {
      _relatedPending = true;
      _relatedError = null;
      if (reset) {
        _relatedPosts = [];
        _relatedPage = 0;
        _relatedHasNext = false;
      }
    });
    try {
      final api = ref.read(postsApiProvider);
      final result = await (retweets
          ? api.getRetweets(widget.postId, page: page, size: 10)
          : api.getReplies(
              widget.postId,
              page: page,
              size: 10,
              sort: 'oldest',
            ));
      if (!valid()) return;
      final seen = <int>{
        if (!reset) ..._relatedPosts.map((post) => post.postId),
      };
      setState(() {
        _relatedPosts = [
          if (!reset) ..._relatedPosts,
          for (final post in result.items)
            if ((retweets ? post.repostOfPostId : post.replyToPostId) ==
                    widget.postId &&
                seen.add(post.postId))
              post,
        ];
        _relatedPage = page;
        _relatedHasNext = result.hasNext;
      });
    } catch (error) {
      if (valid()) setState(() => _relatedError = error);
    } finally {
      if (valid()) setState(() => _relatedPending = false);
    }
  }

  void _selectRelatedPosts({required bool retweets}) {
    if (!_active || (_relatedSelected && _showRetweets == retweets)) return;
    setState(() {
      _relatedSelected = true;
      _showRetweets = retweets;
    });
    _loadRelatedPosts(reset: true);
  }

  Future<void> _submitReply() async {
    if (!_active ||
        _sendingComment ||
        !requireAuthenticatedAction(context, ref)) {
      return;
    }
    final text = _replyController.text.trim();
    if (text.isEmpty) return;
    final parent = _replyTarget;
    final revision = _loadRevision;
    bool valid() => _active && revision == _loadRevision;
    setState(() => _sendingComment = true);
    try {
      final comment = await ref
          .read(postsApiProvider)
          .createComment(
            postId: widget.postId,
            content: text,
            parentCommentId: parent?.commentId,
          );
      if (!valid()) return;
      setState(() {
        if (widget.commentId == null) _comments.insert(0, comment);
        _replyTarget = null;
        _replyController.clear();
      });
      if (widget.commentId != null) {
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.t('post.comment.reply_sent'))),
        );
      }
    } catch (e) {
      if (!valid()) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      if (_active) setState(() => _sendingComment = false);
    }
  }

  void _replyToComment(V2Comment comment) {
    if (!_active ||
        _sendingComment ||
        !requireAuthenticatedAction(context, ref)) {
      return;
    }
    setState(() => _replyTarget = comment);
  }

  Future<void> _deleteComment(V2Comment comment) async {
    if (!_active ||
        _deletingComment ||
        !comment.canDelete ||
        !requireAuthenticatedAction(context, ref)) {
      return;
    }
    final revision = _loadRevision;
    bool valid() => _active && revision == _loadRevision;
    final l10n = AppLocalizations.of(context);
    setState(() => _deletingComment = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(l10n.t('post.comment.delete_title')),
          content: Text(l10n.t('post.comment.delete_body')),
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
      if (confirmed != true || !valid()) return;
      await ref.read(postsApiProvider).deleteComment(comment.commentId);
      if (valid()) _removeComment(comment.commentId);
    } catch (error) {
      if (!valid()) return;
      if (error is ApiException && error.isNotFound) {
        _removeComment(comment.commentId);
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorView.describe(context, error))),
      );
    } finally {
      if (_active) setState(() => _deletingComment = false);
    }
  }

  void _removeComment(int id) {
    setState(() {
      _comments = _comments
          .where((comment) => comment.commentId != id)
          .toList();
    });
  }

  Future<void> _toggleCommentLike(V2Comment comment) async {
    final id = comment.commentId;
    if (!_active ||
        _pendingCommentLikes.contains(id) ||
        !requireAuthenticatedAction(context, ref)) {
      return;
    }
    final revision = _loadRevision;
    bool valid() => _active && revision == _loadRevision;
    setState(() => _pendingCommentLikes.add(id));
    try {
      final api = ref.read(postsApiProvider);
      final state = await (comment.isLiked
          ? api.unlikeComment(id)
          : api.likeComment(id));
      if (!valid()) return;
      setState(() {
        _comments = [
          for (final item in _comments)
            if (item.commentId == id) item.withLikeState(state) else item,
        ];
      });
    } catch (e) {
      if (!valid()) return;
      if (e is ApiException && e.isNotFound) {
        _removeComment(id);
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      if (_active) setState(() => _pendingCommentLikes.remove(id));
    }
  }

  Future<void> _openCompose() async {
    if (!_active || !requireAuthenticatedAction(context, ref)) return;
    final created = await Navigator.of(context).push<V2Post>(
      MaterialPageRoute(
        builder: (_) => ComposePostScreen(replyToPostId: widget.postId),
      ),
    );
    if (created != null && _active) _loadRelatedPosts(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = ref.watch(
      authSessionProvider.select((session) => session.isAuthenticated),
    );
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final social = SocialColors.of(context);
    final topInset = kToolbarHeight + MediaQuery.paddingOf(context).top;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final showComposer =
        !_commentsPending &&
        _commentsError == null &&
        (widget.commentId == null || _replyTarget != null);
    final showRelatedPosts = signedIn && widget.commentId == null;
    return Scaffold(
      backgroundColor: social.surfaceBase,
      extendBodyBehindAppBar: true,
      resizeToAvoidBottomInset: false,
      appBar: LiquidGlassAppBar(
        leading: const SafeBackButton(),
        title: Text(l10n.t('post.title')),
      ),
      body: _expired
          ? Center(child: Text(l10n.t('visibility.sessionChanged')))
          : _loading
          ? const LoadingView()
          : _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : _post == null
          ? EmptyView(message: l10n.t('feed.empty'))
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppBreakpoints.contentMaxWidth,
                ),
                child: AnimatedPadding(
                  duration: AppMotion.resolve(context, AppMotion.glide),
                  curve: AppMotion.glideCurve,
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.viewInsetsOf(context).bottom,
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      NotificationListener<ScrollNotification>(
                        onNotification: (n) {
                          if (n.metrics.pixels >=
                              n.metrics.maxScrollExtent - 200) {
                            _loadMore();
                          }
                          return false;
                        },
                        child: CustomScrollView(
                          slivers: [
                            PinnedHeaderSliver(
                              child: SizedBox(height: topInset),
                            ),
                            if (widget.commentId != null)
                              SliverToBoxAdapter(
                                child: TextButton(
                                  onPressed: () => context.replace(
                                    '/posts/${widget.postId}',
                                  ),
                                  child: Text(
                                    l10n.t('ai.knowledge.all_comments'),
                                  ),
                                ),
                              ),
                            SliverPadding(
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                              sliver: SliverToBoxAdapter(
                                child: Builder(
                                  builder: (context) {
                                    final card = PostCard(
                                      post: _post!,
                                      focused: true,
                                      avatarHeroTag:
                                          'avatar-${_post!.postId}-${_post!.author.userId}',
                                      onOpenLikers:
                                          signedIn &&
                                              _post!.postId == widget.postId
                                          ? () => Navigator.of(context)
                                                .push<void>(
                                                  MaterialPageRoute<void>(
                                                    builder: (_) =>
                                                        PostLikersScreen(
                                                          postId: widget.postId,
                                                        ),
                                                  ),
                                                )
                                          : null,
                                      onRetweeted: () {
                                        if (_showRetweets) {
                                          _loadRelatedPosts(reset: true);
                                        }
                                      },
                                      onChanged: (p) {
                                        if (_active) setState(() => _post = p);
                                      },
                                      onDeleted: _leaveDeletedPost,
                                      onReport: () {
                                        final post = _post;
                                        if (!_active || post == null) return;
                                        showReportDialog(
                                          context,
                                          ref,
                                          targetType: 'post',
                                          targetId: post.postId,
                                        );
                                      },
                                    );
                                    if (!signedIn ||
                                        _post!.postId != widget.postId) {
                                      return card;
                                    }
                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        card,
                                        if (showRelatedPosts)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              top: 10,
                                            ),
                                            child: Wrap(
                                              spacing: 8,
                                              runSpacing: 8,
                                              children: [
                                                ActionChip(
                                                  backgroundColor:
                                                      scheme.surfaceContainer,
                                                  side: BorderSide.none,
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          AppRadius.inner,
                                                        ),
                                                  ),
                                                  avatar: Icon(
                                                    Icons.reply_rounded,
                                                    size: 16,
                                                    color: scheme.primary,
                                                  ),
                                                  label: Text(
                                                    l10n.t(
                                                      'post.replies.write',
                                                    ),
                                                    style: theme
                                                        .textTheme
                                                        .labelMedium
                                                        ?.copyWith(
                                                          fontWeight:
                                                              FontWeight.w600,
                                                        ),
                                                  ),
                                                  onPressed: _openCompose,
                                                ),
                                                if (_post!.visibility ==
                                                        'public' &&
                                                    _post!.content
                                                        .trim()
                                                        .isNotEmpty)
                                                  ActionChip(
                                                    backgroundColor:
                                                        scheme.surfaceContainer,
                                                    side: BorderSide.none,
                                                    shape: RoundedRectangleBorder(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            AppRadius.inner,
                                                          ),
                                                    ),
                                                    avatar: Icon(
                                                      Icons.auto_awesome,
                                                      size: 16,
                                                      color: scheme.primary,
                                                    ),
                                                    label: Text(
                                                      l10n.t(
                                                        _summaryPending
                                                            ? 'common.loading'
                                                            : 'ai.writing.summarize_post',
                                                      ),
                                                      style: theme
                                                          .textTheme
                                                          .labelMedium
                                                          ?.copyWith(
                                                            fontWeight:
                                                                FontWeight.w600,
                                                          ),
                                                    ),
                                                    onPressed: _summaryPending
                                                        ? null
                                                        : _openDiscussionSummary,
                                                  ),
                                              ],
                                            ),
                                          ),
                                      ],
                                    );
                                  },
                                ),
                              ),
                            ),
                            if (showRelatedPosts)
                              SliverPersistentHeader(
                                pinned: true,
                                delegate: _RelatedTabsDelegate(
                                  showRetweets: _showRetweets,
                                  repliesLabel: l10n.t('post.replies.title'),
                                  repostsLabel: l10n.t('post.reposts.title'),
                                  onSelect: _selectRelatedPosts,
                                ),
                              ),
                            if (showRelatedPosts)
                              SliverPadding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                sliver: SliverList.builder(
                                  itemCount: _relatedPosts.length + 1,
                                  itemBuilder: (context, index) {
                                    if (index == _relatedPosts.length) {
                                      return _relatedFooter(l10n);
                                    }
                                    final reply = _relatedPosts[index];
                                    return Padding(
                                      key: ValueKey(reply.postId),
                                      padding: const EdgeInsets.only(
                                        bottom: 10,
                                      ),
                                      child: PostCard(
                                        post: reply,
                                        onChanged: (updated) {
                                          if (!_active) return;
                                          setState(() {
                                            _relatedPosts = [
                                              for (final post in _relatedPosts)
                                                if (post.postId ==
                                                    updated.postId)
                                                  updated
                                                else
                                                  post,
                                            ];
                                          });
                                        },
                                        onDeleted: () {
                                          if (_active) {
                                            _loadRelatedPosts(reset: true);
                                          }
                                        },
                                        onReport: () {
                                          if (!_active) return;
                                          showReportDialog(
                                            context,
                                            ref,
                                            targetType: 'post',
                                            targetId: reply.postId,
                                          );
                                        },
                                      ),
                                    );
                                  },
                                ),
                              ),
                            SliverPadding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                              sliver: SliverList.builder(
                                itemCount:
                                    1 +
                                    (_comments.isEmpty
                                        ? (_hasNext ? 0 : 1)
                                        : _comments.length) +
                                    (_hasNext ? 1 : 0),
                                itemBuilder: (context, index) {
                                  if (index == 0) {
                                    return Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        4,
                                        14,
                                        4,
                                        8,
                                      ),
                                      child: Row(
                                        children: [
                                          Text(
                                            l10n.t('post.stats.comments'),
                                            style: theme.textTheme.labelLarge
                                                ?.copyWith(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w600,
                                                  color:
                                                      scheme.onSurfaceVariant,
                                                ),
                                          ),
                                          if (_comments.isNotEmpty) ...[
                                            const SizedBox(width: 6),
                                            Text(
                                              '· ${_comments.length}',
                                              style: theme.textTheme.labelMedium
                                                  ?.copyWith(
                                                    color: social.inkTertiary,
                                                  ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    );
                                  }

                                  if (_commentsPending) {
                                    return const Padding(
                                      padding: EdgeInsets.all(24),
                                      child: Center(
                                        child: CircularProgressIndicator(),
                                      ),
                                    );
                                  }
                                  if (_commentsError case final error?) {
                                    return ErrorView(
                                      error: error,
                                      onRetry: _loadComments,
                                    );
                                  }
                                  if (_comments.isEmpty) {
                                    if (!_hasNext) {
                                      return Padding(
                                        padding: const EdgeInsets.all(24),
                                        child: EmptyView(
                                          message: l10n.t(
                                            widget.commentId == null
                                                ? 'post.comments.empty'
                                                : 'ai.knowledge.cited_comment_missing',
                                          ),
                                        ),
                                      );
                                    }
                                    return const Padding(
                                      padding: EdgeInsets.all(24),
                                      child: Center(
                                        child: CircularProgressIndicator(),
                                      ),
                                    );
                                  }

                                  final contentIndex = index - 1;
                                  if (contentIndex < _comments.length) {
                                    final c = _comments[contentIndex];
                                    final tile = _CommentTile(
                                      comment: c,
                                      isNestedReply: c.parentCommentId != null,
                                      onReply: _sendingComment
                                          ? null
                                          : () => _replyToComment(c),
                                      onLike:
                                          _pendingCommentLikes.contains(
                                            c.commentId,
                                          )
                                          ? null
                                          : () => _toggleCommentLike(c),
                                      canDelete: c.canDelete,
                                      onDelete: c.canDelete && !_deletingComment
                                          ? () => _deleteComment(c)
                                          : null,
                                    );
                                    if (contentIndex < 8) {
                                      return StaggeredEntrance(
                                        index: contentIndex,
                                        child: tile,
                                      );
                                    }
                                    return tile;
                                  }

                                  return const Padding(
                                    padding: EdgeInsets.all(24),
                                    child: Center(
                                      child: CircularProgressIndicator(),
                                    ),
                                  );
                                },
                              ),
                            ),
                            SliverPadding(
                              padding: EdgeInsets.only(
                                bottom: showComposer
                                    ? math.max(
                                        108 + bottomInset,
                                        _composerHeight,
                                      )
                                    : bottomInset,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (showComposer)
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: measureGlassOverlay(
                            SafeArea(
                              top: false,
                              child: LiquidGlassSurface(
                                preset: LiquidGlassPreset.floatingIsland,
                                borderRadius: BorderRadius.circular(
                                  AppRadius.canvas,
                                ),
                                margin: const EdgeInsets.fromLTRB(
                                  12,
                                  6,
                                  12,
                                  12,
                                ),
                                padding: const EdgeInsets.fromLTRB(
                                  14,
                                  10,
                                  10,
                                  10,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (_replyTarget != null)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 6,
                                        ),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                '${l10n.t('chat.replying_to')} @${_replyTarget!.author.username}',
                                                style: theme
                                                    .textTheme
                                                    .labelMedium
                                                    ?.copyWith(
                                                      color: scheme.primary,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            IconButton(
                                              onPressed: _sendingComment
                                                  ? null
                                                  : () => setState(
                                                      () => _replyTarget = null,
                                                    ),
                                              tooltip: l10n.t('common.cancel'),
                                              visualDensity:
                                                  VisualDensity.compact,
                                              icon: const Icon(
                                                Icons.close,
                                                size: 16,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    AnimatedSize(
                                      duration: AppMotion.resolve(
                                        context,
                                        AppMotion.glide,
                                      ),
                                      curve: AppMotion.glideCurve,
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: [
                                          Expanded(
                                            child: TextField(
                                              controller: _replyController,
                                              enabled: !_sendingComment,
                                              minLines: 1,
                                              maxLines: 5,
                                              decoration: InputDecoration(
                                                hintText: l10n.t(
                                                  'post.reply_placeholder',
                                                ),
                                                isDense: true,
                                                filled: false,
                                                contentPadding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 4,
                                                      vertical: 8,
                                                    ),
                                                border: InputBorder.none,
                                                enabledBorder: InputBorder.none,
                                                focusedBorder: InputBorder.none,
                                              ),
                                              textInputAction:
                                                  TextInputAction.send,
                                              onSubmitted: (_) =>
                                                  _submitReply(),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          ValueListenableBuilder<
                                            TextEditingValue
                                          >(
                                            valueListenable: _replyController,
                                            builder: (context, value, _) {
                                              final hasText = value.text
                                                  .trim()
                                                  .isNotEmpty;
                                              return AnimatedScale(
                                                scale: hasText ? 1.0 : 0.92,
                                                duration: AppMotion.resolve(
                                                  context,
                                                  AppMotion.micro,
                                                ),
                                                curve: AppMotion.glideCurve,
                                                child: IconButton.filled(
                                                  onPressed:
                                                      _sendingComment ||
                                                          !hasText
                                                      ? null
                                                      : _submitReply,
                                                  tooltip: l10n.t(
                                                    'common.post',
                                                  ),
                                                  style: IconButton.styleFrom(
                                                    fixedSize: const Size(
                                                      38,
                                                      38,
                                                    ),
                                                  ),
                                                  icon: const Icon(
                                                    Icons.send_rounded,
                                                    size: 18,
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            (height) {
                              if (_composerHeight != height) {
                                setState(() => _composerHeight = height);
                              }
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _relatedFooter(AppLocalizations l10n) {
    if (_relatedPending) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final error = _relatedError;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(ErrorView.describe(context, error)),
            TextButton(
              onPressed: () => _loadRelatedPosts(reset: !_relatedHasNext),
              child: Text(l10n.t('common.retry')),
            ),
          ],
        ),
      );
    }
    if (_relatedHasNext) {
      return TextButton(
        onPressed: _loadRelatedPosts,
        child: Text(
          l10n.t(_showRetweets ? 'post.reposts.more' : 'post.replies.more'),
        ),
      );
    }
    if (_relatedPosts.isEmpty && !_relatedSelected) {
      return const SizedBox.shrink();
    }
    return _relatedPosts.isEmpty
        ? Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 4, 12),
            child: Text(
              l10n.t(
                _showRetweets ? 'post.reposts.empty' : 'post.replies.empty',
              ),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: SocialColors.of(context).inkTertiary,
              ),
            ),
          )
        : const SizedBox.shrink();
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({
    required this.comment,
    this.isNestedReply = false,
    this.onLike,
    this.onReply,
    required this.canDelete,
    this.onDelete,
  });
  final V2Comment comment;
  final bool isNestedReply;
  final VoidCallback? onLike;
  final VoidCallback? onReply;
  final VoidCallback? onDelete;
  final bool canDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final social = SocialColors.of(context);
    final l10n = AppLocalizations.of(context);
    final displayName = comment.author.displayName.isEmpty
        ? comment.author.username
        : comment.author.displayName;
    final locale = Localizations.localeOf(context);

    final card = SurfaceCard(
      radius: AppRadius.card,
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppAvatar(
            url: comment.author.avatarUrl,
            size: 36,
            name: displayName,
            seed: comment.author.userId,
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
                        displayName,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        '@${comment.author.username}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: social.inkTertiary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      ' · ',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: social.inkTertiary,
                      ),
                    ),
                    Tooltip(
                      message: formatFullTimestamp(
                        comment.createdAt,
                        locale: locale,
                      ),
                      child: Text(
                        formatRelativeTime(comment.createdAt, locale: locale),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: social.inkTertiary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  comment.content,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.60),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Tooltip(
                      message: l10n.t(
                        comment.isLiked ? 'common.unlike' : 'common.like',
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(999),
                        onTap: onLike,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 4,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                comment.isLiked
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                size: 17,
                                color: comment.isLiked
                                    ? social.like
                                    : scheme.onSurfaceVariant,
                              ),
                              if (comment.likesCount > 0) ...[
                                const SizedBox(width: 4),
                                AnimatedCount(
                                  count: comment.likesCount,
                                  hideZero: true,
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: comment.isLiked
                                        ? social.like
                                        : scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: onReply,
                      tooltip: l10n.t('post.comment.reply'),
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        Icons.reply,
                        size: 17,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (canDelete)
            IconButton(
              tooltip: l10n.t('common.delete'),
              visualDensity: VisualDensity.compact,
              icon: Icon(
                Icons.delete_outline,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
              onPressed: onDelete,
            ),
        ],
      ),
    );

    if (!isNestedReply) {
      return Padding(padding: const EdgeInsets.only(bottom: 10), child: card);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 0, 10),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 2,
              margin: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: card),
          ],
        ),
      ),
    );
  }
}

class _RelatedTabsDelegate extends SliverPersistentHeaderDelegate {
  _RelatedTabsDelegate({
    required this.showRetweets,
    required this.repliesLabel,
    required this.repostsLabel,
    required this.onSelect,
  });

  final bool showRetweets;
  final String repliesLabel;
  final String repostsLabel;
  final void Function({required bool retweets}) onSelect;

  @override
  double get minExtent => 60;

  @override
  double get maxExtent => 60;

  Widget _buildTabChip(BuildContext context, String label, bool retweets) {
    final selected = retweets == showRetweets;
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final caption = SizedBox(
          width: constraints.maxWidth,
          height: 34,
          child: Center(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
              ),
            ),
          ),
        );
        return ChoiceChip(
          showCheckmark: false,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
          elevation: 0,
          pressElevation: 0,
          surfaceTintColor: Colors.transparent,
          backgroundColor: Colors.transparent,
          selectedColor: Colors.transparent,
          side: BorderSide.none,
          shape: const StadiumBorder(),
          padding: EdgeInsets.zero,
          labelPadding: EdgeInsets.zero,
          selected: selected,
          onSelected: (_) => onSelect(retweets: retweets),
          label: selected
              ? DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: caption,
                )
              : caption,
        );
      },
    );
  }

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return LiquidGlassSurface(
      preset: LiquidGlassPreset.stickyHeader,
      borderRadius: BorderRadius.zero,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(
            alpha: Theme.of(context).brightness == Brightness.dark
                ? 0.22
                : 0.06,
          ),
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: SizedBox(
            height: 34,
            child: Row(
              children: [
                Expanded(child: _buildTabChip(context, repliesLabel, false)),
                Expanded(child: _buildTabChip(context, repostsLabel, true)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _RelatedTabsDelegate oldDelegate) =>
      oldDelegate.showRetweets != showRetweets ||
      oldDelegate.repliesLabel != repliesLabel ||
      oldDelegate.repostsLabel != repostsLabel;
}
