import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/theme/theme_color_picker.dart';
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
      final s = await ref.read(usersRepositoryProvider).updateSettings(body);
      if (!mounted) return;
      setState(() => _settings = s);
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
    final themePreference = ref.watch(themeProvider);
    final locale = ref.watch(localeProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('common.settings'))),
      body: _loading
          ? const LoadingView()
          : _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : ListView(
              children: [
                _Section(title: l10n.t('settings.section.appearance')),
                ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: Text(l10n.t('settings.appearance.workspace')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/settings/appearance'),
                ),
                ListTile(
                  leading: const Icon(Icons.brightness_6),
                  title: Text(l10n.t('theme.mode')),
                  trailing: DropdownButton<ThemeMode>(
                    value: themePreference.mode,
                    onChanged: (v) {
                      if (v != null) {
                        ref.read(themeProvider.notifier).setMode(v);
                      }
                    },
                    items: [
                      DropdownMenuItem(
                        value: ThemeMode.system,
                        child: Text(l10n.t('settings.option.system')),
                      ),
                      DropdownMenuItem(
                        value: ThemeMode.light,
                        child: Text(l10n.t('settings.option.light')),
                      ),
                      DropdownMenuItem(
                        value: ThemeMode.dark,
                        child: Text(l10n.t('settings.option.dark')),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: ThemeColorPicker(
                    selected: themePreference.seedColor,
                    onSelected: (color) =>
                        ref.read(themeProvider.notifier).setSeedColor(color),
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
                        ref.read(localeProvider.notifier).set(Locale(v));
                      }
                    },
                    items: [
                      DropdownMenuItem(
                        value: 'system',
                        child: Text(l10n.t('settings.option.system')),
                      ),
                      DropdownMenuItem(
                        value: 'zh',
                        child: Text(l10n.t('settings.option.zh')),
                      ),
                      DropdownMenuItem(
                        value: 'en',
                        child: Text(l10n.t('settings.option.en')),
                      ),
                    ],
                  ),
                ),
                const Divider(),
                _Section(title: l10n.t('settings.section.account')),
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: Text(l10n.t('settings.account.edit_profile')),
                  onTap: () => context.push('/account/profile'),
                ),
                ListTile(
                  leading: const Icon(Icons.article_outlined),
                  title: Text(l10n.t('settings.account.my_posts')),
                  onTap: () => context.push('/account/posts'),
                ),
                ListTile(
                  leading: const Icon(Icons.favorite_outline),
                  title: Text(l10n.t('settings.account.liked_posts')),
                  onTap: () => context.push('/account/likes'),
                ),
                ListTile(
                  leading: const Icon(Icons.bookmark_border),
                  title: Text(l10n.t('settings.account.bookmarks')),
                  onTap: () => context.push('/account/bookmarks'),
                ),
                ListTile(
                  leading: const Icon(Icons.workspace_premium_outlined),
                  title: Text(l10n.t('settings.account.pro')),
                  onTap: () => context.push('/settings/pro'),
                ),
                ListTile(
                  leading: const Icon(Icons.receipt_long_outlined),
                  title: Text(l10n.t('settings.account.billing')),
                  onTap: () => context.push('/settings/billing'),
                ),
                const Divider(),
                _Section(title: l10n.t('settings.section.privacy')),
                SwitchListTile(
                  title: Text(l10n.t('settings.privacy.login_alerts')),
                  value: _settings?.loginAlerts ?? false,
                  onChanged: (v) => _patch({'login_alerts': v}),
                ),
                SwitchListTile(
                  title: Text(l10n.t('settings.privacy.show_online_status')),
                  value: _settings?.showOnlineStatus ?? false,
                  onChanged: (v) => _patch({'show_online_status': v}),
                ),
                SwitchListTile(
                  title: Text(l10n.t('settings.privacy.allow_dm_strangers')),
                  value: _settings?.allowDmFromStrangers ?? false,
                  onChanged: (v) => _patch({'allow_dm_from_strangers': v}),
                ),
                ListTile(
                  title: Text(l10n.t('settings.privacy.profile_visibility')),
                  trailing: DropdownButton<String>(
                    value: _settings?.profileVisibility ?? 'public',
                    onChanged: (v) {
                      if (v != null) {
                        _patch({'profile_visibility': v});
                      }
                    },
                    items: [
                      DropdownMenuItem(
                        value: 'public',
                        child: Text(l10n.t('common.public')),
                      ),
                      DropdownMenuItem(
                        value: 'followers',
                        child: Text(l10n.t('common.followers_only')),
                      ),
                      DropdownMenuItem(
                        value: 'private',
                        child: Text(l10n.t('common.private')),
                      ),
                    ],
                  ),
                ),
                const Divider(),
                _Section(title: l10n.t('settings.section.notifications')),
                SwitchListTile(
                  title: Text(l10n.t('settings.notifications.push')),
                  value: _settings?.pushNotificationEnabled ?? false,
                  onChanged: (v) => _patch({'push_notification_enabled': v}),
                ),
                SwitchListTile(
                  title: Text(l10n.t('settings.notifications.email')),
                  value: _settings?.emailNotificationEnabled ?? false,
                  onChanged: (v) => _patch({'email_notification_enabled': v}),
                ),
                const Divider(),
                _Section(title: l10n.t('settings.section.sentiment')),
                SwitchListTile(
                  title: Text(l10n.t('settings.sentiment.enable')),
                  value: _settings?.aiSentimentEnabled ?? false,
                  onChanged: (v) => _patch({'ai_sentiment_enabled': v}),
                ),
                SwitchListTile(
                  title: Text(l10n.t('settings.sentiment.probabilities')),
                  value: _settings?.aiSentimentReturnProbabilities ?? false,
                  onChanged: (v) =>
                      _patch({'ai_sentiment_return_probabilities': v}),
                ),
                SwitchListTile(
                  title: Text(l10n.t('settings.sentiment.metadata')),
                  value: _settings?.aiSentimentIncludeMetadata ?? false,
                  onChanged: (v) =>
                      _patch({'ai_sentiment_include_metadata': v}),
                ),
                const Divider(),
                _Section(title: l10n.t('settings.section.security')),
                ListTile(
                  leading: const Icon(Icons.security),
                  title: Text(l10n.t('settings.security.security')),
                  onTap: () => context.push('/settings/security'),
                ),
                ListTile(
                  leading: const Icon(Icons.devices),
                  title: Text(l10n.t('settings.security.sessions')),
                  onTap: () => context.push('/settings/sessions'),
                ),
                ListTile(
                  leading: const Icon(Icons.gavel),
                  title: Text(l10n.t('settings.security.statements')),
                  onTap: () => context.push('/settings/statements'),
                ),
                const Divider(),
                _Section(title: l10n.t('settings.section.endpoint')),
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
