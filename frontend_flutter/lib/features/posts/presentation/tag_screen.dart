import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/post_models.dart';
import 'post_card.dart';
import 'report_dialog.dart';

class TagScreen extends ConsumerStatefulWidget {
  const TagScreen({super.key, required this.tag});
  final String tag;

  @override
  ConsumerState<TagScreen> createState() => _TagScreenState();
}

class _TagScreenState extends ConsumerState<TagScreen> {
  List<V2Post> _posts = [];
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
      final page = await ref
          .read(postsApiProvider)
          .getPostsByTag(widget.tag, page: 1, size: 30);
      if (!mounted) return;
      setState(() {
        _posts = page.items;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('#${widget.tag}')),
      body: _loading
          ? const LoadingView()
          : _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : _posts.isEmpty
          ? const EmptyView(message: 'No posts')
          : ListView.separated(
              itemCount: _posts.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) => PostCard(
                key: ValueKey(_posts[i].postId),
                post: _posts[i],
                onChanged: (u) => setState(() => _posts[i] = u),
                onReport: () => showReportDialog(
                  context,
                  ref,
                  targetType: 'post',
                  targetId: _posts[i].postId,
                ),
              ),
            ),
    );
  }
}
