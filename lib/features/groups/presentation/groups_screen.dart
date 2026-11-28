import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/theme/tokens.dart';
import '../../../shared/widgets/glass/liquid_glass_bars.dart';
import '../../../shared/widgets/glass/liquid_glass_overlays.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../../../shared/widgets/ui/surface_card.dart';
import '../../../core/network/api_response.dart';
import '../domain/group_draft_metadata.dart';
import '../domain/group_models.dart';
import 'group_image_upload.dart';

class GroupsScreen extends ConsumerStatefulWidget {
  const GroupsScreen({super.key, this.initialTab = 0, this.inviteId});

  final int initialTab;
  final int? inviteId;

  @override
  ConsumerState<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends ConsumerState<GroupsScreen>
    with TickerProviderStateMixin {
  late final TabController _tabController;
  int _membershipRevision = 0;
  final List<_GroupsTab> _tabs = [
    _GroupsTab(mode: 'discover', titleKey: 'group.discover'),
    _GroupsTab(mode: 'my', titleKey: 'group.my'),
    _GroupsTab(mode: 'invites', titleKey: 'group.invites'),
    _GroupsTab(mode: 'popular', titleKey: 'group.popular'),
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
    final theme = Theme.of(context);
    final social = SocialColors.of(context);
    final dockInset = MediaQuery.sizeOf(context).width < AppBreakpoints.medium
        ? 80.0
        : 0.0;
    return Scaffold(
      backgroundColor: social.surfaceBase,
      extendBodyBehindAppBar: true,
      appBar: LiquidGlassAppBar(
        automaticallyImplyLeading:
            ModalRoute.of(context)?.impliesAppBarDismissal ?? false,
        title: Text(
          l10n.t('group.title'),
          style: theme.textTheme.titleLarge?.copyWith(
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          if (widget.inviteId != null)
            TextButton(
              onPressed: () => context.replace('/groups/invites'),
              child: Text(l10n.t('group.invites_view_all')),
            ),
          IconButton(
            tooltip: l10n.t('group.invite_input'),
            icon: const Icon(Icons.link),
            onPressed: () => context.push('/groups/invite'),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppBreakpoints.wideContentMaxWidth,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: AnimatedBuilder(
                  animation: _tabController,
                  builder: (context, _) => LiquidGlassSegmentedControl<int>(
                    options: [
                      for (final (index, tab) in _tabs.indexed)
                        (index, l10n.t(tab.titleKey)),
                    ],
                    tabController: _tabController,
                    selected: _tabController.index,
                    onSelect: _tabController.animateTo,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppBreakpoints.wideContentMaxWidth,
          ),
          child: TabBarView(
            controller: _tabController,
            children: [
              _GroupsList(
                mode: 'discover',
                key: const PageStorageKey('disc'),
                emptyMessageKey: 'group.empty',
                emptyActionLabelKey: 'common.create',
                onEmptyAction: () =>
                    unawaited(_showCreateGroupDialog(context, ref)),
              ),
              _GroupsList(
                mode: 'my',
                key: PageStorageKey(('my', _membershipRevision)),
                emptyMessageKey: 'group.empty_my',
                emptyActionLabelKey: 'group.discover',
                onEmptyAction: () => _tabController.animateTo(0),
              ),
              _InvitesList(
                key: PageStorageKey(('inv', widget.inviteId)),
                inviteId: widget.inviteId,
                onAccepted: () => setState(() => _membershipRevision++),
              ),
              const _GroupsList(
                mode: 'popular',
                key: PageStorageKey('popular'),
                emptyMessageKey: 'group.empty',
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: Padding(
        padding: EdgeInsets.only(bottom: dockInset),
        child: LiquidGlassFab(
          label: l10n.t('common.create'),
          icon: Icons.add,
          onPressed: () => _showCreateGroupDialog(context, ref),
        ),
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
    // Controllers may still be referenced during route teardown.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      name.dispose();
      description.dispose();
      tags.dispose();
    });
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

typedef _GroupFilter = ({String search, String? privacy, String? category});

const _noGroupFilter = (search: '', privacy: null, category: null);

class _GroupsList extends ConsumerStatefulWidget {
  const _GroupsList({
    super.key,
    required this.mode,
    required this.emptyMessageKey,
    this.emptyActionLabelKey,
    this.onEmptyAction,
  });
  final String mode;
  final String emptyMessageKey;
  final String? emptyActionLabelKey;
  final VoidCallback? onEmptyAction;

  @override
  ConsumerState<_GroupsList> createState() => _GroupsListState();
}

class _GroupsListState extends ConsumerState<_GroupsList>
    with AutomaticKeepAliveClientMixin {
  List<V2Group> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasNext = false;
  int _page = 1;
  int _request = 0;
  bool _expired = false;
  _GroupFilter _filter = _noGroupFilter;
  late final VoidCallback _stopSessionListener;
  Object? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    final tokens = ref.read(tokenStoreProvider);
    _expired = tokens.isSessionChanging;
    _stopSessionListener = tokens.listenSessionChanges(_expire);
    _load();
  }

  @override
  void dispose() {
    _stopSessionListener();
    super.dispose();
  }

  void _expire() {
    if (!mounted || _expired) return;
    _request++;
    setState(() {
      _expired = true;
      _items = [];
      _filter = _noGroupFilter;
    });
  }

  Future<PagedResult<V2Group>> _fetchPage(int page) async {
    final api = ref.read(groupsApiProvider);
    if (widget.mode == 'popular') {
      return PagedResult(items: await api.popular());
    }
    final (:search, :privacy, :category) = _filter;
    return widget.mode == 'my'
        ? api.myGroups(
            page: page,
            search: search,
            privacy: privacy,
            category: category,
          )
        : api.list(
            mode: widget.mode,
            page: page,
            search: search,
            privacy: privacy,
            category: category,
          );
  }

  Future<void> _editFilters() async {
    if (_expired) return;
    var (:search, :privacy, :category) = _filter;
    final l10n = AppLocalizations.of(context);
    final choice = await showDialog<_GroupFilter>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(l10n.t('group.filter.title')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  initialValue: search,
                  onChanged: (value) => search = value,
                  decoration: InputDecoration(
                    labelText: l10n.t('group.filter.search'),
                  ),
                ),
                DropdownButtonFormField<String>(
                  initialValue: privacy ?? '',
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: l10n.t('group.privacy'),
                  ),
                  onChanged: (value) =>
                      update(() => privacy = value == '' ? null : value),
                  items: [
                    DropdownMenuItem(
                      value: '',
                      child: Text(l10n.t('group.filter.all')),
                    ),
                    for (final value in ['public', 'private', 'secret'])
                      DropdownMenuItem(
                        value: value,
                        child: Text(l10n.t('group.privacy.$value')),
                      ),
                  ],
                ),
                DropdownButtonFormField<String>(
                  initialValue: category ?? '',
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: l10n.t('group.category'),
                  ),
                  onChanged: (value) =>
                      update(() => category = value == '' ? null : value),
                  items: [
                    DropdownMenuItem(
                      value: '',
                      child: Text(l10n.t('group.filter.all')),
                    ),
                    for (final value in [
                      'tech',
                      'game',
                      'music',
                      'art',
                      'life',
                      'study',
                      'work',
                      'other',
                    ])
                      DropdownMenuItem(
                        value: value,
                        child: Text(l10n.t('group.category.$value')),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, _noGroupFilter),
              child: Text(l10n.t('group.filter.clear')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, (
                search: search.trim(),
                privacy: privacy,
                category: category,
              )),
              child: Text(l10n.t('group.filter.apply')),
            ),
          ],
        ),
      ),
    );
    if (!mounted || _expired || choice == null || choice == _filter) return;
    _filter = choice;
    await _load();
  }

  Future<void> _load() async {
    if (_expired) return;
    final request = ++_request;
    setState(() {
      _items = [];
      _loadingMore = false;
      _loading = true;
      _error = null;
      _page = 1;
      _hasNext = false;
    });
    try {
      final page = await _fetchPage(1);
      if (!mounted || request != _request) return;
      setState(() {
        _items = page.items;
        _page = 1;
        _hasNext = page.hasNext;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = e;
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_expired || _loadingMore || !_hasNext || _loading) return;
    final request = _request;
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final page = await _fetchPage(next);
      if (!mounted || request != _request) return;
      setState(() {
        _items = {
          for (final item in [..._items, ...page.items]) item.groupId: item,
        }.values.toList();
        _page = next;
        _hasNext = page.hasNext;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    ref.listen(groupsApiProvider, (previous, next) {
      if (!identical(previous, next)) _expire();
    });
    final l10n = AppLocalizations.of(context);
    if (_expired) {
      return EmptyView(message: l10n.t('visibility.sessionChanged'));
    }
    final topInset = MediaQuery.paddingOf(context).top;
    if (widget.mode == 'popular') {
      return _buildResults(context, filtered: false, topInset: topInset);
    }
    final filtered = _filter != _noGroupFilter;
    final social = SocialColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildResults(context, filtered: filtered, topInset: topInset + 52),
        Positioned(
          left: 16,
          right: 16,
          top: topInset + 10,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              InkWell(
                onTap: _editFilters,
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: filtered ? social.primarySoft : social.surfaceCard,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Badge(
                        isLabelVisible: filtered,
                        smallSize: 7,
                        child: Icon(
                          Icons.tune_rounded,
                          size: 16,
                          color: filtered
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        l10n.t(
                          filtered
                              ? 'group.filter.active'
                              : 'group.filter.title',
                        ),
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: filtered
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildResults(
    BuildContext context, {
    required bool filtered,
    required double topInset,
  }) {
    final l10n = AppLocalizations.of(context);
    if (_loading) return const LoadingView();
    if (_error != null) return ErrorView(error: _error!, onRetry: _load);
    if (_items.isEmpty && !_hasNext) {
      if (widget.mode == 'popular') {
        return EmptyView(
          message: l10n.t(widget.emptyMessageKey),
          actionLabel: l10n.t('common.retry'),
          onAction: _load,
        );
      }
      if (filtered) {
        return EmptyView(
          message: l10n.t('group.filter.empty'),
          actionLabel: l10n.t('group.filter.clear'),
          onAction: () {
            _filter = _noGroupFilter;
            _load();
          },
        );
      }
      final actionLabelKey = widget.emptyActionLabelKey;
      return EmptyView(
        message: l10n.t(widget.emptyMessageKey),
        actionLabel: actionLabelKey == null ? null : l10n.t(actionLabelKey),
        onAction: widget.onEmptyAction,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = widget.mode == 'popular'
            ? 1
            : (constraints.maxWidth / 340).floor().clamp(1, 3);
        return RefreshIndicator(
          onRefresh: _load,
          edgeOffset: topInset,
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
                unawaited(_loadMore());
              }
              return false;
            },
            child: CustomScrollView(
              physics: widget.mode == 'popular'
                  ? const AlwaysScrollableScrollPhysics()
                  : null,
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(16, topInset + 8, 16, 108),
                  sliver: SliverGrid.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      mainAxisExtent: 204,
                    ),
                    itemCount: _items.length,
                    itemBuilder: (context, i) {
                      final g = _items[i];
                      final privacyLabel = g.privacyDesc.isNotEmpty
                          ? g.privacyDesc
                          : switch (g.privacy) {
                              'public' => l10n.t('group.privacy.public'),
                              'private' => l10n.t('group.privacy.private'),
                              'secret' => l10n.t('group.privacy.secret'),
                              _ => g.privacy,
                            };
                      return _GroupSocialCard(
                        group: g,
                        privacyLabel: privacyLabel,
                        onTap: () async {
                          await context.push('/groups/${g.slug}');
                          if (mounted && !_expired) await _load();
                        },
                      );
                    },
                  ),
                ),
                if (_hasNext)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Center(
                        child: _loadingMore
                            ? const CircularProgressIndicator()
                            : OutlinedButton(
                                onPressed: _loadMore,
                                child: Text(l10n.t('common.more')),
                              ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _InvitesList extends ConsumerStatefulWidget {
  const _InvitesList({super.key, required this.onAccepted, this.inviteId});

  final VoidCallback onAccepted;
  final int? inviteId;

  @override
  ConsumerState<_InvitesList> createState() => _InvitesListState();
}

class _InvitesListState extends ConsumerState<_InvitesList>
    with AutomaticKeepAliveClientMixin {
  List<V2GroupInvite> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasNext = false;
  int _page = 1;
  int _loadVersion = 0;
  bool _responding = false;
  bool _expired = false;
  late final VoidCallback _stopInviteSessionListener;
  Object? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    final store = ref.read(tokenStoreProvider);
    _expired = store.isSessionChanging;
    _stopInviteSessionListener = store.listenSessionChanges(_expire);
    _load();
  }

  @override
  void dispose() {
    _stopInviteSessionListener();
    super.dispose();
  }

  void _expire() {
    if (!mounted || _expired) return;
    _loadVersion++;
    setState(() {
      _expired = true;
      _items = [];
      _hasNext = false;
      _responding = false;
    });
  }

  Future<void> _load() async {
    if (!mounted || _expired) return;
    final version = ++_loadVersion;
    setState(() {
      _loading = true;
      _error = null;
      _page = 1;
      _hasNext = false;
    });
    try {
      final id = widget.inviteId;
      final page = await ref
          .read(groupsApiProvider)
          .myInvites(page: 1, inviteId: id);
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _items = id == null
            ? page.items
            : page.items.where((item) => item.inviteId == id).toList();
        _page = 1;
        _hasNext = id == null && page.hasNext;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _error = e;
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (!mounted ||
        _expired ||
        _responding ||
        _loadingMore ||
        !_hasNext ||
        _loading) {
      return;
    }
    final version = _loadVersion;
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final page = await ref.read(groupsApiProvider).myInvites(page: next);
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _items = {
          for (final invite in _items) invite.inviteId: invite,
          for (final invite in page.items) invite.inviteId: invite,
        }.values.toList();
        _page = next;
        _hasNext = page.hasNext;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || version != _loadVersion) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _respond(V2GroupInvite invite, bool accept) async {
    if (_expired || _responding || _loading || _loadingMore) return;
    final groupId = invite.group?['group_id'];
    if (groupId is! int || groupId <= 0 || invite.inviteId <= 0) return;
    setState(() => _responding = true);
    final l10n = AppLocalizations.of(context);
    try {
      final receipt = await ref
          .read(groupsApiProvider)
          .respondInvite(inviteId: invite.inviteId, accept: accept);
      if (!mounted || _expired) return;
      if (receipt.inviteId != invite.inviteId ||
          receipt.groupId != groupId ||
          receipt.status != (accept ? 'accepted' : 'rejected')) {
        throw const FormatException('Invalid invite response');
      }
      final key = accept
          ? 'group.invite_response.accepted'
          : 'group.invite_response.rejected';
      final slug = invite.group?['slug'];
      if (accept) widget.onAccepted();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.t(key)),
          action:
              accept &&
                  slug is String &&
                  slug.trim().isNotEmpty &&
                  slug != '.' &&
                  slug != '..' &&
                  !slug.contains('/') &&
                  !slug.contains('\\')
              ? SnackBarAction(
                  label: l10n.t('group.invite_open_group'),
                  onPressed: () {
                    if (mounted && !_expired) {
                      context.push('/groups/${Uri.encodeComponent(slug)}');
                    }
                  },
                )
              : null,
        ),
      );
    } catch (_) {
      if (!mounted || _expired) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t('group.invite_response.unknown'))),
      );
    } finally {
      if (mounted && !_expired) {
        await _load();
        if (mounted && !_expired) setState(() => _responding = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    ref.listen(groupsApiProvider, (previous, next) {
      if (!identical(previous, next)) _expire();
    });
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    if (_expired) {
      return EmptyView(message: l10n.t('visibility.sessionChanged'));
    }
    if (_loading) return const LoadingView();
    if (_error != null) return ErrorView(error: _error!, onRetry: _load);
    if (_items.isEmpty && !_hasNext) {
      return EmptyView(
        message: l10n.t(
          widget.inviteId == null
              ? 'group.invites_empty'
              : 'group.invites_target_unavailable',
        ),
      );
    }
    final topInset = MediaQuery.paddingOf(context).top;
    return RefreshIndicator(
      edgeOffset: topInset,
      onRefresh: () async {
        if (!_responding) await _load();
      },
      child: ListView.builder(
        padding: EdgeInsets.fromLTRB(16, topInset + 8, 16, 108),
        itemCount: _items.length + (_hasNext ? 1 : 0),
        itemBuilder: (_, i) {
          if (i >= _items.length) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: _loadingMore
                    ? const SizedBox.square(
                        dimension: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : FilledButton.tonal(
                        style: FilledButton.styleFrom(
                          shape: const StadiumBorder(),
                        ),
                        onPressed: _responding ? null : _loadMore,
                        child: Text(l10n.t('common.more')),
                      ),
              ),
            );
          }
          final inv = _items[i];
          final group = inv.group;
          final groupName = group != null
              ? (group['name'] as String? ?? l10n.t('group.group'))
              : l10n.t('group.group');
          final message = inv.message ?? '';
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SurfaceCard(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppAvatar(
                    url: group != null ? group['avatar_url'] as String? : null,
                    size: 44,
                    name: groupName,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          groupName,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
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
                          const SizedBox(height: 6),
                          Text(
                            message,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              height: 1.55,
                            ),
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
                        tooltip: l10n.t('group.invite_response.accept'),
                        visualDensity: VisualDensity.compact,
                        color: theme.colorScheme.primary,
                        icon: const Icon(Icons.check_rounded),
                        onPressed: _responding || _loadingMore
                            ? null
                            : () => _respond(inv, true),
                      ),
                      IconButton(
                        tooltip: l10n.t('group.invite_response.reject'),
                        visualDensity: VisualDensity.compact,
                        color: theme.colorScheme.error,
                        icon: const Icon(Icons.close_rounded),
                        onPressed: _responding || _loadingMore
                            ? null
                            : () => _respond(inv, false),
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

class _GroupSocialCard extends StatelessWidget {
  const _GroupSocialCard({
    required this.group,
    required this.privacyLabel,
    required this.onTap,
  });

  final V2Group group;
  final String privacyLabel;
  final VoidCallback onTap;

  String _initialFor(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'G';
    return String.fromCharCode(trimmed.runes.first).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final g = group;
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final social = SocialColors.of(context);
    final initial = _initialFor(g.name);
    final hasCover = g.coverUrl != null && g.coverUrl!.trim().isNotEmpty;
    final hasAvatar = g.avatarUrl != null && g.avatarUrl!.trim().isNotEmpty;

    return SurfaceCard(
      radius: AppRadius.card,
      padding: EdgeInsets.zero,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasCover)
            Hero(
              tag: 'group-cover-${g.groupId}',
              child: SizedBox(
                height: 68,
                width: double.infinity,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    AppMediaImage(
                      url: g.coverUrl!,
                      width: double.infinity,
                      height: 68,
                      borderRadius: BorderRadius.zero,
                    ),
                    Positioned(
                      right: 10,
                      top: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: social.surfaceCard.withValues(alpha: 0.88),
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                        child: Text(
                          privacyLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, hasCover ? 12 : 16, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: social.surfaceSubtle,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: hasAvatar
                            ? AppMediaImage(
                                url: g.avatarUrl!,
                                width: 44,
                                height: 44,
                                borderRadius: BorderRadius.circular(14),
                              )
                            : Center(
                                child: Text(
                                  initial,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          g.name,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (!hasCover) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: social.surfaceSubtle,
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                          ),
                          child: Text(
                            privacyLabel,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    g.description.isEmpty ? '@${g.slug}' : g.description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontSize: 13,
                      height: 1.55,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const Spacer(),
                  Row(
                    children: [
                      Icon(
                        Icons.people_outline_rounded,
                        size: 14,
                        color: social.inkTertiary,
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          '${g.memberCount} ${l10n.t('group.members')}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: social.inkTertiary,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: g.membership.isMember
                              ? social.surfaceSubtle
                              : social.primarySoft,
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                        child: Text(
                          g.membership.isMember
                              ? '${l10n.t('group.joined_check')} ✓'
                              : l10n.t('group.join'),
                          style: TextStyle(
                            color: g.membership.isMember
                                ? scheme.onSurfaceVariant
                                : scheme.primary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
