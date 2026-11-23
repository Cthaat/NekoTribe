import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/api_response.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../../ai/presentation/moderation_advice_dialog.dart';
import '../../auth/data/auth_repository.dart';
import '../data/moderation_api.dart';
import '../domain/moderation_models.dart';
import 'ai_operations_tab.dart';

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
      length: 7,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 6),
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
            Tab(text: l10n.t('moderation.aiOps.title')),
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
              const AiOperationsTab(),
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
  late final AuthRepository _auth;
  late final ModerationApi _api;
  late final int _owner;
  late final void Function() _unsubscribe;
  final _searchController = TextEditingController();
  bool _expired = false;
  int _request = 0;
  String? _keyword;
  String _status = 'pending';
  String _priority = 'all';
  String _reason = 'all';
  String _dateRange = 'all';
  String _sort = 'newest';
  List<V2ModerationContentItem> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasNext = false;
  int _page = 1;
  Object? _error;
  final _selectedPosts = <int>{};
  bool _applying = false;
  int? _reviewerId;
  bool _readingReviewer = false;
  ({String action, String note}) _bulkDraft = (action: 'flag', note: '');

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _auth = ref.read(authRepositoryProvider);
    _api = ref.read(moderationApiProvider);
    _owner = _auth.sessionRevision;
    _expired = _auth.isSessionChanging;
    _unsubscribe = _auth.listenSessionChanges(() {
      if (mounted &&
          (_auth.sessionRevision != _owner || _auth.isSessionChanging)) {
        _expire();
      }
    });
    _load();
  }

  @override
  void dispose() {
    _unsubscribe();
    _searchController.dispose();
    super.dispose();
  }

  bool get _current =>
      mounted &&
      !_expired &&
      identical(ref.read(authRepositoryProvider), _auth) &&
      identical(ref.read(moderationApiProvider), _api) &&
      !_auth.isSessionChanging &&
      _auth.sessionRevision == _owner;

  void _expire() {
    if (_expired) return;
    setState(() {
      _expired = true;
      _items = [];
      _selectedPosts.clear();
      _reviewerId = null;
      _bulkDraft = (action: 'flag', note: '');
      _searchController.clear();
    });
  }

  Future<PagedResult<V2ModerationContentItem>> _readPage(int page) {
    return _api.content(
      status: _status,
      priority: _priority == 'all' ? null : _priority,
      reason: _reason == 'all' ? null : _reason,
      keyword: _keyword,
      dateRange: _dateRange,
      sort: _sort,
      page: page,
    );
  }

  Future<void> _readReviewerIfAssigned() async {
    if (!_current ||
        _reviewerId != null ||
        _readingReviewer ||
        !_items.any((item) => item.assignedTo != null)) {
      return;
    }
    _readingReviewer = true;
    try {
      final reviewer = await ref.read(usersRepositoryProvider).getCurrentUser();
      if (_current && reviewer.userId > 0) {
        setState(() => _reviewerId = reviewer.userId);
      }
    } catch (_) {
      // The queue can still be reviewed. A later refresh can retry the profile.
    } finally {
      _readingReviewer = false;
    }
  }

  Future<void> _load() async {
    if (!_current) return;
    final request = ++_request;
    final keyword = _searchController.text.trim();
    _keyword = keyword.isEmpty ? null : keyword;
    setState(() {
      _loading = true;
      _error = null;
      _selectedPosts.clear();
      _bulkDraft = (action: 'flag', note: '');
      _page = 1;
      _hasNext = false;
    });
    try {
      final page = await _readPage(1);
      if (!_current || request != _request) return;
      setState(() {
        _items = page.items;
        _page = 1;
        _hasNext = page.hasNext;
        _loading = false;
        _loadingMore = false;
      });
      await _readReviewerIfAssigned();
    } catch (e) {
      if (!_current || request != _request) return;
      setState(() {
        _error = e;
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (!_current || _loadingMore || !_hasNext || _loading) return;
    final request = _request;
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final page = await _readPage(next);
      if (!_current || request != _request) return;
      setState(() {
        _items = [..._items, ...page.items];
        _page = next;
        _hasNext = page.hasNext;
        _loadingMore = false;
      });
      await _readReviewerIfAssigned();
    } catch (e) {
      if (!_current || request != _request) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _resolveBulk() async {
    if (!_current || _loading || _applying || _selectedPosts.isEmpty) return;
    final request = _request;
    final ids = _selectedPosts.toList();
    final l10n = AppLocalizations.of(context);
    var (action: action, note: note) = _bulkDraft;
    final decision = await showDialog<({String action, String note})>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) {
          final noteTooLong = utf8.encode(note.trim()).length > 1000;
          return AlertDialog(
            title: Text(l10n.t('moderation.bulk.title')),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('${l10n.t('moderation.bulk.selected')} ${ids.length}'),
                  DropdownButtonFormField<String>(
                    initialValue: action,
                    decoration: InputDecoration(
                      labelText: l10n.t('moderation.bulk.action'),
                    ),
                    items: [
                      for (final item in [
                        'approve',
                        'reject',
                        'flag',
                        'remove',
                        'restore',
                      ])
                        DropdownMenuItem(
                          value: item,
                          child: Text(l10n.t('moderation.bulk.$item')),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) update(() => action = value);
                    },
                  ),
                  TextFormField(
                    initialValue: note,
                    maxLines: 3,
                    decoration: InputDecoration(
                      labelText: l10n.t('moderation.bulk.note'),
                      errorText: noteTooLong
                          ? l10n.t('moderation.bulk.note_too_long')
                          : null,
                    ),
                    onChanged: (value) => update(() => note = value),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(l10n.t('common.cancel')),
              ),
              FilledButton(
                onPressed: noteTooLong
                    ? null
                    : () => Navigator.of(
                        dialogContext,
                      ).pop((action: action, note: note.trim())),
                child: Text(l10n.t('common.confirm')),
              ),
            ],
          );
        },
      ),
    );
    if (decision == null || !_current || request != _request || _applying) {
      return;
    }
    setState(() {
      _applying = true;
      _bulkDraft = decision;
    });
    try {
      final count = await _api.bulkAction(
        postIds: ids,
        action: decision.action,
        note: decision.note.isEmpty ? null : decision.note,
      );
      if (!_current) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${l10n.t('moderation.bulk.processed')} $count'),
        ),
      );
      await _load();
    } catch (e) {
      if (!_current) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      if (_current) setState(() => _applying = false);
    }
  }

  Future<void> _resolve(V2ModerationContentItem item, String action) async {
    if (!_current || _applying || !_items.contains(item)) return;
    final assignment = action == 'claim' || action == 'release';
    if (assignment) {
      if (item.status != 'pending' && item.status != 'flagged') return;
      if (action == 'claim' && item.assignedTo != null) return;
      if (action == 'release' &&
          (_reviewerId == null || item.assignedTo?.userId != _reviewerId)) {
        return;
      }
    }
    String? note;
    if (action == 'reject') {
      final l10n = AppLocalizations.of(context);
      var draft = '';
      note = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.t('moderation.users.reason_note')),
          content: TextField(
            key: const Key('moderation-rejection-note'),
            maxLines: 3,
            onChanged: (value) => draft = value,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.t('common.cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(draft.trim()),
              child: Text(l10n.t('common.confirm')),
            ),
          ],
        ),
      );
      if (note == null || !_current || _applying || !_items.contains(item)) {
        return;
      }
    }
    setState(() => _applying = true);
    try {
      await _api.resolveContent(
        postId: item.postId,
        action: action,
        note: note,
      );
      if (!_current) return;
      if (assignment) {
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.t('moderation.assignment.${action}_done')),
          ),
        );
        await _load();
        return;
      }
      setState(() {
        _items.removeWhere((x) => x.caseId == item.caseId);
        _selectedPosts.remove(item.postId);
      });
    } catch (e) {
      if (!_current) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
      if (assignment && e is ApiException && e.statusCode == 409) await _load();
    } finally {
      if (_current) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    ref.listen(authRepositoryProvider, (_, auth) {
      if (!identical(_auth, auth)) _expire();
    });
    ref.listen(moderationApiProvider, (_, api) {
      if (!identical(_api, api)) _expire();
    });
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    if (_expired) {
      return EmptyView(message: l10n.t('visibility.sessionChanged'));
    }
    Widget select(
      String category,
      String value,
      List<String> options,
      ValueChanged<String> update,
    ) {
      return DropdownButtonFormField<String>(
        key: Key('moderation-content-$category'),
        initialValue: value,
        decoration: InputDecoration(
          labelText: l10n.t('moderation.content.filter.$category'),
        ),
        items: [
          for (final option in options)
            DropdownMenuItem(
              value: option,
              child: Text(
                option == 'all'
                    ? l10n.t('common.all')
                    : category == 'reason'
                    ? _moderationReasonLabel(l10n, option)
                    : l10n.t('moderation.content.option.$option'),
              ),
            ),
        ],
        onChanged: (next) {
          if (!_current || next == null || next == value) return;
          setState(() => update(next));
          _load();
        },
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: select('status', _status, [
            'all',
            'pending',
            'approved',
            'rejected',
            'flagged',
            'removed',
            'restored',
          ], (value) => _status = value),
        ),
        ExpansionTile(
          title: Text(l10n.t('moderation.content.filters')),
          childrenPadding: const EdgeInsets.symmetric(horizontal: 12),
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.30,
              ),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        labelText: l10n.t('moderation.content.search'),
                      ),
                      onSubmitted: (_) => _load(),
                    ),
                    select('priority', _priority, [
                      'all',
                      'low',
                      'normal',
                      'high',
                      'urgent',
                    ], (value) => _priority = value),
                    select('reason', _reason, [
                      'all',
                      'spam',
                      'harassment',
                      'hate',
                      'violence',
                      'adult',
                      'misinformation',
                      'copyright',
                      'other',
                    ], (value) => _reason = value),
                    select('date', _dateRange, [
                      'all',
                      'today',
                      'yesterday',
                      'week',
                      'month',
                    ], (value) => _dateRange = value),
                    select('sort', _sort, [
                      'newest',
                      'oldest',
                      'most_reports',
                      'most_engagement',
                    ], (value) => _sort = value),
                  ],
                ),
              ),
            ),
          ],
        ),
        if (_selectedPosts.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: FilledButton(
              onPressed: _applying || _loading ? null : _resolveBulk,
              child: Text(
                '${l10n.t('moderation.bulk.selected')} ${_selectedPosts.length}',
              ),
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
                    itemCount: _items.length + (_hasNext ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (i >= _items.length) {
                        if (!_loadingMore) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            _loadMore();
                          });
                        }
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Center(
                            child: SizedBox.square(
                              dimension: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        );
                      }
                      final item = _items[i];
                      final assignee = item.assignedTo;
                      final assignable =
                          item.status == 'pending' || item.status == 'flagged';
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
                                  Checkbox(
                                    key: Key(
                                      'moderation-select-${item.postId}',
                                    ),
                                    semanticLabel:
                                        '${l10n.t('moderation.bulk.select_post')} ${item.postId}',
                                    value: _selectedPosts.contains(item.postId),
                                    onChanged:
                                        _applying ||
                                            (_selectedPosts.length >= 100 &&
                                                !_selectedPosts.contains(
                                                  item.postId,
                                                ))
                                        ? null
                                        : (selected) {
                                            if (!_current) return;
                                            setState(() {
                                              if (selected == true) {
                                                _selectedPosts.add(item.postId);
                                              } else {
                                                _selectedPosts.remove(
                                                  item.postId,
                                                );
                                              }
                                            });
                                          },
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 8,
                                children: [
                                  Text(
                                    assignee == null
                                        ? l10n.t(
                                            'moderation.assignment.unassigned',
                                          )
                                        : '${l10n.t('moderation.assignment.owner')} ${assignee.displayName.isEmpty ? assignee.username : assignee.displayName}',
                                  ),
                                  if (assignable &&
                                      (assignee == null ||
                                          assignee.userId == _reviewerId))
                                    OutlinedButton(
                                      key: Key(
                                        'moderation-assignment-${item.postId}',
                                      ),
                                      onPressed: _applying
                                          ? null
                                          : () => _resolve(
                                              item,
                                              assignee == null
                                                  ? 'claim'
                                                  : 'release',
                                            ),
                                      child: Text(
                                        l10n.t(
                                          assignee == null
                                              ? 'moderation.assignment.claim'
                                              : 'moderation.assignment.release',
                                        ),
                                      ),
                                    ),
                                ],
                              ),
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
                                  if (item.sentimentSignal case final signal?)
                                    DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: theme
                                            .colorScheme
                                            .surfaceContainerHighest,
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 3,
                                        ),
                                        child: Text(
                                          l10n
                                              .t('moderation.content.sentiment')
                                              .replaceAll(
                                                '{label}',
                                                l10n.t(
                                                  'moderation.content.sentiment.${signal.label.name}',
                                                ),
                                              )
                                              .replaceAll(
                                                '{confidence}',
                                                NumberFormat.percentPattern(
                                                  l10n.locale.languageCode,
                                                ).format(signal.confidence),
                                              ),
                                          style: theme.textTheme.labelSmall,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: ModerationAdviceButton(
                                  kind: 'post',
                                  targetId: item.postId,
                                ),
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
  String _status = 'pending';
  List<V2ModerationReport> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasNext = false;
  int _page = 1;
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
      _page = 1;
      _hasNext = false;
    });
    try {
      final page = await ref
          .read(moderationApiProvider)
          .reports(status: _status, page: 1);
      if (!mounted) return;
      setState(() {
        _items = page.items;
        _page = 1;
        _hasNext = page.hasNext;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasNext || _loading) return;
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final page = await ref
          .read(moderationApiProvider)
          .reports(status: _status, page: next);
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
    final emptyMessage = _status == 'resolved'
        ? l10n.t('moderation.reports.empty_resolved')
        : l10n.t('moderation.reports.empty');
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
                label: Text(l10n.t('moderation.reports.filter.open')),
              ),
              ButtonSegment(
                value: 'resolved',
                label: Text(l10n.t('moderation.reports.filter.resolved')),
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
              ? EmptyView(message: emptyMessage)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    itemCount: _items.length + (_hasNext ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (i >= _items.length) {
                        if (!_loadingMore) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            _loadMore();
                          });
                        }
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Center(
                            child: SizedBox.square(
                              dimension: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        );
                      }
                      final r = _items[i];
                      final isResolved = _status == 'resolved';
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
                                      color: theme.colorScheme.error.withValues(
                                        alpha: 0.1,
                                      ),
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
                                      style: theme.textTheme.titleSmall
                                          ?.copyWith(
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
                                      color: theme.colorScheme.error.withValues(
                                        alpha: 0.1,
                                      ),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      _moderationReasonLabel(l10n, r.reason),
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
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
                                ],
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                alignment: WrapAlignment.end,
                                children: [
                                  ModerationAdviceButton(
                                    kind: r.targetType,
                                    targetId: r.targetId,
                                  ),
                                  if (isResolved)
                                    OutlinedButton.icon(
                                      key: Key(
                                        'moderation-report-reopen-${r.reportId}',
                                      ),
                                      onPressed: () => _resolve(r, 'pending'),
                                      icon: const Icon(Icons.replay, size: 16),
                                      label: Text(
                                        l10n.t('moderation.reports.reopen'),
                                      ),
                                    )
                                  else ...[
                                    TextButton.icon(
                                      onPressed: () => _resolve(r, 'dismissed'),
                                      icon: const Icon(Icons.close, size: 16),
                                      label: Text(
                                        l10n.t('moderation.reports.dismiss'),
                                      ),
                                    ),
                                    FilledButton.icon(
                                      onPressed: () => _resolve(r, 'resolved'),
                                      icon: const Icon(Icons.check, size: 16),
                                      label: Text(
                                        l10n.t('moderation.reports.resolve'),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
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

class _UsersTab extends ConsumerStatefulWidget {
  const _UsersTab();

  @override
  ConsumerState<_UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends ConsumerState<_UsersTab>
    with AutomaticKeepAliveClientMixin {
  late final AuthRepository _auth;
  late final ModerationApi _api;
  late final int _revision;
  late final void Function() _unsubscribe;
  bool _expired = false;
  int _request = 0;
  String? _search;
  String _status = 'all';
  String _sort = 'newest';
  final _keywordController = TextEditingController();
  List<V2ModerationUserItem> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasNext = false;
  int _page = 1;
  Object? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _auth = ref.read(authRepositoryProvider);
    _api = ref.read(moderationApiProvider);
    _revision = _auth.sessionRevision;
    _expired = _auth.isSessionChanging;
    _unsubscribe = _auth.listenSessionChanges(() {
      if (mounted &&
          (_auth.sessionRevision != _revision || _auth.isSessionChanging)) {
        _expire();
      }
    });
    _load();
  }

  @override
  void dispose() {
    _unsubscribe();
    _keywordController.dispose();
    super.dispose();
  }

  bool get _current =>
      mounted &&
      !_expired &&
      identical(ref.read(authRepositoryProvider), _auth) &&
      identical(ref.read(moderationApiProvider), _api) &&
      !_auth.isSessionChanging &&
      _auth.sessionRevision == _revision;

  void _expire() {
    if (_expired) return;
    setState(() {
      _expired = true;
      _items = [];
      _keywordController.clear();
    });
  }

  Future<void> _load() async {
    if (!_current) return;
    final request = ++_request;
    final search = _keywordController.text.trim();
    _search = search.isEmpty ? null : search;
    setState(() {
      _loading = true;
      _error = null;
      _page = 1;
      _hasNext = false;
    });
    try {
      final page = await _api.users(
        status: _status == 'all' ? null : _status,
        sort: _sort,
        keyword: _search,
      );
      if (!_current || request != _request) return;
      setState(() {
        _items = page.items;
        _page = 1;
        _hasNext = page.hasNext;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!_current || request != _request) return;
      setState(() {
        _error = e;
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (!_current || _loadingMore || !_hasNext || _loading) return;
    final request = _request;
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final page = await _api.users(
        status: _status == 'all' ? null : _status,
        sort: _sort,
        keyword: _search,
        page: next,
      );
      if (!_current || request != _request) return;
      setState(() {
        _items = [..._items, ...page.items];
        _page = next;
        _hasNext = page.hasNext;
        _loadingMore = false;
      });
    } catch (e) {
      if (!_current || request != _request) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _moderateUser(V2ModerationUserItem user, String action) async {
    if (!_current) return;
    final reason = TextEditingController();
    final duration = TextEditingController();
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
                    hintText: l10n.t('moderation.users.duration_default'),
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
    final rawDuration = duration.text.trim();
    final durationHours = RegExp(r'^[0-9]+$').hasMatch(rawDuration)
        ? int.tryParse(rawDuration)
        : null;
    reason.dispose();
    duration.dispose();
    if (confirmed != true || !_current) return;
    if ((action == 'ban' || action == 'mute') &&
        rawDuration.isNotEmpty &&
        (durationHours == null || durationHours < (action == 'mute' ? 1 : 0))) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t('moderation.users.duration_invalid'))),
      );
      return;
    }

    try {
      await _api.restrictUser(
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
      if (!_current) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    ref.listen(authRepositoryProvider, (_, auth) {
      if (!identical(_auth, auth)) _expire();
    });
    ref.listen(moderationApiProvider, (_, api) {
      if (!identical(_api, api)) _expire();
    });
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    if (_expired) {
      return EmptyView(message: l10n.t('visibility.sessionChanged'));
    }
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
              Wrap(
                spacing: 12,
                children: [
                  DropdownButton<String>(
                    key: const Key('moderation-users-status'),
                    value: _status,
                    items: [
                      DropdownMenuItem(
                        value: 'all',
                        child: Text(l10n.t('common.all')),
                      ),
                      for (final status in [
                        'active',
                        'suspended',
                        'disabled',
                        'pending',
                      ])
                        DropdownMenuItem(
                          value: status,
                          child: Text(l10n.t('moderation.users.$status')),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null || value == _status) return;
                      setState(() => _status = value);
                      _load();
                    },
                  ),
                  DropdownButton<String>(
                    key: const Key('moderation-users-sort'),
                    value: _sort,
                    items: [
                      for (final sort in ['newest', 'oldest', 'reports'])
                        DropdownMenuItem(
                          value: sort,
                          child: Text(l10n.t('moderation.users.sort.$sort')),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null || value == _sort) return;
                      setState(() => _sort = value);
                      _load();
                    },
                  ),
                ],
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
                    itemCount: _items.length + (_hasNext ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (i >= _items.length) {
                        if (!_loadingMore) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            _loadMore();
                          });
                        }
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Center(
                            child: SizedBox.square(
                              dimension: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        );
                      }
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
  static const _statuses = ['all', 'pending', 'approved', 'rejected'];
  late final AuthRepository _auth;
  late final ModerationApi _api;
  late final int _revision;
  late final VoidCallback _unsubscribe;
  List<V2ModerationAppeal> _items = [];
  String _status = 'pending';
  bool _loading = false;
  bool _hasNext = false;
  bool _expired = false;
  bool _deciding = false;
  int _page = 1;
  Object? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _auth = ref.read(authRepositoryProvider);
    _api = ref.read(moderationApiProvider);
    _revision = _auth.sessionRevision;
    _expired = _auth.isSessionChanging;
    _unsubscribe = _auth.listenSessionChanges(() {
      if (mounted &&
          (_auth.sessionRevision != _revision || _auth.isSessionChanging)) {
        _expire();
      }
    });
    _load();
  }

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }

  void _expire() {
    if (_expired) return;
    setState(() {
      _expired = true;
      _items = [];
      _error = null;
    });
  }

  bool get _current =>
      mounted &&
      !_expired &&
      identical(ref.read(authRepositoryProvider), _auth) &&
      identical(ref.read(moderationApiProvider), _api) &&
      !_auth.isSessionChanging &&
      _auth.sessionRevision == _revision;

  Future<void> _load({bool more = false}) async {
    if (!_current || _loading || (more && !_hasNext)) return;
    setState(() {
      _loading = true;
      _error = null;
      if (!more) _items = [];
    });
    final next = more ? _page + 1 : 1;
    try {
      final page = await _api.appeals(status: _status, page: next);
      if (!_current) return;
      setState(() {
        _items = more ? [..._items, ...page.items] : page.items;
        _page = next;
        _hasNext = page.hasNext;
      });
    } catch (e) {
      if (!_current) return;
      if (more) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
      } else {
        setState(() => _error = e);
      }
    } finally {
      if (_current) setState(() => _loading = false);
    }
  }

  Future<void> _decide(V2ModerationAppeal appeal, String status) async {
    if (!_current ||
        _deciding ||
        _loading ||
        appeal.appealStatus != 'pending' ||
        !_items.contains(appeal)) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    setState(() => _deciding = true);
    var reply = '';
    try {
      final result = await showDialog<String>(
        context: context,
        builder: (dialog) => StatefulBuilder(
          builder: (_, updateDialog) {
            final tooLong = utf8.encode(reply).length > 2000;
            return AlertDialog(
              title: Text(
                l10n.t(
                  status == 'approved'
                      ? 'moderation.appeals.approve'
                      : 'moderation.appeals.reject',
                ),
              ),
              content: TextField(
                onChanged: (value) => updateDialog(() => reply = value.trim()),
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: l10n.t('moderation.appeals.response_hint'),
                  errorText: tooLong
                      ? l10n.t('moderation.appeals.reply_too_long')
                      : null,
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialog),
                  child: Text(l10n.t('common.cancel')),
                ),
                FilledButton(
                  onPressed: tooLong
                      ? null
                      : () => Navigator.pop(dialog, reply),
                  child: Text(l10n.t('common.confirm')),
                ),
              ],
            );
          },
        ),
      );
      if (!_current || result == null) return;
      await _api.updateAppeal(
        appealId: appeal.appealId,
        status: status,
        response: result,
      );
      if (_current) await _load();
    } catch (e) {
      if (!_current) return;
      final handled =
          e is ApiException && (e.statusCode == 409 || e.code == 40901);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            handled
                ? l10n.t('moderation.appeals.handled')
                : ErrorView.describe(context, e),
          ),
        ),
      );
      if (handled) await _load();
    } finally {
      if (_current) setState(() => _deciding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    ref.listen(authRepositoryProvider, (_, auth) {
      if (!identical(_auth, auth)) _expire();
    });
    ref.listen(moderationApiProvider, (_, api) {
      if (!identical(_api, api)) _expire();
    });
    final l10n = AppLocalizations.of(context);
    if (_expired) {
      return EmptyView(message: l10n.t('visibility.sessionChanged'));
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: DropdownButton<String>(
              value: _status,
              items: [
                for (final status in _statuses)
                  DropdownMenuItem(
                    value: status,
                    child: Text(l10n.t('moderation.appeals.status.$status')),
                  ),
              ],
              onChanged: _loading || _deciding
                  ? null
                  : (status) {
                      if (!_current || status == null || status == _status) {
                        return;
                      }
                      setState(() => _status = status);
                      _load();
                    },
            ),
          ),
        ),
        Expanded(child: _results(l10n)),
      ],
    );
  }

  Widget _results(AppLocalizations l10n) {
    if (_loading && _items.isEmpty) return const LoadingView();
    if (_error != null) return ErrorView(error: _error!, onRetry: _load);
    if (_items.isEmpty) {
      return EmptyView(message: l10n.t('moderation.appeals.empty'));
    }
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: _deciding ? () async {} : _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final appeal in _items)
            Card(
              key: ValueKey(appeal.appealId),
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        AppAvatar(url: appeal.user.avatarUrl, size: 32),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '@${appeal.user.username} · #${appeal.statementId}',
                            style: theme.textTheme.titleSmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.t(
                        'moderation.appeals.status.${appeal.appealStatus}',
                      ),
                      style: theme.textTheme.labelMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(appeal.appealMessage),
                    if (appeal.adminResponse.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          appeal.adminResponse,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    if (appeal.appealStatus == 'pending')
                      Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton(
                            onPressed: _deciding || _loading
                                ? null
                                : () => _decide(appeal, 'rejected'),
                            child: Text(l10n.t('moderation.appeals.reject')),
                          ),
                          FilledButton(
                            onPressed: _deciding || _loading
                                ? null
                                : () => _decide(appeal, 'approved'),
                            child: Text(l10n.t('moderation.appeals.approve')),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          if (_hasNext)
            Center(
              child: OutlinedButton(
                onPressed: _loading || _deciding
                    ? null
                    : () => _load(more: true),
                child: Text(
                  l10n.t(
                    _loading
                        ? 'common.loading'
                        : 'moderation.appeals.load_more',
                  ),
                ),
              ),
            ),
        ],
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
  late final AuthRepository _auth;
  late final ModerationApi _api;
  late final int _revision;
  late final void Function() _unsubscribe;
  List<V2ModerationSetting> _items = [];
  Map<String, String> _previous = {};
  int _fieldVersion = 0;
  bool _loading = true;
  bool _saving = false;
  bool _expired = false;
  Object? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _auth = ref.read(authRepositoryProvider);
    _api = ref.read(moderationApiProvider);
    _revision = _auth.sessionRevision;
    _expired = _auth.isSessionChanging;
    _unsubscribe = _auth.listenSessionChanges(() {
      if (mounted &&
          (_auth.sessionRevision != _revision || _auth.isSessionChanging)) {
        _expire();
      }
    });
    _load();
  }

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }

  bool get _current =>
      mounted &&
      !_expired &&
      identical(ref.read(authRepositoryProvider), _auth) &&
      identical(ref.read(moderationApiProvider), _api) &&
      !_auth.isSessionChanging &&
      _auth.sessionRevision == _revision;

  void _expire() {
    if (_expired) return;
    setState(() {
      _expired = true;
      _items = [];
      _previous = {};
    });
  }

  void _replace(List<V2ModerationSetting> settings) {
    _items = settings;
    _previous = {for (final item in settings) item.key: item.value};
    _fieldVersion++;
  }

  Future<void> _load() async {
    if (!_current || _saving) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final settings = await _api.settings();
      if (!_current) return;
      setState(() {
        _replace(settings);
        _loading = false;
      });
    } catch (e) {
      if (!_current) return;
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
    if (!_current || _loading || _saving) return;
    final changes = _items
        .where((item) => _previous[item.key] != item.value)
        .map((item) => {'key': item.key, 'value': item.value})
        .toList(growable: false);
    if (changes.isEmpty) return;
    final l10n = AppLocalizations.of(context);
    setState(() => _saving = true);
    try {
      final updated = await _api.updateSettings({'settings': changes});
      if (!_current) return;
      setState(() => _replace(updated));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t('moderation.settings.saved'))),
      );
    } catch (e) {
      if (!_current) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      if (_current) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    ref.listen(authRepositoryProvider, (_, auth) {
      if (!identical(_auth, auth)) _expire();
    });
    ref.listen(moderationApiProvider, (_, api) {
      if (!identical(_api, api)) _expire();
    });
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    if (_expired) {
      return EmptyView(message: l10n.t('visibility.sessionChanged'));
    }
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
              key: ValueKey((item.key, _fieldVersion)),
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
