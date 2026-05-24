import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../shared/providers/providers.dart';
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
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(groupsApiProvider);
      final group = await api.getGroup(widget.slug);
      final posts = await api.posts(group.groupId, size: 50);
      final post = posts.items
          .where((item) => item.postId == widget.postId)
          .firstOrNull;
      if (!mounted) return;
      setState(() {
        _group = group;
        _post = post;
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
    try {
      await ref.read(groupsApiProvider).setGroupPostPinStatus(
            groupId: _group!.groupId,
            postId: _post!.postId,
            isPinned: !_post!.isPinned,
          );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorView.describe(context, e))),
      );
    }
  }

  Future<void> _toggleLike() async {
    if (_group == null || _post == null) return;
    try {
      await ref.read(groupsApiProvider).setGroupPostLikeStatus(
            groupId: _group!.groupId,
            postId: _post!.postId,
            liked: !_post!.isLikedByMe,
          );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorView.describe(context, e))),
      );
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
                  : ListView(
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
                                    style:
                                        Theme.of(context).textTheme.titleMedium,
                                  ),
                                  Text(_formatDate(_post!.createdAt)),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: Icon(_post!.isPinned
                                  ? Icons.push_pin
                                  : Icons.push_pin_outlined),
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
                              avatar: Icon(_post!.isLikedByMe
                                  ? Icons.favorite
                                  : Icons.favorite_border),
                              label: Text('${_post!.likesCount} likes'),
                              onPressed: _toggleLike,
                            ),
                            Chip(
                              avatar: const Icon(Icons.comment_outlined),
                              label: Text('${_post!.commentsCount} comments'),
                            ),
                          ],
                        ),
                      ],
                    ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
