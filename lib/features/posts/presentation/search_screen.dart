import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/motion/skeleton.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/routing/auth_navigation.dart';
import '../../../shared/theme/tokens.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../../../shared/widgets/ui/surface_card.dart';
import '../../users/presentation/user_discovery_results.dart';
import '../domain/post_models.dart';
import 'post_card.dart';
import 'report_dialog.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key, this.initialQuery});

  final String? initialQuery;

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  static const _recentSearchesKey = 'nekotribe.recent_searches';
  final _controller = TextEditingController();
  final _searchFocus = FocusNode();
  bool _isFocused = false;
  List<String> _recentSearches = [];
  List<V2Post> _posts = [];
  List<V2TagItem> _trendingTags = [];
  List<V2TagItem> _matchingTags = [];
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasSearched = false;
  bool _hasNext = false;
  int _page = 1;
  String _lastQuery = '';
  bool _showUsers = false;
  String _accountQuery = '';
  Object? _error;
  int _postRequest = 0;
  int _tagRequest = 0;
  late final VoidCallback _stopSessionListener;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onQueryChanged);
    _searchFocus.addListener(_onFocusChanged);
    final query = widget.initialQuery?.trim();
    if (query != null && query.isNotEmpty) {
      _controller.text = query;
    }
    _stopSessionListener = ref
        .read(tokenStoreProvider)
        .listenSessionChanges(_resetOwner);
    ref.listenManual(postsApiProvider, (_, _) => _resetOwner());
    ref.listenManual(authSessionProvider, (prev, next) {
      if (!mounted) return;
      if (next.isAuthenticated && prev?.isAuthenticated != true) {
        unawaited(_loadTrending());
      } else if (!next.isAuthenticated && prev?.isAuthenticated == true) {
        setState(() {
          _tagRequest++;
          _trendingTags = [];
        });
      }
    });
    if (ref.read(authSessionProvider).isAuthenticated) {
      unawaited(_loadTrending());
    }
    unawaited(_loadRecentSearches());
    if (_controller.text.isNotEmpty) {
      scheduleMicrotask(() {
        if (mounted) unawaited(_search());
      });
    }
  }

  @override
  void didUpdateWidget(covariant SearchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.initialQuery?.trim() ?? '';
    final previous = oldWidget.initialQuery?.trim() ?? '';
    if (next != previous) {
      _controller.text = next;
      if (next.isNotEmpty) _submitSearch();
    }
  }

  @override
  void dispose() {
    _stopSessionListener();
    _searchFocus.removeListener(_onFocusChanged);
    _searchFocus.dispose();
    _controller.removeListener(_onQueryChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!mounted) return;
    if (_isFocused != _searchFocus.hasFocus) {
      setState(() => _isFocused = _searchFocus.hasFocus);
    }
  }

  Future<void> _loadRecentSearches() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final items = prefs.getStringList(_recentSearchesKey);
      if (!mounted || items == null) return;
      setState(() => _recentSearches = items.take(6).toList());
    } catch (_) {}
  }

  Future<void> _recordRecentSearch(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    final next = [
      trimmed,
      ..._recentSearches.where((item) => item != trimmed),
    ].take(6).toList();
    if (mounted) setState(() => _recentSearches = next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_recentSearchesKey, next);
    } catch (_) {}
  }

  Future<void> _removeRecentSearch(String query) async {
    final next = _recentSearches.where((item) => item != query).toList();
    if (mounted) setState(() => _recentSearches = next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_recentSearchesKey, next);
    } catch (_) {}
  }

  Future<void> _clearRecentSearches() async {
    if (mounted) setState(() => _recentSearches = []);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_recentSearchesKey);
    } catch (_) {}
  }

  void _onQueryChanged() {
    if (!mounted) return;
    setState(() {
      if (_controller.text.trim().isEmpty) {
        _clearPostResults();
        _lastQuery = '';
        _accountQuery = '';
      }
    });
  }

  void _clearSearch() {
    _controller.clear();
  }

  void _clearPostResults() {
    _postRequest++;
    _posts = [];
    _matchingTags = [];
    _hasSearched = false;
    _error = null;
    _page = 1;
    _hasNext = false;
    _loading = false;
    _loadingMore = false;
  }

  void _resetOwner() {
    if (!mounted) return;
    setState(() {
      _tagRequest++;
      _trendingTags = [];
      _clearPostResults();
    });
    if (ref.read(tokenStoreProvider).isSessionChanging) return;
    if (ref.read(authSessionProvider).isAuthenticated) {
      unawaited(_loadTrending());
    }
    if (_lastQuery.isNotEmpty) unawaited(_search(query: _lastQuery));
  }

  void _submitSearch() {
    final q = _controller.text.trim();
    if (q.isNotEmpty) unawaited(_recordRecentSearch(q));
    if (_showUsers) {
      setState(() => _accountQuery = q);
    } else {
      unawaited(_search());
    }
  }

  Future<void> _loadTrending() async {
    if (ref.read(tokenStoreProvider).isSessionChanging ||
        !ref.read(authSessionProvider).isAuthenticated) {
      return;
    }
    final request = ++_tagRequest;
    try {
      final tags = await ref.read(postsApiProvider).getTrendingTags();
      if (!mounted || request != _tagRequest) return;
      setState(() => _trendingTags = tags);
    } catch (_) {}
  }

  Future<void> _search({String? query}) async {
    final q = query ?? _controller.text.trim();
    if (q.isEmpty || ref.read(tokenStoreProvider).isSessionChanging) return;
    final request = ++_postRequest;
    setState(() {
      _lastQuery = q;
      _posts = [];
      _matchingTags = [];
      _loading = true;
      _error = null;
      _page = 1;
      _hasNext = false;
      _loadingMore = false;
    });
    if (ref.read(authSessionProvider).isAuthenticated) {
      unawaited(_searchTags(q, request));
    }
    try {
      final result = await ref
          .read(postsApiProvider)
          .searchPosts(query: q, page: 1);
      if (!mounted || request != _postRequest) return;
      setState(() {
        _posts = result.items;
        _hasSearched = true;
        _page = 1;
        _hasNext = result.hasNext;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || request != _postRequest) return;
      setState(() {
        _error = e;
        _hasSearched = true;
        _loading = false;
      });
    }
  }

  Future<void> _searchTags(String query, int request) async {
    try {
      final tags = await ref.read(postsApiProvider).searchTags(query);
      if (!mounted || request != _postRequest) return;
      setState(() => _matchingTags = tags);
    } catch (_) {
      // Posts remain available if tag search fails.
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasNext || _lastQuery.isEmpty) return;
    if (ref.read(tokenStoreProvider).isSessionChanging) return;
    final request = _postRequest;
    setState(() => _loadingMore = true);
    final next = _page + 1;
    try {
      final result = await ref
          .read(postsApiProvider)
          .searchPosts(query: _lastQuery, page: next);
      if (!mounted || request != _postRequest) return;
      setState(() {
        final existing = _posts.map((p) => p.postId).toSet();
        final fresh = result.items
            .where((p) => existing.add(p.postId))
            .toList();
        _posts = [..._posts, ...fresh];
        _page = next;
        _hasNext = result.hasNext;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || request != _postRequest) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  /// Prefer go_router canPop when available; fall back to Navigator for tests.
  Widget? _searchLeading(BuildContext context) {
    final router = GoRouter.maybeOf(context);
    if (router == null) return null;
    if (router.canPop()) return null;
    return IconButton(
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      icon: const Icon(Icons.arrow_back),
      onPressed: () => context.go('/feed'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final social = SocialColors.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: social.surfaceBase,
      appBar: AppBar(
        backgroundColor: social.glassSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: _searchLeading(context),
        titleSpacing: 0,
        title: AnimatedContainer(
          duration: AppMotion.resolve(context, AppMotion.fast),
          curve: AppMotion.glideCurve,
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: _isFocused ? social.surfaceCard : social.surfaceSubtle,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: _isFocused
                ? Border.all(
                    color: scheme.primary.withValues(alpha: 0.45),
                    width: 1,
                  )
                : null,
          ),
          child: Row(
            children: [
              Icon(
                Icons.search_rounded,
                size: 19,
                color: _isFocused ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _searchFocus,
                  decoration: InputDecoration(
                    hintText: l10n.t('common.search'),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    isDense: true,
                    filled: false,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _submitSearch(),
                ),
              ),
              if (_controller.text.isNotEmpty)
                IconButton(
                  key: const Key('search-clear-button'),
                      tooltip: l10n.t('search.clear_query'),
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  onPressed: _clearSearch,
                  icon: const Icon(Icons.close_rounded),
                ),
            ],
          ),
        ),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppBreakpoints.contentMaxWidth,
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
                child: Container(
                  height: 40,
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: social.surfaceSubtle,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Stack(
                    children: [
                      AnimatedAlign(
                        alignment: _showUsers
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        duration: AppMotion.resolve(context, AppMotion.glide),
                        curve: AppMotion.glideCurve,
                        child: FractionallySizedBox(
                          widthFactor: 0.5,
                          heightFactor: 1,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: social.surfaceCard,
                              borderRadius: BorderRadius.circular(
                                AppRadius.pill,
                              ),
                              boxShadow: isDark
                                  ? const <BoxShadow>[]
                                  : const <BoxShadow>[
                                      BoxShadow(
                                        color: Color(0x0F0F172A),
                                        blurRadius: 4,
                                        offset: Offset(0, 1),
                                      ),
                                    ],
                            ),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: _SearchTabButton(
                              label: l10n.t('search.posts'),
                              selected: !_showUsers,
                              onTap: () => setState(() => _showUsers = false),
                            ),
                          ),
                          Expanded(
                            child: _SearchTabButton(
                              label: l10n.t('search.users'),
                              selected: _showUsers,
                              onTap: () => setState(() {
                                _showUsers = true;
                                _accountQuery = _controller.text.trim();
                              }),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (!_showUsers && _matchingTags.isNotEmpty)
                SizedBox(
                  height: 48,
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    scrollDirection: Axis.horizontal,
                    itemCount: _matchingTags.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (_, index) => _tagChip(_matchingTags[index]),
                  ),
                ),
              Expanded(
                child: _showUsers
                    ? _userResults(l10n)
                    : _postResults(l10n, theme),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tagChip(V2TagItem tag) {
    final social = SocialColors.of(context);
    final theme = Theme.of(context);
    return ActionChip(
      side: BorderSide.none,
      shape: const StadiumBorder(),
      backgroundColor: social.surfaceCard,
      labelStyle: theme.textTheme.labelMedium?.copyWith(
        fontWeight: FontWeight.w500,
      ),
      label: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 180),
        child: Text('#${tag.name}', maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      onPressed: () => context.push('/tags/${Uri.encodeComponent(tag.name)}'),
    );
  }

  Widget _postResults(AppLocalizations l10n, ThemeData theme) {
    final social = SocialColors.of(context);
    return _loading
        ? ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 108),
            children: [
              for (var i = 0; i < 4; i++) ...[
                const PostSkeleton(),
                if (i < 3) const SizedBox(height: 12),
              ],
            ],
          )
        : _error != null
        ? ErrorView(error: _error!, onRetry: _search)
        : _posts.isNotEmpty
        ? NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
                unawaited(_loadMore());
              }
              return false;
            },
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 108),
              itemCount: _posts.length + (_hasNext ? 1 : 0),
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (_, i) {
                if (i >= _posts.length) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final p = _posts[i];
                final request = _postRequest;
                return PostCard(
                  key: ValueKey(p.postId),
                  post: p,
                  onChanged: (updated) {
                    if (!mounted || request != _postRequest) return;
                    final index = _posts.indexWhere(
                      (item) => item.postId == p.postId,
                    );
                    if (index >= 0) setState(() => _posts[index] = updated);
                  },
                  onDeleted: () {
                    if (!mounted || request != _postRequest) return;
                    setState(
                      () =>
                          _posts.removeWhere((item) => item.postId == p.postId),
                    );
                  },
                  onReport: () => showReportDialog(
                    context,
                    ref,
                    targetType: 'post',
                    targetId: p.postId,
                  ),
                );
              },
            ),
          )
        : _hasSearched
        ? EmptyView(message: l10n.t('search.empty'))
        : ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 108),
            children: [
              if (_recentSearches.isNotEmpty) ...[
                SurfaceCard(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            l10n.t('search.recent'),
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          TextButton(
                            onPressed: _clearRecentSearches,
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            child: Text(
                              l10n.t('search.clear_recent'),
                              style: const TextStyle(
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final recent in _recentSearches)
                            InputChip(
                              side: BorderSide.none,
                              shape: const StadiumBorder(),
                              backgroundColor: social.surfaceSubtle,
                              avatar: const Icon(
                                Icons.history_rounded,
                                size: 15,
                              ),
                              label: Text(
                                recent,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onPressed: () {
                                _controller.text = recent;
                                _submitSearch();
                              },
                              onDeleted: () =>
                                  unawaited(_removeRecentSearch(recent)),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 2, 4, 10),
                child: Text(
                  l10n.t('discover.trending_tags'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (_trendingTags.isEmpty)
                SurfaceCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 20,
                  ),
                  child: Center(
                    child: EmptyView(message: l10n.t('right_rail.no_trending')),
                  ),
                )
              else
                LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = constraints.maxWidth >= 340 ? 2 : 1;
                    if (columns == 1) {
                      return Column(
                        children: [
                          for (var i = 0; i < _trendingTags.length; i++) ...[
                            if (i > 0) const SizedBox(height: 10),
                            _TrendingTagBentoCard(
                              rank: i + 1,
                              tag: _trendingTags[i],
                              onTap: () => context.push(
                                '/tags/${Uri.encodeComponent(_trendingTags[i].name)}',
                              ),
                            ),
                          ],
                        ],
                      );
                    }
                    final rows = <Widget>[];
                    for (var i = 0; i < _trendingTags.length; i += 2) {
                      final first = _trendingTags[i];
                      final second = i + 1 < _trendingTags.length
                          ? _trendingTags[i + 1]
                          : null;
                      rows.add(
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _TrendingTagBentoCard(
                                rank: i + 1,
                                tag: first,
                                onTap: () => context.push(
                                  '/tags/${Uri.encodeComponent(first.name)}',
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: second == null
                                  ? const SizedBox.shrink()
                                  : _TrendingTagBentoCard(
                                      rank: i + 2,
                                      tag: second,
                                      onTap: () => context.push(
                                        '/tags/${Uri.encodeComponent(second.name)}',
                                      ),
                                    ),
                            ),
                          ],
                        ),
                      );
                      if (i + 2 < _trendingTags.length) {
                        rows.add(const SizedBox(height: 10));
                      }
                    }
                    return Column(children: rows);
                  },
                ),
            ],
          );
  }

  Widget _userResults(AppLocalizations l10n) {
    final session = ref.watch(authSessionProvider);
    if (session.loading) return const LoadingView();
    if (!session.isAuthenticated) {
      return Center(
        child: TextButton(
          onPressed: () => requireAuthenticatedAction(context, ref),
          child: Text(l10n.t('auth.sign_in_required')),
        ),
      );
    }
    return UserDiscoveryResults(query: _accountQuery);
  }
}

class _SearchTabButton extends StatelessWidget {
  const _SearchTabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          onTap: onTap,
          child: Center(
            child: Text(
              label,
              maxLines: 1,
              softWrap: false,
              style: theme.textTheme.labelLarge?.copyWith(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TrendingTagBentoCard extends StatelessWidget {
  const _TrendingTagBentoCard({
    required this.rank,
    required this.tag,
    required this.onTap,
  });

  final int rank;
  final V2TagItem tag;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final social = SocialColors.of(context);
    final l10n = AppLocalizations.of(context);
    final rankLabel = rank.toString().padLeft(2, '0');
    final count = tag.postsCount;
    return SurfaceCard(
      padding: const EdgeInsets.all(14),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: rank <= 3
                      ? social.primarySoft
                      : social.surfaceSubtle,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                child: Text(
                  rankLabel,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: rank <= 3 ? scheme.primary : scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const Spacer(),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: social.inkTertiary,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '#${tag.name}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            count != null && count > 0
                ? l10n
                      .t('right_rail.posts_count')
                      .replaceFirst('{count}', '$count')
                : '#${tag.name}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: social.inkTertiary,
              fontSize: 12,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
