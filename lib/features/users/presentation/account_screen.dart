import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/ai_conversation_link.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/user_models.dart';

class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen({super.key});

  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  V2SelfUser? _user;
  bool _loading = true;
  Object? _error;
  int _request = 0;
  VoidCallback? _stopSession;

  @override
  void initState() {
    super.initState();
    final tokens = ref.read(tokenStoreProvider);
    var revision = tokens.revision;
    var endpoint = tokens.endpointRevision;
    var changing = tokens.isSessionChanging;
    _stopSession = tokens.listenSessionChanges(() {
      if (revision == tokens.revision &&
          endpoint == tokens.endpointRevision &&
          changing == tokens.isSessionChanging) {
        return;
      }
      revision = tokens.revision;
      endpoint = tokens.endpointRevision;
      changing = tokens.isSessionChanging;
      unawaited(_load());
    });
    ref.listenManual(usersRepositoryProvider, (previous, next) {
      if (!identical(previous, next)) unawaited(_load());
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _stopSession?.call();
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++_request;
    final tokens = ref.read(tokenStoreProvider);
    setState(() {
      _user = null;
      _loading = true;
      _error = null;
    });
    if (tokens.isSessionChanging) return;
    final revision = tokens.revision;
    final endpoint = tokens.endpointRevision;
    final repository = ref.read(usersRepositoryProvider);
    bool isCurrent() =>
        mounted &&
        request == _request &&
        identical(tokens, ref.read(tokenStoreProvider)) &&
        identical(repository, ref.read(usersRepositoryProvider)) &&
        revision == tokens.revision &&
        endpoint == tokens.endpointRevision &&
        !tokens.isSessionChanging;

    try {
      final session = await tokens.read();
      if (!isCurrent()) return;
      if (session == null) {
        setState(() => _loading = false);
        return;
      }
      final user = await repository.getCurrentUser();
      if (!isCurrent()) return;
      setState(() {
        _user = user;
        _loading = false;
      });
    } catch (e) {
      if (!isCurrent()) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _logout() async {
    final repository = ref.read(authRepositoryProvider);
    final receipt = await repository.logout();
    if (!mounted || receipt == null || !repository.isCurrentReceipt(receipt)) {
      return;
    }
    context.go('/auth/login');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('tab.profile')),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push('/settings'),
            tooltip: l10n.t('common.settings'),
          ),
        ],
      ),
      body: _loading
          ? const LoadingView()
          : _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : _user == null
          ? EmptyView(
              message: l10n.t('error.generic'),
              icon: Icons.person_off_outlined,
              actionLabel: l10n.t('common.retry'),
              onAction: _load,
            )
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppBreakpoints.contentMaxWidth,
                ),
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    _AccountHeader(user: _user!),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                      child: Text(
                        l10n.t('settings.account.profile'),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    _Section(
                      tiles: [
                        _Row(
                          icon: Icons.person_outline,
                          label: l10n.t('settings.account.profile'),
                          onTap: () => context.push('/users/${_user!.userId}'),
                        ),
                        _Row(
                          icon: Icons.edit_outlined,
                          label: l10n.t('settings.account.edit_profile'),
                          onTap: () => context.push('/account/profile'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                      child: Text(
                        l10n.t('settings.section.content'),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    _Section(
                      tiles: [
                        _Row(
                          icon: Icons.insights_outlined,
                          label: l10n.t('settings.account.personal_analysis'),
                          onTap: () => context.push('/account/overview'),
                        ),
                        _Row(
                          icon: Icons.query_stats_outlined,
                          label: l10n.t('settings.account.data_analysis'),
                          onTap: () => context.push('/account/data'),
                        ),
                        _Row(
                          icon: Icons.article_outlined,
                          label: l10n.t('settings.account.my_posts'),
                          onTap: () => context.push('/account/posts'),
                        ),
                        _Row(
                          icon: Icons.favorite_outline,
                          label: l10n.t('settings.account.liked_posts'),
                          onTap: () => context.push('/account/likes'),
                        ),
                        _Row(
                          icon: Icons.bookmark_border,
                          label: l10n.t('settings.account.bookmarks'),
                          onTap: () => context.push('/account/bookmarks'),
                        ),
                        _Row(
                          icon: Icons.storage_outlined,
                          label: l10n.t('account.resources.title'),
                          onTap: () => context.push('/account/billing'),
                        ),
                        _Row(
                          icon: Icons.smart_toy_outlined,
                          label: l10n.t('account.resources.ai_title'),
                          onTap: () => context.push('/account/pro'),
                        ),
                        _Row(
                          icon: Icons.groups_outlined,
                          label: l10n.t('settings.account.groups'),
                          onTap: () => context.push('/groups'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                      child: Text(
                        l10n.t('settings.section.tools'),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    _Section(
                      tiles: [
                        _Row(
                          icon: Icons.shield_outlined,
                          label: l10n.t('moderation.title'),
                          onTap: () => context.push('/moderation'),
                        ),
                        _Row(
                          icon: Icons.psychology_outlined,
                          label: l10n.t('ai.knowledge.title'),
                          onTap: () => openAiConversation(context, knowledge: true),
                        ),
                        _Row(
                          icon: Icons.edit_note_outlined,
                          label: l10n.t('ai.writing.title'),
                          onTap: () => openAiConversation(context),
                        ),
                        _Row(
                          icon: Icons.settings_outlined,
                          label: l10n.t('common.settings'),
                          onTap: () => context.push('/settings'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _logout,
                          icon: Icon(
                            Icons.logout,
                            color: theme.colorScheme.error,
                          ),
                          label: Text(
                            l10n.t('auth.logout'),
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                            side: BorderSide(
                              color: theme.colorScheme.error.withValues(
                                alpha: 0.4,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
    );
  }
}

class _AccountHeader extends StatelessWidget {
  const _AccountHeader({required this.user});
  final V2SelfUser user;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
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
            children: [
              AppAvatar(url: user.avatarUrl, size: 72),
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
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Stat(
                label: l10n.t('profile.followers'),
                value: user.followersCount,
              ),
              _Stat(
                label: l10n.t('profile.following'),
                value: user.followingCount,
              ),
              _Stat(label: l10n.t('profile.posts'), value: user.postsCount),
              _Stat(label: l10n.t('profile.likes'), value: user.likesCount),
            ],
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.tiles});
  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(children: tiles),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodyLarge,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(
              Icons.chevron_right,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.45,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
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
      ),
    );
  }
}
