import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/group_draft_metadata.dart';
import '../domain/group_models.dart';
import 'group_image_upload.dart';

bool _canManageGroup(String? role) {
  return role == 'owner' || role == 'admin' || role == 'moderator';
}

class GroupManageScreen extends ConsumerStatefulWidget {
  const GroupManageScreen({super.key, required this.slug});

  final String slug;

  @override
  ConsumerState<GroupManageScreen> createState() => _GroupManageScreenState();
}

class _GroupManageScreenState extends ConsumerState<GroupManageScreen> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _tags = TextEditingController();
  final _inviteMaxUses = TextEditingController(text: '100');
  final _inviteExpireHours = TextEditingController(text: '168');
  final _deleteConfirm = TextEditingController();
  final _memberSearch = TextEditingController();
  V2Group? _group;
  V2GroupNotificationPreference? _notificationPreference;
  List<V2GroupMember> _members = [];
  int _membersPage = 1;
  bool _membersHasNext = false;
  bool _membersLoadingMore = false;
  String? _avatarUrl;
  String? _coverUrl;
  String _privacy = 'public';
  String _category = 'tech';
  String _postPermission = 'all';
  bool _joinApproval = false;
  bool _loading = true;
  bool _saving = false;
  bool _deleting = false;
  bool _uploadingAvatar = false;
  bool _uploadingCover = false;
  bool _notificationSaving = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _memberSearch.addListener(_refreshMemberSearch);
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _tags.dispose();
    _inviteMaxUses.dispose();
    _inviteExpireHours.dispose();
    _deleteConfirm.dispose();
    _memberSearch.removeListener(_refreshMemberSearch);
    _memberSearch.dispose();
    super.dispose();
  }

  void _refreshMemberSearch() {
    if (mounted) setState(() {});
  }

  List<V2GroupMember> get _pendingMembers {
    return _members.where((member) => member.status == 'pending').toList();
  }

  List<V2GroupMember> get _managedMembers {
    final query = _memberSearch.text.trim().toLowerCase();
    final activeMembers = _members
        .where((member) => member.status != 'pending')
        .toList();
    if (query.isEmpty) return activeMembers;
    return activeMembers.where((member) {
      final displayName = member.user.displayName.isEmpty
          ? member.user.username
          : member.user.displayName;
      return displayName.toLowerCase().contains(query) ||
          member.user.username.toLowerCase().contains(query);
    }).toList();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(groupsApiProvider);
      final group = await api.getGroup(widget.slug);
      if (!_canManageGroup(group.membership.role)) {
        if (!mounted) return;
        setState(() {
          _group = group;
          _loading = false;
          _error = Exception('forbidden');
        });
        return;
      }
      final members = await api.members(group.groupId, page: 1);
      V2GroupNotificationPreference? preference;
      try {
        preference = await api.getNotificationPreference(group.groupId);
      } catch (_) {}
      if (!mounted) return;
      _memberSearch.clear();
      setState(() {
        _group = group;
        _notificationPreference = preference;
        _members = members.items;
        _membersPage = 1;
        _membersHasNext = members.hasNext;
        _membersLoadingMore = false;
        _name.text = group.name;
        _description.text = group.description;
        _tags.text = group.tags.join(', ');
        _avatarUrl = group.avatarUrl ?? '';
        _coverUrl = group.coverUrl ?? '';
        _privacy = groupPrivacyValues.contains(group.privacy)
            ? group.privacy
            : 'public';
        _category =
            group.category != null &&
                groupCategoryValues.contains(group.category)
            ? group.category!
            : 'tech';
        _postPermission =
            groupPostPermissionValues.contains(group.postPermission)
            ? group.postPermission
            : 'all';
        _joinApproval = group.joinApproval;
        _deleteConfirm.clear();
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

  Future<void> _loadMoreMembers() async {
    final group = _group;
    if (group == null || _membersLoadingMore || !_membersHasNext || _loading) {
      return;
    }
    setState(() => _membersLoadingMore = true);
    try {
      final next = _membersPage + 1;
      final page = await ref
          .read(groupsApiProvider)
          .members(group.groupId, page: next);
      if (!mounted) return;
      setState(() {
        _members = [..._members, ...page.items];
        _membersPage = next;
        _membersHasNext = page.hasNext;
        _membersLoadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _membersLoadingMore = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _reloadMembers() async {
    final group = _group;
    if (group == null) return;
    final pages = _membersPage.clamp(1, 50);
    try {
      final api = ref.read(groupsApiProvider);
      final all = <V2GroupMember>[];
      var hasNext = false;
      var lastPage = 1;
      for (var p = 1; p <= pages; p++) {
        final page = await api.members(group.groupId, page: p);
        all.addAll(page.items);
        hasNext = page.hasNext;
        lastPage = p;
        if (!page.hasNext) break;
      }
      if (!mounted) return;
      setState(() {
        _members = all;
        _membersPage = lastPage;
        _membersHasNext = hasNext;
        _membersLoadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _save() async {
    if (_group == null || _saving) return;
    setState(() => _saving = true);
    try {
      final next = await ref
          .read(groupsApiProvider)
          .updateGroup(
            groupId: _group!.groupId,
            name: _name.text.trim(),
            description: _description.text.trim(),
            avatarUrl: _avatarUrl ?? '',
            coverUrl: _coverUrl ?? '',
            privacy: _privacy,
            category: _category,
            tags: groupDraftTags(_tags.text),
            joinApproval: _joinApproval,
            postPermission: _postPermission,
          );
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      setState(() {
        _group = next;
        _tags.text = next.tags.join(', ');
      });
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
      final next = await ref
          .read(groupsApiProvider)
          .setNotificationPreference(
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

  Future<void> _pickGroupImage({required bool cover}) async {
    if (_uploadingAvatar || _uploadingCover) return;
    setState(() {
      if (cover) {
        _uploadingCover = true;
      } else {
        _uploadingAvatar = true;
      }
    });
    try {
      final url = await pickAndUploadGroupImage(
        ref: ref,
        altText: _name.text.trim(),
      );
      if (!mounted || url == null) return;
      setState(() {
        if (cover) {
          _coverUrl = url;
        } else {
          _avatarUrl = url;
        }
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      if (mounted) {
        setState(() {
          if (cover) {
            _uploadingCover = false;
          } else {
            _uploadingAvatar = false;
          }
        });
      }
    }
  }

  Future<void> _changeMemberRole(V2GroupMember member, String role) async {
    if (_group == null) return;
    try {
      await ref
          .read(groupsApiProvider)
          .changeMemberRole(
            groupId: _group!.groupId,
            userId: member.user.userId,
            role: role,
          );
      await _reloadMembers();
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

  Future<void> _approveMember(V2GroupMember member, bool approved) async {
    if (_group == null) return;
    try {
      await ref
          .read(groupsApiProvider)
          .approveMember(
            groupId: _group!.groupId,
            memberId: member.memberId,
            approved: approved,
          );
      await _reloadMembers();
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            approved
                ? l10n.t('group.member_approved')
                : l10n.t('group.member_rejected'),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _transferOwnership(V2GroupMember member) async {
    if (_group == null) return;
    try {
      await ref
          .read(groupsApiProvider)
          .transferOwnership(
            groupId: _group!.groupId,
            newOwnerId: member.user.userId,
          );
      await _load();
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t('group.ownership_transferred'))),
      );
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
      await ref
          .read(groupsApiProvider)
          .muteMember(
            groupId: _group!.groupId,
            userId: member.user.userId,
            durationHours: 24,
          );
      await _reloadMembers();
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
      await ref
          .read(groupsApiProvider)
          .unmuteMember(groupId: _group!.groupId, userId: member.user.userId);
      await _reloadMembers();
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
      await ref
          .read(groupsApiProvider)
          .removeMember(groupId: _group!.groupId, userId: member.user.userId);
      await _reloadMembers();
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
      final invite = await ref.read(groupsApiProvider).createInvite(
        _group!.groupId,
        {
          'max_uses': _positiveInt(_inviteMaxUses.text, fallback: 100),
          'expire_hours': _positiveInt(_inviteExpireHours.text, fallback: 168),
        },
      );
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      final code = invite.inviteCode?.trim();
      if (code != null && code.isNotEmpty) {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(l10n.t('group.invite_created')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SelectableText(
                  code,
                  style: Theme.of(dialogContext).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.t('group.invite_code_hint'),
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: code));
                  if (!dialogContext.mounted) return;
                  Navigator.of(dialogContext).pop();
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.t('group.invite_copied'))),
                  );
                },
                child: Text(l10n.t('common.copy')),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(l10n.t('common.done')),
              ),
            ],
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.t('group.invite_created'))),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _deleteGroup() async {
    final group = _group;
    if (group == null || _deleting || _deleteConfirm.text != group.name) {
      return;
    }
    setState(() => _deleting = true);
    try {
      await ref.read(groupsApiProvider).deleteGroup(group.groupId);
      if (!mounted) return;
      context.go('/groups');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final pendingMembers = _pendingMembers;
    final managedMembers = _managedMembers;
    final isOwner = _group?.membership.role == 'owner';
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('group.manage'))),
      body: _loading
          ? const LoadingView()
          : _error != null
          ? (_error.toString().contains('forbidden')
                ? EmptyView(
                    message: l10n.t('error.forbidden'),
                    icon: Icons.lock_outline,
                    actionLabel: l10n.t('common.back'),
                    onAction: () => context.pop(),
                  )
                : ErrorView(error: _error!, onRetry: _load))
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppBreakpoints.contentMaxWidth,
                ),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        AppAvatar(url: _avatarUrl, size: 72),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l10n.t('group.avatar'),
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                l10n.t('group.avatar_hint'),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton.filledTonal(
                          key: const Key('group-manage-avatar-button'),
                          tooltip: l10n.t('group.upload_avatar'),
                          onPressed: _uploadingAvatar
                              ? null
                              : () => _pickGroupImage(cover: false),
                          icon: _uploadingAvatar
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.photo_camera_outlined),
                        ),
                        if (_avatarUrl != null && _avatarUrl!.isNotEmpty)
                          IconButton(
                            key: const Key('group-manage-avatar-clear-button'),
                            tooltip: l10n.t('common.cancel'),
                            onPressed: _uploadingAvatar
                                ? null
                                : () => setState(() => _avatarUrl = ''),
                            icon: const Icon(Icons.close),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n.t('group.cover'),
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton.filledTonal(
                          key: const Key('group-manage-cover-button'),
                          tooltip: l10n.t('group.upload_cover'),
                          onPressed: _uploadingCover
                              ? null
                              : () => _pickGroupImage(cover: true),
                          icon: _uploadingCover
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.image_outlined),
                        ),
                        if (_coverUrl != null && _coverUrl!.isNotEmpty)
                          IconButton(
                            key: const Key('group-manage-cover-clear-button'),
                            tooltip: l10n.t('common.cancel'),
                            onPressed: _uploadingCover
                                ? null
                                : () => setState(() => _coverUrl = ''),
                            icon: const Icon(Icons.close),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 132,
                      child: _coverUrl == null || _coverUrl!.isEmpty
                          ? DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                color:
                                    theme.colorScheme.surfaceContainerHighest,
                              ),
                              child: Center(
                                child: Text(
                                  l10n.t('group.cover_hint'),
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            )
                          : AppMediaImage(
                              url: _coverUrl!,
                              height: 132,
                              width: double.infinity,
                              borderRadius: BorderRadius.circular(14),
                            ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      key: const Key('group-manage-name-field'),
                      controller: _name,
                      maxLength: 50,
                      decoration: InputDecoration(
                        labelText: l10n.t('group.name'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('group-manage-description-field'),
                      controller: _description,
                      minLines: 3,
                      maxLines: 6,
                      maxLength: 500,
                      decoration: InputDecoration(
                        labelText: l10n.t('group.description'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      key: const Key('group-manage-privacy-field'),
                      initialValue: _privacy,
                      decoration: InputDecoration(
                        labelText: l10n.t('group.privacy'),
                      ),
                      items: groupPrivacyValues
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(l10n.t('group.privacy.$value')),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() => _privacy = value);
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      key: const Key('group-manage-category-field'),
                      initialValue: _category,
                      decoration: InputDecoration(
                        labelText: l10n.t('group.category'),
                      ),
                      items: groupCategoryValues
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(l10n.t('group.category.$value')),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() => _category = value);
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('group-manage-tags-field'),
                      controller: _tags,
                      maxLength: 160,
                      decoration: InputDecoration(
                        labelText: l10n.t('group.tags'),
                        hintText: l10n.t('group.tags_hint'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      key: const Key('group-manage-join-approval-switch'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(l10n.t('group.join_approval')),
                      subtitle: Text(l10n.t('group.join_approval_hint')),
                      value: _joinApproval,
                      onChanged: (value) =>
                          setState(() => _joinApproval = value),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      key: const Key('group-manage-post-permission-field'),
                      initialValue: _postPermission,
                      decoration: InputDecoration(
                        labelText: l10n.t('group.post_permission'),
                      ),
                      items: groupPostPermissionValues
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(
                                l10n.t('group.post_permission.$value'),
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() => _postPermission = value);
                      },
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
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: const Key(
                              'group-manage-invite-max-uses-field',
                            ),
                            controller: _inviteMaxUses,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: l10n.t('group.invite_max_uses'),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            key: const Key(
                              'group-manage-invite-expire-hours-field',
                            ),
                            controller: _inviteExpireHours,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: l10n.t('group.invite_expire_hours'),
                            ),
                          ),
                        ),
                      ],
                    ),
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
                    if (isOwner) ...[
                      Text(
                        l10n.t('group.danger_title'),
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.error,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        key: const Key('group-manage-delete-confirm-field'),
                        controller: _deleteConfirm,
                        decoration: InputDecoration(
                          labelText: l10n.t('group.delete_confirm'),
                          hintText: _group?.name ?? '',
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        key: const Key('group-manage-delete-button'),
                        style: FilledButton.styleFrom(
                          backgroundColor: theme.colorScheme.error,
                          foregroundColor: theme.colorScheme.onError,
                        ),
                        onPressed:
                            _deleting ||
                                _group == null ||
                                _deleteConfirm.text != _group!.name
                            ? null
                            : _deleteGroup,
                        icon: _deleting
                            ? const SizedBox(
                                height: 16,
                                width: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.delete_outline),
                        label: Text(l10n.t('group.delete')),
                      ),
                      const SizedBox(height: 24),
                    ],
                    Text(
                      l10n.t('group.members_title'),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (pendingMembers.isNotEmpty) ...[
                      Text(
                        l10n.t('group.pending_members'),
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
                            for (var i = 0; i < pendingMembers.length; i++) ...[
                              if (i > 0)
                                Divider(
                                  height: 1,
                                  indent: 60,
                                  color: theme.dividerColor,
                                ),
                              _PendingMemberRow(
                                member: pendingMembers[i],
                                onApprove: () =>
                                    _approveMember(pendingMembers[i], true),
                                onReject: () =>
                                    _approveMember(pendingMembers[i], false),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    TextField(
                      key: const Key('group-member-search-field'),
                      controller: _memberSearch,
                      decoration: InputDecoration(
                        labelText: l10n.t('group.member_search'),
                        prefixIcon: const Icon(Icons.search),
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
                          for (var i = 0; i < managedMembers.length; i++) ...[
                            if (i > 0)
                              Divider(
                                height: 1,
                                indent: 60,
                                color: theme.dividerColor,
                              ),
                            _MemberRow(
                              member: managedMembers[i],
                              actorRole: _group?.membership.role,
                              onRoleSelected: (role) =>
                                  _changeMemberRole(managedMembers[i], role),
                              onMute: () => _muteMember(managedMembers[i]),
                              onUnmute: () => _unmuteMember(managedMembers[i]),
                              onRemove: () => _removeMember(managedMembers[i]),
                              canTransferOwnership:
                                  isOwner && managedMembers[i].role != 'owner',
                              onTransferOwnership: () =>
                                  _transferOwnership(managedMembers[i]),
                            ),
                          ],
                          if (managedMembers.isEmpty)
                            Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(l10n.t('group.empty_members')),
                            ),
                        ],
                      ),
                    ),
                    if (_membersHasNext) ...[
                      const SizedBox(height: 12),
                      OutlinedButton(
                        key: const Key('group-manage-members-load-more'),
                        onPressed: _membersLoadingMore
                            ? null
                            : _loadMoreMembers,
                        child: _membersLoadingMore
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(l10n.t('common.more')),
                      ),
                    ],
                  ],
                ),
              ),
            ),
    );
  }
}

int _positiveInt(String value, {required int fallback}) {
  final parsed = int.tryParse(value.trim());
  if (parsed == null || parsed < 1) return fallback;
  return parsed;
}

class _PendingMemberRow extends StatelessWidget {
  const _PendingMemberRow({
    required this.member,
    required this.onApprove,
    required this.onReject,
  });

  final V2GroupMember member;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final displayName = member.user.displayName.isEmpty
        ? member.user.username
        : member.user.displayName;
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
                  displayName,
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
          IconButton(
            key: Key('group-member-reject-${member.memberId}'),
            tooltip: l10n.t('group.reject_member'),
            onPressed: onReject,
            icon: Icon(Icons.close, color: theme.colorScheme.error),
          ),
          IconButton(
            key: Key('group-member-approve-${member.memberId}'),
            tooltip: l10n.t('group.approve_member'),
            onPressed: onApprove,
            icon: Icon(Icons.check, color: theme.colorScheme.primary),
          ),
        ],
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.member,
    required this.actorRole,
    required this.onRoleSelected,
    required this.onMute,
    required this.onUnmute,
    required this.onRemove,
    required this.canTransferOwnership,
    required this.onTransferOwnership,
  });
  final V2GroupMember member;
  final String? actorRole;
  final ValueChanged<String> onRoleSelected;
  final VoidCallback onMute;
  final VoidCallback onUnmute;
  final VoidCallback onRemove;
  final bool canTransferOwnership;
  final VoidCallback onTransferOwnership;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isTargetOwner = member.role == 'owner';
    final canChangeRoles = !isTargetOwner &&
        (actorRole == 'owner' ||
            actorRole == 'admin' ||
            actorRole == 'moderator');
    final canModerateMember = !isTargetOwner &&
        (actorRole == 'owner' ||
            actorRole == 'admin' ||
            actorRole == 'moderator');
    // Moderators cannot promote to admin.
    final canSetAdmin = actorRole == 'owner' || actorRole == 'admin';
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
          if (!isTargetOwner || canTransferOwnership)
            PopupMenuButton<String>(
              key: Key('group-member-menu-${member.user.userId}'),
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
                  case 'transfer':
                    onTransferOwnership();
                    break;
                }
              },
              itemBuilder: (context) {
                final l10n = AppLocalizations.of(context);
                final muted =
                    member.muteUntil != null && member.muteUntil!.isNotEmpty;
                final items = <PopupMenuEntry<String>>[];
                if (canChangeRoles) {
                  if (canSetAdmin) {
                    items.add(
                      PopupMenuItem(
                        value: 'role:admin',
                        child: Text('${l10n.t('group.change_role')}: admin'),
                      ),
                    );
                  }
                  items.addAll([
                    PopupMenuItem(
                      value: 'role:moderator',
                      child: Text('${l10n.t('group.change_role')}: moderator'),
                    ),
                    PopupMenuItem(
                      value: 'role:member',
                      child: Text('${l10n.t('group.change_role')}: member'),
                    ),
                  ]);
                }
                if (canModerateMember) {
                  items.add(
                    PopupMenuItem(
                      value: muted ? 'unmute' : 'mute',
                      child: Text(
                        muted ? l10n.t('group.unmute') : l10n.t('group.mute'),
                      ),
                    ),
                  );
                  items.add(
                    PopupMenuItem(
                      value: 'remove',
                      child: Text(l10n.t('group.remove_member')),
                    ),
                  );
                }
                if (canTransferOwnership) {
                  items.add(
                    PopupMenuItem(
                      key: Key('group-member-transfer-${member.user.userId}'),
                      value: 'transfer',
                      child: Text(l10n.t('group.transfer_ownership')),
                    ),
                  );
                }
                return items;
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
