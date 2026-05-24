import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/theme/theme_color_picker.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../../sentiment_flow/data/sentiment_flow_api.dart';
import '../domain/user_models.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  V2UserSettings? _settings;
  V2SentimentFlowConfig? _sentimentConfig;
  V2SentimentModelsData? _sentimentModels;
  V2SentimentStatsOverview? _sentimentStats;
  Object? _sentimentError;
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
      V2SentimentFlowConfig? sentimentConfig;
      V2SentimentModelsData? sentimentModels;
      V2SentimentStatsOverview? sentimentStats;
      Object? sentimentError;
      try {
        final api = ref.read(sentimentFlowApiProvider);
        sentimentConfig = await api.config();
        if (sentimentConfig.enabled && sentimentConfig.baseUrlConfigured) {
          sentimentModels = await api.listModels();
          sentimentStats = await api.statsOverview();
        }
      } catch (e) {
        sentimentError = e;
      }
      if (!mounted) return;
      setState(() {
        _settings = s;
        _sentimentConfig = sentimentConfig;
        _sentimentModels = sentimentModels;
        _sentimentStats = sentimentStats;
        _sentimentError = sentimentError;
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
    final sentimentModels =
        _sentimentModels?.items ?? const <V2SentimentModelItem>[];
    final configuredModelId = _settings?.aiSentimentModelId;
    final selectedModelId =
        sentimentModels.any((m) => m.modelId == configuredModelId)
        ? configuredModelId!
        : (sentimentModels.isNotEmpty ? sentimentModels.first.modelId : null);
    final topKOptions =
        <int>{1, 2, 3, 5, _settings?.aiSentimentTopK ?? 3}.toList()..sort();
    final selectedTopK = topKOptions.contains(_settings?.aiSentimentTopK)
        ? _settings!.aiSentimentTopK!
        : 3;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('common.settings'))),
      body: _loading
          ? const LoadingView()
          : _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppBreakpoints.contentMaxWidth,
                ),
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    _SectionHeader(title: l10n.t('settings.section.appearance')),
                    _Group(
                      children: [
                        _NavRow(
                          icon: Icons.palette_outlined,
                          label: l10n.t('settings.appearance.workspace'),
                          onTap: () => context.push('/settings/appearance'),
                        ),
                        _Divider(),
                        _DropdownRow(
                          icon: Icons.brightness_6,
                          label: l10n.t('theme.mode'),
                          value: themePreference.mode,
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
                        _Divider(),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                          child: ThemeColorPicker(
                            selected: themePreference.seedColor,
                            onSelected: (color) => ref
                                .read(themeProvider.notifier)
                                .setSeedColor(color),
                          ),
                        ),
                        _Divider(),
                        _DropdownRow(
                          icon: Icons.language,
                          label: l10n.t('common.language'),
                          value: locale?.languageCode ?? 'system',
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
                              ref
                                  .read(localeProvider.notifier)
                                  .set(Locale(v));
                            }
                          },
                        ),
                      ],
                    ),
                    _SectionHeader(title: l10n.t('settings.section.account')),
                    _Group(
                      children: [
                        _NavRow(
                          icon: Icons.edit_outlined,
                          label: l10n.t('settings.account.edit_profile'),
                          onTap: () => context.push('/account/profile'),
                        ),
                        _Divider(),
                        _NavRow(
                          icon: Icons.article_outlined,
                          label: l10n.t('settings.account.my_posts'),
                          onTap: () => context.push('/account/posts'),
                        ),
                        _Divider(),
                        _NavRow(
                          icon: Icons.favorite_outline,
                          label: l10n.t('settings.account.liked_posts'),
                          onTap: () => context.push('/account/likes'),
                        ),
                        _Divider(),
                        _NavRow(
                          icon: Icons.bookmark_border,
                          label: l10n.t('settings.account.bookmarks'),
                          onTap: () => context.push('/account/bookmarks'),
                        ),
                        _Divider(),
                        _NavRow(
                          icon: Icons.workspace_premium_outlined,
                          label: l10n.t('settings.account.pro'),
                          onTap: () => context.push('/settings/pro'),
                        ),
                        _Divider(),
                        _NavRow(
                          icon: Icons.receipt_long_outlined,
                          label: l10n.t('settings.account.billing'),
                          onTap: () => context.push('/settings/billing'),
                        ),
                      ],
                    ),
                    _SectionHeader(title: l10n.t('settings.section.privacy')),
                    _Group(
                      children: [
                        _SwitchRow(
                          icon: Icons.notifications_active_outlined,
                          label: l10n.t('settings.privacy.login_alerts'),
                          value: _settings?.loginAlerts ?? false,
                          onChanged: (v) => _patch({'login_alerts': v}),
                        ),
                        _Divider(),
                        _SwitchRow(
                          icon: Icons.visibility_outlined,
                          label: l10n.t('settings.privacy.show_online_status'),
                          value: _settings?.showOnlineStatus ?? false,
                          onChanged: (v) => _patch({'show_online_status': v}),
                        ),
                        _Divider(),
                        _SwitchRow(
                          icon: Icons.mail_outline,
                          label: l10n.t('settings.privacy.allow_dm_strangers'),
                          value: _settings?.allowDmFromStrangers ?? false,
                          onChanged: (v) =>
                              _patch({'allow_dm_from_strangers': v}),
                        ),
                        _Divider(),
                        _DropdownRow(
                          icon: Icons.lock_outline,
                          label: l10n.t('settings.privacy.profile_visibility'),
                          value: _settings?.profileVisibility ?? 'public',
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
                          onChanged: (v) {
                            if (v != null) _patch({'profile_visibility': v});
                          },
                        ),
                      ],
                    ),
                    _SectionHeader(
                      title: l10n.t('settings.section.notifications'),
                    ),
                    _Group(
                      children: [
                        _SwitchRow(
                          icon: Icons.notifications_outlined,
                          label: l10n.t('settings.notifications.push'),
                          value: _settings?.pushNotificationEnabled ?? false,
                          onChanged: (v) =>
                              _patch({'push_notification_enabled': v}),
                        ),
                        _Divider(),
                        _SwitchRow(
                          icon: Icons.email_outlined,
                          label: l10n.t('settings.notifications.email'),
                          value: _settings?.emailNotificationEnabled ?? false,
                          onChanged: (v) =>
                              _patch({'email_notification_enabled': v}),
                        ),
                      ],
                    ),
                    _SectionHeader(title: l10n.t('settings.section.sentiment')),
                    _Group(
                      children: [
                        _SentimentStatusPanel(
                          config: _sentimentConfig,
                          stats: _sentimentStats,
                          error: _sentimentError,
                        ),
                        _Divider(),
                        _SwitchRow(
                          icon: Icons.psychology_outlined,
                          label: l10n.t('settings.sentiment.enable'),
                          value: _settings?.aiSentimentEnabled ?? false,
                          onChanged: (v) => _patch({'ai_sentiment_enabled': v}),
                        ),
                        _Divider(),
                        _SwitchRow(
                          icon: Icons.analytics_outlined,
                          label: l10n.t('settings.sentiment.probabilities'),
                          value:
                              _settings?.aiSentimentReturnProbabilities ??
                              false,
                          onChanged: (v) =>
                              _patch({'ai_sentiment_return_probabilities': v}),
                        ),
                        _Divider(),
                        _SwitchRow(
                          icon: Icons.data_object_outlined,
                          label: l10n.t('settings.sentiment.metadata'),
                          value:
                              _settings?.aiSentimentIncludeMetadata ?? false,
                          onChanged: (v) =>
                              _patch({'ai_sentiment_include_metadata': v}),
                        ),
                        if (selectedModelId != null) ...[
                          _Divider(),
                          _DropdownRow<String>(
                            icon: Icons.memory_outlined,
                            label: l10n.t('settings.sentiment.model'),
                            value: selectedModelId,
                            items: sentimentModels
                                .map(
                                  (m) => DropdownMenuItem<String>(
                                    value: m.modelId,
                                    child: Text(m.name),
                                  ),
                                )
                                .toList(growable: false),
                            onChanged: (v) {
                              if (v != null) {
                                _patch({'ai_sentiment_model_id': v});
                              }
                            },
                          ),
                        ],
                        _Divider(),
                        _DropdownRow<int>(
                          icon: Icons.format_list_numbered,
                          label: l10n.t('settings.sentiment.top_k'),
                          value: selectedTopK,
                          items: topKOptions
                              .map(
                                (v) => DropdownMenuItem<int>(
                                  value: v,
                                  child: Text('$v'),
                                ),
                              )
                              .toList(growable: false),
                          onChanged: (v) {
                            if (v != null) {
                              _patch({'ai_sentiment_top_k': v});
                            }
                          },
                        ),
                      ],
                    ),
                    _SectionHeader(title: l10n.t('settings.section.security')),
                    _Group(
                      children: [
                        _NavRow(
                          icon: Icons.security,
                          label: l10n.t('settings.security.security'),
                          onTap: () => context.push('/settings/security'),
                        ),
                        _Divider(),
                        _NavRow(
                          icon: Icons.devices,
                          label: l10n.t('settings.security.sessions'),
                          onTap: () => context.push('/settings/sessions'),
                        ),
                        _Divider(),
                        _NavRow(
                          icon: Icons.gavel,
                          label: l10n.t('settings.security.statements'),
                          onTap: () => context.push('/settings/statements'),
                        ),
                      ],
                    ),
                    _SectionHeader(title: l10n.t('settings.section.endpoint')),
                    _Group(
                      children: [
                        _NavRow(
                          icon: Icons.dns_outlined,
                          label: l10n.t('endpoint.title'),
                          subtitle: ref.watch(appConfigProvider).apiBaseUrl,
                          onTap: () => context.push('/settings/endpoint'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Text(
        title,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SentimentStatusPanel extends StatelessWidget {
  const _SentimentStatusPanel({
    required this.config,
    required this.stats,
    required this.error,
  });

  final V2SentimentFlowConfig? config;
  final V2SentimentStatsOverview? stats;
  final Object? error;

  String _summary(BuildContext context) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final predictions = stats?.totalPredictions ?? 0;
    final jobs = stats?.totalTrainingJobs ?? 0;
    if (isZh) return '预测 $predictions 次 · 训练 $jobs 次';
    return '$predictions predictions · $jobs training jobs';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final enabled = config?.enabled == true && config?.baseUrlConfigured == true;
    final iconColor = enabled ? theme.colorScheme.primary : theme.disabledColor;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.psychology_alt_outlined, size: 20, color: iconColor),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  enabled
                      ? l10n.t('settings.sentiment.runtime_ready')
                      : l10n.t('sentiment.disabled'),
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 2),
                Text(
                  error == null ? _summary(context) : ErrorView.describe(context, error!),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;

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
      child: Column(children: children),
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      thickness: 1,
      indent: 52,
      color: Theme.of(context).dividerColor,
    );
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final String? subtitle;

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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.bodyLarge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontFeatures: const [],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
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

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });
  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyLarge,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _DropdownRow<T> extends StatelessWidget {
  const _DropdownRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });
  final IconData icon;
  final String label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
          DropdownButton<T>(
            value: value,
            onChanged: onChanged,
            items: items,
            underline: const SizedBox.shrink(),
            isDense: true,
          ),
        ],
      ),
    );
  }
}
