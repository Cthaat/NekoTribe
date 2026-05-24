import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/theme/theme_color_picker.dart';
import '../../../shared/widgets/responsive.dart';

class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final themePreference = ref.watch(themeProvider);
    final locale = ref.watch(localeProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('settings.appearance.title'))),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppBreakpoints.contentMaxWidth,
          ),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _SectionLabel(text: l10n.t('theme.mode')),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: _cardDecoration(theme),
                child: SegmentedButton<ThemeMode>(
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
              ),
              const SizedBox(height: 24),
              _SectionLabel(text: l10n.t('theme.color')),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: _cardDecoration(theme),
                child: ThemeColorPicker(
                  selected: themePreference.seedColor,
                  onSelected: (color) =>
                      ref.read(themeProvider.notifier).setSeedColor(color),
                ),
              ),
              const SizedBox(height: 24),
              _SectionLabel(text: l10n.t('common.language')),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: _cardDecoration(theme),
                child: SegmentedButton<String>(
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
              ),
              const SizedBox(height: 24),
              Container(
                decoration: _cardDecoration(theme),
                child: SwitchListTile(
                  value: false,
                  onChanged: null,
                  title: Text(l10n.t('settings.appearance.compact')),
                  subtitle: Text(l10n.t('settings.appearance.compact_hint')),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  BoxDecoration _cardDecoration(ThemeData theme) => BoxDecoration(
    color: theme.cardTheme.color,
    borderRadius: BorderRadius.circular(14),
    border: Border.all(color: theme.dividerColor),
  );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.labelMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}
