import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/status_views.dart';
import '../../posts/domain/post_models.dart';
import '../../posts/presentation/post_card.dart';
import '../../posts/presentation/report_dialog.dart';
import '../domain/user_models.dart';

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
      final user =
          await ref.read(usersRepositoryProvider).getUserById(widget.userId);
      final posts =
          await ref.read(postsApiProvider).getUserPostsById(widget.userId);
      if (!mounted) return;
      setState(() {
        _user = user;
        _posts = posts.items;
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

  Future<void> _toggleFollow() async {
    if (_user == null) return;
    final wasFollowing = _user!.relationship.isFollowing;
    try {
      final repo = ref.read(usersRepositoryProvider);
      final rel = wasFollowing
          ? await repo.unfollow(_user!.userId)
          : await repo.follow(_user!.userId);
      if (!mounted) return;
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
          followersCount: _user!.followersCount +
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
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorView.describe(context, e))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(_user == null ? 'Profile' : '@${_user!.username}')),
      body: _loading
          ? const LoadingView()
          : _error != null
              ? ErrorView(error: _error!, onRetry: _load)
              : _user == null
                  ? const SizedBox.shrink()
                  : ListView(
                      children: [
                        const SizedBox(height: 12),
                        Center(child: AppAvatar(url: _user!.avatarUrl, size: 88)),
                        const SizedBox(height: 8),
                        Center(
                          child: Text(_user!.displayName,
                              style:
                                  Theme.of(context).textTheme.titleLarge),
                        ),
                        Center(child: Text('@${_user!.username}')),
                        if (_user!.bio.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(_user!.bio,
                                textAlign: TextAlign.center),
                          ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceEvenly,
                            children: [
                              _ProfileStat(
                                  label: l10n.t('profile.followers'),
                                  value: _user!.followersCount),
                              _ProfileStat(
                                  label: l10n.t('profile.following'),
                                  value: _user!.followingCount),
                              _ProfileStat(
                                  label: l10n.t('profile.posts'),
                                  value: _user!.postsCount),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (!_user!.relationship.isSelf)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32),
                            child: FilledButton(
                              onPressed: _toggleFollow,
                              child: Text(_user!.relationship.isFollowing
                                  ? l10n.t('common.unfollow')
                                  : l10n.t('common.follow')),
                            ),
                          ),
                        const Divider(),
                        for (var i = 0; i < _posts.length; i++)
                          PostCard(
                            key: ValueKey(_posts[i].postId),
                            post: _posts[i],
                            onChanged: (u) =>
                                setState(() => _posts[i] = u),
                            onReport: () => showReportDialog(
                              context,
                              ref,
                              targetType: 'post',
                              targetId: _posts[i].postId,
                            ),
                          ),
                      ],
                    ),
    );
  }
}

class _ProfileStat extends StatelessWidget {
  const _ProfileStat({required this.label, required this.value});
  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text('$value',
            style: Theme.of(context).textTheme.titleMedium),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
