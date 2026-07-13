import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
    _loadInitial(0);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _loadInitial(int idx) async {
    final state = _tabs[idx]!;
    if (state.requiresAuth && !ref.read(authSessionProvider).isAuthenticated) {
      return;
    }
    if (state.items.isNotEmpty || state.loading) return;
    state.loading = true;
    if (mounted) setState(() {});
    try {
      final page = await ref
          .read(postsApiProvider)
          .getFeed(mode: state.mode, page: 1, size: 20, sort: state.sort);
      state.items = page.items;
      state.page = 1;
      state.hasMore = page.hasNext;
      state.error = null;
    } catch (e) {
      state.error = e;
    } finally {
      state.loading = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _loadMore(int idx) async {
    final state = _tabs[idx]!;
    if (state.requiresAuth && !ref.read(authSessionProvider).isAuthenticated) {
      return;
    }
    if (state.loadingMore || !state.hasMore) return;
    state.loadingMore = true;
    if (mounted) setState(() {});
    try {
      final next = state.page + 1;
      final page = await ref
          .read(postsApiProvider)
          .getFeed(mode: state.mode, page: next, size: 20, sort: state.sort);
      state.items.addAll(page.items);
      state.page = next;
      state.hasMore = page.hasNext;
    } catch (_) {
      // ignore
    } finally {
      state.loadingMore = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _refresh(int idx) async {
    final state = _tabs[idx]!;
    state.items = [];
    state.page = 0;
    state.hasMore = true;
    await _loadInitial(idx);
  }

  Future<void> _compose() async {
    if (!requireAuthenticatedAction(context, ref)) return;
    final created = await Navigator.of(context).push<V2Post>(
      MaterialPageRoute(builder: (_) => const ComposePostScreen()),
    );
    if (created != null) {
      final state = _tabs[_tab.index]!;
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
                    state.items[i] = updated;
                    if (mounted) setState(() {});
                  },
                  onDeleted: () {
                    state.items.removeAt(i);
                    if (mounted) setState(() {});
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
  bool hasMore = true;
  bool loading = false;
  bool loadingMore = false;
  Object? error;
}
