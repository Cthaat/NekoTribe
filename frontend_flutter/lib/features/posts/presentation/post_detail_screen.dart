import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
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
    });
    try {
      final api = ref.read(postsApiProvider);
      final post = await api.getPost(widget.postId);
      final comments = await api.getComments(widget.postId);
      if (!mounted) return;
      setState(() {
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

  Future<void> _submitReply() async {
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorView.describe(context, e))),
      );
    }
  }

  Future<void> _openCompose() async {
    final created = await Navigator.of(context).push<V2Post>(
      MaterialPageRoute(
        builder: (_) => ComposePostScreen(replyToPostId: widget.postId),
      ),
    );
    if (created != null) _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Post')),
      body: _loading
          ? const LoadingView()
          : _error != null
              ? ErrorView(error: _error!, onRetry: _load)
              : _post == null
                  ? EmptyView(message: l10n.t('feed.empty'))
                  : Column(
                      children: [
                        Expanded(
                          child: ListView(
                            children: [
                              PostCard(
                                post: _post!,
                                onChanged: (p) => setState(() => _post = p),
                                onReport: () => showReportDialog(
                                  context,
                                  ref,
                                  targetType: 'post',
                                  targetId: _post!.postId,
                                ),
                              ),
                              const Divider(height: 1),
                              if (_comments.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.all(24),
                                  child:
                                      EmptyView(message: l10n.t('feed.empty')),
                                )
                              else
                                ..._comments.map(
                                  (c) => ListTile(
                                    title: Text(
                                        c.author.displayName.isEmpty
                                            ? c.author.username
                                            : c.author.displayName),
                                    subtitle: Text(c.content),
                                    trailing: c.canDelete
                                        ? IconButton(
                                            icon: const Icon(Icons.delete_outline),
                                            onPressed: () async {
                                              try {
                                                await ref
                                                    .read(postsApiProvider)
                                                    .deleteComment(c.commentId);
                                                if (!mounted) return;
                                                setState(() => _comments
                                                    .removeWhere((x) =>
                                                        x.commentId ==
                                                        c.commentId));
                                              } catch (_) {}
                                            },
                                          )
                                        : null,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        SafeArea(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _replyController,
                                    decoration: InputDecoration(
                                      hintText: l10n.t('common.comment'),
                                      border: const OutlineInputBorder(),
                                      isDense: true,
                                    ),
                                    onSubmitted: (_) => _submitReply(),
                                  ),
                                ),
                                IconButton(
                                  onPressed: _submitReply,
                                  icon: const Icon(Icons.send),
                                ),
                                IconButton(
                                  onPressed: _openCompose,
                                  icon: const Icon(Icons.reply),
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
