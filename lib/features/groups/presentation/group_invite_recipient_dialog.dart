import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exception.dart';
import '../../../shared/widgets/glass/liquid_glass_overlays.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../users/domain/user_models.dart';

class GroupInviteRecipientDialog extends ConsumerStatefulWidget {
  const GroupInviteRecipientDialog({
    super.key,
    required this.groupId,
    required this.expireHours,
  });

  final int groupId;
  final int expireHours;

  @override
  ConsumerState<GroupInviteRecipientDialog> createState() =>
      _GroupInviteRecipientDialogState();
}

class _GroupInviteRecipientDialogState
    extends ConsumerState<GroupInviteRecipientDialog> {
  final _query = TextEditingController();
  final _message = TextEditingController();
  late final VoidCallback _stopSessionListener;
  List<V2PublicUser> _results = [];
  V2PublicUser? _recipient;
  String? _notice;
  int _searchRevision = 0;
  bool _searching = false;
  bool _sending = false;
  bool _unknown = false;
  bool _expired = false;

  @override
  void initState() {
    super.initState();
    final store = ref.read(tokenStoreProvider);
    _expired = store.isSessionChanging;
    _stopSessionListener = store.listenSessionChanges(_expire);
  }

  @override
  void dispose() {
    _stopSessionListener();
    _query.dispose();
    _message.dispose();
    super.dispose();
  }

  void _expire() {
    if (!mounted || _expired) return;
    _query.clear();
    _message.clear();
    setState(() {
      _expired = true;
      _searching = false;
      _sending = false;
      _results = [];
      _recipient = null;
      _notice = null;
    });
  }

  void _queryChanged(String _) {
    _searchRevision++;
    setState(() {
      _results = [];
      _recipient = null;
      _searching = false;
      _notice = null;
    });
  }

  Future<void> _search() async {
    final query = _query.text.trim();
    if (_expired || _unknown || _searching || _sending || query.length < 2) {
      return;
    }
    final revision = ++_searchRevision;
    bool current() => mounted && !_expired && revision == _searchRevision;
    setState(() {
      _searching = true;
      _recipient = null;
      _results = [];
      _notice = null;
    });
    try {
      final page = await ref
          .read(usersApiProvider)
          .searchUsers(query, size: 12);
      if (!current()) return;
      final users = {
        for (final user in page.items)
          if (user.userId > 0 &&
              user.userId <= 9007199254740991 &&
              user.username.isNotEmpty)
            user.userId: user,
      };
      setState(() {
        _results = users.values.toList();
        if (_results.isEmpty) _notice = 'group.invite_recipient.empty';
      });
    } catch (_) {
      if (current()) {
        setState(() => _notice = 'group.invite_recipient.search_failed');
      }
    } finally {
      if (current()) setState(() => _searching = false);
    }
  }

  Future<void> _send() async {
    final recipient = _recipient;
    if (_expired || _unknown || _sending || _searching || recipient == null) {
      return;
    }
    final message = _message.text.trim();
    if (utf8.encode(message).length > 200) {
      setState(() => _notice = 'group.invite_recipient.message_too_long');
      return;
    }
    setState(() {
      _sending = true;
      _notice = null;
    });
    try {
      final invite = await ref
          .read(groupsApiProvider)
          .createInvite(widget.groupId, {
            'invitee_id': recipient.userId,
            'max_uses': 1,
            'expire_hours': widget.expireHours,
            if (message.isNotEmpty) 'message': message,
          });
      if (!mounted || _expired) return;
      if (invite.inviteId <= 0 ||
          invite.inviteId > 9007199254740991 ||
          invite.inviteCode != null) {
        throw const FormatException('Invalid directed invite receipt');
      }
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted || _expired) return;
      final status = error is ApiException ? error.statusCode : null;
      final rejected =
          status == 400 ||
          status == 401 ||
          status == 403 ||
          status == 404 ||
          status == 422 ||
          status == 429;
      setState(() {
        _unknown = !rejected;
        _notice = _unknown
            ? 'group.invite_recipient.unknown'
            : 'group.invite_recipient.rejected';
      });
    } finally {
      if (mounted && !_expired) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(groupsApiProvider, (previous, next) {
      if (!identical(previous, next)) _expire();
    });
    final l10n = AppLocalizations.of(context);
    String label(String key) => l10n.t('group.invite_recipient.$key');
    final canEdit = !_expired && !_sending && !_unknown;
    return LiquidGlassAlertContent(
      title: Text(label('title')),
      content: SizedBox(
        width: 420,
        child: _expired
            ? Text(l10n.t('group.audit.expired'))
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const Key('group-invite-recipient-query'),
                    controller: _query,
                    enabled: canEdit,
                    textInputAction: TextInputAction.search,
                    onChanged: _queryChanged,
                    onSubmitted: (_) => _search(),
                    decoration: InputDecoration(
                      labelText: label('query'),
                      suffixIcon: IconButton(
                        tooltip: label('search'),
                        onPressed:
                            canEdit &&
                                _query.text.trim().length >= 2 &&
                                !_searching
                            ? _search
                            : null,
                        icon: const Icon(Icons.search),
                      ),
                    ),
                  ),
                  if (_searching || _sending) const LinearProgressIndicator(),
                  for (final user in _results)
                    ListTile(
                      key: ValueKey('group-invite-recipient-${user.userId}'),
                      selected: _recipient?.userId == user.userId,
                      title: Text('@${user.username}'),
                      subtitle: user.displayName.isEmpty
                          ? null
                          : Text(user.displayName),
                      trailing: _recipient?.userId == user.userId
                          ? const Icon(Icons.check)
                          : null,
                      onTap: canEdit
                          ? () => setState(() => _recipient = user)
                          : null,
                    ),
                  if (_recipient != null)
                    TextField(
                      key: const Key('group-invite-recipient-message'),
                      enabled: canEdit,
                      controller: _message,
                      maxLines: 2,
                      decoration: InputDecoration(labelText: label('message')),
                    ),
                  if (_notice != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(l10n.t(_notice!)),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: _sending ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.t('common.cancel')),
        ),
        FilledButton(
          key: const Key('group-invite-recipient-send'),
          onPressed: canEdit && !_searching && _recipient != null
              ? _send
              : null,
          child: Text(label('send')),
        ),
      ],
    );
  }
}
