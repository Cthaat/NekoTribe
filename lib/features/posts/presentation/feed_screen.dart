import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/ai_conversation_link.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/routing/auth_navigation.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/post_models.dart';
import 'post_card.dart';
import 'compose_post_screen.dart';
import 'report_dialog.dart';

class FeedScreen extends ConsumerStatefulWidget {
  const FeedScreen({super.key});

  @override
  ConsumerState<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends ConsumerState<FeedScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  late final VoidCallback _stopSessionListener;
  final Map<int, _FeedTabState> _tabs = {
    0: _FeedTabState(mode: 'home', sort: 'newest'),
    1: _FeedTabState(mode: 'home', sort: 'popular'),
    2: _FeedTabState(mode: 'following', sort: 'newest', requiresAuth: true),
  };

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _tab.addListener(() {
      if (_tab.indexIsChanging) return;
      _loadInitial(_tab.index);
    });
    _stopSessionListener = ref
        .read(tokenStoreProvider)
        .listenSessionChanges(_resetFeed);
    ref.listenManual(postsApiProvider, (_, _) => _resetFeed());
    ref.listenManual(authSessionProvider, (previous, next) {
      if (previous?.isAuthenticated != next.isAuthenticated) _resetFeed();
    });
    _loadInitial(0);
  }

  @override
  void dispose() {
    _stopSessionListener();
    _tab.dispose();
    super.dispose();
  }

  void _resetFeed() {
    if (!mounted) return;
    setState(() => _tabs.updateAll((_, state) => state.empty()));
    unawaited(_loadInitial(_tab.index));
  }

  bool _isCurrent(int idx, _FeedTabState state) =>
      mounted &&
      identical(_tabs[idx], state) &&
      !ref.read(tokenStoreProvider).isSessionChanging;

  Future<void> _loadInitial(int idx) async {
    final state = _tabs[idx]!;
    if (!_isCurrent(idx, state)) return;
    if (state.requiresAuth && !ref.read(authSessionProvider).isAuthenticated) {
      return;
    }
    if (state.loaded || state.loading) return;
    state.loading = true;
    if (mounted) setState(() {});
    try {
      final page = await ref
          .read(postsApiProvider)
          .getFeed(mode: state.mode, page: 1, size: 20, sort: state.sort);
      if (!_isCurrent(idx, state)) return;
      state.items = [...page.items];
      state.loaded = true;
      state.page = 1;
      state.hasMore = page.hasNext;
      state.error = null;
    } catch (e) {
      if (!_isCurrent(idx, state)) return;
      state.error = e;
    } finally {
      state.loading = false;
      if (_isCurrent(idx, state)) setState(() {});
    }
  }

  Future<void> _loadMore(int idx) async {
    final state = _tabs[idx]!;
    if (!_isCurrent(idx, state)) return;
    if (state.requiresAuth && !ref.read(authSessionProvider).isAuthenticated) {
      return;
    }
    if (state.loading || state.loadingMore || !state.hasMore) return;
    state.loadingMore = true;
    if (mounted) setState(() {});
    try {
      final next = state.page + 1;
      final page = await ref
          .read(postsApiProvider)
          .getFeed(mode: state.mode, page: next, size: 20, sort: state.sort);
      if (!_isCurrent(idx, state)) return;
      final seen = state.items.map((post) => post.postId).toSet();
      state.items.addAll(page.items.where((post) => seen.add(post.postId)));
      state.page = next;
      state.hasMore = page.hasNext;
    } catch (e) {
      // Keep hasMore so the user can scroll to retry; surface the failure.
      if (_isCurrent(idx, state)) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
      }
    } finally {
      state.loadingMore = false;
      if (_isCurrent(idx, state)) setState(() {});
    }
  }

  Future<void> _refresh(int idx) async {
    setState(() => _tabs[idx] = _tabs[idx]!.empty());
    await _loadInitial(idx);
  }

  Future<void> _compose() async {
    if (!requireAuthenticatedAction(context, ref)) return;
    final idx = _tab.index;
    final state = _tabs[idx]!;
    final created = await Navigator.of(context).push<V2Post>(
      MaterialPageRoute(builder: (_) => const ComposePostScreen()),
    );
    if (created != null && _isCurrent(idx, state)) {
      setState(() => state.items.insert(0, created));
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
                    labelPadding: const EdgeInsets.symmetric(horizontal: 20),
                    dividerColor: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.45,
                    ),
                    indicatorSize: TabBarIndicatorSize.label,
                    onTap: (idx) => _loadInitial(idx),
                    tabs: [
                      Tab(text: l10n.t('feed.tab.home')),
                      Tab(text: l10n.t('feed.tab.discover')),
                      Tab(text: l10n.t('feed.tab.following')),
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
        children: [for (var i = 0; i < 3; i++) _buildFeedTab(i, session)],
      ),
    );
  }

  Widget _buildFeedTab(int idx, AuthSessionState session) {
    final state = _tabs[idx]!;
    if (state.requiresAuth && !session.isAuthenticated) {
      if (session.loading) return const LoadingView();
      final l10n = AppLocalizations.of(context);
      return EmptyView(
        message: l10n.t('feed.following_auth_required'),
        icon: Icons.person_add_alt_1_outlined,
        actionLabel: l10n.t('auth.login'),
        onAction: () => context.push('/auth/login'),
      );
    }
    if (state.loading && state.items.isEmpty) {
      return const LoadingView();
    }
    if (state.error != null && state.items.isEmpty) {
      return ErrorView(error: state.error!, onRetry: () => _loadInitial(idx));
    }
    if (state.items.isEmpty) {
      final l10n = AppLocalizations.of(context);
      return EmptyView(message: l10n.t('feed.empty'));
    }
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: AppBreakpoints.contentMaxWidth,
        ),
        child: RefreshIndicator(
          onRefresh: () => _refresh(idx),
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
                _loadMore(idx);
              }
              return false;
            },
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 88),
              itemCount: state.items.length + (state.hasMore ? 1 : 0),
              itemBuilder: (context, i) {
                if (i == state.items.length) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final post = state.items[i];
                return PostCard(
                  key: ValueKey(post.postId),
                  post: post,
                  onChanged: (updated) {
                    if (!_isCurrent(idx, state)) return;
                    final index = state.items.indexWhere(
                      (item) => item.postId == post.postId,
                    );
                    if (index >= 0) {
                      setState(() => state.items[index] = updated);
                    }
                  },
                  onDeleted: () {
                    if (!_isCurrent(idx, state)) return;
                    setState(
                      () => state.items.removeWhere(
                        (item) => item.postId == post.postId,
                      ),
                    );
                  },
                  onReport: () => showReportDialog(
                    context,
                    ref,
                    targetType: 'post',
                    targetId: post.postId,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _FeedTabState {
  _FeedTabState({
    required this.mode,
    required this.sort,
    this.requiresAuth = false,
  });

  final String mode;
  final String sort;
  final bool requiresAuth;
  List<V2Post> items = [];
  int page = 0;
  bool hasMore = false;
  bool loaded = false;
  bool loading = false;
  bool loadingMore = false;
  Object? error;

  _FeedTabState empty() =>
      _FeedTabState(mode: mode, sort: sort, requiresAuth: requiresAuth);
}
