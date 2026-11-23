import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/api_response.dart';
import '../../../core/utils/ai_conversation_link.dart';
import '../../../core/utils/group_post_link.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/routing/auth_navigation.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
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

  _HomeFeedTab get _selected => _HomeFeedTab.values[_tab.index];

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: _HomeFeedTab.values.length, vsync: this);
    _tab.addListener(() {
      if (_tab.indexIsChanging) return;
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
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('app.title')),
        actions: [
          IconButton(
            key: const Key('feed-ai-knowledge-button'),
            tooltip: l10n.t('ai.knowledge.title'),
            icon: const Icon(Icons.library_books_outlined),
            onPressed: () {
              if (requireAuthenticatedAction(context, ref)) {
                openAiConversation(context, knowledge: true);
              }
            },
          ),
          IconButton(
            key: const Key('feed-ai-writing-button'),
            tooltip: l10n.t('ai.writing.title'),
            icon: const Icon(Icons.auto_awesome_outlined),
            onPressed: () {
              if (requireAuthenticatedAction(context, ref)) {
                openAiConversation(context);
              }
            },
          ),
          IconButton(
            key: const Key('feed-search-button'),
            tooltip: l10n.t('tab.discover'),
            icon: const Icon(Icons.search),
            onPressed: () => context.push('/discover'),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final theme = Theme.of(context);
              final viewportWidth = MediaQuery.sizeOf(context).width;
              final availableWidth =
                  constraints.maxWidth.isFinite &&
                      constraints.maxWidth < viewportWidth
                  ? constraints.maxWidth
                  : viewportWidth;
              final width = availableWidth < AppBreakpoints.contentMaxWidth
                  ? availableWidth
                  : AppBreakpoints.contentMaxWidth;
              return Center(
                child: SizedBox(
                  width: width,
                  child: TabBar(
                    controller: _tab,
                    isScrollable: true,
                    tabAlignment: TabAlignment.center,
                    labelPadding: const EdgeInsets.symmetric(horizontal: 16),
                    dividerColor: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.45,
                    ),
                    indicatorSize: TabBarIndicatorSize.label,
                    onTap: (idx) => _load(_HomeFeedTab.values[idx]),
                    tabs: [
                      for (final tab in _HomeFeedTab.values)
                        Tab(text: l10n.t('feed.tab.${tab.name}')),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _compose,
        child: const Icon(Icons.edit),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          for (final tab in _HomeFeedTab.values) _buildFeedTab(tab, session),
        ],
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
        (post) => GroupPostCard(
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
      );
    }
    final state = _postTabs[tab]!;
    return _buildTimeline(
      tab,
      state,
      (post) => PostCard(
        key: ValueKey(post.postId),
        post: post,
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
    final hasExplanation = tab == _HomeFeedTab.recommended;
    final messageCount = state.items.isEmpty && !state.hasMore ? 1 : 0;
    final extra = hasExplanation ? 1 : 0;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: AppBreakpoints.contentMaxWidth,
        ),
        child: RefreshIndicator(
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
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 88),
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount:
                  extra +
                  state.items.length +
                  messageCount +
                  (state.hasMore ? 1 : 0),
              itemBuilder: (context, i) {
                if (hasExplanation && i == 0) {
                  final theme = Theme.of(context);
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Text(
                      l10n.t('feed.recommended_explanation'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  );
                }
                final index = i - extra;
                if (index < state.items.length) {
                  return buildItem(state.items[index]);
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

class _FeedTabState<T> {
  final List<T> items = [];
  int page = 0;
  bool hasMore = false;
  bool loaded = false;
  bool loading = false;
  bool nextPageFailed = false;
  Object? error;
}
