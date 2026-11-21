import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/network/api_exception.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/responsive.dart';
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
  bool _loadingMore = false;
  bool _hasNext = false;
  int _page = 1;
  Object? _error;
  V2TagAnalytics? _stats;
  bool _statsFailed = false;
  int _postsRequest = 0;
  int _statsRequest = 0;
  late final VoidCallback _stopSessionListener;

  static const _pageSize = 30;

  @override
  void initState() {
    super.initState();
    final tokens = ref.read(tokenStoreProvider);
    _stopSessionListener = tokens.listenSessionChanges(() {
      if (mounted) unawaited(_refresh());
    });
    ref.listenManual(postsApiProvider, (_, _) => unawaited(_refresh()));
    unawaited(_refresh());
  }

  @override
  void didUpdateWidget(covariant TagScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tag != widget.tag) unawaited(_refresh());
  }

  @override
  void dispose() {
    _stopSessionListener();
    super.dispose();
  }

  Future<void> _refresh() async {
    await Future.wait([_load(), _loadStats()]);
  }

  Future<void> _loadStats() async {
    final request = ++_statsRequest;
    setState(() {
      _stats = null;
      _statsFailed = false;
    });
    final tokens = ref.read(tokenStoreProvider);
    if (tokens.isSessionChanging) return;
    bool current() => mounted && request == _statsRequest;
    try {
      final stats = await ref
          .read(postsApiProvider)
          .getTagAnalytics(widget.tag);
      if (current()) setState(() => _stats = stats);
    } catch (error) {
      if (!current() || error is ApiException && error.isNotFound) return;
      setState(() => _statsFailed = true);
    }
  }

  Future<void> _load() async {
    final request = ++_postsRequest;
    setState(() {
      _posts = [];
      _loading = true;
      _error = null;
      _page = 1;
      _hasNext = false;
      _loadingMore = false;
    });
    if (ref.read(tokenStoreProvider).isSessionChanging) return;
    try {
      final page = await ref
          .read(postsApiProvider)
          .getPostsByTag(widget.tag, page: 1, size: _pageSize);
      if (!mounted || request != _postsRequest) return;
      setState(() {
        _posts = page.items;
        _page = 1;
        _hasNext = page.hasNext;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || request != _postsRequest) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasNext || _loading) return;
    final request = _postsRequest;
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final page = await ref
          .read(postsApiProvider)
          .getPostsByTag(widget.tag, page: next, size: _pageSize);
      if (!mounted || request != _postsRequest) return;
      setState(() {
        final ids = _posts.map((post) => post.postId).toSet();
        _posts = [
          ..._posts,
          ...page.items.where((post) => ids.add(post.postId)),
        ];
        _page = next;
        _hasNext = page.hasNext;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || request != _postsRequest) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Widget? _tagStats(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_statsFailed) {
      return TextButton(
        onPressed: _loadStats,
        child: Text(l10n.t('tag.analytics.retry')),
      );
    }
    final stats = _stats;
    if (stats == null) return null;
    final format = NumberFormat.decimalPatternDigits(
      locale: Localizations.localeOf(context).toLanguageTag(),
      decimalDigits: 2,
    );
    final counts = NumberFormat.decimalPattern(
      Localizations.localeOf(context).toLanguageTag(),
    );
    final metrics = {
      'posts': counts.format(stats.totalPosts),
      'authors': counts.format(stats.totalAuthors),
      'views': counts.format(stats.totalViews),
      'likes': counts.format(stats.totalLikes),
      'engagement': format.format(stats.engagementScore),
    };
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.t('tag.analytics.title'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                for (final metric in metrics.entries)
                  Text(
                    '${l10n.t('tag.analytics.${metric.key}')} ${metric.value}',
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.tag, color: theme.colorScheme.primary),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                widget.tag,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          if (_tagStats(context) case final Widget stats)
            ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppBreakpoints.contentMaxWidth,
              ),
              child: stats,
            ),
          Expanded(
            child: _loading
                ? const LoadingView()
                : _error != null
                ? ErrorView(error: _error!, onRetry: _load)
                : _posts.isEmpty
                ? EmptyView(message: l10n.t('feed.empty'))
                : Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: AppBreakpoints.contentMaxWidth,
                      ),
                      child: RefreshIndicator(
                        onRefresh: _refresh,
                        child: NotificationListener<ScrollNotification>(
                          onNotification: (n) {
                            if (n.metrics.pixels >=
                                n.metrics.maxScrollExtent - 200) {
                              _loadMore();
                            }
                            return false;
                          },
                          child: ListView.separated(
                            itemCount: _posts.length + (_hasNext ? 1 : 0),
                            separatorBuilder: (_, _) =>
                                Divider(height: 1, color: theme.dividerColor),
                            itemBuilder: (_, i) {
                              if (i == _posts.length) {
                                return const Padding(
                                  padding: EdgeInsets.all(24),
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                );
                              }
                              final post = _posts[i];
                              final request = _postsRequest;
                              return PostCard(
                                key: ValueKey(post.postId),
                                post: post,
                                onDeleted: () {
                                  if (!mounted || request != _postsRequest) return;
                                  setState(() {
                                    _posts = _posts
                                        .where((item) => item.postId != post.postId)
                                        .toList();
                                  });
                                },
                                onChanged: (updated) {
                                  if (!mounted || request != _postsRequest) {
                                    return;
                                  }
                                  final index = _posts.indexWhere(
                                    (item) => item.postId == post.postId,
                                  );
                                  if (index >= 0) {
                                    setState(() => _posts[index] = updated);
                                  }
                                },
                                onReport: () => showReportDialog(
                                  context,
                                  ref,
                                  targetType: 'post',
                                  targetId: post.postId,
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
