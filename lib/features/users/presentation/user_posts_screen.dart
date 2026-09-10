import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../../posts/domain/post_models.dart';
import '../../posts/presentation/post_card.dart';
import '../../posts/presentation/report_dialog.dart';

class UserPostsScreen extends ConsumerStatefulWidget {
  const UserPostsScreen({super.key, required this.userId});

  final int userId;

  @override
  ConsumerState<UserPostsScreen> createState() => _UserPostsScreenState();
}

class _UserPostsScreenState extends ConsumerState<UserPostsScreen> {
  List<V2Post> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasNext = false;
  int _page = 1;
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
      _page = 1;
      _hasNext = false;
      _loadingMore = false;
    });
    try {
      final page = await ref
          .read(postsApiProvider)
          .getUserPostsById(widget.userId, page: 1, size: 20);
      if (!mounted) return;
      setState(() {
        _items = page.items;
        _page = 1;
        _hasNext = page.hasNext;
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
          .getUserPostsById(widget.userId, page: next, size: 20);
      if (!mounted) return;
      setState(() {
        _items = [..._items, ...page.items];
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('profile.posts'))),
      body: _loading
          ? const LoadingView()
          : _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : _items.isEmpty
          ? EmptyView(message: l10n.t('feed.empty'))
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppBreakpoints.contentMaxWidth,
                ),
                child: RefreshIndicator(
                  onRefresh: _load,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
                        _loadMore();
                      }
                      return false;
                    },
                    child: ListView.builder(
                      itemCount: _items.length + (_hasNext ? 1 : 0),
                      itemBuilder: (context, i) {
                        if (i == _items.length) {
                          return const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(child: CircularProgressIndicator()),
                          );
                        }
                        final post = _items[i];
                        return Column(
                          children: [
                            PostCard(
                              post: post,
                              onChanged: (updated) =>
                                  setState(() => _items[i] = updated),
                              onReport: () => showReportDialog(
                                context,
                                ref,
                                targetType: 'post',
                                targetId: post.postId,
                              ),
                            ),
                            if (i < _items.length - 1 || _hasNext)
                              Divider(height: 1, color: theme.dividerColor),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
