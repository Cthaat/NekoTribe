import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/group_models.dart';

class GroupsScreen extends ConsumerStatefulWidget {
  const GroupsScreen({super.key});

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
    _tabController = TabController(length: _tabs.length, vsync: this);
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
    final slug = TextEditingController();
    final description = TextEditingController();
    final l10n = AppLocalizations.of(context);
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.t('group.create_title')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: InputDecoration(labelText: l10n.t('group.name')),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: slug,
                decoration: InputDecoration(labelText: l10n.t('group.slug')),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: description,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: l10n.t('group.description'),
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
            onPressed: () => Navigator.pop(context, {
              'name': name.text.trim(),
              'slug': slug.text.trim(),
              'description': description.text.trim(),
            }),
            child: Text(l10n.t('common.create')),
          ),
        ],
      ),
    );
    name.dispose();
    slug.dispose();
    description.dispose();
    if (result == null || result['name']!.isEmpty || result['slug']!.isEmpty) {
      return;
    }
    try {
      final group = await ref.read(groupsApiProvider).createGroup(result);
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
                          g.description.isEmpty
                              ? '@${g.slug}'
                              : g.description,
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
