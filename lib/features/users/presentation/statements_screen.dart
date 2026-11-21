import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/network/api_response.dart';
import '../../../core/network/api_exception.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../../auth/data/auth_repository.dart';
import '../data/users_repository.dart';
import '../domain/user_models.dart';

class StatementsScreen extends ConsumerStatefulWidget {
  const StatementsScreen({super.key});

  @override
  ConsumerState<StatementsScreen> createState() => _StatementsScreenState();
}

class _StatementsScreenState extends ConsumerState<StatementsScreen> {
  static const _statuses = [
    'all',
    'unread',
    'read',
    'resolved',
    'dismissed',
    'appealed',
  ];
  static const _types = ['all', 'info', 'warning', 'strike', 'suspension'];
  late final AuthRepository _owner;
  late final UsersRepository _repository;
  late final int _revision;
  late final VoidCallback _unsubscribe;
  List<V2AccountStatement> _items = [];
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasNext = false;
  bool _expired = false;
  bool _mutating = false;
  int _page = 1;
  String _status = 'all';
  String _type = 'all';
  Object? _error;

  @override
  void initState() {
    super.initState();
    _owner = ref.read(authRepositoryProvider);
    _repository = ref.read(usersRepositoryProvider);
    _revision = _owner.sessionRevision;
    _expired = _owner.isSessionChanging;
    _unsubscribe = _owner.listenSessionChanges(() {
      if (mounted &&
          (_owner.sessionRevision != _revision || _owner.isSessionChanging)) {
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
      identical(ref.read(authRepositoryProvider), _owner) &&
      identical(ref.read(usersRepositoryProvider), _repository) &&
      !_owner.isSessionChanging &&
      _owner.sessionRevision == _revision;
  bool get _busy => _loading || _loadingMore || _mutating;

  Future<PagedResult<V2AccountStatement>> _fetch(int page) =>
      _repository.statements(
        page: page,
        status: _status == 'all' ? null : _status,
        type: _type == 'all' ? null : _type,
      );

  Future<void> _load() async {
    if (!_current || _loading || _loadingMore) return;
    setState(() {
      _loading = true;
      _error = null;
      _page = 1;
      _hasNext = false;
    });
    try {
      final page = await _fetch(1);
      if (!_current) return;
      setState(() {
        _items = page.items;
        _page = 1;
        _hasNext = page.hasNext;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!_current) return;
      setState(() {
        _error = e;
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (!_current || _busy || !_hasNext) return;
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final page = await _fetch(next);
      if (!_current) return;
      setState(() {
        _items = [..._items, ...page.items];
        _page = next;
        _hasNext = page.hasNext;
        _loadingMore = false;
      });
    } catch (e) {
      if (!_current) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _appeal(V2AccountStatement statement) async {
    if (!_current || _busy || !_items.contains(statement)) return;
    setState(() => _mutating = true);
    final l10n = AppLocalizations.of(context);
    var message = '';
    try {
      final result = await showDialog<String>(
        context: context,
        builder: (dialog) => StatefulBuilder(
          builder: (_, updateDialog) => AlertDialog(
            title: Text(l10n.t('account.statements.submit_appeal')),
            content: TextField(
              onChanged: (value) => updateDialog(() => message = value.trim()),
              maxLines: 4,
              decoration: InputDecoration(
                hintText: l10n.t('account.statements.appeal_hint'),
                errorText: utf8.encode(message).length > 2000
                    ? l10n.t('account.statements.appeal_too_long')
                    : null,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: Text(l10n.t('common.cancel')),
              ),
              FilledButton(
                onPressed: message.isEmpty || utf8.encode(message).length > 2000
                    ? null
                    : () => Navigator.pop(dialog, message),
                child: Text(l10n.t('common.submit')),
              ),
            ],
          ),
        ),
      );
      if (!_current || result == null || result.isEmpty) return;
      await _repository.submitStatementAppeal(statement.statementId, result);
      if (!_current) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t('account.statements.appeal_submitted'))),
      );
      await _load();
    } catch (e) {
      if (!_current) return;
      final pending =
          e is ApiException && (e.statusCode == 409 || e.code == 40901);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            pending
                ? l10n.t('account.statements.appeal_pending')
                : ErrorView.describe(context, e),
          ),
        ),
      );
    } finally {
      if (_current) setState(() => _mutating = false);
    }
  }

  Future<void> _changeStatus(
    V2AccountStatement statement,
    String action,
  ) async {
    if (!_current || _busy || !_items.contains(statement)) return;
    setState(() => _mutating = true);
    try {
      await _repository.changeStatementStatus(statement.statementId, action);
      if (_current) await _load();
    } catch (error) {
      if (_current) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorView.describe(context, error))),
        );
      }
    } finally {
      if (_current) setState(() => _mutating = false);
    }
  }

  String _formatDate(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return DateFormat.yMd().add_Hm().format(dt.toLocal());
  }

  Color _statusColor(BuildContext ctx, String status) {
    final cs = Theme.of(ctx).colorScheme;
    switch (status) {
      case 'unread':
        return cs.error;
      case 'resolved':
        return cs.tertiary;
      case 'dismissed':
        return cs.outline;
      default:
        return cs.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(authRepositoryProvider, (_, repo) {
      if (!identical(repo, _owner)) _expire();
    });
    ref.listen(usersRepositoryProvider, (_, repo) {
      if (!identical(repo, _repository)) _expire();
    });
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('account.statements.title'))),
      body: _expired
          ? EmptyView(message: l10n.t('visibility.sessionChanged'))
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 16,
                    children: [
                      _filter(l10n, 'status', _status, _statuses),
                      _filter(l10n, 'type', _type, _types),
                    ],
                  ),
                ),
                Expanded(child: _results(l10n, theme)),
              ],
            ),
    );
  }

  Widget _results(AppLocalizations l10n, ThemeData theme) {
    return _loading
        ? const LoadingView()
        : _error != null
        ? ErrorView(error: _error!, onRetry: _load)
        : _items.isEmpty
        ? EmptyView(message: l10n.t('account.statements.empty'))
        : Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppBreakpoints.contentMaxWidth,
              ),
              child: RefreshIndicator(
                onRefresh: _load,
                child: ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _items.length + (_hasNext ? 1 : 0),
                  itemBuilder: (_, i) {
                    if (i >= _items.length) {
                      return Center(
                        child: OutlinedButton(
                          onPressed: _busy ? null : _loadMore,
                          child: Text(
                            l10n.t(
                              _loadingMore
                                  ? 'common.loading'
                                  : 'account.statements.load_more',
                            ),
                          ),
                        ),
                      );
                    }
                    final s = _items[i];
                    final color = _statusColor(context, s.status);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Container(
                        padding: const EdgeInsets.all(16),
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
                                Icon(
                                  Icons.gavel,
                                  size: 18,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    s.title.isEmpty ? s.type : s.title,
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: color.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    _statuses.contains(s.status)
                                        ? l10n.t(
                                            'account.statements.status.${s.status}',
                                          )
                                        : s.status,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: color,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Text(s.message, style: theme.textTheme.bodyMedium),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Icon(
                                  Icons.schedule,
                                  size: 12,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _formatDate(s.createdAt),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                TextButton.icon(
                                  onPressed: _busy ? null : () => _appeal(s),
                                  icon: const Icon(
                                    Icons.forum_outlined,
                                    size: 16,
                                  ),
                                  label: Text(
                                    l10n.t('account.statements.appeal'),
                                  ),
                                ),
                                PopupMenuButton<String>(
                                  enabled: !_busy,
                                  tooltip: l10n.t('account.statements.actions'),
                                  onSelected: (action) =>
                                      _changeStatus(s, action),
                                  itemBuilder: (_) => [
                                    for (final action in [
                                      s.status == 'unread'
                                          ? 'mark_read'
                                          : 'mark_unread',
                                      'resolve',
                                      'dismiss',
                                    ])
                                      PopupMenuItem(
                                        value: action,
                                        child: Text(
                                          l10n.t('account.statements.$action'),
                                        ),
                                      ),
                                  ],
                                ),
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
          );
  }

  Widget _filter(
    AppLocalizations l10n,
    String group,
    String selected,
    List<String> choices,
  ) {
    return DropdownButton<String>(
      value: selected,
      items: [
        for (final choice in choices)
          DropdownMenuItem(
            value: choice,
            child: Text(l10n.t('account.statements.$group.$choice')),
          ),
      ],
      onChanged: _busy
          ? null
          : (value) {
              if (!_current || _busy || value == null) return;
              setState(() {
                if (group == 'status') {
                  _status = value;
                } else {
                  _type = value;
                }
              });
              _load();
            },
    );
  }
}
