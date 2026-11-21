import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../domain/group_models.dart';

class GroupInviteHistoryScreen extends ConsumerStatefulWidget {
  const GroupInviteHistoryScreen({super.key, required this.groupId});

  final int groupId;

  @override
  ConsumerState<GroupInviteHistoryScreen> createState() =>
      _GroupInviteHistoryScreenState();
}

class _GroupInviteHistoryScreenState
    extends ConsumerState<GroupInviteHistoryScreen> {
  CancelToken? _request;
  late final VoidCallback _stopSessionListener;
  List<V2GroupInvite> _invites = [];
  int _page = 1;
  bool _hasNext = false, _failed = false, _expired = false;

  @override
  void initState() {
    super.initState();
    final session = ref.read(tokenStoreProvider);
    _expired = session.isSessionChanging;
    _stopSessionListener = session.listenSessionChanges(_expire);
    _load(1);
  }

  @override
  void dispose() {
    _stopSessionListener();
    _request?.cancel();
    super.dispose();
  }

  void _expire() {
    if (!mounted || _expired) return;
    _request?.cancel();
    setState(() {
      _expired = true;
      _request = null;
      _invites = [];
      _hasNext = false;
    });
  }

  Future<void> _load(int page) async {
    if (_expired || _request != null) return;
    final request = CancelToken();
    setState(() {
      _request = request;
      _page = page;
      _invites = [];
      _hasNext = false;
      _failed = false;
    });
    try {
      final result = await ref
          .read(groupsApiProvider)
          .groupInvites(widget.groupId, page: page, cancelToken: request);
      if (!mounted || _request != request) return;
      if (result.items.any(
        (invite) => invite.group?['group_id'] != widget.groupId,
      )) {
        throw const FormatException('Invalid invite scope');
      }
      setState(() {
        _request = null;
        _invites = result.items;
        _hasNext = result.hasNext;
      });
    } catch (_) {
      if (!mounted || _request != request) return;
      setState(() {
        _request = null;
        _failed = true;
      });
    }
  }

  Future<void> _copy(String code) async {
    if (_expired) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted || _expired) return;
    final text = AppLocalizations.of(context).t('group.invite_copied');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(groupsApiProvider, (previous, next) {
      if (!identical(previous, next)) _expire();
    });
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('group.invite_history.title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_request != null)
            const LinearProgressIndicator()
          else if (_expired)
            Text(l10n.t('group.audit.expired'))
          else if (_failed)
            Text(l10n.t('group.invite_history.failed'))
          else if (_invites.isEmpty)
            Text(l10n.t('group.invite_history.empty')),
          for (final invite in _invites) _inviteTile(l10n, invite),
          if (!_expired && _request == null)
            Wrap(
              spacing: 8,
              children: [
                if (_failed)
                  OutlinedButton(
                    onPressed: () => _load(_page),
                    child: Text(l10n.t('common.retry')),
                  ),
                if (_page > 1)
                  OutlinedButton(
                    onPressed: () => _load(_page - 1),
                    child: Text(l10n.t('group.audit.previous')),
                  ),
                if (_hasNext)
                  OutlinedButton(
                    onPressed: () => _load(_page + 1),
                    child: Text(l10n.t('group.audit.next')),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _inviteTile(AppLocalizations l10n, V2GroupInvite invite) {
    final code = invite.inviteCode;
    final invitee = invite.invitee;
    final inviter = invite.inviter;
    final expires = invite.expiresAt;
    return Card(
      key: ValueKey(invite.inviteId),
      child: ListTile(
        title: Text(
          invitee == null
              ? code ?? '#${invite.inviteId}'
              : '@${invitee.username}',
        ),
        subtitle: Text(
          [
            '${invite.status} · ${invite.usedCount}/${invite.maxUses ?? '–'}',
            '${l10n.t('group.invite_from')} @${inviter.username}',
            if (expires != null)
              '${l10n.t('group.invite_history.expires')} $expires',
          ].join('\n'),
        ),
        trailing:
            invite.isValid && invitee == null && code != null && code.isNotEmpty
            ? IconButton(
                tooltip: l10n.t('group.invite_history.copy'),
                icon: const Icon(Icons.copy),
                onPressed: () => _copy(code),
              )
            : null,
      ),
    );
  }
}
