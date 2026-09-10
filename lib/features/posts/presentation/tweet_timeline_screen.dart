import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_response.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/post_models.dart';
import 'post_card.dart';
import 'report_dialog.dart';

class TweetTimelineScreen extends ConsumerStatefulWidget {
  const TweetTimelineScreen({
    super.key,
    required this.type,
    required this.userId,
  });

  final String type;
  final int userId;

  @override
  ConsumerState<TweetTimelineScreen> createState() =>
      _TweetTimelineScreenState();
}

class _TweetTimelineScreenState extends ConsumerState<TweetTimelineScreen> {
  List<V2Post> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasNext = false;
  int _page = 1;
  Object? _error;

  static const _pageSize = 20;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant TweetTimelineScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.type != widget.type || oldWidget.userId != widget.userId) {
      _load();
    }
  }

  bool get _supportsPaging => _normalizedType(widget.type) != 'trending';

  Future<PagedResult<V2Post>> _fetchPage(int page) {
    final api = ref.read(postsApiProvider);
    final type = _normalizedType(widget.type);
    return switch (type) {
      'user' => api.getUserPostsById(widget.userId, page: page, size: _pageSize),
      'my_tweets' => api.getMyPosts(page: page, size: _pageSize),
      'bookmark' => api.getMyBookmarks(page: page, size: _pageSize),
      'likes' => api.getMyLikes(page: page, size: _pageSize),
      'mention' => api.getFeed(mode: 'mentions', page: page, size: _pageSize),
      _ => api.getFeed(mode: 'home', page: page, size: _pageSize),
    };
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
      final type = _normalizedType(widget.type);
      if (type == 'trending') {
        final items = await ref.read(postsApiProvider).getTrending(limit: 20);
        if (!mounted) return;
        setState(() {
          _items = items;
          _hasNext = false;
          _loading = false;
        });
        return;
      }

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
    if (!_supportsPaging || _loadingMore || !_hasNext || _loading) return;
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

  String _normalizedType(String value) {
    return switch (value) {
      'my_tweets' ||
      'mention' ||
      'bookmark' ||
      'likes' ||
      'trending' ||
      'user' => value,
      _ => 'home',
    };
  }

  String _title(AppLocalizations l10n) {
    return switch (_normalizedType(widget.type)) {
      'mention' => l10n.t('tweet.timeline.mentions'),
      'bookmark' => l10n.t('tweet.timeline.bookmarks'),
      'likes' => l10n.t('tweet.timeline.likes'),
      'trending' => l10n.t('tweet.timeline.trending'),
      'user' => l10n.t('tweet.timeline.user'),
      'my_tweets' => l10n.t('tweet.timeline.mine'),
      _ => l10n.t('tweet.timeline.home'),
    };
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
                      if (_supportsPaging &&
                          n.metrics.pixels >=
                              n.metrics.maxScrollExtent - 200) {
                        _loadMore();
                      }
                      return false;
                    },
                    child: ListView.separated(
                      itemCount: _items.length + (_hasNext ? 1 : 0),
                      separatorBuilder: (_, _) =>
                          Divider(height: 1, color: theme.dividerColor),
                      itemBuilder: (_, i) {
                        if (i == _items.length) {
                          return const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(child: CircularProgressIndicator()),
                          );
                        }
                        return PostCard(
                          post: _items[i],
                          onChanged: (updated) =>
                              setState(() => _items[i] = updated),
                          onReport: () => showReportDialog(
                            context,
                            ref,
                            targetType: 'post',
                            targetId: _items[i].postId,
                          ),
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
