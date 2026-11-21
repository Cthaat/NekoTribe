import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../../posts/domain/post_models.dart';
import '../../posts/presentation/post_card.dart';
import '../../posts/presentation/report_dialog.dart';
import '../../../core/network/api_response.dart';
import 'account_data_analytics_screen.dart';

enum AccountPostsKind { posts, likes, bookmarks }

enum _PostSort { newest, oldest, popular }

enum _PostVisibilityFilter { all, public, followers, mentioned, private }

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
  int _request = 0;
  bool _expired = false;
  _PostSort _sort = _PostSort.newest;
  _PostVisibilityFilter _visibility = _PostVisibilityFilter.all;
  final _search = TextEditingController();
  String _query = '';
  late final VoidCallback _stopSessionListener;
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
      AccountPostsKind.likes => api.getMyLikes(
        page: page,
        size: 20,
        sort: _sort.name,
      ),
      AccountPostsKind.bookmarks => api.getMyBookmarks(page: page, size: 20),
      AccountPostsKind.posts => api.getMyPosts(
        page: page,
        size: 20,
        sort: _sort.name,
        query: _query,
      ),
    };
  }

  @override
  void initState() {
    super.initState();
    final session = ref.read(tokenStoreProvider);
    _expired = session.isSessionChanging;
    _stopSessionListener = session.listenSessionChanges(_expire);
    _load();
  }

  @override
  void dispose() {
    _stopSessionListener();
    _search.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant AccountPostsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.kind != widget.kind) {
      _sort = _PostSort.newest;
      _visibility = _PostVisibilityFilter.all;
      _query = '';
      _search.clear();
      _load();
    }
  }

  void _expire() {
    if (!mounted || _expired) return;
    _request++;
    setState(() {
      _expired = true;
      _items = [];
    });
  }

  void _applySearch(String text) {
    if (_expired || widget.kind != AccountPostsKind.posts) return;
    final next = text.trim();
    if (_query == next) return;
    _query = next;
    _load();
  }

  Future<void> _publish() async {
    if (_expired) return;
    final post = await context.push<V2Post>('/meow');
    if (!mounted || _expired || widget.kind != AccountPostsKind.posts) return;
    if (post != null && post.postId > 0) await _load();
  }

  void _openStats(V2Post post) {
    if (_expired || !post.viewerState.canDelete) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AccountDataAnalyticsScreen(selectedPost: post),
      ),
    );
  }

  Future<void> _load() async {
    if (_expired) return;
    final request = ++_request;
    setState(() {
      _items = [];
      _loading = true;
      _error = null;
      _page = 1;
      _hasNext = false;
      _loadingMore = false;
    });
    try {
      final page = await _fetchPage(1);
      if (!mounted || request != _request) return;
      setState(() {
        _items = page.items;
        _page = 1;
        _hasNext = page.hasNext;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_expired || _loadingMore || !_hasNext || _loading) return;
    final request = _request;
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final page = await _fetchPage(next);
      if (!mounted || request != _request) return;
      setState(() {
        _items = {
          for (final item in [..._items, ...page.items]) item.postId: item,
        }.values.toList();
        _page = next;
        _hasNext = page.hasNext;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(postsApiProvider, (before, after) {
      if (!identical(before, after)) _expire();
    });
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final request = _request;
    final visible = _visibility == _PostVisibilityFilter.all
        ? _items
        : _items.where((post) => post.visibility == _visibility.name).toList();
    final emptyMessage = l10n.t(
      _visibility == _PostVisibilityFilter.all
          ? 'feed.empty'
          : 'account.posts.visibility_empty',
    );
    final hasEmptyRow = visible.isEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(_title(l10n)),
        bottom: !_expired && widget.kind == AccountPostsKind.posts
            ? PreferredSize(
                preferredSize: const Size.fromHeight(62),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    controller: _search,
                    textInputAction: TextInputAction.search,
                    onSubmitted: _applySearch,
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: l10n.t('account.posts.search'),
                      prefixIcon: IconButton(
                        tooltip: l10n.t('account.posts.search'),
                        icon: const Icon(Icons.search),
                        onPressed: () => _applySearch(_search.text),
                      ),
                      suffixIcon: IconButton(
                        tooltip: l10n.t('account.posts.clear_search'),
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _search.clear();
                          _applySearch('');
                        },
                      ),
                    ),
                  ),
                ),
              )
            : null,
        actions: [
          if (!_expired && widget.kind == AccountPostsKind.posts)
            IconButton(
              tooltip: l10n.t('account.posts.publish'),
              icon: const Icon(Icons.add),
              onPressed: _publish,
            ),
          if (!_expired && widget.kind == AccountPostsKind.posts)
            PopupMenuButton<_PostVisibilityFilter>(
              tooltip: l10n.t('account.posts.visibility_filter'),
              icon: Badge(
                isLabelVisible: _visibility != _PostVisibilityFilter.all,
                child: const Icon(Icons.filter_list),
              ),
              onSelected: (filter) {
                if (!_expired && widget.kind == AccountPostsKind.posts) {
                  setState(() => _visibility = filter);
                }
              },
              itemBuilder: (_) => [
                for (final filter in _PostVisibilityFilter.values)
                  CheckedPopupMenuItem(
                    value: filter,
                    checked: _visibility == filter,
                    child: Text(
                      l10n.t(switch (filter) {
                        _PostVisibilityFilter.all =>
                          'account.posts.visibility_all',
                        _PostVisibilityFilter.public => 'common.public',
                        _PostVisibilityFilter.followers =>
                          'common.followers_only',
                        _PostVisibilityFilter.mentioned =>
                          'common.mentioned_only',
                        _PostVisibilityFilter.private => 'common.private',
                      }),
                    ),
                  ),
              ],
            ),
          if (!_expired && widget.kind != AccountPostsKind.bookmarks)
            PopupMenuButton<_PostSort>(
              tooltip: l10n.t(
                widget.kind == AccountPostsKind.likes
                    ? 'account.likes.sort'
                    : 'account.posts.sort',
              ),
              icon: const Icon(Icons.sort),
              onSelected: (sort) {
                if (_expired || sort == _sort) return;
                _sort = sort;
                _load();
              },
              itemBuilder: (_) => [
                for (final sort in _PostSort.values)
                  CheckedPopupMenuItem(
                    value: sort,
                    checked: _sort == sort,
                    child: Text(
                      l10n.t(
                        widget.kind == AccountPostsKind.likes
                            ? 'account.likes.sort.${sort.name}'
                            : 'account.posts.sort.${sort.name}',
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
      body: _expired
          ? EmptyView(message: l10n.t('visibility.sessionChanged'))
          : _loading
          ? const LoadingView()
          : _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppBreakpoints.contentMaxWidth,
                ),
                child: RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount:
                        visible.length +
                        (hasEmptyRow ? 1 : 0) +
                        (_hasNext ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (hasEmptyRow && i == 0) {
                        return Padding(
                          padding: const EdgeInsets.all(24),
                          child: Center(child: Text(emptyMessage)),
                        );
                      }
                      if (i >= visible.length) {
                        return Padding(
                          padding: const EdgeInsets.all(16),
                          child: Center(
                            child: _loadingMore
                                ? const CircularProgressIndicator()
                                : OutlinedButton(
                                    onPressed: _loadMore,
                                    child: Text(l10n.t('account.posts.more')),
                                  ),
                          ),
                        );
                      }
                      final post = visible[i];
                      return Column(
                        key: ValueKey(post.postId),
                        children: [
                          PostCard(
                            post: post,
                            onEdited: (_) {
                              if (mounted && request == _request) _load();
                            },
                            onDeleted: () {
                              if (mounted && request == _request) _load();
                            },
                            onBookmarkChanged: (saved) {
                              if (mounted &&
                                  request == _request &&
                                  !saved &&
                                  widget.kind == AccountPostsKind.bookmarks) {
                                _load();
                              }
                            },
                            onChanged: (updated) {
                              if (!mounted || request != _request) return;
                              if (widget.kind == AccountPostsKind.likes &&
                                  !updated.viewerState.isLiked) {
                                _load();
                                return;
                              }
                              final index = _items.indexWhere(
                                (item) => item.postId == updated.postId,
                              );
                              if (index >= 0) {
                                setState(() => _items[index] = updated);
                              }
                            },
                            onReport: () => showReportDialog(
                              context,
                              ref,
                              targetType: 'post',
                              targetId: post.postId,
                            ),
                          ),
                          if (widget.kind == AccountPostsKind.posts &&
                              post.viewerState.canDelete)
                            Align(
                              alignment: AlignmentDirectional.centerEnd,
                              child: TextButton.icon(
                                onPressed: () => _openStats(post),
                                icon: const Icon(Icons.query_stats),
                                label: Text(l10n.t('account.posts.post_stats')),
                              ),
                            ),
                          if (i < visible.length - 1 || _hasNext)
                            Divider(height: 1, color: theme.dividerColor),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
    );
  }
}
