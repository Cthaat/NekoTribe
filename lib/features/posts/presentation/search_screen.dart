import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/routing/auth_navigation.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
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
  final _controller = TextEditingController();
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
    final query = widget.initialQuery?.trim();
    if (query != null && query.isNotEmpty) {
      _controller.text = query;
    }
    _stopSessionListener = ref
        .read(tokenStoreProvider)
        .listenSessionChanges(_resetOwner);
    ref.listenManual(postsApiProvider, (_, _) => _resetOwner());
    unawaited(_loadTrending());
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
    _controller.removeListener(_onQueryChanged);
    _controller.dispose();
    super.dispose();
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
    unawaited(_loadTrending());
    if (_lastQuery.isNotEmpty) unawaited(_search(query: _lastQuery));
  }

  void _submitSearch() {
    if (_showUsers) {
      setState(() => _accountQuery = _controller.text.trim());
    } else {
      unawaited(_search());
    }
  }

  Future<void> _loadTrending() async {
    if (ref.read(tokenStoreProvider).isSessionChanging) return;
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
      icon: const Icon(Icons.arrow_back),
      onPressed: () => context.go('/feed'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: _searchLeading(context),
        titleSpacing: 0,
        title: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: theme.inputDecorationTheme.fillColor,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: theme.dividerColor),
          ),
          child: Row(
            children: [
              Icon(
                Icons.search,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _controller,
                  decoration: InputDecoration(
                    hintText: l10n.t('common.search'),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    isDense: true,
                    filled: false,
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _submitSearch(),
                ),
              ),
              if (_controller.text.isNotEmpty)
                IconButton(
                  key: const Key('search-clear-button'),
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  onPressed: _clearSearch,
                  icon: const Icon(Icons.close),
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
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(
                      value: false,
                      label: Text(l10n.t('search.posts')),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text(l10n.t('search.users')),
                    ),
                  ],
                  selected: {_showUsers},
                  onSelectionChanged: (selection) {
                    setState(() {
                      _showUsers = selection.single;
                      if (_showUsers) _accountQuery = _controller.text.trim();
                    });
                  },
                ),
              ),
              if (!_showUsers && _matchingTags.isNotEmpty)
                SizedBox(
                  height: 48,
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
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

  Widget _tagChip(V2TagItem tag) => ActionChip(
    label: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 180),
      child: Text('#${tag.name}', maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
    onPressed: () => context.push('/tags/${Uri.encodeComponent(tag.name)}'),
  );

  Widget _postResults(AppLocalizations l10n, ThemeData theme) {
    return _loading
        ? const LoadingView()
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
              itemCount: _posts.length + (_hasNext ? 1 : 0),
              separatorBuilder: (_, _) =>
                  Divider(height: 1, color: theme.dividerColor),
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
        : SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.t('discover.trending_tags'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [for (final t in _trendingTags) _tagChip(t)],
                ),
              ],
            ),
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
