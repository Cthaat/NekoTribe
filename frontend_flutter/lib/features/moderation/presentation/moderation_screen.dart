import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/moderation_models.dart';

String _moderationReasonLabel(AppLocalizations l10n, String reason) {
  final normalized = reason.trim().toLowerCase();
  final key = switch (normalized) {
    'abuse' || 'harassment' => 'report.reason.abuse',
    'adult' || 'sexual' => 'report.reason.sexual',
    'copyright' => 'report.reason.copyright',
    'hate' => 'report.reason.hate',
    'misinformation' => 'report.reason.misinformation',
    'other' => 'report.reason.other',
    'spam' => 'report.reason.spam',
    'violence' => 'report.reason.violence',
    _ => 'report.reason.$normalized',
  };
  final translated = l10n.t(key);
  return translated == key ? reason : translated;
}

class ModerationScreen extends ConsumerStatefulWidget {
  const ModerationScreen({super.key, this.initialTab = 0});
  final int initialTab;

  @override
  ConsumerState<ModerationScreen> createState() => _ModerationScreenState();
}

class _ModerationScreenState extends ConsumerState<ModerationScreen>
    with TickerProviderStateMixin {
  late final TabController _tabController;

  V2ModerationStats? _stats;
  bool _statsLoading = true;
  Object? _statsError;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 6,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 5),
    );
    _loadStats();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadStats() async {
    setState(() {
      _statsLoading = true;
      _statsError = null;
    });
    try {
      final s = await ref.read(moderationApiProvider).stats();
      if (!mounted) return;
      setState(() {
        _stats = s;
        _statsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statsError = e;
        _statsLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('moderation.title')),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(text: l10n.t('moderation.tabs.overview')),
            Tab(text: l10n.t('moderation.tabs.content')),
            Tab(text: l10n.t('moderation.tabs.reports')),
            Tab(text: l10n.t('moderation.tabs.users')),
            Tab(text: l10n.t('moderation.tabs.appeals')),
            Tab(text: l10n.t('moderation.tabs.settings')),
          ],
        ),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppBreakpoints.contentMaxWidth,
          ),
          child: TabBarView(
            controller: _tabController,
            children: [
              _OverviewTab(
                stats: _stats,
                loading: _statsLoading,
                error: _statsError,
                onRetry: _loadStats,
              ),
              const _ContentTab(),
              const _ReportsTab(),
              const _UsersTab(),
              const _AppealsTab(),
              const _SettingsTab(),
            ],
          ),
        ),
      ),
    );
  }
}

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({
    required this.stats,
    required this.loading,
    required this.error,
    required this.onRetry,
  });

  final V2ModerationStats? stats;
  final bool loading;
  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (loading) return const LoadingView();
    if (error != null) return ErrorView(error: error!, onRetry: onRetry);
    if (stats == null) {
      return EmptyView(message: l10n.t('moderation.stats.empty'));
    }
    return RefreshIndicator(
      onRefresh: () async => onRetry(),
      child: GridView.count(
        padding: const EdgeInsets.all(16),
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 1.7,
        children: [
          _StatCard(
            icon: Icons.hourglass_top_outlined,
            label: l10n.t('moderation.stats.pending'),
            value: '${stats!.pending}',
            color: const Color(0xFFE3A857),
          ),
          _StatCard(
            icon: Icons.check_circle_outline,
            label: l10n.t('moderation.stats.approved'),
            value: '${stats!.approved}',
            color: const Color(0xFF34A853),
          ),
          _StatCard(
            icon: Icons.cancel_outlined,
            label: l10n.t('moderation.stats.rejected'),
            value: '${stats!.rejected}',
            color: const Color(0xFFE0245E),
          ),
          _StatCard(
            icon: Icons.flag_outlined,
            label: l10n.t('moderation.stats.flagged'),
            value: '${stats!.flagged}',
            color: const Color(0xFFE94E77),
          ),
          _StatCard(
            icon: Icons.task_alt,
            label: l10n.t('moderation.stats.today_processed'),
            value: '${stats!.todayProcessed}',
          ),
          _StatCard(
            icon: Icons.report_problem_outlined,
            label: l10n.t('moderation.stats.open_reports'),
            value: '${stats!.openReports}',
          ),
          _StatCard(
            icon: Icons.timer_outlined,
            label: l10n.t('moderation.stats.avg_minutes'),
            value: stats!.avgProcessMinutes.toStringAsFixed(1),
          ),
          _StatCard(
            icon: Icons.gavel_outlined,
            label: l10n.t('moderation.stats.appeal_success'),
            value: '${(stats!.appealSuccessRate * 100).toStringAsFixed(1)}%',
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    this.color,
  });
  final IconData icon;
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = color ?? theme.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 16, color: tint),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const Spacer(),
          Text(
            value,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _ContentTab extends ConsumerStatefulWidget {
  const _ContentTab();

  @override
  ConsumerState<_ContentTab> createState() => _ContentTabState();
}

class _ContentTabState extends ConsumerState<_ContentTab>
    with AutomaticKeepAliveClientMixin {
  String _status = 'pending';
  List<V2ModerationContentItem> _items = [];
  bool _loading = true;
  Object? _error;

  @override
  bool get wantKeepAlive => true;

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
          .read(moderationApiProvider)
          .content(status: _status);
      if (!mounted) return;
      setState(() {
        _items = page.items;
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

  Future<void> _resolve(V2ModerationContentItem item, String action) async {
    try {
      await ref
          .read(moderationApiProvider)
          .resolveContent(postId: item.postId, action: action);
      if (!mounted) return;
      setState(() => _items.removeWhere((x) => x.caseId == item.caseId));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: SegmentedButton<String>(
            selected: {_status},
            showSelectedIcon: false,
            onSelectionChanged: (s) {
              setState(() => _status = s.first);
              _load();
            },
            segments: [
              ButtonSegment(
                value: 'pending',
                label: Text(l10n.t('moderation.pending')),
              ),
              ButtonSegment(
                value: 'approved',
                label: Text(l10n.t('moderation.approved')),
              ),
              ButtonSegment(
                value: 'rejected',
                label: Text(l10n.t('moderation.rejected')),
              ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const LoadingView()
              : _error != null
              ? ErrorView(error: _error!, onRetry: _load)
              : _items.isEmpty
              ? EmptyView(message: l10n.t('moderation.content.empty'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    itemCount: _items.length,
                    itemBuilder: (_, i) {
                      final item = _items[i];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: theme.cardTheme.color,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: theme.dividerColor),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  AppAvatar(
                                    url: item.author.avatarUrl,
                                    size: 32,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      item.author.displayName.isEmpty
                                          ? item.author.username
                                          : item.author.displayName,
                                      style: theme.textTheme.titleSmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                item.content,
                                style: theme.textTheme.bodyMedium,
                                maxLines: 4,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.error.withValues(
                                        alpha: 0.1,
                                      ),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      '${l10n.t('moderation.content.reports')} ${item.reportCount}',
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                            color: theme.colorScheme.error,
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                  ),
                                  ...item.reportReasons.map(
                                    (r) => Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: theme
                                            .colorScheme
                                            .onSurfaceVariant
                                            .withValues(alpha: 0.1),
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                      ),
                                      child: Text(
                                        _moderationReasonLabel(l10n, r),
                                        style: theme.textTheme.labelSmall,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (_status == 'pending') ...[
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        key: Key(
                                          'moderation-content-reject-${item.postId}',
                                        ),
                                        onPressed: () =>
                                            _resolve(item, 'reject'),
                                        icon: Icon(
                                          Icons.close,
                                          color: theme.colorScheme.error,
                                          size: 16,
                                        ),
                                        label: Text(
                                          l10n.t('moderation.reject'),
                                          style: TextStyle(
                                            color: theme.colorScheme.error,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: FilledButton.icon(
                                        key: Key(
                                          'moderation-content-approve-${item.postId}',
                                        ),
                                        onPressed: () =>
                                            _resolve(item, 'approve'),
                                        icon: const Icon(Icons.check, size: 16),
                                        label: Text(
                                          l10n.t('moderation.approve'),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

class _ReportsTab extends ConsumerStatefulWidget {
  const _ReportsTab();

  @override
  ConsumerState<_ReportsTab> createState() => _ReportsTabState();
}

class _ReportsTabState extends ConsumerState<_ReportsTab>
    with AutomaticKeepAliveClientMixin {
  List<V2ModerationReport> _items = [];
  bool _loading = true;
  Object? _error;

  @override
  bool get wantKeepAlive => true;

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
          .read(moderationApiProvider)
          .reports(status: 'open');
      if (!mounted) return;
      setState(() {
        _items = page.items;
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

  Future<void> _resolve(V2ModerationReport r, String status) async {
    try {
      await ref
          .read(moderationApiProvider)
          .updateReport(reportId: r.reportId, status: status);
      if (!mounted) return;
      setState(() => _items.removeWhere((x) => x.reportId == r.reportId));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  String _formatDate(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return DateFormat.Md().add_Hm().format(dt.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    if (_loading) return const LoadingView();
    if (_error != null) return ErrorView(error: _error!, onRetry: _load);
    if (_items.isEmpty) {
      return EmptyView(message: l10n.t('moderation.reports.empty'));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _items.length,
        itemBuilder: (_, i) {
          final r = _items[i];
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: theme.cardTheme.color,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: theme.dividerColor),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.error.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          Icons.report_outlined,
                          size: 16,
                          color: theme.colorScheme.error,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '${r.targetType} #${r.targetId}',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.error.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          _moderationReasonLabel(l10n, r.reason),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.error,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    r.description,
                    style: theme.textTheme.bodyMedium,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(
                        Icons.schedule,
                        size: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _formatDate(r.createdAt),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () => _resolve(r, 'dismissed'),
                        icon: const Icon(Icons.close, size: 16),
                        label: Text(l10n.t('moderation.reports.dismiss')),
                      ),
                      const SizedBox(width: 4),
                      FilledButton.icon(
                        onPressed: () => _resolve(r, 'resolved'),
                        icon: const Icon(Icons.check, size: 16),
                        label: Text(l10n.t('moderation.reports.resolve')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _UsersTab extends ConsumerStatefulWidget {
  const _UsersTab();

  @override
  ConsumerState<_UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends ConsumerState<_UsersTab>
    with AutomaticKeepAliveClientMixin {
  String _status = 'all';
  final _keywordController = TextEditingController();
  List<V2ModerationUserItem> _items = [];
  bool _loading = true;
  Object? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _keywordController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await ref
          .read(moderationApiProvider)
          .users(
            status: _status == 'all' ? null : _status,
            keyword: _keywordController.text.trim().isEmpty
                ? null
                : _keywordController.text.trim(),
          );
      if (!mounted) return;
      setState(() {
        _items = page.items;
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

  Future<void> _moderateUser(V2ModerationUserItem user, String action) async {
    final reason = TextEditingController();
    final duration = TextEditingController(text: '24');
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${_actionLabel(l10n, action)} @${user.username}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: reason,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: l10n.t('moderation.users.reason_note'),
                ),
              ),
              if (action == 'ban' || action == 'mute') ...[
                const SizedBox(height: 12),
                TextField(
                  controller: duration,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: l10n.t('moderation.users.duration_hours'),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.t('common.confirm')),
          ),
        ],
      ),
    );
    final reasonText = reason.text.trim();
    final durationHours = int.tryParse(duration.text.trim());
    reason.dispose();
    duration.dispose();
    if (confirmed != true) return;

    try {
      await ref
          .read(moderationApiProvider)
          .restrictUser(
            userId: user.userId,
            action: action,
            reason: action == 'note' || reasonText.isEmpty ? null : reasonText,
            note: reasonText.isEmpty ? null : reasonText,
            durationHours: action == 'ban' || action == 'mute'
                ? durationHours
                : null,
          );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              TextField(
                controller: _keywordController,
                decoration: InputDecoration(
                  hintText: l10n.t('moderation.users.search'),
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                ),
                onSubmitted: (_) => _load(),
              ),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(
                    value: 'all',
                    label: Text(l10n.t('common.all')),
                  ),
                  ButtonSegment(
                    value: 'active',
                    label: Text(l10n.t('moderation.users.active')),
                  ),
                  ButtonSegment(
                    value: 'suspended',
                    label: Text(l10n.t('moderation.users.suspended')),
                  ),
                ],
                selected: {_status},
                onSelectionChanged: (value) {
                  setState(() => _status = value.first);
                  _load();
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const LoadingView()
              : _error != null
              ? ErrorView(error: _error!, onRetry: _load)
              : _items.isEmpty
              ? EmptyView(message: l10n.t('moderation.users.empty'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    itemCount: _items.length,
                    itemBuilder: (_, i) {
                      final user = _items[i];
                      final restriction = user.activeRestriction ?? 'none';
                      final restricted =
                          restriction == 'ban' || restriction == 'mute';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: InkWell(
                          onTap: () => context.push('/users/${user.userId}'),
                          borderRadius: BorderRadius.circular(14),
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: theme.cardTheme.color,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: restricted
                                    ? theme.colorScheme.error.withValues(
                                        alpha: 0.4,
                                      )
                                    : theme.dividerColor,
                              ),
                            ),
                            child: Row(
                              children: [
                                AppAvatar(url: user.avatarUrl, size: 44),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        user.displayName.isEmpty
                                            ? '@${user.username}'
                                            : user.displayName,
                                        style: theme.textTheme.titleSmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                            ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(
                                        '@${user.username} · ${user.status}',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 4),
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 4,
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: theme.colorScheme.error
                                                  .withValues(alpha: 0.1),
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                            ),
                                            child: Text(
                                              '${l10n.t('moderation.users.reports')} ${user.reportCount}',
                                              style: theme.textTheme.labelSmall
                                                  ?.copyWith(
                                                    color:
                                                        theme.colorScheme.error,
                                                  ),
                                            ),
                                          ),
                                          if (restriction != 'none')
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                    vertical: 2,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: theme
                                                    .colorScheme
                                                    .tertiary
                                                    .withValues(alpha: 0.1),
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                              ),
                                              child: Text(
                                                _actionLabel(l10n, restriction),
                                                style: theme
                                                    .textTheme
                                                    .labelSmall
                                                    ?.copyWith(
                                                      color: theme
                                                          .colorScheme
                                                          .tertiary,
                                                    ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                PopupMenuButton<String>(
                                  key: Key(
                                    'moderation-user-actions-${user.userId}',
                                  ),
                                  onSelected: (action) =>
                                      _moderateUser(user, action),
                                  itemBuilder: (_) => [
                                    PopupMenuItem(
                                      value: 'note',
                                      child: Text(
                                        l10n.t('moderation.users.add_note'),
                                      ),
                                    ),
                                    if (user.activeRestriction != 'ban')
                                      PopupMenuItem(
                                        value: 'ban',
                                        child: Text(
                                          l10n.t('moderation.users.ban'),
                                        ),
                                      ),
                                    if (user.activeRestriction == 'ban')
                                      PopupMenuItem(
                                        value: 'unban',
                                        child: Text(
                                          l10n.t('moderation.users.unban'),
                                        ),
                                      ),
                                    if (user.activeRestriction != 'mute')
                                      PopupMenuItem(
                                        value: 'mute',
                                        child: Text(
                                          l10n.t('moderation.users.mute'),
                                        ),
                                      ),
                                    if (user.activeRestriction == 'mute')
                                      PopupMenuItem(
                                        value: 'unmute',
                                        child: Text(
                                          l10n.t('moderation.users.unmute'),
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  String _actionLabel(AppLocalizations l10n, String action) {
    return switch (action) {
      'note' => l10n.t('moderation.users.add_note'),
      'ban' => l10n.t('moderation.users.ban'),
      'unban' => l10n.t('moderation.users.unban'),
      'mute' => l10n.t('moderation.users.mute'),
      'unmute' => l10n.t('moderation.users.unmute'),
      _ => action,
    };
  }
}

class _AppealsTab extends ConsumerStatefulWidget {
  const _AppealsTab();

  @override
  ConsumerState<_AppealsTab> createState() => _AppealsTabState();
}

class _AppealsTabState extends ConsumerState<_AppealsTab>
    with AutomaticKeepAliveClientMixin {
  List<V2ModerationAppeal> _items = [];
  bool _loading = true;
  Object? _error;

  @override
  bool get wantKeepAlive => true;

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
          .read(moderationApiProvider)
          .appeals(status: 'pending');
      if (!mounted) return;
      setState(() {
        _items = page.items;
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

  Future<void> _decide(V2ModerationAppeal a, String status) async {
    final controller = TextEditingController();
    final l10n = AppLocalizations.of(context);
    final response = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          status == 'approved'
              ? l10n.t('moderation.appeals.approve')
              : l10n.t('moderation.appeals.reject'),
        ),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: InputDecoration(
            hintText: l10n.t('moderation.appeals.response_hint'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: Text(l10n.t('common.confirm')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (response == null) return;
    try {
      await ref
          .read(moderationApiProvider)
          .updateAppeal(
            appealId: a.appealId,
            status: status,
            response: response,
          );
      if (!mounted) return;
      setState(() => _items.removeWhere((x) => x.appealId == a.appealId));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    if (_loading) return const LoadingView();
    if (_error != null) return ErrorView(error: _error!, onRetry: _load);
    if (_items.isEmpty) {
      return EmptyView(message: l10n.t('moderation.appeals.empty'));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _items.length,
        itemBuilder: (_, i) {
          final a = _items[i];
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: theme.cardTheme.color,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: theme.dividerColor),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      AppAvatar(url: a.user.avatarUrl, size: 32),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '@${a.user.username}',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '#${a.statementId}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    a.appealMessage,
                    style: theme.textTheme.bodyMedium,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _decide(a, 'rejected'),
                          icon: Icon(
                            Icons.close,
                            color: theme.colorScheme.error,
                            size: 16,
                          ),
                          label: Text(
                            l10n.t('moderation.appeals.reject'),
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => _decide(a, 'approved'),
                          icon: const Icon(Icons.check, size: 16),
                          label: Text(l10n.t('moderation.appeals.approve')),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SettingsTab extends ConsumerStatefulWidget {
  const _SettingsTab();

  @override
  ConsumerState<_SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends ConsumerState<_SettingsTab>
    with AutomaticKeepAliveClientMixin {
  List<V2ModerationSetting> _items = [];
  bool _loading = true;
  bool _saving = false;
  Object? _error;

  @override
  bool get wantKeepAlive => true;

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
      final settings = await ref.read(moderationApiProvider).settings();
      if (!mounted) return;
      setState(() {
        _items = settings;
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

  bool _boolValue(String value) {
    return value == 'true' || value == '1';
  }

  String _settingText(
    AppLocalizations l10n,
    V2ModerationSetting item,
    String field,
  ) {
    final key = 'moderation.settings.definitions.${item.key}.$field';
    final text = l10n.t(key);
    if (text != key) return text;
    if (field == 'label') {
      return item.label.isEmpty ? item.key : item.label;
    }
    return item.description;
  }

  void _setValue(V2ModerationSetting setting, String value) {
    setState(() {
      _items = _items
          .map(
            (item) =>
                item.key == setting.key ? item.copyWith(value: value) : item,
          )
          .toList(growable: false);
    });
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _saving = true);
    try {
      final updated = await ref.read(moderationApiProvider).updateSettings({
        'settings': _items
            .map((item) => {'key': item.key, 'value': item.value})
            .toList(growable: false),
      });
      if (!mounted) return;
      setState(() => _items = updated);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t('moderation.settings.saved'))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    if (_loading) return const LoadingView();
    if (_error != null) return ErrorView(error: _error!, onRetry: _load);
    if (_items.isEmpty) {
      return EmptyView(message: l10n.t('moderation.settings.empty'));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.2),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.settings_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.t('moderation.settings.title'),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        l10n.t('moderation.settings.description'),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          ..._items.map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: theme.cardTheme.color,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: theme.dividerColor),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _settingText(l10n, item, 'label'),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _settingText(l10n, item, 'description'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (item.valueType == 'boolean')
                      SwitchListTile(
                        key: Key('moderation-setting-${item.key}'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          item.key,
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                        value: _boolValue(item.value),
                        onChanged: _saving
                            ? null
                            : (value) =>
                                  _setValue(item, value ? 'true' : 'false'),
                      )
                    else
                      TextFormField(
                        key: Key('moderation-setting-${item.key}'),
                        initialValue: item.value,
                        enabled: !_saving,
                        keyboardType: item.valueType == 'number'
                            ? TextInputType.number
                            : TextInputType.text,
                        decoration: InputDecoration(labelText: item.key),
                        onChanged: (value) => _setValue(item, value.trim()),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('moderation-settings-save'),
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: Text(
                _saving ? l10n.t('common.loading') : l10n.t('common.save'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
