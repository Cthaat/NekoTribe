import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  Object? _error;

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

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(postsApiProvider);
      final type = _normalizedType(widget.type);
      final List<V2Post> items;
      if (type == 'trending') {
        items = await api.getTrending(limit: 20);
      } else {
        final page = switch (type) {
          'user' => await api.getUserPostsById(widget.userId),
          'my_tweets' => await api.getMyPosts(),
          'bookmark' => await api.getMyBookmarks(),
          'likes' => await api.getMyLikes(),
          'mention' => await api.getFeed(mode: 'mentions'),
          _ => await api.getFeed(mode: 'home'),
        };
        items = page.items;
      }
      if (!mounted) return;
      setState(() {
        _items = items;
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
                  child: ListView.separated(
                    itemCount: _items.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: theme.dividerColor),
                    itemBuilder: (_, i) => PostCard(
                      post: _items[i],
                      onChanged: (updated) =>
                          setState(() => _items[i] = updated),
                      onReport: () => showReportDialog(
                        context,
                        ref,
                        targetType: 'post',
                        targetId: _items[i].postId,
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
