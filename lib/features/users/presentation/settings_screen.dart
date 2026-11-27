import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/ai_conversation_link.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/theme/theme_color_picker.dart';
import '../../../shared/theme/tokens.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/safe_back_button.dart';
import '../../../shared/widgets/status_views.dart';
import '../../../shared/widgets/ui/settings_group.dart';
import '../../auth/data/auth_repository.dart';
import '../data/users_repository.dart';
import '../domain/user_models.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  V2UserSettings? _settings;
  bool _loading = false;
  bool _saving = false;
  bool _expired = false;
  bool _saveUncertain = false;
  int _generation = 0;
  late AuthRepository _owner;
  late UsersRepository _ownerRepository;
  late int _ownerRevision;
  AuthRepository? _observed;
  VoidCallback? _stopObserving;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _owner = ref.read(authRepositoryProvider);
    _ownerRepository = ref.read(usersRepositoryProvider);
    _ownerRevision = _owner.sessionRevision;
    _expired = _owner.isSessionChanging;
    _observe(_owner);
    _load();
  }

  void _observe(AuthRepository auth) {
    if (identical(_observed, auth)) return;
    _stopObserving?.call();
    _observed = auth;
    _stopObserving = auth.listenSessionChanges(() {
      if (!mounted) return;
      if (!identical(auth, _owner) ||
          auth.sessionRevision != _ownerRevision ||
          auth.isSessionChanging) {
        setState(_expire);
      } else {
        setState(() {});
      }
    });
  }

  void _expire() {
    _expired = true;
    _saveUncertain = false;
    _generation++;
    _settings = null;
    _error = null;
    _loading = false;
    _saving = false;
  }

  bool _isCurrent(int generation) =>
      mounted &&
      !_expired &&
      generation == _generation &&
      identical(ref.read(authRepositoryProvider), _owner) &&
      identical(ref.read(usersRepositoryProvider), _ownerRepository) &&
      !_owner.isSessionChanging &&
      _owner.sessionRevision == _ownerRevision;

  void _reopen() {
    final auth = ref.read(authRepositoryProvider);
    if (!_expired || auth.isSessionChanging) return;
    setState(() {
      _owner = auth;
      _ownerRepository = ref.read(usersRepositoryProvider);
      _ownerRevision = auth.sessionRevision;
      _expired = false;
    });
    _load();
  }

  @override
  void dispose() {
    _generation++;
    _stopObserving?.call();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading || _saving || !_isCurrent(_generation)) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _settings = null;
      _error = null;
    });
    try {
      final s = await _ownerRepository.getSettings();
      if (!_isCurrent(generation)) return;
      setState(() {
        _settings = s;
        _loading = false;
        _saveUncertain = false;
      });
    } catch (e) {
      if (!_isCurrent(generation)) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _patch(Map<String, dynamic> body, int generation) async {
    if (!_isCurrent(generation) ||
        _loading ||
        _saving ||
        _settings == null ||
        _error != null) {
      return;
    }
    if (body.containsKey('profile_visibility') &&
        body['profile_visibility'] != 'public' &&
        body['profile_visibility'] != 'private') {
      return;
    }
    setState(() => _saving = true);
    try {
      final s = await _ownerRepository.updateSettings(
        Map<String, dynamic>.unmodifiable(body),
      );
      if (!_isCurrent(generation)) return;
      setState(() {
        _settings = s;
        _generation++;
        _saving = false;
      });
    } catch (e) {
      if (!_isCurrent(generation)) return;
      setState(() {
        _settings = null;
        _error = e;
        _saveUncertain = true;
        _generation++;
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final auth = ref.watch(authRepositoryProvider);
    final repository = ref.watch(usersRepositoryProvider);
    _observe(auth);
    if (!identical(auth, _owner) ||
        !identical(repository, _ownerRepository) ||
        auth.sessionRevision != _ownerRevision ||
        auth.isSessionChanging) {
      _expire();
    }
    if (_expired) {
      return Scaffold(
        appBar: AppBar(
          leading: const SafeBackButton(fallbackRoute: '/me'),
          title: Text(l10n.t('common.settings')),
        ),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.t('settings.session_changed')),
              const SizedBox(height: 12),
              FilledButton(
                key: const Key('settings-session-reopen'),
                onPressed: auth.isSessionChanging ? null : _reopen,
                child: Text(l10n.t('settings.reopen')),
              ),
            ],
          ),
        ),
      );
    }
    final generation = _generation;
    void patch(Map<String, dynamic> body) {
      _patch(body, generation);
    }

    final themePreference = ref.watch(themeProvider);
    final locale = ref.watch(localeProvider);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: const SafeBackButton(fallbackRoute: '/me'),
        title: Text(l10n.t('common.settings')),
        bottom: _saving
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(),
              )
            : null,
      ),
      body: _loading
          ? const LoadingView()
          : _saveUncertain
          ? EmptyView(
              key: const Key('settings-save-uncertain'),
              message: l10n.t('settings.save_uncertain'),
              icon: Icons.sync_problem_outlined,
              actionLabel: l10n.t('common.retry'),
              onAction: _load,
            )
          : _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppBreakpoints.contentMaxWidth,
                ),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                  children: [
                    SettingsGroup(
                      title: l10n.t('settings.section.appearance'),
                      children: [
                        SettingsTile(
                          icon: Icons.palette_outlined,
                          title: Text(l10n.t('settings.appearance.workspace')),
                          trailing: Icon(
                            Icons.chevron_right,
                            color: scheme.onSurfaceVariant,
                          ),
                          onTap: () => context.push('/settings/appearance'),
                        ),
                        SettingsTile(
                          icon: Icons.brightness_6,
                          title: Text(l10n.t('theme.mode')),
                          trailing: DropdownButton<ThemeMode>(
                            value: themePreference.mode,
                            underline: const SizedBox.shrink(),
                            isDense: true,
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
                            onChanged: (v) {
                              if (v != null) {
                                ref.read(themeProvider.notifier).setMode(v);
                              }
                            },
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppGap.lg,
                            vertical: AppGap.md,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.palette_outlined,
                                    size: 20,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: AppGap.md),
                                  Expanded(
                                    child: Text(
                                      l10n.t('theme.color'),
                                      style: ListTileTheme.of(
                                        context,
                                      ).titleTextStyle,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: AppGap.sm),
                              ThemeColorPicker(
                                selected: themePreference.seedColor,
                                onSelected: (color) => ref
                                    .read(themeProvider.notifier)
                                    .setSeedColor(color),
                              ),
                            ],
                          ),
                        ),
                        SettingsTile(
                          icon: Icons.language,
                          title: Text(l10n.t('common.language')),
                          trailing: DropdownButton<String>(
                            value: locale?.languageCode ?? 'system',
                            underline: const SizedBox.shrink(),
                            isDense: true,
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
                            onChanged: (v) {
                              if (v == 'system') {
                                ref.read(localeProvider.notifier).set(null);
                              } else if (v != null) {
                                ref.read(localeProvider.notifier).set(Locale(v));
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    SettingsGroup(
                      title: l10n.t('settings.section.account'),
                      children: [
                        SettingsTile(
                          icon: Icons.edit_outlined,
                          title: Text(l10n.t('settings.account.edit_profile')),
                          trailing: Icon(
                            Icons.chevron_right,
                            color: scheme.onSurfaceVariant,
                          ),
                          onTap: () => context.push('/account/profile'),
                        ),
                        SettingsTile(
                          icon: Icons.article_outlined,
                          title: Text(l10n.t('settings.account.my_posts')),
                          trailing: Icon(
                            Icons.chevron_right,
                            color: scheme.onSurfaceVariant,
                          ),
                          onTap: () => context.push('/account/posts'),
                        ),
                        SettingsTile(
                          icon: Icons.favorite_outline,
                          title: Text(l10n.t('settings.account.liked_posts')),
                          trailing: Icon(
                            Icons.chevron_right,
                            color: scheme.onSurfaceVariant,
                          ),
                          onTap: () => context.push('/account/likes'),
                        ),
                        SettingsTile(
                          icon: Icons.bookmark_border,
                          title: Text(l10n.t('settings.account.bookmarks')),
                          trailing: Icon(
                            Icons.chevron_right,
                            color: scheme.onSurfaceVariant,
                          ),
                          onTap: () => context.push('/account/bookmarks'),
                        ),
                        SettingsTile(
                          icon: Icons.workspace_premium_outlined,
                          title: Text(l10n.t('settings.account.pro')),
                          trailing: Icon(
                            Icons.chevron_right,
                            color: scheme.onSurfaceVariant,
                          ),
                          onTap: () => context.push('/settings/pro'),
                        ),
                        SettingsTile(
                          icon: Icons.receipt_long_outlined,
                          title: Text(l10n.t('settings.account.billing')),
                          trailing: Icon(
                            Icons.chevron_right,
                            color: scheme.onSurfaceVariant,
                          ),
                          onTap: () => context.push('/settings/billing'),
                        ),
                      ],
                    ),
                    SettingsGroup(
                      title: l10n.t('settings.section.ai'),
                      children: [
                        SettingsTile(
                          icon: Icons.psychology_outlined,
                          title: Text(l10n.t('ai.knowledge.title')),
                          trailing: Icon(
                            Icons.chevron_right,
                            color: scheme.onSurfaceVariant,
                          ),
                          onTap: () =>
                              openAiConversation(context, knowledge: true),
                        ),
                        SettingsTile(
                          icon: Icons.edit_note_outlined,
                          title: Text(l10n.t('ai.writing.title')),
                          trailing: Icon(
                            Icons.chevron_right,
                            color: scheme.onSurfaceVariant,
                          ),
                          onTap: () => openAiConversation(context),
                        ),
                        SettingsTile(
                          icon: Icons.vpn_key_outlined,
                          title: Text(l10n.t('ai.provider.title')),
                          trailing: Icon(
                            Icons.chevron_right,
                            color: scheme.onSurfaceVariant,
                          ),
                          onTap: () => context.push('/settings/ai-provider'),
                        ),
                      ],
                    ),
                    SettingsGroup(
                      title: l10n.t('settings.section.privacy'),
                      children: [
                        SettingsTile(
                          icon: Icons.people_outline,
                          title: Text(l10n.t('visibility.title')),
                          trailing: Icon(
                            Icons.chevron_right,
                            color: scheme.onSurfaceVariant,
                          ),
                          onTap: () => context.push('/settings/relationships'),
                        ),
                        SettingsTile(
                          icon: Icons.notifications_active_outlined,
                          title: Text(l10n.t('settings.privacy.login_alerts')),
                          trailing: Switch(
                            value: _settings?.loginAlerts ?? false,
                            onChanged: _saving
                                ? null
                                : (v) => patch({'login_alerts': v}),
                          ),
                        ),
                        SettingsTile(
                          icon: Icons.visibility_outlined,
                          title: Text(
                            l10n.t('settings.privacy.show_online_status'),
                          ),
                          trailing: Switch(
                            value: _settings?.showOnlineStatus ?? false,
                            onChanged: _saving
                                ? null
                                : (v) => patch({'show_online_status': v}),
                          ),
                        ),
                        SettingsTile(
                          icon: Icons.mail_outline,
                          title: Text(
                            l10n.t('settings.privacy.allow_dm_strangers'),
                          ),
                          trailing: Switch(
                            value: _settings?.allowDmFromStrangers ?? false,
                            onChanged: _saving
                                ? null
                                : (v) => patch({'allow_dm_from_strangers': v}),
                          ),
                        ),
                        SettingsTile(
                          icon: Icons.lock_outline,
                          title: Text(
                            l10n.t('settings.privacy.profile_visibility'),
                          ),
                          trailing: DropdownButton<String>(
                            value: _settings?.profileVisibility ?? 'public',
                            underline: const SizedBox.shrink(),
                            isDense: true,
                            items: [
                              DropdownMenuItem(
                                value: 'public',
                                child: Text(l10n.t('common.public')),
                              ),
                              if (![
                                'public',
                                'private',
                              ].contains(_settings?.profileVisibility))
                                DropdownMenuItem(
                                  value: _settings?.profileVisibility ?? '',
                                  enabled: false,
                                  child: Text(
                                    l10n.t(
                                      'settings.privacy.unknown_visibility',
                                    ),
                                  ),
                                ),
                              DropdownMenuItem(
                                value: 'private',
                                child: Text(l10n.t('common.private')),
                              ),
                            ],
                            onChanged: _saving
                                ? null
                                : (v) {
                                    if (v != null) {
                                      patch({'profile_visibility': v});
                                    }
                                  },
                          ),
                        ),
                      ],
                    ),
                    SettingsGroup(
                      title: l10n.t('settings.section.notifications'),
                      children: [
                        SettingsTile(
                          icon: Icons.notifications_outlined,
                          title: Text(l10n.t('settings.notifications.push')),
                          trailing: Switch(
                            value: _settings?.pushNotificationEnabled ?? false,
                            onChanged: _saving
                                ? null
                                : (v) =>
                                      patch({'push_notification_enabled': v}),
                          ),
                        ),
                        SettingsTile(
                          icon: Icons.email_outlined,
                          title: Text(l10n.t('settings.notifications.email')),
                          trailing: Switch(
                            value: _settings?.emailNotificationEnabled ?? false,
                            onChanged: _saving
                                ? null
                                : (v) =>
                                      patch({'email_notification_enabled': v}),
                          ),
                        ),
                      ],
                    ),
                    SettingsGroup(
                      title: l10n.t('settings.section.security'),
                      children: [
                        SettingsTile(
                          icon: Icons.security,
                          title: Text(l10n.t('settings.security.security')),
                          trailing: Icon(
                            Icons.chevron_right,
                            color: scheme.onSurfaceVariant,
                          ),
                          onTap: () => context.push('/settings/security'),
                        ),
                        SettingsTile(
                          icon: Icons.devices,
                          title: Text(l10n.t('settings.security.sessions')),
                          trailing: Icon(
                            Icons.chevron_right,
                            color: scheme.onSurfaceVariant,
                          ),
                          onTap: () => context.push('/settings/sessions'),
                        ),
                        SettingsTile(
                          icon: Icons.gavel,
                          title: Text(l10n.t('settings.security.statements')),
                          trailing: Icon(
                            Icons.chevron_right,
                            color: scheme.onSurfaceVariant,
                          ),
                          onTap: () => context.push('/settings/statements'),
                        ),
                      ],
                    ),
                    SettingsGroup(
                      title: l10n.t('settings.section.endpoint'),
                      children: [
                        SettingsTile(
                          icon: Icons.dns_outlined,
                          title: Text(l10n.t('endpoint.title')),
                          subtitle: Text(
                            ref.watch(appConfigProvider).apiBaseUrl,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Icon(
                            Icons.chevron_right,
                            color: scheme.onSurfaceVariant,
                          ),
                          onTap: () => context.push('/settings/endpoint'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
