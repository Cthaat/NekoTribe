import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/routing/auth_navigation.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/post_models.dart';
import 'post_card.dart';
import 'compose_post_screen.dart';
import 'report_dialog.dart';

class PostDetailScreen extends ConsumerStatefulWidget {
  const PostDetailScreen({super.key, required this.postId});
  final int postId;

  @override
  ConsumerState<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends ConsumerState<PostDetailScreen> {
  V2Post? _post;
  List<V2Comment> _comments = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasNext = false;
  int _page = 1;
  Object? _error;
  final _replyController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _replyController.dispose();
    super.dispose();
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
      final api = ref.read(postsApiProvider);
      final post = await api.getPost(widget.postId);
      final comments = await api.getComments(widget.postId, page: 1, size: 20);
      if (!mounted) return;
      setState(() {
        _post = post;
        _comments = comments.items;
        _page = 1;
        _hasNext = comments.hasNext;
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

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasNext || _loading) return;
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final page = await ref
          .read(postsApiProvider)
          .getComments(widget.postId, page: next, size: 20);
      if (!mounted) return;
      setState(() {
        _comments = [..._comments, ...page.items];
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

  Future<void> _submitReply() async {
    if (!requireAuthenticatedAction(context, ref)) return;
    final text = _replyController.text.trim();
    if (text.isEmpty) return;
    try {
      final comment = await ref
          .read(postsApiProvider)
          .createComment(postId: widget.postId, content: text);
      if (!mounted) return;
      setState(() {
        _comments.insert(0, comment);
        _replyController.clear();
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _openCompose() async {
    if (!requireAuthenticatedAction(context, ref)) return;
    final created = await Navigator.of(context).push<V2Post>(
      MaterialPageRoute(
        builder: (_) => ComposePostScreen(replyToPostId: widget.postId),
      ),
    );
    if (created != null && mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('post.title'))),
      body: _loading
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
                      child: NotificationListener<ScrollNotification>(
                        onNotification: (n) {
                          if (n.metrics.pixels >=
                              n.metrics.maxScrollExtent - 200) {
                            _loadMore();
                          }
                          return false;
                        },
                        child: ListView.builder(
                          itemCount:
                              2 + // post card + divider
                              (_comments.isEmpty
                                  ? (_hasNext ? 0 : 1)
                                  : _comments.length) +
                              (_hasNext ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index == 0) {
                              return PostCard(
                                post: _post!,
                                onChanged: (p) => setState(() => _post = p),
                                onDeleted: () =>
                                    Navigator.of(context).maybePop(),
                                onReport: () => showReportDialog(
                                  context,
                                  ref,
                                  targetType: 'post',
                                  targetId: _post!.postId,
                                ),
                              );
                            }
                            if (index == 1) {
                              return Divider(
                                height: 1,
                                color: theme.dividerColor,
                              );
                            }

                            if (_comments.isEmpty) {
                              if (!_hasNext) {
                                return Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: EmptyView(
                                    message: l10n.t('post.comments.empty'),
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

                            final contentIndex = index - 2;
                            if (contentIndex < _comments.length) {
                              final c = _comments[contentIndex];
                              return _CommentTile(
                                comment: c,
                                onDelete: c.canDelete
                                    ? () async {
                                        try {
                                          await ref
                                              .read(postsApiProvider)
                                              .deleteComment(c.commentId);
                                          if (!mounted) return;
                                          setState(
                                            () => _comments.removeWhere(
                                              (x) =>
                                                  x.commentId == c.commentId,
                                            ),
                                          );
                                        } catch (e) {
                                          if (!mounted) return;
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                ErrorView.describe(
                                                  context,
                                                  e,
                                                ),
                                              ),
                                            ),
                                          );
                                        }
                                      }
                                    : null,
                              );
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
                    ),
                    Container(
                      decoration: BoxDecoration(
                        color: theme.scaffoldBackgroundColor,
                        border: Border(
                          top: BorderSide(color: theme.dividerColor),
                        ),
                      ),
                      child: SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _replyController,
                                  decoration: InputDecoration(
                                    hintText: l10n.t('common.comment'),
                                    isDense: true,
                                  ),
                                  textInputAction: TextInputAction.send,
                                  onSubmitted: (_) => _submitReply(),
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                onPressed: _submitReply,
                                tooltip: l10n.t('common.post'),
                                icon: Icon(
                                  Icons.send_rounded,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                              IconButton(
                                onPressed: _openCompose,
                                tooltip: l10n.t('post.quote.menu'),
                                icon: const Icon(Icons.reply_outlined),
                              ),
                            ],
                          ),
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

class _CommentTile extends StatelessWidget {
  const _CommentTile({required this.comment, this.onDelete});
  final V2Comment comment;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppAvatar(url: comment.author.avatarUrl, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        comment.author.displayName.isEmpty
                            ? comment.author.username
                            : comment.author.displayName,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
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
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(comment.content, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
          if (onDelete != null)
            IconButton(
              icon: Icon(
                Icons.delete_outline,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              onPressed: onDelete,
            ),
        ],
      ),
    );
  }
}
