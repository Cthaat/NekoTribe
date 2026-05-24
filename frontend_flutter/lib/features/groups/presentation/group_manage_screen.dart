import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/group_models.dart';

class GroupManageScreen extends ConsumerStatefulWidget {
  const GroupManageScreen({super.key, required this.slug});

  final String slug;

  @override
  ConsumerState<GroupManageScreen> createState() => _GroupManageScreenState();
}

class _GroupManageScreenState extends ConsumerState<GroupManageScreen> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  V2Group? _group;
  V2GroupNotificationPreference? _notificationPreference;
  List<V2GroupMember> _members = [];
  bool _loading = true;
  bool _saving = false;
  bool _notificationSaving = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(groupsApiProvider);
      final group = await api.getGroup(widget.slug);
      final members = await api.members(group.groupId);
      V2GroupNotificationPreference? preference;
      try {
        preference = await api.getNotificationPreference(group.groupId);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _group = group;
        _notificationPreference = preference;
        _members = members.items;
        _name.text = group.name;
        _description.text = group.description;
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

  Future<void> _save() async {
    if (_group == null || _saving) return;
    setState(() => _saving = true);
    try {
      final next = await ref.read(groupsApiProvider).updateGroup(
        _group!.groupId,
        {'name': _name.text.trim(), 'description': _description.text.trim()},
      );
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      setState(() => _group = next);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.t('group.updated'))));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _setNotifications(bool enabled) async {
    if (_group == null || _notificationSaving) return;
    setState(() => _notificationSaving = true);
    try {
      final next = await ref.read(groupsApiProvider).setNotificationPreference(
            groupId: _group!.groupId,
            isEnabled: enabled,
          );
      if (!mounted) return;
      setState(() => _notificationPreference = next);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      if (mounted) setState(() => _notificationSaving = false);
    }
  }

  Future<void> _changeMemberRole(V2GroupMember member, String role) async {
    if (_group == null) return;
    try {
      await ref.read(groupsApiProvider).changeMemberRole(
            groupId: _group!.groupId,
            userId: member.user.userId,
            role: role,
          );
      await _load();
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.t('group.member_updated'))));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _muteMember(V2GroupMember member) async {
    if (_group == null) return;
    try {
      await ref.read(groupsApiProvider).muteMember(
            groupId: _group!.groupId,
            userId: member.user.userId,
            durationHours: 24,
          );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _unmuteMember(V2GroupMember member) async {
    if (_group == null) return;
    try {
      await ref.read(groupsApiProvider).unmuteMember(
            groupId: _group!.groupId,
            userId: member.user.userId,
          );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _removeMember(V2GroupMember member) async {
    if (_group == null) return;
    try {
      await ref.read(groupsApiProvider).removeMember(
            groupId: _group!.groupId,
            userId: member.user.userId,
          );
      await _load();
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.t('group.member_removed'))));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _createInvite() async {
    if (_group == null) return;
    try {
      await ref.read(groupsApiProvider).createInvite(_group!.groupId, {});
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.t('group.invite_created'))));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('group.manage'))),
      body: _loading
          ? const LoadingView()
          : _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppBreakpoints.contentMaxWidth,
                ),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    TextField(
                      controller: _name,
                      decoration: InputDecoration(labelText: l10n.t('group.name')),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _description,
                      minLines: 3,
                      maxLines: 6,
                      decoration: InputDecoration(
                        labelText: l10n.t('group.description'),
                      ),
                    ),
                    if (_notificationPreference != null) ...[
                      const SizedBox(height: 12),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(l10n.t('group.notifications')),
                        subtitle: Text(l10n.t('group.notifications_hint')),
                        value: _notificationPreference!.isEnabled,
                        onChanged: _notificationSaving
                            ? null
                            : (value) => _setNotifications(value),
                      ),
                    ],
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _saving ? null : _save,
                            icon: _saving
                                ? const SizedBox(
                                    height: 16,
                                    width: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.save_outlined),
                            label: Text(l10n.t('common.save')),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _createInvite,
                            icon: const Icon(Icons.mail_outline),
                            label: Text(l10n.t('group.create_invite')),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Text(
                      l10n.t('group.members_title'),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: theme.cardTheme.color,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: theme.dividerColor),
                      ),
                      child: Column(
                        children: [
                          for (var i = 0; i < _members.length; i++) ...[
                            if (i > 0)
                              Divider(
                                height: 1,
                                indent: 60,
                                color: theme.dividerColor,
                              ),
                            _MemberRow(
                              member: _members[i],
                              onRoleSelected: (role) =>
                                  _changeMemberRole(_members[i], role),
                              onMute: () => _muteMember(_members[i]),
                              onUnmute: () => _unmuteMember(_members[i]),
                              onRemove: () => _removeMember(_members[i]),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.member,
    required this.onRoleSelected,
    required this.onMute,
    required this.onUnmute,
    required this.onRemove,
  });
  final V2GroupMember member;
  final ValueChanged<String> onRoleSelected;
  final VoidCallback onMute;
  final VoidCallback onUnmute;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          AppAvatar(url: member.user.avatarUrl, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  member.user.displayName.isEmpty
                      ? member.user.username
                      : member.user.displayName,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '@${member.user.username}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          _RoleChip(role: member.role),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_horiz),
            onSelected: (value) {
              switch (value) {
                case 'role:admin':
                  onRoleSelected('admin');
                  break;
                case 'role:moderator':
                  onRoleSelected('moderator');
                  break;
                case 'role:member':
                  onRoleSelected('member');
                  break;
                case 'mute':
                  onMute();
                  break;
                case 'unmute':
                  onUnmute();
                  break;
                case 'remove':
                  onRemove();
                  break;
              }
            },
            itemBuilder: (context) {
              final l10n = AppLocalizations.of(context);
              final muted =
                  member.muteUntil != null && member.muteUntil!.isNotEmpty;
              return [
                PopupMenuItem(
                  value: 'role:admin',
                  child: Text('${l10n.t('group.change_role')}: admin'),
                ),
                PopupMenuItem(
                  value: 'role:moderator',
                  child: Text('${l10n.t('group.change_role')}: moderator'),
                ),
                PopupMenuItem(
                  value: 'role:member',
                  child: Text('${l10n.t('group.change_role')}: member'),
                ),
                PopupMenuItem(
                  value: muted ? 'unmute' : 'mute',
                  child: Text(
                    muted ? l10n.t('group.unmute') : l10n.t('group.mute'),
                  ),
                ),
                PopupMenuItem(
                  value: 'remove',
                  child: Text(l10n.t('group.remove_member')),
                ),
              ];
            },
          ),
        ],
      ),
    );
  }
}

class _RoleChip extends StatelessWidget {
  const _RoleChip({required this.role});

  final String role;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        role,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
