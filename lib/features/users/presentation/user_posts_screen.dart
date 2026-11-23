import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../../posts/domain/post_models.dart';
import '../../posts/presentation/post_card.dart';
import '../../posts/presentation/report_dialog.dart';
import 'profile_pinned_post.dart';

class UserPostsScreen extends ConsumerStatefulWidget {
  const UserPostsScreen({super.key, required this.userId});

  final int userId;

  @override
  ConsumerState<UserPostsScreen> createState() => _UserPostsScreenState();
}

class _UserPostsScreenState extends ConsumerState<UserPostsScreen> {
  List<V2Post> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasNext = false;
  int _page = 1;
  int _scope = 0;
  late final VoidCallback _stopSession;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _stopSession = ref.read(tokenStoreProvider).listenSessionChanges(_reset);
    ref.listenManual(postsApiProvider, (_, _) => _reset());
    _load();
  }

  @override
  void didUpdateWidget(covariant UserPostsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.userId != oldWidget.userId) _reset();
  }

  @override
  void dispose() {
    _stopSession();
    super.dispose();
  }

  bool _current(int scope) =>
      mounted && _scope == scope && !ref.read(tokenStoreProvider).isSessionChanging;

  void _reset() {
    if (!mounted) return;
    setState(() {
      _scope++;
      _items = [];
      _error = null;
      _loading = true;
      _hasNext = false;
      _loadingMore = false;
    });
    _load();
  }

  Future<void> _refresh() {
    ref.invalidate(profilePinnedPostProvider(widget.userId));
    return _load();
  }

  Future<void> _load() async {
    final scope = ++_scope;
    if (!_current(scope)) return;
    setState(() {
      _loading = true;
      _error = null;
      _page = 1;
      _hasNext = false;
      _loadingMore = false;
    });
    try {
      final page = await ref
          .read(postsApiProvider)
          .getUserPostsById(widget.userId, page: 1, size: 20);
      if (!_current(scope)) return;
      setState(() {
        _items = page.items;
        _page = 1;
        _hasNext = page.hasNext;
        _loading = false;
      });
    } catch (e) {
      if (!_current(scope)) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasNext || _loading) return;
    final scope = _scope;
    if (!_current(scope)) return;
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final page = await ref
          .read(postsApiProvider)
          .getUserPostsById(widget.userId, page: next, size: 20);
      if (!_current(scope)) return;
      setState(() {
        _items = appendProfilePosts(_items, page.items);
        _page = next;
        _hasNext = page.hasNext;
        _loadingMore = false;
      });
    } catch (e) {
      if (!_current(scope)) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scope = _scope;
    final signedIn = ref.watch(authSessionProvider).isAuthenticated;
    final showPin = signedIn && _current(scope);
    final pinProvider = profilePinnedPostProvider(widget.userId);
    final pin = showPin ? ref.watch(pinProvider) : null;
    final controller = showPin ? ref.read(pinProvider.notifier) : null;
    final visible = profilePostsWithPin(_items, pin?.post);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('profile.posts'))),
      body: _loading
          ? const LoadingView()
          : _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : visible.isEmpty && !_hasNext
          ? EmptyView(message: l10n.t('feed.empty'))
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppBreakpoints.contentMaxWidth,
                ),
                child: RefreshIndicator(
                  onRefresh: _refresh,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
                        _loadMore();
                      }
                      return false;
                    },
                    child: ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: visible.length + (_hasNext ? 1 : 0),
                      findChildIndexCallback: (key) {
                        if (key is! ValueKey<int>) return null;
                        final index = visible.indexWhere((post) => post.postId == key.value);
                        return index < 0 ? null : index;
                      },
                      itemBuilder: (context, i) {
                        if (i == visible.length) {
                          return const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(child: CircularProgressIndicator()),
                          );
                        }
                        final post = visible[i];
                        return Column(
                          key: ValueKey(post.postId),
                          children: [
                            PostCard(
                              post: post,
                              profilePinned: pin?.post?.postId == post.postId,
                              onChangeProfilePin: pin?.ready == true &&
                                      pin?.busy == false &&
                                      post.author.userId == widget.userId &&
                                      (post.author.relationship.isSelf ||
                                          post.viewerState.canDelete) &&
                                      controller != null
                                  ? (pinned) {
                                      if (_current(scope)) {
                                        changeProfilePin(
                                          context,
                                          controller,
                                          post,
                                          pinned: pinned,
                                        );
                                      }
                                    }
                                  : null,
                              onDeleted: () {
                                if (!_current(scope)) return;
                                controller?.remove(post.postId);
                                setState(() {
                                  _items = _items
                                      .where((item) => item.postId != post.postId)
                                      .toList();
                                });
                              },
                              onChanged: (updated) {
                                if (!_current(scope)) return;
                                controller?.update(updated);
                                final index = _items.indexWhere(
                                  (item) => item.postId == updated.postId,
                                );
                                if (index >= 0) {
                                  setState(() => _items[index] = updated);
                                }
                              },
                              onReport: () => showReportDialog(
                                context,
                                ref,
                                targetType: 'post',
                                targetId: post.postId,
                              ),
                            ),
                            if (i < visible.length - 1 || _hasNext)
                              Divider(height: 1, color: theme.dividerColor),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
