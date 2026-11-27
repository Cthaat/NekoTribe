import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/safe_back_button.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/user_models.dart';

class AccountAnalyticsScreen extends ConsumerStatefulWidget {
  const AccountAnalyticsScreen({super.key});

  @override
  ConsumerState<AccountAnalyticsScreen> createState() =>
      _AccountAnalyticsScreenState();
}

class _AccountAnalyticsScreenState
    extends ConsumerState<AccountAnalyticsScreen> {
  V2SelfUser? _user;
  V2UserAnalytics? _analytics;
  List<V2UserDailyAnalytics> _daily = [];
  int _days = 14;
  bool _loading = true;
  bool _dailyLoading = true, _dailyFailed = false, _expired = false;
  int _overviewRequest = 0, _dailyRequest = 0;
  late final VoidCallback _stopSessionListener;
  Object? _error;

  @override
  void initState() {
    super.initState();
    final store = ref.read(tokenStoreProvider);
    _expired = store.isSessionChanging;
    _stopSessionListener = store.listenSessionChanges(_expire);
    _load();
  }

  @override
  void dispose() {
    _stopSessionListener();
    super.dispose();
  }

  void _expire() {
    if (!mounted || _expired) return;
    _overviewRequest++;
    _dailyRequest++;
    setState(() {
      _expired = true;
      _user = null;
      _analytics = null;
      _daily = [];
    });
  }

  Future<void> _load() async {
    if (_expired) return;
    final request = ++_overviewRequest;
    _dailyRequest++;
    bool current() => mounted && request == _overviewRequest;
    setState(() {
      _loading = true;
      _error = null;
      _daily = [];
      _dailyLoading = true;
      _dailyFailed = false;
    });
    try {
      final repo = ref.read(usersRepositoryProvider);
      final user = await repo.getCurrentUser();
      if (!current()) return;
      final analytics = await repo.getUserAnalytics(user.userId);
      if (!current()) return;
      setState(() {
        _user = user;
        _analytics = analytics;
        _loading = false;
      });
      await _loadDaily(_days);
    } catch (e) {
      if (!current()) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _loadDaily(int days) async {
    final user = _user;
    if (user == null || _expired) return;
    final request = ++_dailyRequest;
    bool current() => mounted && request == _dailyRequest;
    setState(() {
      _days = days;
      _daily = [];
      _dailyLoading = true;
      _dailyFailed = false;
    });
    try {
      final rows = await ref
          .read(usersRepositoryProvider)
          .getUserDailyAnalytics(user.userId, days: days);
      if (current()) setState(() => _daily = rows);
    } catch (_) {
      if (current()) setState(() => _dailyFailed = true);
    } finally {
      if (current()) setState(() => _dailyLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(usersRepositoryProvider, (previous, next) {
      if (!identical(previous, next)) _expire();
    });
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: const SafeBackButton(fallbackRoute: '/me'),
        title: Text(l10n.t('account.analytics.title')),
      ),
      body: _expired
          ? EmptyView(message: l10n.t('visibility.sessionChanged'))
          : _loading
          ? const LoadingView()
          : _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : _analytics == null
          ? EmptyView(message: l10n.t('account.analytics.empty'))
          : RefreshIndicator(
              onRefresh: _load,
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: AppBreakpoints.contentMaxWidth,
                  ),
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    children: [
                      _AnalyticsHeader(user: _user),
                      const SizedBox(height: 14),
                      _MetricGrid(analytics: _analytics!),
                      const SizedBox(height: 18),
                      _DailyAnalyticsSection(
                        daily: _daily,
                        days: _days,
                        loading: _dailyLoading,
                        failed: _dailyFailed,
                        onRangeChanged: _loadDaily,
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

class _AnalyticsHeader extends StatelessWidget {
  const _AnalyticsHeader({required this.user});

  final V2SelfUser? user;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final name = user == null
        ? 'NekoTribe'
        : (user!.displayName.isEmpty ? user!.username : user!.displayName);
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
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.insights_outlined,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.t('account.analytics.title'),
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${l10n.t('account.analytics.description')} $name',
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

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.analytics});

  final V2UserAnalytics analytics;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 680;
        final width = isWide
            ? (constraints.maxWidth - 24) / 3
            : (constraints.maxWidth - 12) / 2;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _MetricCard(
              width: width,
              icon: Icons.article_outlined,
              label: l10n.t('account.analytics.total_posts'),
              value: '${analytics.totalPosts}',
            ),
            _MetricCard(
              width: width,
              icon: Icons.calendar_view_week_outlined,
              label: l10n.t('account.analytics.posts_this_week'),
              value: '${analytics.postsThisWeek}',
            ),
            _MetricCard(
              width: width,
              icon: Icons.favorite_border,
              label: l10n.t('account.analytics.likes_received'),
              value: '${analytics.totalLikesReceived}',
            ),
            _MetricCard(
              width: width,
              icon: Icons.favorite,
              label: l10n.t('account.analytics.likes_given'),
              value: '${analytics.totalLikesGiven}',
            ),
            _MetricCard(
              width: width,
              icon: Icons.mode_comment_outlined,
              label: l10n.t('account.analytics.comments_made'),
              value: '${analytics.totalCommentsMade}',
            ),
            _MetricCard(
              width: width,
              icon: Icons.trending_up,
              label: l10n.t('account.analytics.engagement_score'),
              value: _formatDecimal(analytics.engagementScore),
            ),
          ],
        );
      },
    );
  }
}

class _DailyAnalyticsSection extends StatelessWidget {
  const _DailyAnalyticsSection({
    required this.daily,
    required this.days,
    required this.loading,
    required this.failed,
    required this.onRangeChanged,
  });

  final List<V2UserDailyAnalytics> daily;
  final int days;
  final bool loading;
  final bool failed;
  final ValueChanged<int> onRangeChanged;

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
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.t('account.analytics.daily_title'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.t('account.analytics.daily_description'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Row(
              children: [
                Text(l10n.t('account.analytics.daily_range')),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButton<int>(
                    key: const Key('account-analytics-range'),
                    isExpanded: true,
                    value: days,
                    items: [
                      for (final period in [7, 14, 30, 90])
                        DropdownMenuItem(
                          value: period,
                          child: Text(
                            l10n
                                .t('account.analytics.range_days')
                                .replaceAll('{days}', '$period'),
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null && value != days) onRangeChanged(value);
                    },
                  ),
                ),
              ],
            ),
            if (loading)
              const LinearProgressIndicator()
            else if (failed)
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(l10n.t('account.analytics.daily_failed')),
                  TextButton(
                    onPressed: () => onRangeChanged(days),
                    child: Text(l10n.t('common.retry')),
                  ),
                ],
              )
            else if (daily.isEmpty)
              EmptyView(message: l10n.t('account.analytics.daily_empty'))
            else
              for (final item in daily) ...[
                _DailyAnalyticsRow(item: item),
                if (item != daily.last) const Divider(height: 22),
              ],
          ],
        ),
      ),
    );
  }
}

class _DailyAnalyticsRow extends StatelessWidget {
  const _DailyAnalyticsRow({required this.item});

  final V2UserDailyAnalytics item;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final maxValue = [
      item.postsCount,
      item.receivedInteractions,
      item.outgoingInteractions,
    ].fold<int>(1, (max, value) => value > max ? value : max);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                item.day,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              '${l10n.t('account.analytics.engagement_score')} ${_formatDecimal(item.engagementScore)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _MiniBar(
          label: l10n.t('account.analytics.daily_posts'),
          value: item.postsCount,
          maxValue: maxValue,
        ),
        _MiniBar(
          label: l10n.t('account.analytics.daily_received'),
          value: item.receivedInteractions,
          maxValue: maxValue,
        ),
        _MiniBar(
          label: l10n.t('account.analytics.daily_outgoing'),
          value: item.outgoingInteractions,
          maxValue: maxValue,
        ),
      ],
    );
  }
}

class _MiniBar extends StatelessWidget {
  const _MiniBar({
    required this.label,
    required this.value,
    required this.maxValue,
  });

  final String label;
  final int value;
  final int maxValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = maxValue <= 0 ? 0.0 : value / maxValue;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        children: [
          SizedBox(width: 72, child: Text(label)),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: progress.clamp(0, 1),
                minHeight: 8,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 36,
            child: Text(
              '$value',
              textAlign: TextAlign.right,
              style: theme.textTheme.labelMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.width,
    required this.icon,
    required this.label,
    required this.value,
  });

  final double width;
  final IconData icon;
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
              Icon(icon, color: theme.colorScheme.primary),
              const SizedBox(height: 12),
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

String _formatDecimal(double value) => value.toStringAsFixed(1);
