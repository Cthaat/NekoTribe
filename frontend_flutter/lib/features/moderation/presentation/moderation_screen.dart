import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/moderation_models.dart';

class ModerationScreen extends ConsumerStatefulWidget {
  const ModerationScreen({super.key});

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
    _tabController = TabController(length: 4, vsync: this);
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
          tabs: const [
            Tab(text: 'Overview'),
            Tab(text: 'Content'),
            Tab(text: 'Reports'),
            Tab(text: 'Appeals'),
          ],
        ),
      ),
      body: TabBarView(
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
          const _AppealsTab(),
        ],
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
    if (loading) return const LoadingView();
    if (error != null) return ErrorView(error: error!, onRetry: onRetry);
    if (stats == null) {
      return const EmptyView(message: 'No stats');
    }
    return RefreshIndicator(
      onRefresh: () async => onRetry(),
      child: GridView.count(
        padding: const EdgeInsets.all(16),
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 2,
        children: [
          _StatCard(label: 'Pending', value: '${stats!.pending}'),
          _StatCard(label: 'Approved', value: '${stats!.approved}'),
          _StatCard(label: 'Rejected', value: '${stats!.rejected}'),
          _StatCard(label: 'Flagged', value: '${stats!.flagged}'),
          _StatCard(label: 'Today processed', value: '${stats!.todayProcessed}'),
          _StatCard(
              label: 'Open reports', value: '${stats!.openReports}'),
          _StatCard(
              label: 'Avg minutes',
              value: stats!.avgProcessMinutes.toStringAsFixed(1)),
          _StatCard(
              label: 'Appeal success',
              value:
                  '${(stats!.appealSuccessRate * 100).toStringAsFixed(1)}%'),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 4),
            Text(label,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).hintColor,
                    )),
          ],
        ),
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
          .resolveContent(caseId: item.caseId, action: action);
      if (!mounted) return;
      setState(
          () => _items.removeWhere((x) => x.caseId == item.caseId));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorView.describe(context, e))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'pending', label: Text('Pending')),
              ButtonSegment(value: 'approved', label: Text('Approved')),
              ButtonSegment(value: 'rejected', label: Text('Rejected')),
            ],
            selected: {_status},
            onSelectionChanged: (s) {
              setState(() => _status = s.first);
              _load();
            },
          ),
        ),
        Expanded(
          child: _loading
              ? const LoadingView()
              : _error != null
                  ? ErrorView(error: _error!, onRetry: _load)
                  : _items.isEmpty
                      ? const EmptyView(message: 'No items')
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.separated(
                            itemCount: _items.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (_, i) {
                              final item = _items[i];
                              return ListTile(
                                leading:
                                    AppAvatar(url: item.author.avatarUrl),
                                title: Text(item.author.displayName),
                                subtitle: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(item.content,
                                        maxLines: 3,
                                        overflow:
                                            TextOverflow.ellipsis),
                                    Text(
                                      'Reports: ${item.reportCount} · ${item.reportReasons.join(', ')}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                                  ],
                                ),
                                trailing: _status == 'pending'
                                    ? Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            icon: const Icon(Icons.check,
                                                color: Colors.green),
                                            onPressed: () =>
                                                _resolve(item, 'approve'),
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.close,
                                                color: Colors.red),
                                            onPressed: () =>
                                                _resolve(item, 'reject'),
                                          ),
                                        ],
                                      )
                                    : null,
                                isThreeLine: true,
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
      final page =
          await ref.read(moderationApiProvider).reports(status: 'open');
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorView.describe(context, e))),
      );
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
    if (_loading) return const LoadingView();
    if (_error != null) return ErrorView(error: _error!, onRetry: _load);
    if (_items.isEmpty) {
      return const EmptyView(message: 'No open reports');
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: _items.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final r = _items[i];
          return ListTile(
            leading: const Icon(Icons.report_outlined),
            title: Text('${r.targetType} #${r.targetId} · ${r.reason}'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.description,
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                Text(_formatDate(r.createdAt),
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.check, color: Colors.green),
                  onPressed: () => _resolve(r, 'resolved'),
                ),
                IconButton(
                  icon: const Icon(Icons.cancel, color: Colors.grey),
                  onPressed: () => _resolve(r, 'dismissed'),
                ),
              ],
            ),
            isThreeLine: true,
          );
        },
      ),
    );
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
    final response = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(status == 'approved' ? 'Approve appeal' : 'Reject appeal'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Optional admin response',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (response == null) return;
    try {
      await ref.read(moderationApiProvider).updateAppeal(
            appealId: a.appealId,
            status: status,
            response: response,
          );
      if (!mounted) return;
      setState(() => _items.removeWhere((x) => x.appealId == a.appealId));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorView.describe(context, e))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const LoadingView();
    if (_error != null) return ErrorView(error: _error!, onRetry: _load);
    if (_items.isEmpty) {
      return const EmptyView(message: 'No pending appeals');
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: _items.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final a = _items[i];
          return ListTile(
            leading: AppAvatar(url: a.user.avatarUrl),
            title: Text('@${a.user.username} · #${a.statementId}'),
            subtitle: Text(a.appealMessage,
                maxLines: 3, overflow: TextOverflow.ellipsis),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.check, color: Colors.green),
                  onPressed: () => _decide(a, 'approved'),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.red),
                  onPressed: () => _decide(a, 'rejected'),
                ),
              ],
            ),
            isThreeLine: true,
          );
        },
      ),
    );
  }
}
