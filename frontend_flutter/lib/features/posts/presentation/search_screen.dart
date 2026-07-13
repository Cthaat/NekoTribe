import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
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
  bool _loading = false;
  bool _hasSearched = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onQueryChanged);
    final query = widget.initialQuery?.trim();
    if (query != null && query.isNotEmpty) {
      _controller.text = query;
    }
    _loadTrending();
    if (_controller.text.isNotEmpty) {
      Future<void>.microtask(_search);
    }
  }

  @override
  void didUpdateWidget(covariant SearchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.initialQuery?.trim() ?? '';
    final previous = oldWidget.initialQuery?.trim() ?? '';
    if (next != previous && next.isNotEmpty) {
      _controller.text = next;
      _search();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onQueryChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _clearSearch() {
    setState(() {
      _controller.clear();
      _posts = [];
      _hasSearched = false;
      _error = null;
    });
  }

  Future<void> _loadTrending() async {
    try {
      final tags = await ref.read(postsApiProvider).getTrendingTags();
      if (!mounted) return;
      setState(() => _trendingTags = tags);
    } catch (_) {}
  }

  Future<void> _search() async {
    final q = _controller.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref.read(postsApiProvider).searchPosts(query: q);
      if (!mounted) return;
      setState(() {
        _posts = result.items;
        _hasSearched = true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _hasSearched = true;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
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
                  onSubmitted: (_) => _search(),
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
          child: _loading
              ? const LoadingView()
              : _error != null
              ? ErrorView(error: _error!, onRetry: _search)
              : _posts.isNotEmpty
              ? ListView.separated(
                  itemCount: _posts.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, color: theme.dividerColor),
                  itemBuilder: (_, i) {
                    final p = _posts[i];
                    return PostCard(
                      key: ValueKey(p.postId),
                      post: p,
                      onChanged: (u) => setState(() => _posts[i] = u),
                      onDeleted: () {
                        _posts.removeAt(i);
                        setState(() {});
                      },
                      onReport: () => showReportDialog(
                        context,
                        ref,
                        targetType: 'post',
                        targetId: p.postId,
                      ),
                    );
                  },
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
                        children: [
                          for (final t in _trendingTags)
                            ActionChip(
                              label: Text('#${t.name}'),
                              onPressed: () => context.push('/tags/${t.name}'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}
