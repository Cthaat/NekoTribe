import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/group_models.dart';

class GroupDetailScreen extends ConsumerStatefulWidget {
  const GroupDetailScreen({super.key, required this.slug});
  final String slug;

  @override
  ConsumerState<GroupDetailScreen> createState() => _GroupDetailScreenState();
}

class _GroupDetailScreenState extends ConsumerState<GroupDetailScreen> {
  V2Group? _group;
  List<V2GroupPost> _posts = [];
  bool _loading = true;
  Object? _error;
  bool _busy = false;

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
      final posts = await api.posts(group.groupId);
      if (!mounted) return;
      setState(() {
        _group = group;
        _posts = posts.items;
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

  Future<void> _toggleMembership() async {
    if (_group == null || _busy) return;
    setState(() => _busy = true);
    try {
      final api = ref.read(groupsApiProvider);
      if (_group!.membership.isMember) {
        await api.leaveGroup(_group!.groupId);
      } else {
        await api.joinGroup(_group!.groupId);
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorView.describe(context, e))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _composePost() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('New post'),
        content: TextField(
          controller: controller,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: 'Share something with the group...',
            border: OutlineInputBorder(),
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
    if (result == null || result.isEmpty) return;
    try {
      await ref.read(groupsApiProvider).createPost(
            groupId: _group!.groupId,
            content: result,
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
      appBar: AppBar(
        title: Text(_group?.name ?? 'Group'),
        actions: [
          if (_group != null && _group!.membership.isMember)
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => context.push('/groups/${widget.slug}/manage'),
            ),
        ],
      ),
      floatingActionButton:
          _group != null && _group!.membership.isMember
              ? FloatingActionButton(
                  onPressed: _composePost,
                  child: const Icon(Icons.edit),
                )
              : null,
      body: _loading
          ? const LoadingView()
          : _error != null
              ? ErrorView(error: _error!, onRetry: _load)
              : _group == null
                  ? const SizedBox.shrink()
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        children: [
                          if (_group!.coverUrl != null)
                            AppMediaImage(
                              url: _group!.coverUrl!,
                              height: 180,
                              borderRadius: BorderRadius.zero,
                            ),
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                AppAvatar(url: _group!.avatarUrl, size: 56),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(_group!.name,
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleLarge),
                                      const SizedBox(height: 4),
                                      Text(
                                          '${_group!.memberCount} members · ${_group!.privacyDesc.isEmpty ? _group!.privacy : _group!.privacyDesc}'),
                                    ],
                                  ),
                                ),
                                FilledButton(
                                  onPressed: _busy ? null : _toggleMembership,
                                  child: Text(_group!.membership.isMember
                                      ? 'Leave'
                                      : 'Join'),
                                ),
                              ],
                            ),
                          ),
                          if (_group!.description.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16),
                              child: Text(_group!.description),
                            ),
                          if (_group!.tags.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.all(16),
                              child: Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: _group!.tags
                                    .map((t) => Chip(label: Text('#$t')))
                                    .toList(),
                              ),
                            ),
                          const Divider(),
                          if (_posts.isEmpty)
                            const Padding(
                              padding: EdgeInsets.all(32),
                              child:
                                  Center(child: Text('No posts in this group')),
                            )
                          else
                            ..._posts.map(
                              (p) => _GroupPostTile(
                                post: p,
                                onTap: () => context.push(
                                  '/groups/${widget.slug}/posts/${p.postId}',
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
    );
  }
}

class _GroupPostTile extends StatelessWidget {
  const _GroupPostTile({required this.post, required this.onTap});
  final V2GroupPost post;
  final VoidCallback onTap;

  String _formatDate(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return DateFormat.MMMd().add_Hm().format(dt.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppAvatar(url: post.author.avatarUrl, size: 36),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(post.author.displayName,
                        style: Theme.of(context).textTheme.titleSmall),
                    Text(_formatDate(post.createdAt),
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              if (post.isPinned)
                const Icon(Icons.push_pin, size: 16),
              if (post.isAnnouncement)
                const Icon(Icons.campaign, size: 16),
            ],
          ),
          const SizedBox(height: 8),
          Text(post.content),
          if (post.mediaUrls.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: post.mediaUrls
                  .map((url) => AppMediaImage(
                        url: url,
                        width: 120,
                        height: 120,
                      ))
                  .toList(),
            ),
          ],
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.favorite_border,
                  size: 16, color: Theme.of(context).hintColor),
              const SizedBox(width: 4),
              Text('${post.likesCount}'),
              const SizedBox(width: 12),
              Icon(Icons.comment_outlined,
                  size: 16, color: Theme.of(context).hintColor),
              const SizedBox(width: 4),
              Text('${post.commentsCount}'),
              const SizedBox(width: 12),
              Icon(Icons.visibility_outlined,
                  size: 16, color: Theme.of(context).hintColor),
              const SizedBox(width: 4),
              Text('${post.viewsCount}'),
            ],
          ),
        ],
        ),
      ),
    );
  }
}
