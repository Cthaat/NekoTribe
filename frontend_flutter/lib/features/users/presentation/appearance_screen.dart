import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/theme/theme_color_picker.dart';

class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final themePreference = ref.watch(themeProvider);
    final locale = ref.watch(localeProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('settings.appearance.title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(l10n.t('theme.mode'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SegmentedButton<ThemeMode>(
            segments: [
              ButtonSegment(
                value: ThemeMode.system,
                icon: const Icon(Icons.brightness_auto),
                label: Text(l10n.t('settings.option.system')),
              ),
              ButtonSegment(
                value: ThemeMode.light,
                icon: const Icon(Icons.light_mode),
                label: Text(l10n.t('settings.option.light')),
              ),
              ButtonSegment(
                value: ThemeMode.dark,
                icon: const Icon(Icons.dark_mode),
                label: Text(l10n.t('settings.option.dark')),
              ),
            ],
            selected: {themePreference.mode},
            onSelectionChanged: (value) =>
                ref.read(themeProvider.notifier).setMode(value.first),
          ),
          const SizedBox(height: 24),
          Text(l10n.t('theme.color'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ThemeColorPicker(
            selected: themePreference.seedColor,
            onSelected: (color) =>
                ref.read(themeProvider.notifier).setSeedColor(color),
          ),
          const SizedBox(height: 24),
          Text(
            l10n.t('common.language'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(
                value: 'system',
                label: Text(l10n.t('settings.option.system')),
              ),
              ButtonSegment(
                value: 'zh',
                label: Text(l10n.t('settings.option.zh')),
              ),
              ButtonSegment(
                value: 'en',
                label: Text(l10n.t('settings.option.en')),
              ),
            ],
            selected: {locale?.languageCode ?? 'system'},
            onSelectionChanged: (value) {
              final selected = value.first;
              ref
                  .read(localeProvider.notifier)
                  .set(selected == 'system' ? null : Locale(selected));
            },
          ),
          const SizedBox(height: 24),
          SwitchListTile(
            value: false,
            onChanged: null,
            title: Text(l10n.t('settings.appearance.compact')),
            subtitle: Text(l10n.t('settings.appearance.compact_hint')),
          ),
        ],
      ),
    );
  }
}
