import 'package:flutter/material.dart';

import '../i18n/app_localizations.dart';
import '../motion/pressable.dart';
import 'app_theme.dart';
import 'tokens.dart';

class ThemeColorPicker extends StatelessWidget {
  const ThemeColorPicker({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final Color selected;
  final ValueChanged<Color> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final duration = AppMotion.resolve(context, AppMotion.fast);
    final surface = Theme.of(context).colorScheme.surface;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final option in AppTheme.seedOptions)
          _SwatchItem(
            option: option,
            label: l10n.t(option.labelKey),
            selected:
                selected.toARGB32() == option.color.toARGB32() ||
                (option.color.toARGB32() ==
                        AppTheme.defaultSeedColor.toARGB32() &&
                    selected.toARGB32() == 0xFF2563EB),
            duration: duration,
            surface: surface,
            onTap: () => onSelected(option.color),
          ),
      ],
    );
  }
}

class _SwatchItem extends StatelessWidget {
  const _SwatchItem({
    required this.option,
    required this.label,
    required this.selected,
    required this.duration,
    required this.surface,
    required this.onTap,
  });

  final ThemeSeedOption option;
  final String label;
  final bool selected;
  final Duration duration;
  final Color surface;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: Pressable(
          scale: 0.90,
          haptic: HapticKind.selection,
          onTap: onTap,
          child: AnimatedScale(
            scale: selected ? 1.08 : 1.0,
            duration: duration,
            curve: AppMotion.emphasizedDecelerate,
            child: AnimatedContainer(
              duration: duration,
              curve: AppMotion.emphasizedDecelerate,
              width: 42,
              height: 42,
              padding: const EdgeInsets.all(2.5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: surface,
                border: Border.all(
                  color: selected ? option.color : Colors.transparent,
                  width: 2.5,
                ),
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: option.color,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
