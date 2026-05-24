import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/user_models.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  V2UserSettings? _settings;
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
      final s = await ref.read(usersRepositoryProvider).getSettings();
      if (!mounted) return;
      setState(() {
        _settings = s;
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

  Future<void> _patch(Map<String, dynamic> body) async {
    try {
      final s =
          await ref.read(usersRepositoryProvider).updateSettings(body);
      if (!mounted) return;
      setState(() => _settings = s);
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
    final themeMode = ref.watch(themeProvider);
    final locale = ref.watch(localeProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('common.settings'))),
      body: _loading
          ? const LoadingView()
          : _error != null
              ? ErrorView(error: _error!, onRetry: _load)
              : ListView(
                  children: [
                    _Section(title: 'Appearance'),
                    ListTile(
                      leading: const Icon(Icons.palette_outlined),
                      title: const Text('Appearance workspace'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => context.push('/settings/appearance'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.brightness_6),
                      title: Text(l10n.t('common.theme')),
                      trailing: DropdownButton<ThemeMode>(
                        value: themeMode,
                        onChanged: (v) {
                          if (v != null) {
                            ref.read(themeProvider.notifier).set(v);
                          }
                        },
                        items: const [
                          DropdownMenuItem(
                              value: ThemeMode.system,
                              child: Text('System')),
                          DropdownMenuItem(
                              value: ThemeMode.light, child: Text('Light')),
                          DropdownMenuItem(
                              value: ThemeMode.dark, child: Text('Dark')),
                        ],
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.language),
                      title: Text(l10n.t('common.language')),
                      trailing: DropdownButton<String>(
                        value: locale?.languageCode ?? 'system',
                        onChanged: (v) {
                          if (v == 'system') {
                            ref.read(localeProvider.notifier).set(null);
                          } else if (v != null) {
                            ref
                                .read(localeProvider.notifier)
                                .set(Locale(v));
                          }
                        },
                        items: const [
                          DropdownMenuItem(
                              value: 'system', child: Text('System')),
                          DropdownMenuItem(value: 'zh', child: Text('中文')),
                          DropdownMenuItem(
                              value: 'en', child: Text('English')),
                        ],
                      ),
                    ),
                    const Divider(),
                    _Section(title: 'Account surfaces'),
                    ListTile(
                      leading: const Icon(Icons.edit_outlined),
                      title: const Text('Edit profile'),
                      onTap: () => context.push('/account/profile'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.article_outlined),
                      title: const Text('My posts'),
                      onTap: () => context.push('/account/posts'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.favorite_outline),
                      title: const Text('Liked posts'),
                      onTap: () => context.push('/account/likes'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.bookmark_border),
                      title: const Text('Bookmarks'),
                      onTap: () => context.push('/account/bookmarks'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.workspace_premium_outlined),
                      title: const Text('NekoTribe Pro'),
                      onTap: () => context.push('/settings/pro'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.receipt_long_outlined),
                      title: const Text('Billing'),
                      onTap: () => context.push('/settings/billing'),
                    ),
                    const Divider(),
                    _Section(title: 'Account & Privacy'),
                    SwitchListTile(
                      title: const Text('Login alerts'),
                      value: _settings?.loginAlerts ?? false,
                      onChanged: (v) =>
                          _patch({'login_alerts': v}),
                    ),
                    SwitchListTile(
                      title: const Text('Show online status'),
                      value: _settings?.showOnlineStatus ?? false,
                      onChanged: (v) =>
                          _patch({'show_online_status': v}),
                    ),
                    SwitchListTile(
                      title: const Text('Allow DMs from strangers'),
                      value: _settings?.allowDmFromStrangers ?? false,
                      onChanged: (v) =>
                          _patch({'allow_dm_from_strangers': v}),
                    ),
                    ListTile(
                      title: const Text('Profile visibility'),
                      trailing: DropdownButton<String>(
                        value: _settings?.profileVisibility ?? 'public',
                        onChanged: (v) {
                          if (v != null) {
                            _patch({'profile_visibility': v});
                          }
                        },
                        items: const [
                          DropdownMenuItem(
                              value: 'public', child: Text('Public')),
                          DropdownMenuItem(
                              value: 'followers', child: Text('Followers')),
                          DropdownMenuItem(
                              value: 'private', child: Text('Private')),
                        ],
                      ),
                    ),
                    const Divider(),
                    _Section(title: 'Notifications'),
                    SwitchListTile(
                      title: const Text('Push notifications'),
                      value: _settings?.pushNotificationEnabled ?? false,
                      onChanged: (v) =>
                          _patch({'push_notification_enabled': v}),
                    ),
                    SwitchListTile(
                      title: const Text('Email notifications'),
                      value: _settings?.emailNotificationEnabled ?? false,
                      onChanged: (v) =>
                          _patch({'email_notification_enabled': v}),
                    ),
                    const Divider(),
                    _Section(title: 'SentimentFlow'),
                    SwitchListTile(
                      title: const Text('Enable AI sentiment'),
                      value: _settings?.aiSentimentEnabled ?? false,
                      onChanged: (v) =>
                          _patch({'ai_sentiment_enabled': v}),
                    ),
                    SwitchListTile(
                      title: const Text('Return probabilities'),
                      value:
                          _settings?.aiSentimentReturnProbabilities ?? false,
                      onChanged: (v) =>
                          _patch({'ai_sentiment_return_probabilities': v}),
                    ),
                    SwitchListTile(
                      title: const Text('Include metadata'),
                      value:
                          _settings?.aiSentimentIncludeMetadata ?? false,
                      onChanged: (v) =>
                          _patch({'ai_sentiment_include_metadata': v}),
                    ),
                    const Divider(),
                    _Section(title: 'Security'),
                    ListTile(
                      leading: const Icon(Icons.security),
                      title: const Text('Security'),
                      onTap: () => context.push('/settings/security'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.devices),
                      title: const Text('Sessions'),
                      onTap: () => context.push('/settings/sessions'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.gavel),
                      title: const Text('Account statements'),
                      onTap: () => context.push('/settings/statements'),
                    ),
                    const Divider(),
                    _Section(title: 'Server endpoint'),
                    ListTile(
                      leading: const Icon(Icons.dns_outlined),
                      title: Text(l10n.t('endpoint.title')),
                      subtitle: Text(
                        ref.watch(appConfigProvider).apiBaseUrl,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => context.push('/settings/endpoint'),
                    ),
                  ],
                ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}
