import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/routing/auth_navigation.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/group_models.dart';

class GroupPostDetailScreen extends ConsumerStatefulWidget {
  const GroupPostDetailScreen({
    super.key,
    required this.slug,
    required this.postId,
  });

  final String slug;
  final int postId;

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
  bool _commentsHasNext = false;
  int _commentsPage = 1;
  Object? _error;
  final _commentController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _commentsPage = 1;
      _commentsHasNext = false;
    });
    try {
      final api = ref.read(groupsApiProvider);
      final group = await api.getGroup(widget.slug);
      final post = await api.getPost(
        groupId: group.groupId,
        postId: widget.postId,
      );
      final comments = await api.comments(
        groupId: group.groupId,
        postId: widget.postId,
        page: 1,
      );
      if (!mounted) return;
      setState(() {
        _group = group;
        _post = post;
        _comments = comments.items;
        _commentsPage = 1;
        _commentsHasNext = comments.hasNext;
        _loading = false;
        _loadingMoreComments = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
        _loadingMoreComments = false;
      });
    }
  }

  Future<void> _loadMoreComments() async {
    final group = _group;
    if (group == null ||
        _loadingMoreComments ||
        !_commentsHasNext ||
        _loading) {
      return;
    }
    setState(() => _loadingMoreComments = true);
    try {
      final next = _commentsPage + 1;
      final page = await ref
          .read(groupsApiProvider)
          .comments(
            groupId: group.groupId,
            postId: widget.postId,
            page: next,
          );
      if (!mounted) return;
      setState(() {
        _comments = [..._comments, ...page.items];
        _commentsPage = next;
        _commentsHasNext = page.hasNext;
        _loadingMoreComments = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMoreComments = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  String _formatDate(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return DateFormat.yMMMd().add_Hm().format(dt.toLocal());
  }

  Future<void> _togglePin() async {
    if (_group == null || _post == null) return;
    if (!requireAuthenticatedAction(context, ref)) return;
    try {
      await ref
          .read(groupsApiProvider)
          .setGroupPostPinStatus(
            groupId: _group!.groupId,
            postId: _post!.postId,
            isPinned: !_post!.isPinned,
          );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _toggleLike() async {
    if (_group == null || _post == null) return;
    if (!requireAuthenticatedAction(context, ref)) return;
    try {
      await ref
          .read(groupsApiProvider)
          .setGroupPostLikeStatus(
            groupId: _group!.groupId,
            postId: _post!.postId,
            liked: !_post!.isLikedByMe,
          );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _submitComment() async {
    if (_group == null || _post == null) return;
    if (!requireAuthenticatedAction(context, ref)) return;
    final text = _commentController.text.trim();
    if (text.isEmpty) return;
    try {
      final comment = await ref
          .read(groupsApiProvider)
          .createComment(
            groupId: _group!.groupId,
            postId: _post!.postId,
            content: text,
          );
      if (!mounted) return;
      setState(() {
        _comments.insert(0, comment);
        _commentController.clear();
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _deleteComment(V2GroupComment comment) async {
    if (_group == null || _post == null) return;
    if (!requireAuthenticatedAction(context, ref)) return;
    try {
      await ref
          .read(groupsApiProvider)
          .deleteComment(
            groupId: _group!.groupId,
            postId: _post!.postId,
            commentId: comment.commentId,
          );
      if (!mounted) return;
      setState(
        () => _comments.removeWhere(
          (item) => item.commentId == comment.commentId,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _toggleCommentLike(V2GroupComment comment) async {
    if (_group == null || _post == null) return;
    if (!requireAuthenticatedAction(context, ref)) return;
    try {
      await ref
          .read(groupsApiProvider)
          .setCommentLikeStatus(
            groupId: _group!.groupId,
            postId: _post!.postId,
            commentId: comment.commentId,
            liked: !comment.isLikedByMe,
          );
      await _load();
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
      ),
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
                                    crossAxisAlignment: CrossAxisAlignment.start,
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
                                  onPressed: _togglePin,
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            Text(
                              _post!.content,
                              style: theme.textTheme.bodyLarge,
                            ),
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                _StatButton(
                                  icon: _post!.isLikedByMe
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  label: '${_post!.likesCount}',
                                  active: _post!.isLikedByMe,
                                  activeColor: const Color(0xFFE0245E),
                                  onTap: _toggleLike,
                                ),
                                const SizedBox(width: 20),
                                _StatButton(
                                  icon: Icons.mode_comment_outlined,
                                  label: '${_post!.commentsCount}',
                                  onTap: () {},
                                ),
                                const SizedBox(width: 20),
                                _StatButton(
                                  icon: Icons.visibility_outlined,
                                  label: '${_post!.viewsCount}',
                                  onTap: () {},
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
                            if (_comments.isEmpty)
                              Padding(
                                padding: const EdgeInsets.all(24),
                                child: EmptyView(
                                  message: l10n.t('feed.empty'),
                                ),
                              )
                            else ...[
                              for (final comment in _comments)
                                _CommentTile(
                                  comment: comment,
                                  onLike: () => _toggleCommentLike(comment),
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
                                          : _loadMoreComments,
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
                          ],
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
                                  controller: _commentController,
                                  decoration: InputDecoration(
                                    hintText: l10n.t('common.comment'),
                                    isDense: true,
                                  ),
                                  onSubmitted: (_) => _submitComment(),
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                onPressed: _submitComment,
                                icon: Icon(
                                  Icons.send_rounded,
                                  color: theme.colorScheme.primary,
                                ),
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

class _StatButton extends StatelessWidget {
  const _StatButton({
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
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
      ),
    );
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({
    required this.comment,
    required this.onLike,
    this.onDelete,
  });
  final V2GroupComment comment;
  final VoidCallback onLike;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
