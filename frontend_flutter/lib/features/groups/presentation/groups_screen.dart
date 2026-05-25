import 'package:flutter/material.dart';
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

class GroupsScreen extends ConsumerStatefulWidget {
  const GroupsScreen({super.key, this.initialTab = 0});

  final int initialTab;

  @override
  ConsumerState<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends ConsumerState<GroupsScreen>
    with TickerProviderStateMixin {
  late final TabController _tabController;
  final List<_GroupsTab> _tabs = [
    _GroupsTab(mode: 'discover', titleKey: 'group.discover'),
    _GroupsTab(mode: 'my', titleKey: 'group.my'),
    _GroupsTab(mode: 'invites', titleKey: 'group.invites'),
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: _tabs.length,
      vsync: this,
      initialIndex: widget.initialTab < 0
          ? 0
          : widget.initialTab >= _tabs.length
          ? _tabs.length - 1
          : widget.initialTab,
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('group.title'))),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppBreakpoints.contentMaxWidth,
          ),
          child: Column(
            children: [
              TabBar(
                controller: _tabController,
                tabs: _tabs.map((t) => Tab(text: l10n.t(t.titleKey))).toList(),
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _GroupsList(
                      mode: 'discover',
                      key: const PageStorageKey('disc'),
                    ),
                    _GroupsList(mode: 'my', key: const PageStorageKey('my')),
                    const _InvitesList(key: PageStorageKey('inv')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreateGroupDialog(context, ref),
        icon: const Icon(Icons.add),
        label: Text(l10n.t('common.create')),
      ),
    );
  }

  Future<void> _showCreateGroupDialog(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final name = TextEditingController();
    final description = TextEditingController();
    final tags = TextEditingController();
    String? avatarUrl;
    String? coverUrl;
    var privacy = 'public';
    var category = 'tech';
    var uploadingAvatar = false;
    var uploadingCover = false;
    final l10n = AppLocalizations.of(context);

    Future<void> pickImage({
      required bool cover,
      required void Function(void Function()) setDialogState,
    }) async {
      if (uploadingAvatar || uploadingCover) return;
      setDialogState(() {
        if (cover) {
          uploadingCover = true;
        } else {
          uploadingAvatar = true;
        }
      });
      try {
        final url = await pickAndUploadGroupImage(
          ref: ref,
          altText: name.text.trim(),
        );
        if (url == null) return;
        setDialogState(() {
          if (cover) {
            coverUrl = url;
          } else {
            avatarUrl = url;
          }
        });
      } catch (e) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
      } finally {
        if (context.mounted) {
          setDialogState(() {
            if (cover) {
              uploadingCover = false;
            } else {
              uploadingAvatar = false;
            }
          });
        }
      }
    }

    final result = await showDialog<_CreateGroupDraft>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(l10n.t('group.create_title')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    AppAvatar(url: avatarUrl, size: 64),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.t('group.avatar'),
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            l10n.t('group.avatar_hint'),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      key: const Key('group-create-avatar-button'),
                      tooltip: l10n.t('group.upload_avatar'),
                      onPressed: uploadingAvatar
                          ? null
                          : () => pickImage(
                              cover: false,
                              setDialogState: setDialogState,
                            ),
                      icon: uploadingAvatar
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.photo_camera_outlined),
                    ),
                    if (avatarUrl != null && avatarUrl!.isNotEmpty)
                      IconButton(
                        key: const Key('group-create-avatar-clear-button'),
                        tooltip: l10n.t('common.cancel'),
                        onPressed: uploadingAvatar
                            ? null
                            : () => setDialogState(() => avatarUrl = null),
                        icon: const Icon(Icons.close),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n.t('group.cover'),
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        IconButton(
                          key: const Key('group-create-cover-button'),
                          tooltip: l10n.t('group.upload_cover'),
                          onPressed: uploadingCover
                              ? null
                              : () => pickImage(
                                  cover: true,
                                  setDialogState: setDialogState,
                                ),
                          icon: uploadingCover
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.image_outlined),
                        ),
                        if (coverUrl != null && coverUrl!.isNotEmpty)
                          IconButton(
                            key: const Key('group-create-cover-clear-button'),
                            tooltip: l10n.t('common.cancel'),
                            onPressed: uploadingCover
                                ? null
                                : () => setDialogState(() => coverUrl = null),
                            icon: const Icon(Icons.close),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 108,
                      child: coverUrl == null || coverUrl!.isEmpty
                          ? DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest,
                              ),
                              child: Center(
                                child: Text(l10n.t('group.cover_hint')),
                              ),
                            )
                          : AppMediaImage(
                              url: coverUrl!,
                              height: 108,
                              width: double.infinity,
                              borderRadius: BorderRadius.circular(12),
                            ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('group-create-name-field'),
                  controller: name,
                  maxLength: 50,
                  decoration: InputDecoration(labelText: l10n.t('group.name')),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('group-create-description-field'),
                  controller: description,
                  maxLines: 3,
                  maxLength: 500,
                  decoration: InputDecoration(
                    labelText: l10n.t('group.description'),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const Key('group-create-privacy-field'),
                  initialValue: privacy,
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
                    setDialogState(() => privacy = value);
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const Key('group-create-category-field'),
                  initialValue: category,
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
                    setDialogState(() => category = value);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('group-create-tags-field'),
                  controller: tags,
                  maxLength: 160,
                  decoration: InputDecoration(
                    labelText: l10n.t('group.tags'),
                    hintText: l10n.t('group.tags_hint'),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.t('common.cancel')),
            ),
            FilledButton(
              onPressed: () {
                final groupName = name.text.trim();
                final groupDescription = description.text.trim();
                if (groupName.isEmpty || groupDescription.isEmpty) return;
                Navigator.pop(
                  context,
                  _CreateGroupDraft(
                    name: groupName,
                    description: groupDescription,
                    avatarUrl: avatarUrl,
                    coverUrl: coverUrl,
                    privacy: privacy,
                    category: category,
                    tags: groupDraftTags(tags.text),
                  ),
                );
              },
              child: Text(l10n.t('common.create')),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    try {
      final group = await ref
          .read(groupsApiProvider)
          .createGroup(
            name: result.name,
            description: result.description,
            avatarUrl: result.avatarUrl,
            coverUrl: result.coverUrl,
            privacy: result.privacy,
            category: result.category,
            tags: result.tags,
            joinApproval: result.privacy != 'public',
            postPermission: 'all',
          );
      if (!context.mounted) return;
      context.push('/groups/${group.slug}');
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }
}

class _CreateGroupDraft {
  const _CreateGroupDraft({
    required this.name,
    required this.description,
    this.avatarUrl,
    this.coverUrl,
    required this.privacy,
    required this.category,
    required this.tags,
  });

  final String name;
  final String description;
  final String? avatarUrl;
  final String? coverUrl;
  final String privacy;
  final String category;
  final List<String> tags;
}

class _GroupsTab {
  _GroupsTab({required this.mode, required this.titleKey});
  final String mode;
  final String titleKey;
}

class _GroupsList extends ConsumerStatefulWidget {
  const _GroupsList({super.key, required this.mode});
  final String mode;

  @override
  ConsumerState<_GroupsList> createState() => _GroupsListState();
}

class _GroupsListState extends ConsumerState<_GroupsList>
    with AutomaticKeepAliveClientMixin {
  List<V2Group> _items = [];
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
      final api = ref.read(groupsApiProvider);
      final page = widget.mode == 'my'
          ? await api.myGroups()
          : await api.list(mode: widget.mode);
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

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    if (_loading) return const LoadingView();
    if (_error != null) return ErrorView(error: _error!, onRetry: _load);
    if (_items.isEmpty) {
      return EmptyView(message: l10n.t('group.empty'));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: _items.length,
        separatorBuilder: (_, _) =>
            Divider(height: 1, color: theme.dividerColor),
        itemBuilder: (_, i) {
          final g = _items[i];
          return InkWell(
            onTap: () => context.push('/groups/${g.slug}'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: [
                  AppAvatar(url: g.avatarUrl, size: 48),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          g.name,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          g.description.isEmpty ? '@${g.slug}' : g.description,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.people_outline,
                            size: 14,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${g.memberCount}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        g.privacyDesc.isEmpty ? g.privacy : g.privacyDesc,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _InvitesList extends ConsumerStatefulWidget {
  const _InvitesList({super.key});

  @override
  ConsumerState<_InvitesList> createState() => _InvitesListState();
}

class _InvitesListState extends ConsumerState<_InvitesList>
    with AutomaticKeepAliveClientMixin {
  List<V2GroupInvite> _items = [];
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
      final page = await ref.read(groupsApiProvider).myInvites();
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

  Future<void> _respond(V2GroupInvite invite, String action) async {
    try {
      await ref
          .read(groupsApiProvider)
          .respondInvite(inviteId: invite.inviteId, action: action);
      if (!mounted) return;
      setState(() => _items.removeWhere((i) => i.inviteId == invite.inviteId));
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
    final theme = Theme.of(context);
    if (_loading) return const LoadingView();
    if (_error != null) return ErrorView(error: _error!, onRetry: _load);
    if (_items.isEmpty) {
      return EmptyView(message: l10n.t('group.invites_empty'));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: _items.length,
        separatorBuilder: (_, _) =>
            Divider(height: 1, color: theme.dividerColor),
        itemBuilder: (_, i) {
          final inv = _items[i];
          final group = inv.group;
          final groupName = group != null
              ? (group['name'] as String? ?? l10n.t('group.group'))
              : l10n.t('group.group');
          final message = inv.message ?? '';
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppAvatar(
                  url: group != null ? group['avatar_url'] as String? : null,
                  size: 44,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        groupName,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${l10n.t('group.invite_from')} @${inv.inviter.username}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (message.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          message,
                          style: theme.textTheme.bodyMedium,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                Column(
                  children: [
                    IconButton(
                      tooltip: l10n.t('common.confirm'),
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.check, color: theme.colorScheme.primary),
                      onPressed: () => _respond(inv, 'accept'),
                    ),
                    IconButton(
                      tooltip: l10n.t('common.cancel'),
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.close, color: theme.colorScheme.error),
                      onPressed: () => _respond(inv, 'decline'),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
