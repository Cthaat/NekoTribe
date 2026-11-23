import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/routing/auth_navigation.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../../posts/domain/post_models.dart';
import '../../posts/presentation/post_card.dart';
import '../../posts/presentation/report_dialog.dart';
import '../../auth/data/auth_repository.dart';
import '../domain/user_models.dart';
import 'profile_pinned_post.dart';

enum _VisibilityAction { block, mute, muteDay }

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key, required this.userId});
  final int userId;

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  V2PublicUser? _user;
  List<V2Post> _posts = [];
  bool _loading = true;
  bool _loadingPosts = false;
  bool _loadingMore = false;
  bool _hasNext = false;
  int _page = 1;
  Object? _error;
  Object? _postsError;
  int _scope = 0;
  bool _relationshipBusy = false;
  bool _locallyBlocked = false;
  late AuthRepository _auth;
  late int _revision;
  late bool _changing;
  VoidCallback? _stopObserving;

  @override
  void initState() {
    super.initState();
    _observe(ref.read(authRepositoryProvider));
    _load();
  }

  void _observe(AuthRepository auth) {
    _stopObserving?.call();
    _auth = auth;
    _revision = auth.sessionRevision;
    _changing = auth.isSessionChanging;
    _stopObserving = auth.listenSessionChanges(() {
      if (!mounted || !identical(auth, _auth)) return;
      if (_revision == auth.sessionRevision &&
          _changing == auth.isSessionChanging) {
        return;
      }
      _revision = auth.sessionRevision;
      _changing = auth.isSessionChanging;
      _resetProfile();
    });
  }

  void _resetProfile() {
    setState(() {
      _scope++;
      _relationshipBusy = false;
      _locallyBlocked = false;
      _user = null;
      _posts = [];
      _error = null;
      _postsError = null;
      _loadingPosts = false;
      _loading = true;
    });
    if (!_changing) _load();
  }

  bool _isCurrent(int scope) =>
      mounted &&
      scope == _scope &&
      identical(ref.read(authRepositoryProvider), _auth) &&
      _auth.sessionRevision == _revision &&
      !_auth.isSessionChanging;

  bool get _restricted =>
      _locallyBlocked ||
      (_user?.relationship.isBlocking ?? false) ||
      (_user?.relationship.isBlocked ?? false);

  @override
  void didUpdateWidget(covariant ProfileScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId) _resetProfile();
  }

  @override
  void dispose() {
    _stopObserving?.call();
    super.dispose();
  }

  Future<void> _load() async {
    final scope = _scope;
    final target = widget.userId;
    if (!_isCurrent(scope)) return;
    setState(() {
      _loading = true;
      _error = null;
      _page = 1;
      _hasNext = false;
      _loadingMore = false;
    });
    try {
      final user = await ref.read(usersRepositoryProvider).getUserById(target);
      if (!_isCurrent(scope)) return;
      setState(() {
        _user = user;
        _loading = false;
      });
      await _loadPosts();
    } catch (e) {
      if (!_isCurrent(scope)) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _loadPosts() async {
    final scope = _scope;
    final target = widget.userId;
    if (!_isCurrent(scope) || _loadingPosts || _user?.userId != target) return;
    setState(() {
      _loadingPosts = true;
      _postsError = null;
    });
    try {
      final posts = await ref
          .read(postsApiProvider)
          .getUserPostsById(target, page: 1, size: 20);
      if (!_isCurrent(scope)) return;
      setState(() {
        _posts = posts.items;
        _page = 1;
        _hasNext = posts.hasNext;
      });
    } catch (e) {
      if (!_isCurrent(scope)) return;
      setState(() => _postsError = e);
    } finally {
      if (_isCurrent(scope)) setState(() => _loadingPosts = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasNext || _loading || _loadingPosts) return;
    final scope = _scope;
    if (!_isCurrent(scope)) return;
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final page = await ref
          .read(postsApiProvider)
          .getUserPostsById(widget.userId, page: next, size: 20);
      if (!_isCurrent(scope)) return;
      setState(() {
        _posts = appendProfilePosts(_posts, page.items);
        _page = next;
        _hasNext = page.hasNext;
        _loadingMore = false;
      });
    } catch (e) {
      if (!_isCurrent(scope)) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _toggleFollow() async {
    final user = _user;
    final scope = _scope;
    if (user == null ||
        user.userId != widget.userId ||
        _restricted ||
        _relationshipBusy ||
        !_isCurrent(scope)) {
      return;
    }
    if (!requireAuthenticatedAction(context, ref)) return;
    final wasFollowing = user.relationship.isFollowing;
    setState(() => _relationshipBusy = true);
    try {
      final repo = ref.read(usersRepositoryProvider);
      final rel = wasFollowing
          ? await repo.unfollow(user.userId)
          : await repo.follow(user.userId);
      if (!_isCurrent(scope)) return;
      setState(() {
        _user = V2PublicUser(
          userId: _user!.userId,
          username: _user!.username,
          displayName: _user!.displayName,
          avatarUrl: _user!.avatarUrl,
          bio: _user!.bio,
          location: _user!.location,
          website: _user!.website,
          isVerified: _user!.isVerified,
          followersCount:
              _user!.followersCount +
              (rel.isFollowing && !wasFollowing
                  ? 1
                  : !rel.isFollowing && wasFollowing
                  ? -1
                  : 0),
          followingCount: _user!.followingCount,
          postsCount: _user!.postsCount,
          likesCount: _user!.likesCount,
          relationship: rel,
          onlineStatus: _user!.onlineStatus,
          lastSeenAt: _user!.lastSeenAt,
        );
      });
    } catch (e) {
      if (!_isCurrent(scope)) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      if (_isCurrent(scope)) setState(() => _relationshipBusy = false);
    }
  }

  Future<void> _changeVisibility(_VisibilityAction action) async {
    final user = _user;
    final scope = _scope;
    if (user == null ||
        user.userId != widget.userId ||
        user.relationship.isSelf ||
        _relationshipBusy ||
        !_isCurrent(scope)) {
      return;
    }
    if (!requireAuthenticatedAction(context, ref)) return;
    final repository = ref.read(usersRepositoryProvider);
    final l10n = AppLocalizations.of(context);
    setState(() => _relationshipBusy = true);
    try {
      if (action == _VisibilityAction.block) {
        final name = user.displayName.isEmpty
            ? user.username
            : user.displayName;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: Text(l10n.t('visibility.block')),
            content: Text(
              l10n.t('visibility.confirmBlock').replaceFirst('{name}', name),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: Text(l10n.t('common.cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: Text(l10n.t('visibility.block')),
              ),
            ],
          ),
        );
        if (confirmed != true ||
            !_isCurrent(scope) ||
            !identical(ref.read(usersRepositoryProvider), repository)) {
          return;
        }
        await repository.blockUser(user.userId);
        if (!_isCurrent(scope)) return;
        setState(() => _locallyBlocked = true);
        ref.invalidate(profilePinnedPostProvider(user.userId));
        await _load();
      } else {
        final expiry = action == _VisibilityAction.muteDay
            ? DateTime.now().toUtc().add(const Duration(hours: 24))
            : null;
        await repository.muteUser(user.userId, expiresAt: expiry);
      }
      if (_isCurrent(scope)) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.t('visibility.saved'))));
      }
    } catch (error) {
      if (_isCurrent(scope)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorView.describe(context, error))),
        );
      }
    } finally {
      if (_isCurrent(scope)) setState(() => _relationshipBusy = false);
    }
  }

  Future<void> _openDirectMessage() async {
    final user = _user;
    final scope = _scope;
    if (user == null ||
        user.userId != widget.userId ||
        _restricted ||
        _relationshipBusy ||
        !_isCurrent(scope)) {
      return;
    }
    if (!requireAuthenticatedAction(context, ref)) return;
    try {
      final conversation = await ref
          .read(chatApiProvider)
          .openConversation(userId: user.userId);
      if (!_isCurrent(scope) || _restricted) return;
      final displayName = user.displayName.trim().isNotEmpty
          ? user.displayName
          : user.username;
      context.push(
        '/chat/conversation/${conversation.conversationId}',
        extra: {'title': displayName, 'name': displayName},
      );
    } catch (e) {
      if (!_isCurrent(scope)) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = ref.watch(authSessionProvider).isAuthenticated;
    ref.listen(authRepositoryProvider, (_, auth) {
      if (!identical(_auth, auth)) {
        _observe(auth);
        _resetProfile();
      }
    });
    ref.listen(usersRepositoryProvider, (_, repository) => _resetProfile());
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final menuScope = _scope;
    final pinProvider = profilePinnedPostProvider(widget.userId);
    final showPin = signedIn && !_restricted && !_changing &&
        _user?.userId == widget.userId;
    final pin = showPin ? ref.watch(pinProvider) : null;
    final pinController = showPin ? ref.read(pinProvider.notifier) : null;
    final visiblePosts = profilePostsWithPin(_posts, pin?.post);
    final canPin = _user?.relationship.isSelf == true &&
        pin?.ready == true && pin?.busy == false;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _user == null
              ? l10n.t('settings.account.profile')
              : '@${_user!.username}',
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (signedIn &&
              !_changing &&
              _user?.userId == widget.userId &&
              _user?.relationship.isSelf == false)
            PopupMenuButton<_VisibilityAction>(
              tooltip: l10n.t('visibility.actions'),
              enabled: !_relationshipBusy,
              onSelected: (action) {
                if (_isCurrent(menuScope)) _changeVisibility(action);
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: _VisibilityAction.muteDay,
                  child: Text(l10n.t('visibility.muteDay')),
                ),
                PopupMenuItem(
                  value: _VisibilityAction.mute,
                  child: Text(l10n.t('visibility.mute')),
                ),
                if (!_locallyBlocked && _user?.relationship.isBlocking == false)
                  PopupMenuItem(
                    value: _VisibilityAction.block,
                    child: Text(l10n.t('visibility.block')),
                  ),
              ],
            ),
        ],
      ),
      body: _loading
          ? const LoadingView()
          : _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : _user == null
          ? EmptyView(message: l10n.t('feed.empty'))
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppBreakpoints.contentMaxWidth,
                ),
                child: NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
                      _loadMore();
                    }
                    return false;
                  },
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    // header + optional empty + posts + optional footer
                    itemCount:
                        1 +
                        (visiblePosts.isEmpty ? 1 : visiblePosts.length) +
                        (_hasNext || (_postsError != null && visiblePosts.isNotEmpty)
                            ? 1
                            : 0),
                    findChildIndexCallback: (key) {
                      if (key is! ValueKey<int>) return null;
                      final index = visiblePosts.indexWhere((post) => post.postId == key.value);
                      return index < 0 ? null : index + 1;
                    },
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return Column(
                          children: [
                            _ProfileHeader(
                              user: _user!,
                              onFollow: _relationshipBusy
                                  ? null
                                  : _toggleFollow,
                              onMessage: _relationshipBusy
                                  ? null
                                  : _openDirectMessage,
                              restricted: _restricted,
                            ),
                            Divider(height: 1, color: theme.dividerColor),
                          ],
                        );
                      }

                      if (_loadingPosts) {
                        return const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      if (_postsError case final error?) {
                        if (visiblePosts.isEmpty || index > visiblePosts.length) {
                          return ErrorView(error: error, onRetry: _loadPosts);
                        }
                      }
                      if (visiblePosts.isEmpty) {
                        // empty state under header
                        if (index == 1 && !_hasNext) {
                          return Padding(
                            padding: const EdgeInsets.all(24),
                            child: EmptyView(message: l10n.t('feed.empty')),
                          );
                        }
                        // footer while hasNext (unlikely with empty)
                        return const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }

                      final postIndex = index - 1;
                      if (postIndex < visiblePosts.length) {
                        final post = visiblePosts[postIndex];
                        return Column(
                          key: ValueKey(post.postId),
                          children: [
                            PostCard(
                              post: post,
                              profilePinned: pin?.post?.postId == post.postId,
                              onChangeProfilePin: canPin &&
                                      post.author.userId == widget.userId &&
                                      pinController != null
                                  ? (pinned) {
                                      if (_isCurrent(menuScope)) {
                                        changeProfilePin(
                                          context,
                                          pinController,
                                          post,
                                          pinned: pinned,
                                        );
                                      }
                                    }
                                  : null,
                              onChanged: (updated) {
                                if (!_isCurrent(menuScope)) return;
                                pinController?.update(updated);
                                final index = _posts.indexWhere(
                                  (item) => item.postId == updated.postId,
                                );
                                if (index >= 0) {
                                  setState(() => _posts[index] = updated);
                                }
                              },
                              onDeleted: () {
                                if (!_isCurrent(menuScope)) return;
                                pinController?.remove(post.postId);
                                setState(() {
                                  _posts = _posts
                                      .where((item) => item.postId != post.postId)
                                      .toList();
                                });
                              },
                              onReport: () => showReportDialog(
                                context,
                                ref,
                                targetType: 'post',
                                targetId: post.postId,
                              ),
                            ),
                            Divider(height: 1, color: theme.dividerColor),
                          ],
                        );
                      }

                      return const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    },
                  ),
                ),
              ),
            ),
    );
  }
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({
    required this.user,
    required this.onFollow,
    required this.onMessage,
    required this.restricted,
  });

  final V2PublicUser user;
  final VoidCallback? onFollow;
  final VoidCallback? onMessage;
  final bool restricted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppAvatar(url: user.avatarUrl, size: 88),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.displayName.isEmpty
                          ? user.username
                          : user.displayName,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '@${user.username}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (user.bio.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(user.bio, style: theme.textTheme.bodyMedium),
          ],
          if (user.location.isNotEmpty || user.website.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 16,
              runSpacing: 6,
              children: [
                if (user.location.isNotEmpty)
                  _MetaItem(icon: Icons.place_outlined, text: user.location),
                if (user.website.isNotEmpty)
                  _MetaItem(icon: Icons.link, text: user.website),
              ],
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              _ProfileStat(
                label: l10n.t('profile.following'),
                value: user.followingCount,
              ),
              const SizedBox(width: 20),
              _ProfileStat(
                label: l10n.t('profile.followers'),
                value: user.followersCount,
              ),
              const SizedBox(width: 20),
              _ProfileStat(
                label: l10n.t('profile.posts'),
                value: user.postsCount,
              ),
            ],
          ),
          if (!user.relationship.isSelf && !restricted) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: user.relationship.isFollowing
                      ? OutlinedButton(
                          onPressed: onFollow,
                          child: Text(l10n.t('common.unfollow')),
                        )
                      : FilledButton(
                          onPressed: onFollow,
                          child: Text(l10n.t('common.follow')),
                        ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onMessage,
                    icon: const Icon(Icons.mail_outline, size: 18),
                    label: Text(
                      l10n.t('profile.message'),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _MetaItem extends StatelessWidget {
  const _MetaItem({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Text(
            text,
            style: theme.textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ),
      ],
    );
  }
}

class _ProfileStat extends StatelessWidget {
  const _ProfileStat({required this.label, required this.value});
  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          '$value',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
