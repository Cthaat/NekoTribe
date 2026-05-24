import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/app_avatar.dart';
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
      appBar: AppBar(
        title: const Text('Groups'),
        bottom: TabBar(
          controller: _tabController,
          tabs: _tabs.map((t) => Tab(text: l10n.t(t.titleKey))).toList(),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _GroupsList(mode: 'discover', key: const PageStorageKey('disc')),
          _GroupsList(mode: 'my', key: const PageStorageKey('my')),
          const _InvitesList(key: PageStorageKey('inv')),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showCreateGroupDialog(context, ref),
        child: const Icon(Icons.add),
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
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Create group'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              TextField(
                controller: slug,
                decoration: const InputDecoration(labelText: 'Slug'),
              ),
              TextField(
                controller: description,
                decoration: const InputDecoration(labelText: 'Description'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, {
              'name': name.text.trim(),
              'slug': slug.text.trim(),
              'description': description.text.trim(),
            }),
            child: const Text('Create'),
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
    if (_loading) return const LoadingView();
    if (_error != null) return ErrorView(error: _error!, onRetry: _load);
    if (_items.isEmpty) {
      return const EmptyView(message: 'No groups');
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: _items.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final g = _items[i];
          return ListTile(
            leading: AppAvatar(url: g.avatarUrl, size: 48),
            title: Text(g.name),
            subtitle: Text(
              g.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('${g.memberCount}'),
                Text(
                  g.privacyDesc.isEmpty ? g.privacy : g.privacyDesc,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            onTap: () => context.push('/groups/${g.slug}'),
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
    if (_loading) return const LoadingView();
    if (_error != null) return ErrorView(error: _error!, onRetry: _load);
    if (_items.isEmpty) {
      return const EmptyView(message: 'No invites');
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: _items.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final inv = _items[i];
          final group = inv.group;
          return ListTile(
            leading: AppAvatar(
              url: group != null ? group['avatar_url'] as String? : null,
              size: 48,
            ),
            title: Text(
              group != null ? (group['name'] as String? ?? '') : 'Group',
            ),
            subtitle: Text(
              'From @${inv.inviter.username} · ${inv.message ?? ''}',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.check, color: Colors.green),
                  onPressed: () => _respond(inv, 'accept'),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.red),
                  onPressed: () => _respond(inv, 'decline'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
