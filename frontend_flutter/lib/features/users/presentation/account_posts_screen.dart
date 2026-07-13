import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../../posts/domain/post_models.dart';
import '../../posts/presentation/post_card.dart';
import '../../posts/presentation/report_dialog.dart';
import '../../../core/network/api_response.dart';

enum AccountPostsKind { posts, likes, bookmarks }

class AccountPostsScreen extends ConsumerStatefulWidget {
  const AccountPostsScreen({super.key, required this.kind});

  final AccountPostsKind kind;

  @override
  ConsumerState<AccountPostsScreen> createState() => _AccountPostsScreenState();
}

class _AccountPostsScreenState extends ConsumerState<AccountPostsScreen> {
  List<V2Post> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasNext = false;
  int _page = 1;
  Object? _error;

  String _title(AppLocalizations l10n) {
    switch (widget.kind) {
      case AccountPostsKind.likes:
        return l10n.t('settings.account.liked_posts');
      case AccountPostsKind.bookmarks:
        return l10n.t('settings.account.bookmarks');
      case AccountPostsKind.posts:
        return l10n.t('settings.account.my_posts');
    }
  }

  Future<PagedResult<V2Post>> _fetchPage(int page) {
    final api = ref.read(postsApiProvider);
    return switch (widget.kind) {
      AccountPostsKind.likes => api.getMyLikes(page: page, size: 20),
      AccountPostsKind.bookmarks => api.getMyBookmarks(page: page, size: 20),
      AccountPostsKind.posts => api.getMyPosts(page: page, size: 20),
    };
  }

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
      final page = await _fetchPage(1);
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
      final page = await _fetchPage(next);
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
      appBar: AppBar(title: Text(_title(l10n))),
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
