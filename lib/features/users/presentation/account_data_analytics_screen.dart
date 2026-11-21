import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../../posts/domain/post_models.dart';

class AccountDataAnalyticsScreen extends ConsumerStatefulWidget {
  const AccountDataAnalyticsScreen({super.key, this.selectedPost});

  final V2Post? selectedPost;

  @override
  ConsumerState<AccountDataAnalyticsScreen> createState() =>
      _AccountDataAnalyticsScreenState();
}

class _AccountDataAnalyticsScreenState
    extends ConsumerState<AccountDataAnalyticsScreen> {
  List<_PostAnalyticsItem> _items = [];
  bool _loading = true;
  bool _loadingMore = false, _hasNext = false, _expired = false;
  int _page = 0;
  int _request = 0;
  Object? _error;
  late final VoidCallback _stopSessionListener;

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
    super.dispose();
  }

  void _expire() {
    if (!mounted || _expired) return;
    _request++;
    setState(() {
      _expired = true;
      _items = [];
    });
  }

  Future<void> _load({bool append = false}) async {
    if (_expired || (append && (_loading || _loadingMore || !_hasNext))) return;
    final request = ++_request;
    final nextPage = append ? _page + 1 : 1;
    bool current() => mounted && request == _request;
    setState(() {
      _loading = !append;
      _loadingMore = append;
      _error = null;
      if (!append) {
        _items = [];
        _page = 0;
        _hasNext = false;
      }
    });
    try {
      final api = ref.read(postsApiProvider);
      final selected = widget.selectedPost;
      if (selected != null) {
        final analytics = await api.getPostAnalytics(selected.postId);
        if (!current()) return;
        if (analytics.postId != selected.postId) {
          throw const FormatException('Unexpected post analytics');
        }
        setState(() {
          _items = [_PostAnalyticsItem(post: selected, analytics: analytics)];
          _loading = false;
        });
        return;
      }
      final page = await api.getMyPosts(page: nextPage, size: 20);
      if (!current()) return;
      final items = await Future.wait(
        page.items.map((post) async {
          try {
            final analytics = await api.getPostAnalytics(post.postId);
            return _PostAnalyticsItem(
              post: post,
              analytics: analytics.postId == post.postId ? analytics : null,
            );
          } catch (_) {
            return _PostAnalyticsItem(post: post, analytics: null);
          }
        }),
      );
      if (!current()) return;
      setState(() {
        _items = {
          for (final item in _items) item.post.postId: item,
          for (final item in items) item.post.postId: item,
        }.values.toList();
        _page = nextPage;
        _hasNext = page.hasNext;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!current()) return;
      setState(() {
        if (!append) _error = e;
        _loading = false;
        _loadingMore = false;
      });
      if (append) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(postsApiProvider, (previous, next) {
      if (!identical(previous, next)) _expire();
    });
    final l10n = AppLocalizations.of(context);
    final single = widget.selectedPost != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          l10n.t(single ? 'account.posts.post_stats' : 'account.data.title'),
        ),
      ),
      body: _expired
          ? EmptyView(message: l10n.t('visibility.sessionChanged'))
          : _loading
          ? const LoadingView()
          : _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : _items.isEmpty && !_hasNext
          ? EmptyView(message: l10n.t('account.data.empty'))
          : RefreshIndicator(
              onRefresh: _load,
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: AppBreakpoints.contentMaxWidth,
                  ),
                  child: ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    itemCount: single
                        ? 1
                        : _items.length + 2 + (_hasNext ? 1 : 0),
                    separatorBuilder: (_, index) => index <= 1
                        ? const SizedBox(height: 14)
                        : const Divider(),
                    itemBuilder: (context, index) {
                      if (single) {
                        return _PostAnalyticsCard(item: _items.single);
                      }
                      if (index == 0) return const _DataAnalyticsHeader();
                      if (index == 1) {
                        return _DataSummary(items: _items);
                      }
                      if (index == _items.length + 2) {
                        return OutlinedButton(
                          key: const Key('account-data-load-more'),
                          onPressed: _loadingMore
                              ? null
                              : () => _load(append: true),
                          child: Text(
                            l10n.t(
                              _loadingMore ? 'common.loading' : 'common.more',
                            ),
                          ),
                        );
                      }
                      return _PostAnalyticsCard(item: _items[index - 2]);
                    },
                  ),
                ),
              ),
            ),
    );
  }
}

class _DataAnalyticsHeader extends StatelessWidget {
  const _DataAnalyticsHeader();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(16),
        color: theme.cardTheme.color,
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: theme.colorScheme.secondary.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.query_stats_outlined,
                color: theme.colorScheme.secondary,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.t('account.data.title'),
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.t('account.data.description'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DataSummary extends StatelessWidget {
  const _DataSummary({required this.items});

  final List<_PostAnalyticsItem> items;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final confirmed = items
        .map((item) => item.analytics)
        .whereType<V2PostAnalytics>()
        .toList();
    final views = confirmed.fold<int>(
      0,
      (sum, stats) => sum + stats.viewsCount,
    );
    final interactions = confirmed.fold<int>(
      0,
      (sum, stats) =>
          sum +
          stats.likesCount +
          stats.commentsCount +
          stats.repliesCount +
          stats.retweetsCount,
    );
    final coverage = l10n
        .t('account.data.coverage')
        .replaceAll('{confirmed}', '${confirmed.length}')
        .replaceAll('{loaded}', '${items.length}');
    if (confirmed.isEmpty) return Text(coverage);
    final likeRate =
        confirmed.fold<double>(0, (sum, stats) => sum + stats.likeRate) /
        confirmed.length;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth >= 680
            ? (constraints.maxWidth - 36) / 4
            : (constraints.maxWidth - 12) / 2;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(coverage),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _SummaryCard(
                  width: width,
                  label: l10n.t('account.data.total_posts'),
                  value: '${confirmed.length}',
                ),
                _SummaryCard(
                  width: width,
                  label: l10n.t('account.data.total_views'),
                  value: '$views',
                ),
                _SummaryCard(
                  width: width,
                  label: l10n.t('account.data.total_interactions'),
                  value: '$interactions',
                ),
                _SummaryCard(
                  width: width,
                  label: l10n.t('account.data.avg_like_rate'),
                  value: _formatPercent(likeRate),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _PostAnalyticsCard extends StatelessWidget {
  const _PostAnalyticsCard({required this.item});

  final _PostAnalyticsItem item;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final post = item.post;
    final analytics = item.analytics;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(16),
        color: theme.cardTheme.color,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    post.content.isEmpty
                        ? l10n.t('account.data.empty_content')
                        : post.content,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '#${post.postId}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (analytics == null)
              Text(l10n.t('account.data.analytics_unavailable'))
            else
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _MetricPill(
                    icon: Icons.visibility_outlined,
                    label: l10n.t('account.data.views'),
                    value: '${analytics.viewsCount}',
                  ),
                  _MetricPill(
                    icon: Icons.favorite_border,
                    label: l10n.t('account.data.likes'),
                    value: '${analytics.likesCount}',
                  ),
                  _MetricPill(
                    icon: Icons.mode_comment_outlined,
                    label: l10n.t('account.data.comments'),
                    value: '${analytics.commentsCount}',
                  ),
                  _MetricPill(
                    icon: Icons.reply_outlined,
                    label: l10n.t('account.data.replies'),
                    value: '${analytics.repliesCount}',
                  ),
                  _MetricPill(
                    icon: Icons.repeat_rounded,
                    label: l10n.t('account.data.retweets'),
                    value: '${analytics.retweetsCount}',
                  ),
                  _MetricPill(
                    icon: Icons.percent,
                    label: l10n.t('account.data.like_rate'),
                    value: _formatPercent(analytics.likeRate),
                  ),
                  _MetricPill(
                    icon: Icons.trending_up,
                    label: l10n.t('account.data.engagement'),
                    value: analytics.engagementScore.toStringAsFixed(1),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.width,
    required this.label,
    required this.value,
  });

  final double width;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: width,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(14),
          color: theme.cardTheme.color,
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricPill extends StatelessWidget {
  const _MetricPill({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Text(label, style: theme.textTheme.labelMedium),
            const SizedBox(width: 6),
            Text(
              value,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PostAnalyticsItem {
  const _PostAnalyticsItem({required this.post, required this.analytics});

  final V2Post post;
  final V2PostAnalytics? analytics;
}

String _formatPercent(double value) => '${(value * 100).toStringAsFixed(1)}%';
