import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/utils/group_post_link.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/routing/auth_navigation.dart';
import '../../../shared/theme/tokens.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../../ai/presentation/ai_writing_screen.dart';
import '../../links/presentation/content_link_preview.dart';
import '../../posts/domain/post_draft_metadata.dart';
import '../../posts/presentation/post_poll_card.dart';
import '../../posts/presentation/post_markdown_body.dart';
import '../domain/group_models.dart';

class GroupPostDetailScreen extends ConsumerStatefulWidget {
  const GroupPostDetailScreen({
    super.key,
    this.slug,
    this.groupId,
    required this.postId,
    this.commentId,
  }) : assert((slug == null) != (groupId == null));

  final String? slug;
  final int? groupId;
  final int postId;
  final int? commentId;

  @override
  ConsumerState<GroupPostDetailScreen> createState() =>
      _GroupPostDetailScreenState();
}

class _GroupPostDetailScreenState extends ConsumerState<GroupPostDetailScreen> {
  V2Group? _group;
  V2GroupPost? _post;
  List<V2GroupComment> _comments = [];
  bool _loading = true;
  bool _loadingMoreComments = false;
  bool _loadingComments = false;
  Object? _commentsError;
  String _commentSort = 'newest';
  int _commentRequest = 0;
  bool _commentsHasNext = false;
  int _commentsPage = 1;
  Object? _error;
  bool _expired = false;
  bool _postMutationPending = false;
  bool _summaryPending = false;
  final _pendingCommentLikes = <int>{};
  int _loadRevision = 0;
  VoidCallback? _stopSession;
  bool get _active => mounted && !_expired;
  final _commentController = TextEditingController();
  final _commentFocus = FocusNode();
  V2GroupComment? _replyTarget;
  bool _submittingComment = false;
  bool get _canComment => _group?.membership.status == 'active';
  bool get _canSummarizeDiscussion =>
      _active &&
      !_loading &&
      _error == null &&
      widget.commentId == null &&
      _group?.privacy == 'public' &&
      _group?.isActive == 1 &&
      _post?.content.trim().isNotEmpty == true;

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
    _stopSession?.call();
    _commentController.dispose();
    _commentFocus.dispose();
    super.dispose();
  }

  void _expire() {
    if (!_active) return;
    _commentController.clear();
    setState(() {
      _expired = true;
      _group = null;
      _post = null;
      _comments = [];
      _replyTarget = null;
      _commentRequest++;
    });
  }

  Future<void> _summarizeDiscussion() async {
    final group = _group;
    final post = _post;
    if (group == null ||
        post == null ||
        !_canSummarizeDiscussion ||
        _summaryPending ||
        !requireAuthenticatedAction(context, ref)) {
      return;
    }
    final store = ref.read(tokenStoreProvider);
    final revision = store.revision;
    final loadRevision = _loadRevision;
    final viewed = _commentRequest;
    final sort = _commentSort;
    final seen = _comments
        .where((comment) => comment.postId == post.postId)
        .map((comment) => comment.commentId)
        .toSet();
    final api = ref.read(groupsApiProvider);
    bool sameSource() =>
        _canSummarizeDiscussion &&
        !store.isSessionChanging &&
        store.revision == revision &&
        _loadRevision == loadRevision &&
        _commentRequest == viewed &&
        _group?.groupId == group.groupId &&
        _post?.postId == post.postId &&
        identical(api, ref.read(groupsApiProvider));
    bool current() => sameSource() && ModalRoute.of(context)?.isCurrent == true;
    if (!current()) return;
    setState(() => _summaryPending = true);
    try {
      final confirmed = seen.isEmpty
          ? const <V2GroupComment>[]
          : (await api.comments(
              groupId: group.groupId,
              postId: post.postId,
              page: 1,
              size: 20,
              sort: sort,
            )).items;
      if (!current()) return;
      final updated = await api.getPost(
        groupId: group.groupId,
        postId: post.postId,
      );
      if (!current()) return;
      final visibility = await api.getGroupById(group.groupId);
      if (!current()) return;
      if (updated.postId != post.postId ||
          updated.groupId != group.groupId ||
          visibility.groupId != group.groupId ||
          visibility.privacy != 'public' ||
          visibility.isActive != 1) {
        throw const FormatException('Group discussion is unavailable');
      }
      final draft = discussionTextDraft(
        postId: updated.postId,
        visibility: visibility.privacy,
        content: updated.content,
        comments: confirmed
            .where(
              (comment) =>
                  comment.postId == post.postId &&
                  seen.remove(comment.commentId),
            )
            .map(
              (comment) => (postId: comment.postId, content: comment.content),
            ),
      );
      if (draft.isEmpty) {
        throw const FormatException('Group discussion is unavailable');
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
      ).t('group.summary_unavailable');
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
      _commentsPage = 1;
      _commentsHasNext = false;
      _commentRequest++;
      _comments = [];
      _loadingComments = false;
      _loadingMoreComments = false;
    });
    try {
      final api = ref.read(groupsApiProvider);
      final targetGroup = widget.groupId;
      final group = targetGroup == null
          ? await api.getGroup(widget.slug!)
          : await api.getGroupById(targetGroup);
      if (!valid()) return;
      if (group.groupId <= 0 ||
          (targetGroup != null && group.groupId != targetGroup) ||
          (widget.slug != null && group.slug != widget.slug)) {
        throw const FormatException('Unexpected group');
      }
      final post = await api.getPost(
        groupId: group.groupId,
        postId: widget.postId,
      );
      if (!valid()) return;
      if (post.groupId != group.groupId || post.postId != widget.postId) {
        throw const FormatException('Unexpected group post');
      }
      setState(() {
        _group = group;
        _post = post;
        _loading = false;
      });
      await _readComments();
    } catch (e) {
      if (!valid()) return;
      setState(() {
        _error = e;
        _loading = false;
        _loadingMoreComments = false;
      });
    }
  }

  Future<void> _readComments({bool append = false}) async {
    final post = _post;
    final target = widget.commentId;
    if (!_active ||
        post == null ||
        _loading ||
        (append &&
            (target != null ||
                _loadingComments ||
                _loadingMoreComments ||
                !_commentsHasNext))) {
      return;
    }
    final revision = _loadRevision;
    final request = ++_commentRequest;
    bool current() =>
        _active &&
        revision == _loadRevision &&
        request == _commentRequest &&
        _post?.postId == post.postId;
    final next = append ? _commentsPage + 1 : 1;
    setState(() {
      _commentsError = null;
      _loadingComments = !append;
      _loadingMoreComments = append;
      if (!append) {
        _comments = [];
        _commentsHasNext = false;
      }
    });
    try {
      final page = await ref
          .read(groupsApiProvider)
          .comments(
            groupId: post.groupId,
            postId: post.postId,
            page: next,
            size: target == null ? 20 : 1,
            commentId: target,
            sort: _commentSort,
          );
      if (!current()) return;
      setState(() {
        _comments = {
          for (final comment in [..._comments, ...page.items])
            if (comment.postId == post.postId &&
                comment.commentId > 0 &&
                (target == null || comment.commentId == target))
              comment.commentId: comment,
        }.values.toList();
        _commentsPage = next;
        _commentsHasNext = target == null && page.hasNext;
        _loadingComments = false;
        _loadingMoreComments = false;
      });
    } catch (e) {
      if (!current()) return;
      setState(() {
        if (!append) _commentsError = e;
        _loadingComments = false;
        _loadingMoreComments = false;
      });
      if (append) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
      }
    }
  }

  String _formatDate(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return DateFormat.yMMMd().add_Hm().format(dt.toLocal());
  }

  Future<void> _togglePin() => _mutatePost((post) async {
    final pinned = await ref
        .read(groupsApiProvider)
        .setGroupPostPinStatus(
          groupId: post.groupId,
          postId: post.postId,
          isPinned: !post.isPinned,
        );
    return (V2GroupPost current) => current.copyWith(isPinned: pinned);
  });

  Future<void> _toggleLike() => _mutatePost((post) async {
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

  Future<void> _mutatePost(
    Future<V2GroupPost Function(V2GroupPost)> Function(V2GroupPost) mutate,
  ) async {
    final post = _post;
    if (!_active ||
        post == null ||
        _postMutationPending ||
        !requireAuthenticatedAction(context, ref)) {
      return;
    }
    final revision = _loadRevision;
    bool valid() => _active && revision == _loadRevision && _post != null;
    setState(() => _postMutationPending = true);
    try {
      final update = await mutate(post);
      if (valid()) setState(() => _post = update(_post!));
    } catch (error) {
      if (!valid()) return;
      if (error is ApiException && error.isNotFound) {
        setState(() {
          _post = null;
          _comments = [];
          _error = error;
        });
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorView.describe(context, error))),
      );
    } finally {
      if (_active) setState(() => _postMutationPending = false);
    }
  }

  Future<void> _submitComment() async {
    final post = _post;
    final target = _replyTarget;
    if (!_active ||
        !_canComment ||
        post == null ||
        _loading ||
        _submittingComment) {
      return;
    }
    if (target != null && target.postId != post.postId) return;
    if (!requireAuthenticatedAction(context, ref)) return;
    final text = _commentController.text.trim();
    if (text.isEmpty || utf8.encode(text).length > 1000) return;
    final revision = _loadRevision;
    bool current() =>
        _active && revision == _loadRevision && _post?.postId == post.postId;
    setState(() => _submittingComment = true);
    try {
      final created = await ref
          .read(groupsApiProvider)
          .createComment(
            groupId: post.groupId,
            postId: post.postId,
            content: text,
            parentCommentId: target?.commentId,
          );
      if (!current()) return;
      if (created.postId != post.postId ||
          created.commentId < 1 ||
          created.commentId > 9007199254740991 ||
          created.parentCommentId != target?.commentId) {
        throw const FormatException('Unexpected group comment receipt');
      }
      setState(() {
        _commentController.clear();
        _replyTarget = null;
        final updated = _post!;
        _post = updated.copyWith(commentsCount: updated.commentsCount + 1);
      });
      if (target != null) {
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.t('post.comment.reply_sent'))),
        );
      }
      if (widget.commentId == null) await _readComments();
    } catch (e) {
      if (!current()) return;
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e is FormatException
                ? l10n.t('group.comment_unconfirmed')
                : ErrorView.describe(context, e),
          ),
        ),
      );
    } finally {
      if (_active) setState(() => _submittingComment = false);
    }
  }

  void _replyTo(V2GroupComment comment) {
    if (!_active ||
        !_canComment ||
        _submittingComment ||
        comment.postId != _post?.postId) {
      return;
    }
    setState(() => _replyTarget = comment);
    _commentFocus.requestFocus();
  }

  Future<void> _deleteComment(V2GroupComment comment) async {
    if (_group == null || _post == null) return;
    if (!requireAuthenticatedAction(context, ref)) return;
    final revision = _loadRevision;
    try {
      await ref
          .read(groupsApiProvider)
          .deleteComment(
            groupId: _group!.groupId,
            postId: _post!.postId,
            commentId: comment.commentId,
          );
      if (!_active || revision != _loadRevision) return;
      setState(() {
        _comments = _comments
            .where((item) => item.commentId != comment.commentId)
            .toList();
        final post = _post;
        if (post != null) {
          _post = post.copyWith(
            commentsCount: (post.commentsCount - 1).clamp(0, 1 << 30),
          );
        }
      });
      await _readComments();
    } catch (e) {
      if (!_active) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _toggleCommentLike(V2GroupComment comment) async {
    final post = _post;
    final id = comment.commentId;
    if (!_active ||
        post == null ||
        _pendingCommentLikes.contains(id) ||
        !requireAuthenticatedAction(context, ref)) {
      return;
    }
    final revision = _loadRevision;
    bool valid() => _active && revision == _loadRevision && _post != null;
    _pendingCommentLikes.add(id);
    try {
      final state = await ref
          .read(groupsApiProvider)
          .setCommentLikeStatus(
            groupId: post.groupId,
            postId: post.postId,
            commentId: id,
            liked: !comment.isLikedByMe,
          );
      if (!valid()) return;
      if (_commentSort == 'popular' && widget.commentId == null) {
        await _readComments();
        return;
      }
      setState(() {
        _comments = [
          for (final current in _comments)
            if (current.commentId == id)
              current.copyWith(
                isLikedByMe: state.liked,
                likesCount: state.count,
              )
            else
              current,
        ];
      });
    } catch (error) {
      if (!valid()) return;
      if (error is ApiException && error.isNotFound) {
        setState(
          () => _comments = _comments
              .where((current) => current.commentId != id)
              .toList(),
        );
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorView.describe(context, error))),
      );
    } finally {
      _pendingCommentLikes.remove(id);
    }
  }

  Future<void> _sharePost() async {
    final post = _post;
    if (!_active || _loading || _error != null || post == null) return;
    final revision = _loadRevision;
    bool current() => _active && revision == _loadRevision;
    final l10n = AppLocalizations.of(context);
    final url = groupPostShareUrl(
      (groupId: post.groupId, postId: post.postId, commentId: widget.commentId),
      configuredBase: ref.read(appConfigBundleProvider).groupPostShareBaseUrl,
      browserEntry: kIsWeb ? Uri.base : null,
    );
    if (url == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t('group.share_unavailable'))),
      );
      return;
    }
    try {
      await Clipboard.setData(ClipboardData(text: url.toString()));
      if (current()) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.t('group.share_copied'))));
      }
    } catch (_) {
      if (!current()) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(l10n.t('group.share_post')),
          content: SelectableText(url.toString()),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.t('common.cancel')),
            ),
          ],
        ),
      );
    }
  }

  Widget _buildCommentComposer(AppLocalizations l10n, ThemeData theme) {
    final target = _replyTarget;
    return Container(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (target != null)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${l10n.t('chat.replying_to')} @${target.author.username}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      onPressed: _submittingComment
                          ? null
                          : () => setState(() => _replyTarget = null),
                      tooltip: l10n.t('chat.cancel_reply'),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _commentController,
                      focusNode: _commentFocus,
                      enabled: !_submittingComment,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: l10n.t('common.comment'),
                        isDense: true,
                        errorText:
                            utf8.encode(_commentController.text.trim()).length >
                                1000
                            ? l10n.t('group.comment_too_long')
                            : null,
                      ),
                      onSubmitted: (_) => _submitComment(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed:
                        _submittingComment ||
                            _commentController.text.trim().isEmpty
                        ? null
                        : _submitComment,
                    icon: const Icon(Icons.send_rounded),
                    tooltip: l10n.t('common.post'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final signedIn = ref.watch(
      authSessionProvider.select((session) => session.isAuthenticated),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _group?.name ?? l10n.t('group.group'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (signedIn && _canSummarizeDiscussion)
            IconButton(
              tooltip: l10n.t('ai.writing.summarize_post'),
              icon: _summaryPending
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome_outlined),
              onPressed: _summaryPending ? null : _summarizeDiscussion,
            ),
          if (!_expired && !_loading && _error == null && _post != null)
            IconButton(
              tooltip: l10n.t('group.share_post'),
              icon: const Icon(Icons.share_outlined),
              onPressed: _sharePost,
            ),
        ],
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
                child: Column(
                  children: [
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: _load,
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                          children: [
                            Row(
                              children: [
                                AppAvatar(
                                  url: _post!.author.avatarUrl,
                                  size: 44,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _post!.author.displayName.isEmpty
                                            ? _post!.author.username
                                            : _post!.author.displayName,
                                        style: theme.textTheme.titleSmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                            ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(
                                        _formatDate(_post!.createdAt),
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: _post!.isPinned
                                      ? l10n.t('chat.unpin')
                                      : l10n.t('chat.pin'),
                                  icon: Icon(
                                    _post!.isPinned
                                        ? Icons.push_pin
                                        : Icons.push_pin_outlined,
                                    color: _post!.isPinned
                                        ? theme.colorScheme.primary
                                        : null,
                                  ),
                                  onPressed: _postMutationPending
                                      ? null
                                      : _togglePin,
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            if (_post!.markdown case final source?)
                              PostMarkdownBody(source: source)
                            else
                              Text(
                                _post!.content,
                                style: theme.textTheme.bodyLarge,
                              ),
                            ContentLinkPreview(
                              content: _post!.content,
                              markdown: _post!.markdown,
                            ),
                            if (_post!.poll case final poll?)
                              PostPollCard(
                                key: ValueKey((
                                  _post!.groupId,
                                  _post!.postId,
                                  poll.pollId,
                                )),
                                groupId: _post!.groupId,
                                postId: _post!.postId,
                                poll: poll,
                                canWrite: _group?.canWritePosts ?? false,
                              ),
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                _PostMetric(
                                  icon: _post!.isLikedByMe
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  label: '${_post!.likesCount}',
                                  semanticLabel: l10n.t(
                                    _post!.isLikedByMe
                                        ? 'common.unlike'
                                        : 'common.like',
                                  ),
                                  active: _post!.isLikedByMe,
                                  activeColor: const Color(0xFFE0245E),
                                  onTap: _postMutationPending
                                      ? null
                                      : _toggleLike,
                                ),
                                const SizedBox(width: 20),
                                _PostMetric(
                                  icon: Icons.mode_comment_outlined,
                                  label: '${_post!.commentsCount}',
                                  semanticLabel: l10n.t('post.stats.comments'),
                                ),
                                const SizedBox(width: 20),
                                _PostMetric(
                                  icon: Icons.visibility_outlined,
                                  label: '${_post!.viewsCount}',
                                  semanticLabel: l10n.t('post.stats.views'),
                                ),
                              ],
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              child: Divider(
                                height: 1,
                                color: theme.dividerColor,
                              ),
                            ),
                            if (widget.commentId != null)
                              TextButton(
                                onPressed: () => context.replace(
                                  groupPostLocation((
                                    groupId: _group!.groupId,
                                    postId: widget.postId,
                                    commentId: null,
                                  )),
                                ),
                                child: Text(
                                  l10n.t('ai.knowledge.all_comments'),
                                ),
                              )
                            else
                              Wrap(
                                spacing: 12,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text(l10n.t('group.comment_order.label')),
                                  DropdownButton<String>(
                                    key: const Key('group-comment-order'),
                                    value: _commentSort,
                                    onChanged: (sort) {
                                      if (sort == null ||
                                          sort == _commentSort) {
                                        return;
                                      }
                                      setState(() => _commentSort = sort);
                                      _readComments();
                                    },
                                    items: [
                                      for (final sort in [
                                        'newest',
                                        'oldest',
                                        'popular',
                                      ])
                                        DropdownMenuItem(
                                          value: sort,
                                          child: Text(
                                            l10n.t('group.comment_order.$sort'),
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            if (_loadingComments)
                              const Center(child: CircularProgressIndicator())
                            else if (_commentsError != null)
                              ErrorView(
                                error: _commentsError!,
                                onRetry: _readComments,
                              )
                            else if (_comments.isEmpty)
                              Padding(
                                padding: const EdgeInsets.all(24),
                                child: EmptyView(
                                  message: l10n.t(
                                    widget.commentId == null
                                        ? 'feed.empty'
                                        : 'ai.knowledge.cited_comment_missing',
                                  ),
                                ),
                              )
                            else
                              for (final comment in _comments)
                                _CommentTile(
                                  comment: comment,
                                  onLike: () => _toggleCommentLike(comment),
                                  onReply: _canComment && !_submittingComment
                                      ? () => _replyTo(comment)
                                      : null,
                                  onDelete: comment.canDeleteByMe
                                      ? () => _deleteComment(comment)
                                      : null,
                                ),
                            if (_commentsHasNext)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Center(
                                  child: TextButton(
                                    key: const Key(
                                      'group-post-comments-load-more',
                                    ),
                                    onPressed: _loadingMoreComments
                                        ? null
                                        : () => _readComments(append: true),
                                    child: _loadingMoreComments
                                        ? const SizedBox.square(
                                            dimension: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : Text(l10n.t('common.more')),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (_canComment) _buildCommentComposer(l10n, theme),
                  ],
                ),
              ),
            ),
    );
  }
}

class _PostMetric extends StatelessWidget {
  const _PostMetric({
    required this.icon,
    required this.label,
    required this.semanticLabel,
    this.onTap,
    this.active = false,
    this.activeColor,
  });
  final IconData icon;
  final String label;
  final String semanticLabel;
  final VoidCallback? onTap;
  final bool active;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = active
        ? (activeColor ?? theme.colorScheme.primary)
        : theme.colorScheme.onSurfaceVariant;
    final content = Padding(
      padding: const EdgeInsets.all(AppGap.xs),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ],
      ),
    );
    return Semantics(
      label: semanticLabel,
      button: onTap != null,
      child: onTap == null
          ? content
          : InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: content,
            ),
    );
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({
    required this.comment,
    required this.onLike,
    this.onReply,
    this.onDelete,
  });
  final V2GroupComment comment;
  final VoidCallback onLike;
  final VoidCallback? onReply;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppAvatar(url: comment.author.avatarUrl, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  comment.author.displayName.isEmpty
                      ? comment.author.username
                      : comment.author.displayName,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                if (comment.replyToUser case final user?)
                  Text(
                    '${l10n.t('chat.replying_to')} @${user.username}',
                    style: theme.textTheme.labelMedium,
                  ),
                Text(comment.content, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 4),
                Row(
                  children: [
                    InkWell(
                      onTap: onLike,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              comment.isLikedByMe
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              size: 14,
                              color: comment.isLikedByMe
                                  ? const Color(0xFFE0245E)
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${comment.likesCount}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: comment.isLikedByMe
                                    ? const Color(0xFFE0245E)
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (onReply != null)
            IconButton(
              tooltip: l10n.t('post.comment.reply'),
              icon: const Icon(Icons.reply, size: 18),
              onPressed: onReply,
            ),
          if (onDelete != null)
            IconButton(
              tooltip: l10n.t('common.delete'),
              color: theme.colorScheme.onSurfaceVariant,
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: onDelete,
            ),
        ],
      ),
    );
  }
}
