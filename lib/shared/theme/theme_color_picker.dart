import 'package:flutter/material.dart';

import '../i18n/app_localizations.dart';
import 'app_theme.dart';

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
    final theme = Theme.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final option in AppTheme.seedOptions)
          Tooltip(
            message: l10n.t(option.labelKey),
            child: ChoiceChip(
              selected: selected.toARGB32() == option.color.toARGB32(),
              showCheckmark: false,
              avatar: _ColorDot(color: option.color),
              label: Text(l10n.t(option.labelKey)),
              selectedColor: theme.colorScheme.primaryContainer,
              onSelected: (_) => onSelected(option.color),
            ),
          ),
      ],
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: const SizedBox(width: 14, height: 14),
    );
  }
}
