import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../shared/providers/providers.dart';
import '../../../shared/routing/auth_navigation.dart';
import '../../../shared/widgets/app_avatar.dart';
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
      );
      if (!mounted) return;
      setState(() {
        _group = group;
        _post = post;
        _comments = comments.items;
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
    return Scaffold(
      appBar: AppBar(title: Text(_group?.name ?? 'Group post')),
      body: _loading
          ? const LoadingView()
          : _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : _post == null
          ? const EmptyView(message: 'Post not found')
          : Column(
              children: [
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        Row(
                          children: [
                            AppAvatar(url: _post!.author.avatarUrl, size: 44),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _post!.author.displayName,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                  Text(_formatDate(_post!.createdAt)),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: Icon(
                                _post!.isPinned
                                    ? Icons.push_pin
                                    : Icons.push_pin_outlined,
                              ),
                              onPressed: _togglePin,
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Text(_post!.content),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 8,
                          children: [
                            ActionChip(
                              avatar: Icon(
                                _post!.isLikedByMe
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                              ),
                              label: Text('${_post!.likesCount} likes'),
                              onPressed: _toggleLike,
                            ),
                            Chip(
                              avatar: const Icon(Icons.comment_outlined),
                              label: Text('${_post!.commentsCount} comments'),
                            ),
                          ],
                        ),
                        const Divider(height: 32),
                        if (_comments.isEmpty)
                          const EmptyView(message: 'No comments')
                        else
                          for (final comment in _comments)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: AppAvatar(
                                url: comment.author.avatarUrl,
                                size: 36,
                              ),
                              title: Text(comment.author.displayName),
                              subtitle: Text(comment.content),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: Icon(
                                      comment.isLikedByMe
                                          ? Icons.favorite
                                          : Icons.favorite_border,
                                    ),
                                    onPressed: () =>
                                        _toggleCommentLike(comment),
                                  ),
                                  Text('${comment.likesCount}'),
                                  if (comment.canDeleteByMe)
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline),
                                      onPressed: () => _deleteComment(comment),
                                    ),
                                ],
                              ),
                            ),
                      ],
                    ),
                  ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _commentController,
                            decoration: const InputDecoration(
                              hintText: 'Write a comment',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            onSubmitted: (_) => _submitComment(),
                          ),
                        ),
                        IconButton(
                          onPressed: _submitComment,
                          icon: const Icon(Icons.send),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
