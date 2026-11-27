import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/motion/animated_count.dart';
import '../../../shared/motion/skeleton.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/routing/auth_navigation.dart';
import '../../../shared/theme/tokens.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/glass/liquid_glass_bars.dart';
import '../../../shared/widgets/glass/liquid_glass_surface.dart';
import '../../../shared/widgets/glass/liquid_glass_tokens.dart';
import '../../../shared/widgets/safe_back_button.dart';
import '../../../shared/widgets/status_views.dart';
import '../../../shared/widgets/ui/subtle_grid_box.dart';
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
  int _activeTab = 0;
  bool _showAppBarTitle = false;
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
    final scheme = theme.colorScheme;
    final social = SocialColors.of(context);
    final menuScope = _scope;
    final pinProvider = profilePinnedPostProvider(widget.userId);
    final showPin =
        signedIn &&
        !_restricted &&
        !_changing &&
        _user?.userId == widget.userId;
    final pin = showPin ? ref.watch(pinProvider) : null;
    final pinController = showPin ? ref.read(pinProvider.notifier) : null;
    final visiblePosts = profilePostsWithPin(_posts, pin?.post);
    final displayedPosts = switch (_activeTab) {
      1 => visiblePosts.where((post) => post.replyToPostId != null).toList(),
      2 => visiblePosts.where((post) => post.media.isNotEmpty).toList(),
      _ => visiblePosts,
    };
    final canPin =
        _user?.relationship.isSelf == true &&
        pin?.ready == true &&
        pin?.busy == false;

    final showProfileBack =
        Navigator.of(context).canPop() ||
        GoRouter.maybeOf(
              context,
            )?.routerDelegate.currentConfiguration.uri.path !=
            '/me';

    if (_loading) {
      return Scaffold(
        backgroundColor: social.surfaceBase,
        extendBodyBehindAppBar: true,
        appBar: LiquidGlassAppBar(
          automaticallyImplyLeading: showProfileBack,
          leading: showProfileBack
              ? const SafeBackButton(fallbackRoute: '/feed')
              : null,
          title: Text(l10n.t('settings.account.profile')),
        ),
        body: const LoadingView(),
      );
    }
    if (_error != null) {
      return Scaffold(
        backgroundColor: social.surfaceBase,
        extendBodyBehindAppBar: true,
        appBar: LiquidGlassAppBar(
          automaticallyImplyLeading: showProfileBack,
          leading: showProfileBack
              ? const SafeBackButton(fallbackRoute: '/feed')
              : null,
          title: Text(l10n.t('settings.account.profile')),
        ),
        body: ErrorView(error: _error!, onRetry: _load),
      );
    }
    final user = _user;
    if (user == null) {
      return Scaffold(
        backgroundColor: social.surfaceBase,
        extendBodyBehindAppBar: true,
        appBar: LiquidGlassAppBar(
          automaticallyImplyLeading: showProfileBack,
          leading: showProfileBack
              ? const SafeBackButton(fallbackRoute: '/feed')
              : null,
          title: Text(l10n.t('settings.account.profile')),
        ),
        body: EmptyView(message: l10n.t('feed.empty')),
      );
    }

    final displayName = user.displayName.trim().isEmpty
        ? user.username
        : user.displayName;
    final showPostsErrorFull =
        _postsError != null && displayedPosts.isEmpty && !_loadingPosts;

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: social.surfaceBase,
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppBreakpoints.contentMaxWidth,
          ),
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.metrics.axis == Axis.vertical) {
                final showCollapsed = n.metrics.pixels > 130;
                if (showCollapsed != _showAppBarTitle) {
                  setState(() => _showAppBarTitle = showCollapsed);
                }
                if (_activeTab == 0 &&
                    n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
                  _loadMore();
                }
              }
              return false;
            },
            child: CustomScrollView(
              slivers: [
                SliverAppBar(
                  pinned: true,
                  toolbarHeight: 56,
                  elevation: 0,
                  scrolledUnderElevation: 0,
                  backgroundColor: Colors.transparent,
                  surfaceTintColor: Colors.transparent,
                  forceMaterialTransparency: true,
                  automaticallyImplyLeading: showProfileBack,
                  flexibleSpace: const LiquidGlassSurface(
                    preset: LiquidGlassPreset.stickyHeader,
                    borderRadius: BorderRadius.zero,
                    child: SizedBox.expand(),
                  ),
                  leading: showProfileBack
                      ? const SafeBackButton(fallbackRoute: '/feed')
                      : null,
                  title: AnimatedSwitcher(
                    duration: AppMotion.resolve(context, AppMotion.fast),
                    child: _showAppBarTitle
                        ? Column(
                            key: const ValueKey('collapsed-profile-title'),
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                l10n
                                    .t('profile.posts_subtitle')
                                    .replaceFirst(
                                      '{count}',
                                      '${user.postsCount}',
                                    ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          )
                        : const SizedBox.shrink(
                            key: ValueKey('empty-profile-title'),
                          ),
                  ),
                  actions: [
                    if (signedIn &&
                        !_changing &&
                        user.userId == widget.userId &&
                        !user.relationship.isSelf)
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
                          if (!_locallyBlocked && !user.relationship.isBlocking)
                            PopupMenuItem(
                              value: _VisibilityAction.block,
                              child: Text(l10n.t('visibility.block')),
                            ),
                        ],
                      ),
                  ],
                ),
                SliverToBoxAdapter(
                  child: _ProfileHeader(
                    user: user,
                    onFollow: _relationshipBusy ? null : _toggleFollow,
                    onMessage: _relationshipBusy ? null : _openDirectMessage,
                    onEditProfile: () => context.push('/account/profile'),
                    restricted: _restricted,
                  ),
                ),
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _ProfileTabsDelegate(
                    selectedIndex: _activeTab,
                    labels: [
                      l10n.t('profile.tab.posts'),
                      l10n.t('profile.tab.replies'),
                      l10n.t('profile.tab.media'),
                    ],
                    onSelect: (index) {
                      if (_activeTab != index) {
                        setState(() => _activeTab = index);
                      }
                    },
                  ),
                ),
                if (_loadingPosts)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                      child: Column(
                        children: [
                          for (var i = 0; i < 4; i++)
                            const Padding(
                              padding: EdgeInsets.only(bottom: 12),
                              child: PostSkeleton(),
                            ),
                        ],
                      ),
                    ),
                  )
                else if (showPostsErrorFull)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: ErrorView(
                        error: _postsError!,
                        onRetry: _loadPosts,
                      ),
                    ),
                  )
                else if (displayedPosts.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: EmptyView(message: l10n.t('feed.empty')),
                    ),
                  )
                else ...[
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final post = displayedPosts[index];
                        return Padding(
                          key: ValueKey(post.postId),
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          child: PostCard(
                            post: post,
                            avatarHeroTag:
                                'avatar-${post.postId}-${post.author.userId}',
                            profilePinned: pin?.post?.postId == post.postId,
                            onChangeProfilePin:
                                canPin &&
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
                              final idx = _posts.indexWhere(
                                (item) => item.postId == updated.postId,
                              );
                              if (idx >= 0) {
                                setState(() => _posts[idx] = updated);
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
                        );
                      },
                      childCount: displayedPosts.length,
                      findChildIndexCallback: (key) {
                        if (key is! ValueKey<int>) return null;
                        final idx = displayedPosts.indexWhere(
                          (post) => post.postId == key.value,
                        );
                        return idx < 0 ? null : idx;
                      },
                    ),
                  ),
                  if (_activeTab == 0 && (_hasNext || _postsError != null))
                    SliverToBoxAdapter(
                      child: _postsError != null
                          ? ErrorView(error: _postsError!, onRetry: _loadPosts)
                          : const Padding(
                              padding: EdgeInsets.all(24),
                              child: Center(child: CircularProgressIndicator()),
                            ),
                    ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 96)),
              ],
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
    required this.onEditProfile,
    required this.restricted,
  });

  final V2PublicUser user;
  final VoidCallback? onFollow;
  final VoidCallback? onMessage;
  final VoidCallback onEditProfile;
  final bool restricted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final social = SocialColors.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context);
    final displayName = user.displayName.trim().isEmpty
        ? user.username
        : user.displayName;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Container(
        decoration: BoxDecoration(
          color: social.surfaceCard,
          borderRadius: BorderRadius.circular(AppRadius.card),
          boxShadow: isDark
              ? const <BoxShadow>[]
              : const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x080F172A),
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                SubtleGridBox(
                  backgroundColor: scheme.surfaceContainer,
                  child: const SizedBox(height: 116, width: double.infinity),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 76, 16, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0.94, end: 1.0),
                        duration: AppMotion.resolve(context, AppMotion.glide),
                        curve: AppMotion.glideCurve,
                        builder: (context, scale, child) =>
                            Transform.scale(scale: scale, child: child),
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: social.surfaceCard,
                                border: Border.all(
                                  color: social.surfaceCard,
                                  width: 4,
                                ),
                              ),
                              child: AppAvatar(
                                url: user.avatarUrl,
                                size: 80,
                                name: displayName,
                                seed: user.userId,
                              ),
                            ),
                            if (user.onlineStatus == 'online')
                              Positioned(
                                right: 4,
                                bottom: 4,
                                child: Tooltip(
                                  message: l10n.t('profile.online'),
                                  child: Container(
                                    width: 15,
                                    height: 15,
                                    decoration: BoxDecoration(
                                      color: social.statusOnlineFg,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: social.surfaceCard,
                                        width: 2.5,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (user.relationship.isSelf)
                              FilledButton.tonal(
                                onPressed: onEditProfile,
                                style: FilledButton.styleFrom(
                                  backgroundColor: scheme.surfaceContainer,
                                  foregroundColor: scheme.onSurface,
                                  elevation: 0,
                                  shape: const StadiumBorder(),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 10,
                                  ),
                                ),
                                child: Text(
                                  l10n.t('profile.edit_profile'),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              )
                            else if (!restricted) ...[
                              IconButton.filledTonal(
                                tooltip: l10n.t('profile.message'),
                                onPressed: onMessage,
                                style: IconButton.styleFrom(
                                  backgroundColor: scheme.surfaceContainer,
                                  foregroundColor: scheme.onSurface,
                                  fixedSize: const Size(38, 38),
                                ),
                                icon: const Icon(Icons.mail_outline, size: 18),
                              ),
                              const SizedBox(width: 8),
                              _FollowButton(
                                isFollowing: user.relationship.isFollowing,
                                followLabel: l10n.t('common.follow'),
                                followingLabel: l10n.t('right_rail.following'),
                                unfollowLabel: l10n.t('common.unfollow'),
                                onTap: onFollow,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          displayName,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.2,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (user.verified) ...[
                        const SizedBox(width: 4),
                        Icon(Icons.verified, size: 18, color: scheme.primary),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '@${user.username}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: 13.5,
                      color: social.inkTertiary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (user.bio.trim().isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      user.bio,
                      style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
                    ),
                  ],
                  if (user.location.isNotEmpty || user.website.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 14,
                      runSpacing: 6,
                      children: [
                        if (user.location.isNotEmpty)
                          _MetaItem(
                            icon: Icons.place_outlined,
                            text: user.location,
                          ),
                        if (user.website.isNotEmpty)
                          _MetaItem(icon: Icons.link, text: user.website),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 18,
                    runSpacing: 6,
                    children: [
                      _ProfileStat(
                        label: l10n.t('profile.following'),
                        value: user.followingCount,
                      ),
                      _ProfileStat(
                        label: l10n.t('profile.followers'),
                        value: user.followersCount,
                      ),
                      _ProfileStat(
                        label: l10n.t('profile.posts'),
                        value: user.postsCount,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FollowButton extends StatefulWidget {
  const _FollowButton({
    required this.isFollowing,
    required this.followLabel,
    required this.followingLabel,
    required this.unfollowLabel,
    required this.onTap,
  });

  final bool isFollowing;
  final String followLabel;
  final String followingLabel;
  final String unfollowLabel;
  final VoidCallback? onTap;

  @override
  State<_FollowButton> createState() => _FollowButtonState();
}

class _FollowButtonState extends State<_FollowButton> {
  bool _hovered = false;

  void _handleTap() {
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android)) {
      HapticFeedback.lightImpact();
    }
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final showUnfollow = widget.isFollowing && _hovered;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedSize(
        duration: AppMotion.resolve(context, AppMotion.glide),
        curve: AppMotion.glideCurve,
        child: widget.isFollowing
            ? FilledButton.tonal(
                onPressed: widget.onTap == null ? null : _handleTap,
                style: FilledButton.styleFrom(
                  shape: const StadiumBorder(),
                  elevation: 0,
                  foregroundColor: showUnfollow
                      ? scheme.error
                      : scheme.onSurface,
                  backgroundColor: showUnfollow
                      ? scheme.error.withValues(alpha: 0.10)
                      : scheme.surfaceContainer,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 10,
                  ),
                ),
                child: Text(
                  showUnfollow ? widget.unfollowLabel : widget.followingLabel,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              )
            : FilledButton(
                onPressed: widget.onTap == null ? null : _handleTap,
                style: FilledButton.styleFrom(
                  shape: const StadiumBorder(),
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                ),
                child: Text(
                  widget.followLabel,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
      ),
    );
  }
}

class _ProfileTabsDelegate extends SliverPersistentHeaderDelegate {
  const _ProfileTabsDelegate({
    required this.selectedIndex,
    required this.labels,
    required this.onSelect,
  });

  final int selectedIndex;
  final List<String> labels;
  final ValueChanged<int> onSelect;

  @override
  double get minExtent => 54;

  @override
  double get maxExtent => 54;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return LiquidGlassSurface(
      preset: LiquidGlassPreset.stickyHeader,
      borderRadius: BorderRadius.zero,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: LiquidGlassSegmentedControl<int>(
        options: labels.indexed.toList(),
        selected: selectedIndex,
        onSelect: onSelect,
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _ProfileTabsDelegate oldDelegate) =>
      oldDelegate.selectedIndex != selectedIndex ||
      oldDelegate.labels != labels;
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
        Icon(icon, size: 15, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
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
        AnimatedCount(
          count: value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
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
