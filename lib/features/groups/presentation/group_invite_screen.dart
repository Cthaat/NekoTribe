import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/group_invite.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/group_models.dart';

class GroupInviteScreen extends ConsumerStatefulWidget {
  const GroupInviteScreen({super.key, this.code});

  final String? code;

  @override
  ConsumerState<GroupInviteScreen> createState() => _GroupInviteScreenState();
}

class _GroupInviteScreenState extends ConsumerState<GroupInviteScreen> {
  final _input = TextEditingController();
  V2GroupInvitePreview? _preview;
  Object? _error;
  String? _status;
  bool _loading = false;
  bool _joining = false;
  bool _invalidInput = false;
  int _sequence = 0;

  @override
  void initState() {
    super.initState();
    if (widget.code != null) unawaited(_load());
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final sequence = ++_sequence;
    final code = normalizeGroupInviteCode(widget.code);
    final api = ref.read(groupsApiProvider);
    setState(() {
      _preview = null;
      _error = null;
      _status = null;
      _joining = false;
      _loading = code != null;
      _invalidInput = code == null;
    });
    if (code == null) return;
    try {
      final preview = await api.previewInvite(code);
      if (!mounted || sequence != _sequence) return;
      setState(() {
        if (!preview.isValid || preview.group.groupId < 1) {
          _invalidInput = true;
        } else {
          _preview = preview;
          _status = preview.group.membership.status;
        }
        _loading = false;
      });
    } catch (error) {
      if (!mounted || sequence != _sequence) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  void _openInput() {
    final code = parseGroupInviteInput(_input.text);
    if (code == null) {
      setState(() => _invalidInput = true);
      return;
    }
    context.push(groupInviteLocation(code)!);
  }

  Future<void> _join() async {
    final preview = _preview;
    final code = normalizeGroupInviteCode(widget.code);
    if (_joining || _status != null || preview == null || code == null) return;
    final sequence = _sequence;
    final api = ref.read(groupsApiProvider);
    setState(() {
      _joining = true;
      _error = null;
    });
    try {
      final result = await api.joinGroup(
        preview.group.groupId,
        inviteCode: code,
      );
      if (!mounted || sequence != _sequence) return;
      setState(() => _status = result.status);
    } catch (error) {
      if (!mounted || sequence != _sequence) return;
      setState(() => _error = error);
    } finally {
      if (mounted && sequence == _sequence) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(groupsApiProvider, (previous, next) {
      if (widget.code != null && previous != next) unawaited(_load());
    });
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final preview = _preview;
    final status = _status;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('group.invite_preview'))),
      body: _loading
          ? const LoadingView()
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.all(24),
                  children: [
                    if (widget.code == null) ...[
                      TextField(
                        controller: _input,
                        decoration: InputDecoration(
                          labelText: l10n.t('group.invite_input'),
                          errorText: _invalidInput
                              ? l10n.t('group.invite_invalid')
                              : null,
                        ),
                        onSubmitted: (_) => _openInput(),
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _openInput,
                        child: Text(l10n.t('group.invite_preview')),
                      ),
                    ] else if (preview != null) ...[
                      Text(
                        preview.group.name,
                        style: theme.textTheme.headlineSmall,
                      ),
                      if (preview.group.description.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(preview.group.description),
                      ],
                      const SizedBox(height: 12),
                      Text(
                        '${l10n.t('group.invite_from')} ${preview.inviter.displayName.isNotEmpty ? preview.inviter.displayName : preview.inviter.username}',
                      ),
                      if (preview.message?.isNotEmpty == true) ...[
                        const SizedBox(height: 8),
                        Text(preview.message!),
                      ],
                      const SizedBox(height: 16),
                      if (status == null)
                        FilledButton(
                          onPressed: _joining ? null : _join,
                          child: Text(l10n.t('group.join')),
                        )
                      else
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            l10n.t(switch (status) {
                              'pending' => 'group.invite_pending',
                              'banned' => 'group.invite_unavailable',
                              _ => 'group.invite_joined',
                            }),
                          ),
                        ),
                      if ((status == 'active' || status == 'muted') &&
                          preview.group.slug.isNotEmpty)
                        TextButton(
                          onPressed: () => context.go(
                            '/groups/${Uri.encodeComponent(preview.group.slug)}',
                          ),
                          child: Text(l10n.t('group.invite_open_group')),
                        ),
                    ] else if (_invalidInput)
                      Text(l10n.t('group.invite_invalid')),
                    if (_error case final error?) ...[
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          ErrorView.describe(context, error),
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ),
                      if (preview == null)
                        OutlinedButton(
                          onPressed: _load,
                          child: Text(l10n.t('common.retry')),
                        ),
                    ],
                  ],
                ),
              ),
            ),
    );
  }
}
