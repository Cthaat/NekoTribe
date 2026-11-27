import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/theme/theme_color_picker.dart';
import '../../../shared/theme/tokens.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/glass/liquid_glass_bars.dart';
import '../../../shared/widgets/glass/liquid_glass_surface.dart';
import '../../../shared/widgets/glass/liquid_glass_tokens.dart';
import '../../../shared/widgets/safe_back_button.dart';
import '../../../shared/widgets/ui/settings_group.dart';
import '../../../shared/widgets/ui/surface_card.dart';

class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final themePreference = ref.watch(themeProvider);
    final locale = ref.watch(localeProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final social = SocialColors.of(context);
    return Scaffold(
      backgroundColor: social.surfaceBase,
      extendBodyBehindAppBar: true,
      appBar: LiquidGlassAppBar(
        leading: const SafeBackButton(fallbackRoute: '/me'),
        title: Text(l10n.t('settings.appearance.title')),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppBreakpoints.contentMaxWidth,
          ),
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              kToolbarHeight + MediaQuery.paddingOf(context).top + 12,
              16,
              96,
            ),
            children: [
              SurfaceCard(
                radius: AppRadius.card,
                padding: const EdgeInsets.all(18),
                child: Column(
                  children: [
                    Text(
                      l10n.t('appearance.preview_title'),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 268),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: ShapeDecoration(
                          color: social.surfaceSubtle,
                          shape: RoundedSuperellipseBorder(
                            borderRadius: BorderRadius.circular(
                              AppRadius.canvas,
                            ),
                          ),
                        ),
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
                          decoration: ShapeDecoration(
                            color: social.surfaceBase,
                            shape: RoundedSuperellipseBorder(
                              borderRadius: BorderRadius.circular(
                                AppRadius.card,
                              ),
                            ),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 42,
                                height: 4,
                                decoration: BoxDecoration(
                                  color: scheme.surfaceContainerHigh,
                                  borderRadius: BorderRadius.circular(
                                    AppRadius.pill,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Stack(
                                alignment: Alignment.bottomCenter,
                                children: [
                                  Column(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(12),
                                        decoration: ShapeDecoration(
                                          color: social.surfaceCard,
                                          shape: RoundedSuperellipseBorder(
                                            borderRadius: BorderRadius.circular(
                                              AppRadius.card,
                                            ),
                                            side:
                                                theme.brightness ==
                                                    Brightness.dark
                                                ? BorderSide(
                                                    color: Colors.white
                                                        .withValues(
                                                          alpha: 0.055,
                                                        ),
                                                    width: 0.8,
                                                  )
                                                : BorderSide.none,
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                AppAvatar(
                                                  url: null,
                                                  size: 36,
                                                  name: l10n.t(
                                                    'appearance.preview_sample_name',
                                                  ),
                                                  seed: 7,
                                                ),
                                                const SizedBox(width: 10),
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Text(
                                                        l10n.t(
                                                          'appearance.preview_sample_name',
                                                        ),
                                                        style: theme
                                                            .textTheme
                                                            .labelLarge
                                                            ?.copyWith(
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w600,
                                                            ),
                                                      ),
                                                      const SizedBox(height: 4),
                                                      Text(
                                                        l10n.t(
                                                          'appearance.preview_sample_msg',
                                                        ),
                                                        style: theme
                                                            .textTheme
                                                            .bodySmall
                                                            ?.copyWith(
                                                              color: scheme
                                                                  .onSurfaceVariant,
                                                              height: 1.5,
                                                            ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 10),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 10,
                                                    vertical: 8,
                                                  ),
                                              decoration: ShapeDecoration(
                                                color: social.surfaceSubtle,
                                                shape: RoundedSuperellipseBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        AppRadius.tile,
                                                      ),
                                                ),
                                              ),
                                              child: Row(
                                                children: [
                                                  Container(
                                                    width: 8,
                                                    height: 8,
                                                    decoration: BoxDecoration(
                                                      color: scheme.primary,
                                                      shape: BoxShape.circle,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Expanded(
                                                    child: Container(
                                                      height: 8,
                                                      decoration: BoxDecoration(
                                                        color: social
                                                            .surfaceHover,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              AppRadius.pill,
                                                            ),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(height: 10),
                                            Align(
                                              alignment: Alignment.centerRight,
                                              child: AnimatedContainer(
                                                duration: AppMotion.resolve(
                                                  context,
                                                  AppMotion.glide,
                                                ),
                                                curve: AppMotion.glideCurve,
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 14,
                                                      vertical: 6,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: scheme.primary,
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        AppRadius.pill,
                                                      ),
                                                ),
                                                child: Text(
                                                  l10n.t('common.follow'),
                                                  style: theme
                                                      .textTheme
                                                      .labelMedium
                                                      ?.copyWith(
                                                        color: scheme.onPrimary,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Row(
                                        children: [
                                          for (final color in [
                                            scheme.primary,
                                            const Color(0xFFEC4899),
                                            const Color(0xFF16A34A),
                                          ])
                                            Expanded(
                                              child: Container(
                                                height: 42,
                                                margin:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 3,
                                                    ),
                                                decoration: ShapeDecoration(
                                                  color: color,
                                                  shape: RoundedSuperellipseBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          AppRadius.tile,
                                                        ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 22),
                                    ],
                                  ),
                                  LiquidGlassSurface(
                                    preset: LiquidGlassPreset.navDock,
                                    intensityOverride:
                                        themePreference.glassIntensity,
                                    borderRadius: BorderRadius.circular(
                                      AppRadius.pill,
                                    ),
                                    padding: const EdgeInsets.all(4),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: LiquidGlassSurface(
                                            preset:
                                                LiquidGlassPreset.pillIndicator,
                                            borderRadius: BorderRadius.circular(
                                              AppRadius.pill,
                                            ),
                                            blurEnabled: false,
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 5,
                                            ),
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(
                                                  Icons.home_rounded,
                                                  color: scheme.primary,
                                                  size: 14,
                                                ),
                                                const SizedBox(height: 1),
                                                Text(
                                                  l10n.t('tab.home'),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: theme
                                                      .textTheme
                                                      .labelSmall
                                                      ?.copyWith(
                                                        fontSize: 9.5,
                                                        height: 1.1,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                        color: scheme.primary,
                                                      ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        for (final item in [
                                          (
                                            Icons.groups_outlined,
                                            l10n.t('group.title'),
                                          ),
                                          (
                                            Icons.notifications_none,
                                            l10n.t('tab.notifications'),
                                          ),
                                        ])
                                          Expanded(
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 4,
                                                    vertical: 5,
                                                  ),
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(
                                                    item.$1,
                                                    color:
                                                        scheme.onSurfaceVariant,
                                                    size: 14,
                                                  ),
                                                  const SizedBox(height: 1),
                                                  Text(
                                                    item.$2,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: theme
                                                        .textTheme
                                                        .labelSmall
                                                        ?.copyWith(
                                                          fontSize: 9.5,
                                                          height: 1.1,
                                                          color: scheme
                                                              .onSurfaceVariant,
                                                        ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SettingsGroup(
                title: l10n.t('theme.glass'),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: _TonalSegmentedControl<LiquidGlassIntensity>(
                      selected: themePreference.glassIntensity,
                      onSelected: (intensity) => ref
                          .read(themeProvider.notifier)
                          .setGlassIntensity(intensity),
                      options: [
                        for (final intensity in LiquidGlassIntensity.values)
                          _TonalSegmentOption(
                            value: intensity,
                            label: l10n.t('theme.glass.${intensity.name}'),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              SettingsGroup(
                title: l10n.t('theme.mode'),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: _TonalSegmentedControl<ThemeMode>(
                      selected: themePreference.mode,
                      onSelected: (mode) =>
                          ref.read(themeProvider.notifier).setMode(mode),
                      options: [
                        _TonalSegmentOption(
                          value: ThemeMode.system,
                          icon: Icons.brightness_auto,
                          label: l10n.t('settings.option.system'),
                        ),
                        _TonalSegmentOption(
                          value: ThemeMode.light,
                          icon: Icons.light_mode,
                          label: l10n.t('settings.option.light'),
                        ),
                        _TonalSegmentOption(
                          value: ThemeMode.dark,
                          icon: Icons.dark_mode,
                          label: l10n.t('settings.option.dark'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              SettingsGroup(
                title: l10n.t('theme.color'),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      child: ThemeColorPicker(
                        selected: themePreference.seedColor,
                        onSelected: (color) => ref
                            .read(themeProvider.notifier)
                            .setSeedColor(color),
                      ),
                    ),
                  ),
                ],
              ),
              SettingsGroup(
                title: l10n.t('settings.appearance.font_size'),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _TonalSegmentedControl<AppFontSize>(
                          selected: themePreference.fontSize,
                          onSelected: (size) => ref
                              .read(themeProvider.notifier)
                              .setFontSize(size),
                          options: [
                            _TonalSegmentOption(
                              value: AppFontSize.small,
                              label: l10n.t(
                                'settings.appearance.font_size.small',
                              ),
                            ),
                            _TonalSegmentOption(
                              value: AppFontSize.normal,
                              label: l10n.t(
                                'settings.appearance.font_size.normal',
                              ),
                            ),
                            _TonalSegmentOption(
                              value: AppFontSize.large,
                              label: l10n.t(
                                'settings.appearance.font_size.large',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          l10n.t('settings.appearance.font_size_hint'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              SettingsGroup(
                title: l10n.t('common.language'),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: _TonalSegmentedControl<String>(
                      selected: locale?.languageCode ?? 'system',
                      onSelected: (selected) {
                        ref
                            .read(localeProvider.notifier)
                            .set(
                              selected == 'system' ? null : Locale(selected),
                            );
                      },
                      options: [
                        _TonalSegmentOption(
                          value: 'system',
                          label: l10n.t('settings.option.system'),
                        ),
                        _TonalSegmentOption(
                          value: 'zh',
                          label: l10n.t('settings.option.zh'),
                        ),
                        _TonalSegmentOption(
                          value: 'en',
                          label: l10n.t('settings.option.en'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              SettingsGroup(
                title: l10n.t('settings.appearance.compact'),
                children: [
                  SwitchListTile(
                    secondary: const Icon(
                      Icons.view_compact_outlined,
                      size: 20,
                    ),
                    title: Text(l10n.t('settings.appearance.compact_hint')),
                    value: themePreference.compactMode,
                    onChanged: (value) =>
                        ref.read(themeProvider.notifier).setCompactMode(value),
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

class _TonalSegmentOption<T> {
  const _TonalSegmentOption({
    required this.value,
    required this.label,
    this.icon,
  });

  final T value;
  final String label;
  final IconData? icon;
}

class _TonalSegmentedControl<T> extends StatelessWidget {
  const _TonalSegmentedControl({
    required this.selected,
    required this.options,
    required this.onSelected,
  });

  final T selected;
  final List<_TonalSegmentOption<T>> options;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final social = SocialColors.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: social.surfaceSubtle,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        children: [
          for (final option in options)
            Expanded(
              child: Semantics(
                button: true,
                selected: option.value == selected,
                child: AnimatedContainer(
                  duration: AppMotion.resolve(context, AppMotion.fast),
                  curve: AppMotion.glideCurve,
                  decoration: BoxDecoration(
                    color: option.value == selected
                        ? social.surfaceCard
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      onTap: () => onSelected(option.value),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 9,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (option.icon != null) ...[
                              Icon(
                                option.icon,
                                size: 16,
                                color: option.value == selected
                                    ? scheme.onSurface
                                    : scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 6),
                            ],
                            Flexible(
                              child: Text(
                                option.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelLarge?.copyWith(
                                  fontWeight: option.value == selected
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  color: option.value == selected
                                      ? scheme.onSurface
                                      : scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
