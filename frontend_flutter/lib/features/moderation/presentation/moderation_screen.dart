import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/moderation_models.dart';

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
          const _UsersTab(),
          const _AppealsTab(),
          const _SettingsTab(),
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
        childAspectRatio: 2,
        children: [
          _StatCard(
            label: l10n.t('moderation.stats.pending'),
            value: '${stats!.pending}',
          ),
          _StatCard(
            label: l10n.t('moderation.stats.approved'),
            value: '${stats!.approved}',
          ),
          _StatCard(
            label: l10n.t('moderation.stats.rejected'),
            value: '${stats!.rejected}',
          ),
          _StatCard(
            label: l10n.t('moderation.stats.flagged'),
            value: '${stats!.flagged}',
          ),
          _StatCard(
            label: l10n.t('moderation.stats.today_processed'),
            value: '${stats!.todayProcessed}',
          ),
          _StatCard(
            label: l10n.t('moderation.stats.open_reports'),
            value: '${stats!.openReports}',
          ),
          _StatCard(
            label: l10n.t('moderation.stats.avg_minutes'),
            value: stats!.avgProcessMinutes.toStringAsFixed(1),
          ),
          _StatCard(
            label: l10n.t('moderation.stats.appeal_success'),
            value: '${(stats!.appealSuccessRate * 100).toStringAsFixed(1)}%',
          ),
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
            Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).hintColor,
              ),
            ),
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
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
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
                  child: ListView.separated(
                    itemCount: _items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final item = _items[i];
                      return ListTile(
                        leading: AppAvatar(url: item.author.avatarUrl),
                        title: Text(item.author.displayName),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.content,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              'Reports: ${item.reportCount} · ${item.reportReasons.join(', ')}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                        trailing: _status == 'pending'
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(
                                      Icons.check,
                                      color: Colors.green,
                                    ),
                                    onPressed: () => _resolve(item, 'approve'),
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.close,
                                      color: Colors.red,
                                    ),
                                    onPressed: () => _resolve(item, 'reject'),
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
    if (_loading) return const LoadingView();
    if (_error != null) return ErrorView(error: _error!, onRetry: _load);
    if (_items.isEmpty) {
      return EmptyView(message: l10n.t('moderation.reports.empty'));
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
                Text(
                  r.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _formatDate(r.createdAt),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
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
      builder: (_) => AlertDialog(
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
                  border: const OutlineInputBorder(),
                ),
              ),
              if (action == 'ban' || action == 'mute') ...[
                const SizedBox(height: 12),
                TextField(
                  controller: duration,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: l10n.t('moderation.users.duration_hours'),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
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
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 260,
                child: TextField(
                  controller: _keywordController,
                  decoration: InputDecoration(
                    labelText: l10n.t('moderation.users.search'),
                    prefixIcon: const Icon(Icons.search),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _load(),
                ),
              ),
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
                  child: ListView.separated(
                    itemCount: _items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final user = _items[i];
                      final restriction = user.activeRestriction ?? 'none';
                      return ListTile(
                        leading: AppAvatar(url: user.avatarUrl, size: 44),
                        title: Text(
                          user.displayName.isEmpty
                              ? '@${user.username}'
                              : user.displayName,
                        ),
                        subtitle: Text(
                          '@${user.username} · ${user.status} · ${l10n.t('moderation.users.reports')} ${user.reportCount} · ${l10n.t('moderation.users.restriction')} $restriction',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => context.push('/users/${user.userId}'),
                        trailing: PopupMenuButton<String>(
                          onSelected: (action) => _moderateUser(user, action),
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: 'note',
                              child: Text(l10n.t('moderation.users.add_note')),
                            ),
                            if (user.activeRestriction != 'ban')
                              PopupMenuItem(
                                value: 'ban',
                                child: Text(l10n.t('moderation.users.ban')),
                              ),
                            if (user.activeRestriction == 'ban')
                              PopupMenuItem(
                                value: 'unban',
                                child: Text(l10n.t('moderation.users.unban')),
                              ),
                            if (user.activeRestriction != 'mute')
                              PopupMenuItem(
                                value: 'mute',
                                child: Text(l10n.t('moderation.users.mute')),
                              ),
                            if (user.activeRestriction == 'mute')
                              PopupMenuItem(
                                value: 'unmute',
                                child: Text(l10n.t('moderation.users.unmute')),
                              ),
                          ],
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
      builder: (_) => AlertDialog(
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
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(l10n.t('common.confirm')),
          ),
        ],
      ),
    );
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
    if (_loading) return const LoadingView();
    if (_error != null) return ErrorView(error: _error!, onRetry: _load);
    if (_items.isEmpty) {
      return EmptyView(message: l10n.t('moderation.appeals.empty'));
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
            subtitle: Text(
              a.appealMessage,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
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
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.settings_outlined),
            title: Text(l10n.t('moderation.settings.title')),
            subtitle: Text(l10n.t('moderation.settings.description')),
            trailing: FilledButton.icon(
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
          const SizedBox(height: 12),
          ..._items.map(
            (item) => Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _settingText(l10n, item, 'label'),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _settingText(l10n, item, 'description'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    if (item.valueType == 'boolean')
                      SwitchListTile(
                        key: Key('moderation-setting-${item.key}'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(item.key),
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
                        decoration: InputDecoration(
                          labelText: item.key,
                          border: const OutlineInputBorder(),
                        ),
                        onChanged: (value) => _setValue(item, value.trim()),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            key: const Key('moderation-settings-save-bottom'),
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
        ],
      ),
    );
  }
}
