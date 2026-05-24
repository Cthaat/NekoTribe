import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/status_views.dart';
import '../../posts/domain/post_models.dart';
import '../../posts/presentation/post_card.dart';
import '../../posts/presentation/report_dialog.dart';

class UserPostsScreen extends ConsumerStatefulWidget {
  const UserPostsScreen({super.key, required this.userId});

  final int userId;

  @override
  ConsumerState<UserPostsScreen> createState() => _UserPostsScreenState();
}

class _UserPostsScreenState extends ConsumerState<UserPostsScreen> {
  List<V2Post> _items = [];
  bool _loading = true;
  Object? _error;

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
      final page = await ref
          .read(postsApiProvider)
          .getUserPostsById(widget.userId);
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
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('profile.posts'))),
      body: _loading
          ? const LoadingView()
          : _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : _items.isEmpty
          ? EmptyView(message: l10n.t('feed.empty'))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                itemCount: _items.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) => PostCard(
                  post: _items[i],
                  onChanged: (updated) => setState(() => _items[i] = updated),
                  onReport: () => showReportDialog(
                    context,
                    ref,
                    targetType: 'post',
                    targetId: _items[i].postId,
                  ),
                ),
              ),
            ),
    );
  }
}
