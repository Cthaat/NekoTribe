import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/motion/entrance.dart';
import '../../../shared/motion/skeleton.dart';
import '../../../core/utils/ai_conversation_link.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/motion/animated_count.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/theme/tokens.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../../../shared/widgets/ui/settings_group.dart';
import '../../../shared/widgets/ui/subtle_grid_box.dart';
import '../../../shared/widgets/ui/surface_card.dart';
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
    final scheme = theme.colorScheme;
    final social = SocialColors.of(context);
    return Scaffold(
      backgroundColor: social.surfaceBase,
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
      body: SkeletonCrossFade(loading: _loading, child: _loading
          ? const LoadingView(layout: SkeletonLayout.account)
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
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                  children: [
                    StaggeredEntrance(index: 0, child: _AccountHeader(user: _user!)),
                    const SizedBox(height: 12),
                    StaggeredEntrance(index: 1, child: _BentoShortcutGrid(
                      items: [
                        _BentoShortcutItem(
                          icon: Icons.article_outlined,
                          title: l10n.t('account.shortcut_posts'),
                          subtitle:
                              '${_user!.postsCount} ${l10n.t('profile.posts')} · ${_user!.likesCount} ${l10n.t('profile.likes')}',
                          onTap: () => context.push('/account/posts'),
                        ),
                        _BentoShortcutItem(
                          icon: Icons.auto_awesome_outlined,
                          title: l10n.t('settings.section.ai'),
                          subtitle:
                              '${l10n.t('account.shortcut_writing')} · ${l10n.t('account.shortcut_knowledge')}',
                          onTap: () => openAiConversation(context),
                        ),
                        _BentoShortcutItem(
                          icon: Icons.groups_outlined,
                          title: l10n.t('account.shortcut_groups'),
                          subtitle: l10n.t('settings.account.groups'),
                          onTap: () => context.push('/groups'),
                        ),
                        _BentoShortcutItem(
                          icon: Icons.insights_outlined,
                          title: l10n.t('account.shortcut_analytics'),
                          subtitle: l10n.t('settings.account.personal_analysis'),
                          onTap: () => context.push('/account/overview'),
                        ),
                      ],
                    )),
                    SettingsGroup(
                      title: l10n.t('settings.section.content'),
                      children: [
                        SettingsTile(
                          icon: Icons.favorite_outline_rounded,
                          title: Text(l10n.t('account.shortcut_likes')),
                          trailing: const Icon(Icons.chevron_right, size: 20),
                          onTap: () => context.push('/account/likes'),
                        ),
                        SettingsTile(
                          icon: Icons.bookmark_border_rounded,
                          title: Text(l10n.t('account.shortcut_bookmarks')),
                          trailing: const Icon(Icons.chevron_right, size: 20),
                          onTap: () => context.push('/account/bookmarks'),
                        ),
                        SettingsTile(
                          icon: Icons.psychology_outlined,
                          title: Text(l10n.t('account.shortcut_knowledge')),
                          trailing: const Icon(Icons.chevron_right, size: 20),
                          onTap: () =>
                              openAiConversation(context, knowledge: true),
                        ),
                        SettingsTile(
                          icon: Icons.shield_outlined,
                          title: Text(l10n.t('account.shortcut_moderation')),
                          trailing: const Icon(Icons.chevron_right, size: 20),
                          onTap: () => context.push('/moderation'),
                        ),
                      ],
                    ),
                    SettingsGroup(
                      title: l10n.t('settings.account.profile'),
                      children: [
                        SettingsTile(
                          icon: Icons.edit_outlined,
                          title: Text(l10n.t('settings.account.edit_profile')),
                          trailing: const Icon(Icons.chevron_right, size: 20),
                          onTap: () => context.push('/account/profile'),
                        ),
                        SettingsTile(
                          icon: Icons.palette_outlined,
                          title: Text(l10n.t('settings.appearance.title')),
                          trailing: const Icon(Icons.chevron_right, size: 20),
                          onTap: () => context.push('/settings/appearance'),
                        ),
                        SettingsTile(
                          icon: Icons.tune_rounded,
                          title: Text(l10n.t('common.settings')),
                          trailing: const Icon(Icons.chevron_right, size: 20),
                          onTap: () => context.push('/settings'),
                        ),
                        SettingsTile(
                          icon: Icons.security_outlined,
                          title: Text(l10n.t('account.security.title')),
                          trailing: const Icon(Icons.chevron_right, size: 20),
                          onTap: () => context.push('/settings/security'),
                        ),
                        SettingsTile(
                          icon: Icons.devices_outlined,
                          title: Text(l10n.t('account.sessions.title')),
                          trailing: const Icon(Icons.chevron_right, size: 20),
                          onTap: () => context.push('/settings/sessions'),
                        ),
                        SettingsTile(
                          icon: Icons.visibility_off_outlined,
                          title: Text(l10n.t('visibility.title')),
                          trailing: const Icon(Icons.chevron_right, size: 20),
                          onTap: () => context.push('/settings/relationships'),
                        ),
                      ],
                    ),
                    SettingsGroup(
                      title: l10n.t('settings.section.tools'),
                      children: [
                        SettingsTile(
                          icon: Icons.query_stats_outlined,
                          title: Text(l10n.t('settings.account.data_analysis')),
                          trailing: const Icon(Icons.chevron_right, size: 20),
                          onTap: () => context.push('/account/data'),
                        ),
                        SettingsTile(
                          icon: Icons.smart_toy_outlined,
                          title: Text(l10n.t('account.resources.ai_title')),
                          trailing: const Icon(Icons.chevron_right, size: 20),
                          onTap: () => context.push('/account/pro'),
                        ),
                        SettingsTile(
                          icon: Icons.storage_outlined,
                          title: Text(l10n.t('account.resources.title')),
                          trailing: const Icon(Icons.chevron_right, size: 20),
                          onTap: () => context.push('/account/billing'),
                        ),
                        SettingsTile(
                          icon: Icons.hub_outlined,
                          title: Text(l10n.t('ai.provider.title')),
                          trailing: const Icon(Icons.chevron_right, size: 20),
                          onTap: () => context.push('/settings/ai-provider'),
                        ),
                        SettingsTile(
                          icon: Icons.gavel_outlined,
                          title: Text(l10n.t('account.statements.title')),
                          trailing: const Icon(Icons.chevron_right, size: 20),
                          onTap: () => context.push('/settings/statements'),
                        ),
                        SettingsTile(
                          icon: Icons.info_outline,
                          title: Text(l10n.t('about.title')),
                          trailing: const Icon(Icons.chevron_right, size: 20),
                          onTap: () => context.push('/about'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    SurfaceCard(
                      radius: AppRadius.card,
                      color: scheme.errorContainer.withValues(alpha: 0.25),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 15,
                      ),
                      onTap: _logout,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.logout_rounded,
                            size: 20,
                            color: scheme.error,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            l10n.t('auth.logout'),
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: scheme.error,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            )),
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
    final scheme = theme.colorScheme;
    final social = SocialColors.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final displayName = user.displayName.isEmpty
        ? user.username
        : user.displayName;

    return Container(
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
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SubtleGridBox(
            backgroundColor: scheme.surfaceContainer,
            child: const SizedBox(height: 88, width: double.infinity),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Transform.translate(
                  offset: const Offset(0, -28),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(3.5),
                        decoration: BoxDecoration(
                          color: social.surfaceCard,
                          shape: BoxShape.circle,
                        ),
                        child: AppAvatar(
                          url: user.avatarUrl,
                          size: 68,
                          name: displayName,
                          seed: user.userId,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 32),
                        child: FilledButton.tonalIcon(
                          onPressed: () =>
                              context.push('/users/${user.userId}'),
                          icon: const Icon(Icons.arrow_forward_rounded, size: 16),
                          label: Text(
                            l10n.t('account.view_profile'),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: scheme.surfaceContainer,
                            foregroundColor: scheme.onSurface,
                            elevation: 0,
                            shape: const StadiumBorder(),
                            minimumSize: const Size(0, 34),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 6,
                            ),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Transform.translate(
                  offset: const Offset(0, -14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayName,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
                        const SizedBox(height: 8),
                        Text(
                          user.bio.trim(),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            height: 1.55,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 16,
                        runSpacing: 8,
                        children: [
                          _InlineStat(
                            value: user.followingCount,
                            label: l10n.t('profile.following'),
                          ),
                          _InlineStat(
                            value: user.followersCount,
                            label: l10n.t('profile.followers'),
                          ),
                          _InlineStat(
                            value: user.postsCount,
                            label: l10n.t('profile.posts'),
                          ),
                          _InlineStat(
                            value: user.likesCount,
                            label: l10n.t('profile.likes'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineStat extends StatelessWidget {
  const _InlineStat({required this.value, required this.label});

  final int value;
  final String label;

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
          style: theme.textTheme.titleMedium?.copyWith(
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

class _BentoShortcutItem {
  const _BentoShortcutItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
}

class _BentoShortcutGrid extends StatelessWidget {
  const _BentoShortcutGrid({required this.items});

  final List<_BentoShortcutItem> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var row = 0; row < items.length; row += 2) ...[
          if (row > 0) const SizedBox(height: 10),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _BentoCell(item: items[row])),
                const SizedBox(width: 10),
                Expanded(
                  child: row + 1 < items.length
                      ? _BentoCell(item: items[row + 1])
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _BentoCell extends StatelessWidget {
  const _BentoCell({required this.item});

  final _BentoShortcutItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final social = SocialColors.of(context);
    return SurfaceCard(
      radius: AppRadius.card,
      padding: const EdgeInsets.all(14),
      onTap: item.onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: scheme.surfaceContainer,
              borderRadius: BorderRadius.circular(AppRadius.inner),
            ),
            alignment: Alignment.center,
            child: Icon(item.icon, size: 20, color: scheme.onSurface),
          ),
          const SizedBox(height: 12),
          Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            item.subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 12.5,
              color: social.inkTertiary,
            ),
          ),
        ],
      ),
    );
  }
}
