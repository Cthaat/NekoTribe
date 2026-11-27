import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/api_response.dart';
import '../../../core/utils/ai_conversation_link.dart';
import '../../../core/utils/group_post_link.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/motion/entrance.dart';
import '../../../shared/motion/skeleton.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/routing/auth_navigation.dart';
import '../../../shared/theme/tokens.dart';
import '../../../shared/widgets/glass/liquid_glass_bars.dart';
import '../../../shared/widgets/glass/liquid_glass_surface.dart';
import '../../../shared/widgets/glass/liquid_glass_tokens.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../../../shared/widgets/ui/surface_card.dart';
import '../../groups/domain/group_models.dart';
import '../../groups/presentation/group_post_card.dart';
import '../domain/post_models.dart';
import 'post_card.dart';
import 'compose_post_screen.dart';
import 'report_dialog.dart';

enum _HomeFeedTab {
  recommended,
  following,
  trending,
  groups;

  bool get requiresAuth => this == following || this == groups;
}

class FeedScreen extends ConsumerStatefulWidget {
  const FeedScreen({super.key});

  @override
  ConsumerState<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends ConsumerState<FeedScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  late final VoidCallback _stopSessionListener;
  final _postTabs = <_HomeFeedTab, _FeedTabState<V2Post>>{
    _HomeFeedTab.recommended: _FeedTabState(),
    _HomeFeedTab.following: _FeedTabState(),
    _HomeFeedTab.trending: _FeedTabState(),
  };
  _FeedTabState<V2GroupPost> _groups = _FeedTabState();
  final _pendingGroupLikes = <(int, int)>{};
  bool _fabVisible = true;

  _HomeFeedTab get _selected => _HomeFeedTab.values[_tab.index];

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: _HomeFeedTab.values.length, vsync: this);
    _tab.addListener(() {
      if (_tab.indexIsChanging) return;
      if (mounted) setState(() {});
      _load(_selected);
    });
    _stopSessionListener = ref
        .read(tokenStoreProvider)
        .listenSessionChanges(_resetFeed);
    ref.listenManual(postsApiProvider, (_, _) => _resetFeed());
    ref.listenManual(groupsApiProvider, (_, _) => _resetFeed());
    ref.listenManual(authSessionProvider, (previous, next) {
      if (previous?.isAuthenticated != next.isAuthenticated) _resetFeed();
    });
    _load(_selected);
  }

  @override
  void dispose() {
    _stopSessionListener();
    _tab.dispose();
    super.dispose();
  }

  void _resetFeed() {
    if (!mounted) return;
    setState(() {
      _postTabs.updateAll((_, _) => _FeedTabState());
      _groups = _FeedTabState();
      _pendingGroupLikes.clear();
    });
    unawaited(_load(_selected));
  }

  bool _isCurrent(_HomeFeedTab tab, Object state) =>
      mounted &&
      identical(tab == _HomeFeedTab.groups ? _groups : _postTabs[tab], state) &&
      !ref.read(tokenStoreProvider).isSessionChanging;

  Future<void> _load(_HomeFeedTab tab, {bool more = false}) async {
    if (tab.requiresAuth && !ref.read(authSessionProvider).isAuthenticated) {
      return;
    }
    if (tab == _HomeFeedTab.groups) {
      final api = ref.read(groupsApiProvider);
      return _readPage(
        tab,
        _groups,
        (page) => api.homeActivity(page: page),
        _groupKey,
        more,
      );
    }
    final api = ref.read(postsApiProvider);
    return _readPage(
      tab,
      _postTabs[tab]!,
      (page) => tab == _HomeFeedTab.trending
          ? api.getTrendingPage(page: page)
          : api.getFeed(mode: tab.name, page: page),
      (post) => post.postId,
      more,
    );
  }

  Future<void> _readPage<T>(
    _HomeFeedTab tab,
    _FeedTabState<T> state,
    Future<PagedResult<T>> Function(int page) fetch,
    Object Function(T entry) itemKey,
    bool more,
  ) async {
    if (!_isCurrent(tab, state) ||
        state.loading ||
        (more ? !state.hasMore : state.loaded)) {
      return;
    }
    setState(() {
      state.loading = true;
      state.error = null;
      state.nextPageFailed = false;
    });
    try {
      final next = more ? state.page + 1 : 1;
      final page = await fetch(next);
      if (!_isCurrent(tab, state)) return;
      if (!more) state.items.clear();
      final seen = state.items.map(itemKey).toSet();
      state.items.addAll(page.items.where((entry) => seen.add(itemKey(entry))));
      state.page = next;
      state.loaded = true;
      state.hasMore = page.hasNext;
    } catch (error) {
      if (!_isCurrent(tab, state)) return;
      if (more) {
        state.nextPageFailed = true;
        if (_selected == tab) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(ErrorView.describe(context, error))),
          );
        }
      } else {
        state.error = error;
      }
    } finally {
      state.loading = false;
      if (_isCurrent(tab, state)) setState(() {});
    }
  }

  Future<void> _refresh(_HomeFeedTab tab) async {
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android)) {
      HapticFeedback.selectionClick();
    }
    setState(() {
      if (tab == _HomeFeedTab.groups) {
        _groups = _FeedTabState();
        _pendingGroupLikes.clear();
      } else {
        _postTabs[tab] = _FeedTabState();
      }
    });
    await _load(tab);
  }

  void _showRecommendedInfo() {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => LiquidGlassSurface(
        preset: LiquidGlassPreset.popover,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.canvas),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.t('feed.recommended_info_title'),
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  l10n.t('feed.recommended_explanation'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _compose() async {
    if (!requireAuthenticatedAction(context, ref)) return;
    const tab = _HomeFeedTab.recommended;
    final state = _postTabs[tab]!;
    final created = await Navigator.of(context).push<V2Post>(
      MaterialPageRoute(builder: (_) => const ComposePostScreen()),
    );
    if (created != null && _isCurrent(tab, state) && state.loaded) {
      setState(() {
        state.items.removeWhere((post) => post.postId == created.postId);
        state.items.insert(0, created);
      });
    }
  }

  (int, int) _groupKey(V2GroupPost post) => (post.groupId, post.postId);

  Future<void> _likeGroupPost(
    _FeedTabState<V2GroupPost> state,
    V2GroupPost post,
  ) async {
    const tab = _HomeFeedTab.groups;
    final key = _groupKey(post);
    if (!_isCurrent(tab, state) ||
        _pendingGroupLikes.contains(key) ||
        !requireAuthenticatedAction(context, ref)) {
      return;
    }
    setState(() => _pendingGroupLikes.add(key));
    try {
      final receipt = await ref
          .read(groupsApiProvider)
          .setGroupPostLikeStatus(
            groupId: post.groupId,
            postId: post.postId,
            liked: !post.isLikedByMe,
          );
      if (!_isCurrent(tab, state)) return;
      final index = state.items.indexWhere((item) => _groupKey(item) == key);
      if (index >= 0) {
        setState(
          () => state.items[index] = state.items[index].copyWith(
            isLikedByMe: receipt.liked,
            likesCount: receipt.count,
          ),
        );
      }
    } catch (error) {
      if (!_isCurrent(tab, state)) return;
      if (error is ApiException && error.isNotFound) {
        setState(
          () => state.items.removeWhere((item) => _groupKey(item) == key),
        );
      }
      if (_selected == tab) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorView.describe(context, error))),
        );
      }
    } finally {
      if (_isCurrent(tab, state)) {
        setState(() => _pendingGroupLikes.remove(key));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final session = ref.watch(authSessionProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final social = SocialColors.of(context);
    final isWide = AppBreakpoints.isMedium(context);

    final mqPadding = MediaQuery.paddingOf(context);
    final mqViewPadding = MediaQuery.viewPaddingOf(context);
    final dockInset = (mqPadding.bottom - mqViewPadding.bottom).clamp(
      0.0,
      200.0,
    );

    final headerActions = <Widget>[
      if (_selected == _HomeFeedTab.recommended)
        LiquidGlassIconButton(
          key: const Key('feed-recommended-info-button'),
          tooltip: l10n.t('feed.recommended_explanation'),
          icon: Icon(
            Icons.info_outline_rounded,
            size: 19,
            color: scheme.onSurfaceVariant,
          ),
          onPressed: _showRecommendedInfo,
        ),
      LiquidGlassIconButton(
        key: const Key('feed-ai-knowledge-button'),
        tooltip: l10n.t('ai.knowledge.title'),
        icon: const Icon(Icons.library_books_outlined),
        onPressed: () {
          if (requireAuthenticatedAction(context, ref)) {
            openAiConversation(context, knowledge: true);
          }
        },
      ),
      LiquidGlassIconButton(
        key: const Key('feed-ai-writing-button'),
        tooltip: l10n.t('ai.writing.title'),
        icon: const Icon(Icons.auto_awesome_outlined),
        onPressed: () {
          if (requireAuthenticatedAction(context, ref)) {
            openAiConversation(context);
          }
        },
      ),
      LiquidGlassIconButton(
        key: const Key('feed-search-button'),
        tooltip: l10n.t('tab.discover'),
        icon: const Icon(Icons.search_rounded),
        onPressed: () => context.push('/discover'),
      ),
    ];

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: social.surfaceBase,
      floatingActionButton: isWide
          ? null
          : Padding(
              padding: EdgeInsets.only(bottom: dockInset, right: 4),
              child: AnimatedSlide(
                offset: _fabVisible ? Offset.zero : const Offset(0, 1.8),
                duration: AppMotion.resolve(context, AppMotion.glide),
                curve: AppMotion.curve,
                child: AnimatedScale(
                  scale: _fabVisible ? 1.0 : 0.72,
                  duration: AppMotion.resolve(context, AppMotion.glide),
                  curve: AppMotion.curve,
                  child: Tooltip(
                    message: l10n.t('common.post'),
                    excludeFromSemantics: true,
                    child: Semantics(
                      button: true,
                      label: l10n.t('common.post'),
                      child: SizedBox.square(
                        dimension: 50,
                        child: LiquidGlassSurface(
                          preset: LiquidGlassPreset.iconButton,
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                          interactive: true,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: scheme.primary.withValues(
                                alpha: theme.brightness == Brightness.dark
                                    ? 0.24
                                    : 0.86,
                              ),
                            ),
                            child: Material(
                              type: MaterialType.transparency,
                              child: InkWell(
                                customBorder: const CircleBorder(),
                                onTap: _compose,
                                child: Center(
                                  child: Icon(
                                    Icons.edit_rounded,
                                    size: 22,
                                    color: theme.brightness == Brightness.dark
                                        ? scheme.primary
                                        : scheme.onPrimary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
      body: NotificationListener<ScrollUpdateNotification>(
        onNotification: (n) {
          if (isWide || n.metrics.axis != Axis.vertical) return false;
          final delta = n.scrollDelta ?? 0;
          if (delta > 10 && _fabVisible) {
            setState(() => _fabVisible = false);
          } else if ((delta < -10 || n.metrics.pixels <= 16) && !_fabVisible) {
            setState(() => _fabVisible = true);
          }
          return false;
        },
        child: NestedScrollView(
          floatHeaderSlivers: true,
          headerSliverBuilder: (context, innerBoxIsScrolled) => [
            SliverAppBar(
              floating: true,
              snap: true,
              pinned: true,
              elevation: 0,
              scrolledUnderElevation: 0,
              backgroundColor: Colors.transparent,
              forceMaterialTransparency: true,
              flexibleSpace: AnimatedSwitcher(
                duration: AppMotion.resolve(context, AppMotion.fast),
                child: innerBoxIsScrolled
                    ? const LiquidGlassSurface(
                        key: ValueKey('feed-header-glass'),
                        preset: LiquidGlassPreset.stickyHeader,
                        borderRadius: BorderRadius.zero,
                        child: SizedBox.expand(),
                      )
                    : const SizedBox.expand(
                        key: ValueKey('feed-header-clear'),
                      ),
              ),
              leadingWidth: isWide ? null : 54,
              leading: isWide
                  ? null
                  : Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: Center(
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            Icons.pets_rounded,
                            size: 17,
                            color: scheme.onPrimary,
                          ),
                        ),
                      ),
                    ),
              titleSpacing: isWide ? 0 : 8,
              title: isWide
                  ? Align(
                      alignment: Alignment.center,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: AppBreakpoints.contentMaxWidth,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  l10n.t('tab.home'),
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              for (var i = 0; i < headerActions.length; i++) ...[
                                if (i > 0) const SizedBox(width: 8),
                                headerActions[i],
                              ],
                            ],
                          ),
                        ),
                      ),
                    )
                  : Text(
                      l10n.t('app.title'),
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
              actions: isWide
                  ? null
                  : [
                      for (var i = 0; i < headerActions.length; i++) ...[
                        if (i > 0) const SizedBox(width: 6),
                        headerActions[i],
                      ],
                      const SizedBox(width: 12),
                    ],
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(54),
                child: Align(
                  alignment: Alignment.center,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: AppBreakpoints.contentMaxWidth,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                      child: _CapsuleSegmentedTabs(
                        controller: _tab,
                        labels: [
                          for (final tab in _HomeFeedTab.values)
                            l10n.t('feed.tab.${tab.name}'),
                        ],
                        onSelect: (idx) => _load(_HomeFeedTab.values[idx]),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
          body: TabBarView(
            controller: _tab,
            children: [
              for (final tab in _HomeFeedTab.values)
                _buildFeedTab(tab, session),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFeedTab(_HomeFeedTab tab, AuthSessionState session) {
    final l10n = AppLocalizations.of(context);
    if (tab.requiresAuth && !session.isAuthenticated) {
      if (session.loading) return const LoadingView();
      return EmptyView(
        message: l10n.t(
          tab == _HomeFeedTab.groups
              ? 'feed.groups_auth_required'
              : 'feed.following_auth_required',
        ),
        icon: tab == _HomeFeedTab.groups
            ? Icons.groups_outlined
            : Icons.person_add_alt_1_outlined,
        actionLabel: l10n.t('auth.login'),
        onAction: () => context.push('/auth/login'),
      );
    }
    if (tab == _HomeFeedTab.groups) {
      final state = _groups;
      return _buildTimeline(
        tab,
        state,
        (post) => SurfaceCard(
          radius: AppRadius.card,
          padding: EdgeInsets.zero,
          child: GroupPostCard(
            key: ValueKey(_groupKey(post)),
            post: post,
            groupName: post.groupName,
            showModerationActions: false,
            onTap: () {
              if (!_isCurrent(tab, state)) return;
              context.push(
                groupPostLocation((
                  groupId: post.groupId,
                  postId: post.postId,
                  commentId: null,
                )),
              );
            },
            onLike: _pendingGroupLikes.contains(_groupKey(post))
                ? null
                : () => _likeGroupPost(state, post),
            onReport: () => showReportDialog(
              context,
              ref,
              targetType: 'group_post',
              targetId: post.postId,
            ),
          ),
        ),
      );
    }
    final state = _postTabs[tab]!;
    return _buildTimeline(
      tab,
      state,
      (post) => PostCard(
        key: ValueKey(post.postId),
        post: post,
        avatarHeroTag: 'feed-${tab.name}-${post.postId}',
        onChanged: (updated) {
          if (!_isCurrent(tab, state)) return;
          setState(() {
            for (final page in _postTabs.values) {
              final index = page.items.indexWhere(
                (item) => item.postId == updated.postId,
              );
              if (index >= 0) page.items[index] = updated;
            }
          });
        },
        onDeleted: () {
          if (!_isCurrent(tab, state)) return;
          setState(() {
            for (final page in _postTabs.values) {
              page.items.removeWhere((item) => item.postId == post.postId);
            }
          });
        },
        onRecommendationFeedback: tab == _HomeFeedTab.recommended
            ? () {
                if (_isCurrent(tab, state)) unawaited(_refresh(tab));
              }
            : null,
        onReport: () => showReportDialog(
          context,
          ref,
          targetType: 'post',
          targetId: post.postId,
        ),
      ),
    );
  }

  Widget _buildTimeline<T>(
    _HomeFeedTab tab,
    _FeedTabState<T> state,
    Widget Function(T item) buildItem,
  ) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (state.loading && state.items.isEmpty) {
      return Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppBreakpoints.contentMaxWidth,
          ),
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 108),
            physics: const NeverScrollableScrollPhysics(),
            itemCount: 6,
            itemBuilder: (_, _) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: PostSkeleton(animate: _selected == tab),
            ),
          ),
        ),
      );
    }
    final messageCount = state.items.isEmpty && !state.hasMore ? 1 : 0;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: AppBreakpoints.contentMaxWidth,
        ),
        child: RefreshIndicator(
          color: scheme.primary,
          onRefresh: () => _refresh(tab),
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.depth == 0 &&
                  n.metrics.axis == Axis.vertical &&
                  _selected == tab &&
                  !state.nextPageFailed &&
                  n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
                _load(tab, more: true);
              }
              return false;
            },
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 108),
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount:
                  state.items.length + messageCount + (state.hasMore ? 1 : 0),
              itemBuilder: (context, index) {
                if (index < state.items.length) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: StaggeredEntrance(
                      index: index,
                      child: buildItem(state.items[index]),
                    ),
                  );
                }
                if (state.loading) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (state.error case final error?) {
                  return ErrorView(error: error, onRetry: () => _load(tab));
                }
                if (state.hasMore) {
                  return Padding(
                    padding: const EdgeInsets.all(14),
                    child: Center(
                      child: OutlinedButton(
                        onPressed: () => _load(tab, more: true),
                        child: Text(
                          l10n.t(
                            state.nextPageFailed
                                ? 'common.retry'
                                : 'feed.load_more',
                          ),
                        ),
                      ),
                    ),
                  );
                }
                return EmptyView(message: l10n.t('feed.empty'));
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _CapsuleSegmentedTabs extends StatelessWidget {
  const _CapsuleSegmentedTabs({
    required this.controller,
    required this.labels,
    required this.onSelect,
  });

  final TabController controller;
  final List<String> labels;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => LiquidGlassSegmentedControl<int>(
        options: labels.indexed.toList(),
        selected: controller.index,
        onSelect: (index) {
          if (controller.index != index) controller.animateTo(index);
          onSelect(index);
        },
      ),
    );
  }
}

class _FeedTabState<T> {
  final List<T> items = [];
  int page = 0;
  bool hasMore = false;
  bool loaded = false;
  bool loading = false;
  bool nextPageFailed = false;
  Object? error;
}
