import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/user_models.dart';

class SessionsScreen extends ConsumerStatefulWidget {
  const SessionsScreen({super.key});

  @override
  ConsumerState<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends ConsumerState<SessionsScreen> {
  List<V2SessionItem> _items = [];
  bool _loading = true;
  bool _changing = false;
  bool _confirming = false;
  bool _hasNext = false;
  int _page = 1, _total = 0, _request = 0;
  late final VoidCallback _stopSessionListener;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _stopSessionListener = ref.read(tokenStoreProvider).listenSessionChanges(
      () {
        if (!mounted) return;
        setState(() {
          _request++;
          _items = [];
          _page = 1;
          _total = 0;
          _loading = _changing = _confirming = _hasNext = false;
          _error = null;
        });
      },
    );
    _load();
  }

  @override
  void dispose() {
    _stopSessionListener();
    super.dispose();
  }

  bool _current(int revision) {
    if (!mounted) return false;
    final tokens = ref.read(tokenStoreProvider);
    return tokens.revision == revision && !tokens.isSessionChanging;
  }

  Future<void> _load({int page = 1}) async {
    final revision = ref.read(tokenStoreProvider).revision;
    if (!_current(revision)) return;
    final request = ++_request;
    bool valid() => _current(revision) && request == _request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(authApiProvider);
      var result = await api.listSessions(page: page);
      if (!valid()) return;
      if (page > 1 && result.items.isEmpty) {
        result = await api.listSessions();
        if (!valid()) return;
      }
      setState(() {
        _items = result.items;
        _page = result.page;
        _total = result.total;
        _hasNext = result.hasNext;
        _loading = false;
      });
    } catch (e) {
      if (!valid()) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _revoke(V2SessionItem session) async {
    if (session.isCurrent || !_items.contains(session)) return;
    await _change(ref.read(tokenStoreProvider).revision, id: session.sessionId);
  }

  Future<void> _revokeOthers() async {
    final revision = ref.read(tokenStoreProvider).revision;
    if (_confirming || _changing || _loading || !_current(revision)) return;
    setState(() => _confirming = true);
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.t('account.sessions.revoke_others')),
        content: Text(l10n.t('account.sessions.revoke_others_body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.t('common.confirm')),
          ),
        ],
      ),
    );
    if (!_current(revision)) return;
    setState(() => _confirming = false);
    if (ok == true) await _change(revision);
  }

  Future<void> _change(int revision, {String? id}) async {
    if (!_current(revision) || _changing || _loading) return;
    setState(() => _changing = true);
    try {
      final api = ref.read(authApiProvider);
      if (id == null) {
        await api.revokeOtherSessions();
      } else {
        await api.revokeSession(id);
      }
      if (!_current(revision)) return;
      setState(
        () => _items = _items
            .where(
              (session) =>
                  id == null ? session.isCurrent : session.sessionId != id,
            )
            .toList(),
      );
      await _load(page: id == null ? 1 : _page);
    } catch (e) {
      if (!_current(revision)) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      if (_current(revision)) setState(() => _changing = false);
    }
  }

  String _formatDate(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return DateFormat.yMd().add_Hm().format(dt.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('account.sessions.title')),
        actions: [
          IconButton(
            tooltip: l10n.t('account.sessions.refresh'),
            icon: const Icon(Icons.refresh),
            onPressed: _loading || _changing ? null : () => _load(page: _page),
          ),
          IconButton(
            tooltip: l10n.t('account.sessions.revoke_others'),
            icon: const Icon(Icons.logout),
            onPressed:
                !_loading &&
                    !_changing &&
                    !_confirming &&
                    (_total > 1 || _items.any((item) => !item.isCurrent))
                ? _revokeOthers
                : null,
          ),
        ],
      ),
      bottomNavigationBar: _page > 1 || _hasNext
          ? SafeArea(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_page > 1)
                    TextButton(
                      onPressed: _loading || _changing
                          ? null
                          : () => _load(page: _page - 1),
                      child: Text(l10n.t('account.sessions.previous_page')),
                    ),
                  if (_hasNext)
                    TextButton(
                      onPressed: _loading || _changing
                          ? null
                          : () => _load(page: _page + 1),
                      child: Text(l10n.t('account.sessions.next_page')),
                    ),
                ],
              ),
            )
          : null,
      body: _loading
          ? const LoadingView()
          : _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : _items.isEmpty
          ? EmptyView(message: l10n.t('account.sessions.empty'))
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppBreakpoints.contentMaxWidth,
                ),
                child: RefreshIndicator(
                  onRefresh: () async {
                    if (!_changing) await _load(page: _page);
                  },
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _items.length,
                    itemBuilder: (_, i) {
                      final s = _items[i];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: theme.cardTheme.color,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: s.isCurrent
                                  ? theme.colorScheme.primary
                                  : theme.dividerColor,
                              width: s.isCurrent ? 1.5 : 1,
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color:
                                      (s.isCurrent
                                              ? theme.colorScheme.primary
                                              : theme
                                                    .colorScheme
                                                    .onSurfaceVariant)
                                          .withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(
                                  s.isCurrent
                                      ? Icons.smartphone
                                      : Icons.devices_other,
                                  color: s.isCurrent
                                      ? theme.colorScheme.primary
                                      : theme.colorScheme.onSurfaceVariant,
                                  size: 22,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            s.deviceInfo.isEmpty
                                                ? l10n.t(
                                                    'account.sessions.unknown_device',
                                                  )
                                                : s.deviceInfo,
                                            style: theme.textTheme.titleSmall
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        if (s.isCurrent)
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 3,
                                            ),
                                            decoration: BoxDecoration(
                                              color: theme.colorScheme.primary,
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                            ),
                                            child: Text(
                                              l10n.t('common.current'),
                                              style: theme.textTheme.labelSmall
                                                  ?.copyWith(
                                                    color: theme
                                                        .colorScheme
                                                        .onPrimary,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                            ),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    _MetaLine(
                                      icon: Icons.public,
                                      text:
                                          '${l10n.t('account.sessions.ip')}: ${s.ipAddress}',
                                    ),
                                    const SizedBox(height: 2),
                                    _MetaLine(
                                      icon: Icons.schedule,
                                      text:
                                          '${l10n.t('account.sessions.last')}: ${_formatDate(s.lastAccessedAt)}',
                                    ),
                                  ],
                                ),
                              ),
                              if (!s.isCurrent)
                                IconButton(
                                  icon: Icon(
                                    Icons.delete_outline,
                                    color: theme.colorScheme.error,
                                  ),
                                  onPressed: _changing || _loading
                                      ? null
                                      : () => _revoke(s),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
    );
  }
}

class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 12, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
