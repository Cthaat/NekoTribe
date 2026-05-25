import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../../posts/domain/post_models.dart';

class AccountDataAnalyticsScreen extends ConsumerStatefulWidget {
  const AccountDataAnalyticsScreen({super.key});

  @override
  ConsumerState<AccountDataAnalyticsScreen> createState() =>
      _AccountDataAnalyticsScreenState();
}

class _AccountDataAnalyticsScreenState
    extends ConsumerState<AccountDataAnalyticsScreen> {
  List<_PostAnalyticsItem> _items = [];
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
      final api = ref.read(postsApiProvider);
      final page = await api.getMyPosts(size: 20);
      final items = await Future.wait(
        page.items.map((post) async {
          try {
            final analytics = await api.getPostAnalytics(post.postId);
            return _PostAnalyticsItem(post: post, analytics: analytics);
          } catch (_) {
            return _PostAnalyticsItem(
              post: post,
              analytics: V2PostAnalytics.fromPost(post),
            );
          }
        }),
      );
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('account.data.title'))),
      body: _loading
          ? const LoadingView()
          : _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : _items.isEmpty
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
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    itemCount: _items.length + 2,
                    separatorBuilder: (_, index) =>
                        index <= 1 ? const SizedBox(height: 14) : const Divider(),
                    itemBuilder: (context, index) {
                      if (index == 0) return const _DataAnalyticsHeader();
                      if (index == 1) {
                        return _DataSummary(items: _items);
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
    final views = items.fold<int>(
      0,
      (sum, item) => sum + item.analytics.viewsCount,
    );
    final interactions = items.fold<int>(
      0,
      (sum, item) =>
          sum +
          item.analytics.likesCount +
          item.analytics.commentsCount +
          item.analytics.repliesCount +
          item.analytics.retweetsCount,
    );
    final likeRate = items.isEmpty
        ? 0.0
        : items.fold<double>(
                0,
                (sum, item) => sum + item.analytics.likeRate,
              ) /
              items.length;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth >= 680
            ? (constraints.maxWidth - 36) / 4
            : (constraints.maxWidth - 12) / 2;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _SummaryCard(
              width: width,
              label: l10n.t('account.data.total_posts'),
              value: '${items.length}',
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
  final V2PostAnalytics analytics;
}

String _formatPercent(double value) => '${(value * 100).toStringAsFixed(1)}%';
