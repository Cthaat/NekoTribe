import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/app_avatar.dart';
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
          await ref.read(usersRepositoryProvider).getCurrentUser();
      if (!mounted) return;
      setState(() {
        _user = user;
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

  Future<void> _logout() async {
    await ref.read(authRepositoryProvider).logout();
    if (!mounted) return;
    ref.read(authSessionProvider.notifier).markLoggedOut();
    context.go('/auth/login');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('tab.profile')),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: _loading
          ? const LoadingView()
          : _error != null
              ? ErrorView(error: _error!, onRetry: _load)
              : _user == null
                  ? const SizedBox.shrink()
                  : ListView(
                      children: [
                        const SizedBox(height: 16),
                        Center(
                          child: AppAvatar(url: _user!.avatarUrl, size: 88),
                        ),
                        const SizedBox(height: 8),
                        Center(
                          child: Text(_user!.displayName,
                              style:
                                  Theme.of(context).textTheme.titleLarge),
                        ),
                        Center(child: Text('@${_user!.username}')),
                        const SizedBox(height: 16),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceEvenly,
                            children: [
                              _Stat(
                                  label: l10n.t('profile.followers'),
                                  value: _user!.followersCount),
                              _Stat(
                                  label: l10n.t('profile.following'),
                                  value: _user!.followingCount),
                              _Stat(
                                  label: l10n.t('profile.posts'),
                                  value: _user!.postsCount),
                              _Stat(
                                  label: l10n.t('profile.likes'),
                                  value: _user!.likesCount),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        ListTile(
                          leading: const Icon(Icons.person),
                          title: const Text('Profile'),
                          onTap: () => context
                              .push('/users/${_user!.username}'),
                        ),
                        ListTile(
                          leading: const Icon(Icons.group),
                          title: const Text('Groups'),
                          onTap: () => context.push('/groups'),
                        ),
                        ListTile(
                          leading: const Icon(Icons.shield),
                          title: Text(l10n.t('moderation.title')),
                          onTap: () => context.push('/moderation'),
                        ),
                        ListTile(
                          leading: const Icon(Icons.psychology),
                          title: Text(l10n.t('sentiment.title')),
                          onTap: () => context.push('/sentiment'),
                        ),
                        ListTile(
                          leading: const Icon(Icons.settings),
                          title: Text(l10n.t('common.settings')),
                          onTap: () => context.push('/settings'),
                        ),
                        const Divider(),
                        ListTile(
                          leading: Icon(Icons.logout,
                              color: Theme.of(context).colorScheme.error),
                          title: Text(l10n.t('auth.logout'),
                              style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .error)),
                          onTap: _logout,
                        ),
                      ],
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
    return Column(
      children: [
        Text('$value',
            style: Theme.of(context).textTheme.titleMedium),
        Text(label,
            style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
