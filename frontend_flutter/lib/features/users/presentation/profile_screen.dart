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
      final user = await ref
          .read(usersRepositoryProvider)
          .getUserById(widget.userId);
      final posts = await ref
          .read(postsApiProvider)
          .getUserPostsById(widget.userId);
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
    if (!requireAuthenticatedAction(context, ref)) return;
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
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _openDirectMessage() async {
    if (_user == null) return;
    if (!requireAuthenticatedAction(context, ref)) return;
    try {
      final conversation = await ref
          .read(chatApiProvider)
          .openConversation(userId: _user!.userId);
      if (!mounted) return;
      final displayName = _user!.displayName.trim().isNotEmpty
          ? _user!.displayName
          : _user!.username;
      context.push(
        '/chat/conversation/${conversation.conversationId}',
        extra: {
          'title': displayName,
          'name': displayName,
        },
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _user == null
              ? l10n.t('settings.account.profile')
              : '@${_user!.username}',
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: _loading
          ? const LoadingView()
          : _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : _user == null
          ? const SizedBox.shrink()
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppBreakpoints.contentMaxWidth,
                ),
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    _ProfileHeader(
                      user: _user!,
                      onFollow: _toggleFollow,
                      onMessage: _openDirectMessage,
                    ),
                    Divider(
                      height: 1,
                      color: Theme.of(context).dividerColor,
                    ),
                    for (var i = 0; i < _posts.length; i++) ...[
                      PostCard(
                        key: ValueKey(_posts[i].postId),
                        post: _posts[i],
                        onChanged: (u) => setState(() => _posts[i] = u),
                        onDeleted: () {
                          _posts.removeAt(i);
                          setState(() {});
                        },
                        onReport: () => showReportDialog(
                          context,
                          ref,
                          targetType: 'post',
                          targetId: _posts[i].postId,
                        ),
                      ),
                      Divider(
                        height: 1,
                        color: Theme.of(context).dividerColor,
                      ),
                    ],
                  ],
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
  });

  final V2PublicUser user;
  final VoidCallback onFollow;
  final VoidCallback onMessage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
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
          if (!user.relationship.isSelf) ...[
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
        Icon(
          icon,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
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
