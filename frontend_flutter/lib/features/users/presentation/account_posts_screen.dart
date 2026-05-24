import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../../posts/domain/post_models.dart';
import '../../posts/presentation/post_card.dart';
import '../../posts/presentation/report_dialog.dart';

enum AccountPostsKind { posts, likes, bookmarks }

class AccountPostsScreen extends ConsumerStatefulWidget {
  const AccountPostsScreen({super.key, required this.kind});

  final AccountPostsKind kind;

  @override
  ConsumerState<AccountPostsScreen> createState() => _AccountPostsScreenState();
}

class _AccountPostsScreenState extends ConsumerState<AccountPostsScreen> {
  List<V2Post> _items = [];
  bool _loading = true;
  Object? _error;

  String _title(AppLocalizations l10n) {
    switch (widget.kind) {
      case AccountPostsKind.likes:
        return l10n.t('account.likes');
      case AccountPostsKind.bookmarks:
        return l10n.t('account.bookmarks');
      case AccountPostsKind.posts:
        return l10n.t('account.my_posts');
    }
  }

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
      final api = ref.read(postsApiProvider);
      final page = switch (widget.kind) {
        AccountPostsKind.likes => await api.getMyLikes(),
        AccountPostsKind.bookmarks => await api.getMyBookmarks(),
        AccountPostsKind.posts => await api.getMyPosts(),
      };
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
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(_title(l10n))),
      body: _loading
          ? const LoadingView()
          : _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : _items.isEmpty
          ? EmptyView(message: l10n.t('feed.empty'))
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppBreakpoints.contentMaxWidth,
                ),
                child: RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    itemCount: _items.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: theme.dividerColor),
                    itemBuilder: (_, i) => PostCard(
                      post: _items[i],
                      onChanged: (updated) =>
                          setState(() => _items[i] = updated),
                      onReport: () => showReportDialog(
                        context,
                        ref,
                        targetType: 'post',
                        targetId: _items[i].postId,
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
