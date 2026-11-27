import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../../theme/tokens.dart';
import '../safe_back_button.dart';
import 'liquid_glass_surface.dart';
import 'liquid_glass_tokens.dart';

class LiquidGlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  const LiquidGlassAppBar({
    super.key,
    this.title,
    this.leading,
    this.actions,
    this.bottom,
    this.automaticallyImplyLeading = true,
  });

  final Widget? title;
  final Widget? leading;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;
  final bool automaticallyImplyLeading;

  @override
  Size get preferredSize =>
      Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) => AppBar(
    toolbarHeight: kToolbarHeight,
    title: title,
    leading:
        leading ?? (automaticallyImplyLeading ? const SafeBackButton() : null),
    automaticallyImplyLeading: false,
    actions: actions,
    bottom: bottom,
    backgroundColor: Colors.transparent,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    scrolledUnderElevation: 0,
    forceMaterialTransparency: true,
    flexibleSpace: const LiquidGlassSurface(
      preset: LiquidGlassPreset.stickyHeader,
      borderRadius: BorderRadius.zero,
      child: SizedBox.expand(),
    ),
  );
}

class LiquidGlassIconButton extends StatelessWidget {
  const LiquidGlassIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.size = 36,
    this.iconSize = 19,
    this.foregroundColor,
  });

  final Widget icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;
  final double iconSize;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final fg = foregroundColor ?? scheme.onSurface;

    Widget control = LiquidGlassSurface(
      preset: LiquidGlassPreset.iconButton,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      interactive: enabled,
      child: SizedBox.square(
        dimension: size,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: Center(
              child: IconTheme.merge(
                data: IconThemeData(
                  size: iconSize,
                  color: enabled ? fg : fg.withValues(alpha: 0.38),
                ),
                child: icon,
              ),
            ),
          ),
        ),
      ),
    );

    if (tooltip != null && tooltip!.isNotEmpty) {
      control = Tooltip(
        message: tooltip!,
        excludeFromSemantics: true,
        child: control,
      );
    }

    return Semantics(
      button: true,
      enabled: enabled,
      label: tooltip,
      child: control,
    );
  }
}

@immutable
class LiquidGlassNavItem {
  const LiquidGlassNavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.badgeCount = 0,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final int badgeCount;
}

class LiquidGlassNavDock extends StatefulWidget {
  const LiquidGlassNavDock({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<LiquidGlassNavItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  State<LiquidGlassNavDock> createState() => _LiquidGlassNavDockState();
}

class _LiquidGlassNavDockState extends State<LiquidGlassNavDock>
    with SingleTickerProviderStateMixin {
  int get selectedIndex =>
      widget.selectedIndex.clamp(0, math.max(0, widget.items.length - 1));
  late final _position = AnimationController.unbounded(
    vsync: this,
    value: selectedIndex.toDouble(),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) _position.value = selectedIndex.toDouble();
  }

  @override
  void didUpdateWidget(LiquidGlassNavDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex == widget.selectedIndex &&
        oldWidget.items.length == widget.items.length) {
      return;
    }
    final target = selectedIndex.toDouble();
    if (AppMotion.reduced(context) ||
        oldWidget.items.isEmpty ||
        widget.items.isEmpty) {
      _position.value = target;
    } else {
      _position.animateWith(
        SpringSimulation(
          AppMotion.springSnappy,
          _position.value,
          target,
          _position.velocity,
          snapToEnd: true,
        ),
      );
    }
  }

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }

  void _select(int index) {
    if (index != selectedIndex &&
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      HapticFeedback.selectionClick();
    }
    widget.onSelected(index);
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    if (items.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final safeIndex = selectedIndex;
    final pillRadius = BorderRadius.circular(AppRadius.pill);

    return LiquidGlassSurface(
      preset: LiquidGlassPreset.navDock,
      borderRadius: pillRadius,
      padding: const EdgeInsets.all(4),
      child: SizedBox(
        height: 54,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final itemWidth = constraints.maxWidth / items.length;
            return Stack(
              children: [
                AnimatedBuilder(
                  animation: _position,
                  child: LiquidGlassSurface(
                    preset: LiquidGlassPreset.pillIndicator,
                    borderRadius: pillRadius,
                    blurEnabled: false,
                    child: const SizedBox.expand(),
                  ),
                  builder: (context, child) => PositionedDirectional(
                    start:
                        _position.value.clamp(0, items.length - 1) * itemWidth,
                    top: 0,
                    bottom: 0,
                    width: itemWidth,
                    child: child!,
                  ),
                ),
                Material(
                  type: MaterialType.transparency,
                  child: Row(
                    children: [
                      for (var i = 0; i < items.length; i++)
                        Expanded(
                          child: _NavDockItemButton(
                            item: items[i],
                            selected: i == safeIndex,
                            borderRadius: pillRadius,
                            theme: theme,
                            scheme: scheme,
                            onTap: () => _select(i),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _NavDockItemButton extends StatelessWidget {
  const _NavDockItemButton({
    required this.item,
    required this.selected,
    required this.borderRadius,
    required this.theme,
    required this.scheme,
    required this.onTap,
  });

  final LiquidGlassNavItem item;
  final bool selected;
  final BorderRadius borderRadius;
  final ThemeData theme;
  final ColorScheme scheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? scheme.primary : scheme.onSurfaceVariant;
    final iconData = selected ? item.selectedIcon : item.icon;
    Widget iconWidget = TweenAnimationBuilder<double>(
      key: ValueKey((iconData.codePoint, selected)),
      tween: Tween(begin: selected ? 0.90 : 1.0, end: 1.0),
      duration: AppMotion.resolve(context, AppMotion.fast),
      curve: AppMotion.emphasizedDecelerate,
      builder: (context, scale, child) =>
          Transform.scale(scale: scale, child: child),
      child: Icon(iconData, size: 21, color: fg),
    );

    if (item.badgeCount > 0) {
      iconWidget = Badge(
        backgroundColor: scheme.primary,
        textColor: scheme.onPrimary,
        label: Text(item.badgeCount > 99 ? '99+' : '${item.badgeCount}'),
        child: iconWidget,
      );
    }

    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: InkWell(
        borderRadius: borderRadius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              iconWidget,
              const SizedBox(height: 2),
              Text(
                item.label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontSize: 11,
                  height: 1.15,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class LiquidGlassSegmentedControl<T> extends StatelessWidget {
  const LiquidGlassSegmentedControl({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelect,
    this.height = 40,
  });

  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onSelect;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final rawIndex = options.indexWhere((option) => option.$1 == selected);
    final active = rawIndex < 0 ? 0 : rawIndex;
    final radius = BorderRadius.circular(AppRadius.pill);
    final duration = AppMotion.resolve(context, AppMotion.glide);
    return Container(
      height: height,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.black.withValues(alpha: 0.06),
        borderRadius: radius,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth / options.length;
          return Stack(
            children: [
              TweenAnimationBuilder<double>(
                duration: duration,
                curve: AppMotion.glideCurve,
                tween: Tween(end: active.toDouble()),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: radius,
                    boxShadow: isDark
                        ? const <BoxShadow>[]
                        : [
                            BoxShadow(
                              color: scheme.primary.withValues(alpha: 0.24),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                  ),
                  child: const SizedBox.expand(),
                ),
                builder: (context, position, child) => PositionedDirectional(
                  start: position * width,
                  top: 0,
                  bottom: 0,
                  width: width,
                  child: Transform.scale(
                    scaleX: 1 + 0.03 * math.sin(math.pi * position).abs(),
                    child: child,
                  ),
                ),
              ),
              Material(
                type: MaterialType.transparency,
                child: Row(
                  children: [
                    for (final (value, label) in options)
                      Expanded(
                        child: Semantics(
                          selected: value == selected,
                          child: InkWell(
                            borderRadius: radius,
                            onTap: () => onSelect(value),
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                child: Text(
                                  label,
                                  maxLines: 1,
                                  softWrap: false,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    fontSize: 13,
                                    fontWeight: value == selected
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                    color: value == selected
                                        ? scheme.onPrimary
                                        : scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Reports the laid-out overlay height so only the end of the list reserves space.
Widget measureGlassOverlay(
  Widget child,
  ValueChanged<double> onHeightChanged,
) => Builder(
  builder: (context) {
    void report() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) onHeightChanged(context.size!.height);
      });
    }

    report();
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        report();
        return true;
      },
      child: SizeChangedLayoutNotifier(child: child),
    );
  },
);
