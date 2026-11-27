import 'dart:math' as math;

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

class _LiquidGlassNavDockState extends State<LiquidGlassNavDock> with TickerProviderStateMixin {
  int get _selected => widget.selectedIndex.clamp(0, math.max(0, widget.items.length - 1));
  late int _target = _selected;
  late final _position = AnimationController.unbounded(vsync: this, value: _target.toDouble());
  late final _lift = AnimationController.unbounded(vsync: this);
  late final _speed = AnimationController.unbounded(vsync: this);
  late final _motion = Listenable.merge([_position, _lift, _speed]);
  int? _hover, _focus;
  bool _reduced = false;
  Duration _lastMove = Duration.zero;
  Duration _pointerTime = Duration.zero;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = AppMotion.reduced(context);
    if (_reduced) {
      _lift.value = 0;
      _speed.value = 0;
      if (_hover == null) _position.value = _target.toDouble();
    }
  }

  @override
  void didUpdateWidget(covariant LiquidGlassNavDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items.length != widget.items.length ||
        (oldWidget.selectedIndex != widget.selectedIndex && _target != _selected)) {
      _hover = null;
      _spring(_lift, AppMotion.liquidLensSpring, 0);
      _snap(_selected);
    }
  }

  @override
  void dispose() {
    _position.dispose();
    _lift.dispose();
    _speed.dispose();
    super.dispose();
  }

  void _spring(
    AnimationController controller,
    SpringDescription spring,
    double end, [
    double velocity = 0,
  ]) {
    if (_reduced || (controller.value == end && velocity == 0)) {
      controller.value = end;
    } else {
      controller.animateWith(
        SpringSimulation(spring, controller.value, end, velocity, snapToEnd: true),
      );
    }
  }

  void _snap(int index, [double velocity = 0]) {
    _target = index;
    _spring(_position, AppMotion.liquidSnapSpring, index.toDouble(), velocity.clamp(-12, 12));
  }

  void _tap(int index) {
    HapticFeedback.lightImpact();
    _snap(index);
    widget.onSelected(index);
  }

  double _track(double x) {
    final edge = x.clamp(0.0, widget.items.length - 1.0);
    final excess = x - edge;
    return _reduced ? edge : edge + excess.sign * 0.22 * (1 - math.exp(-excess.abs() / 0.22));
  }

  void _move(double raw, {bool start = false, Duration? timeStamp}) {
    if (!start && _hover == null) return;
    final x = _track(raw);
    final index = x.round().clamp(0, widget.items.length - 1);
    final now = timeStamp ?? _pointerTime;
    if (start) {
      _spring(_lift, AppMotion.liquidLensSpring, _reduced ? 0 : 1);
      _speed.value = 0;
    } else if (!_reduced && now > _lastMove) {
      final seconds = (now - _lastMove).inMicroseconds / Duration.microsecondsPerSecond;
      _speed.value = ((x - _position.value) / seconds).clamp(-12, 12);
      _speed.animateTo(0, duration: const Duration(milliseconds: 100));
    }
    if (start || index != _hover) HapticFeedback.selectionClick();
    _lastMove = now;
    _hover = index;
    _position.value = x;
  }

  void _end(double velocity, {bool cancel = false}) {
    if (_hover == null) return;
    final next = cancel
        ? _selected
        : (_position.value + velocity * 0.08).round().clamp(0, widget.items.length - 1);
    _hover = null;
    _speed.value = 0;
    _spring(_lift, AppMotion.liquidLensSpring, 0);
    _snap(next, velocity);
    if (!cancel) widget.onSelected(next);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return SizedBox(
      height: 62,
      child: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.none,
        children: [
          const LiquidGlassSurface(
            preset: LiquidGlassPreset.navDock,
            borderRadius: BorderRadius.all(Radius.circular(31)),
            child: SizedBox.expand(),
          ),
          Padding(
            padding: const EdgeInsets.all(4),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth / widget.items.length;
                if (width <= 0) return const SizedBox.shrink();
                double slot(double dx) => (rtl ? constraints.maxWidth - dx : dx) / width - 0.5;
                double velocity(double dx) => (rtl ? -dx : dx) / width;
                return Listener(
                  onPointerDown: (e) => _pointerTime = e.timeStamp,
                  onPointerMove: (e) => _pointerTime = e.timeStamp,
                  onPointerCancel: (_) => _end(0, cancel: true),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    excludeFromSemantics: true,
                    onTapUp: (e) =>
                        _tap(slot(e.localPosition.dx).round().clamp(0, widget.items.length - 1)),
                    onLongPressStart: (e) => _move(slot(e.localPosition.dx), start: true),
                    onLongPressMoveUpdate: (e) => _move(slot(e.localPosition.dx)),
                    onLongPressEnd: (e) => _end(velocity(e.velocity.pixelsPerSecond.dx)),
                    onHorizontalDragStart: (e) =>
                        _move(slot(e.localPosition.dx), start: true, timeStamp: e.sourceTimeStamp),
                    onHorizontalDragUpdate: (e) =>
                        _move(slot(e.localPosition.dx), timeStamp: e.sourceTimeStamp),
                    onHorizontalDragEnd: (e) => _end(velocity(e.primaryVelocity ?? 0)),
                    child: AnimatedBuilder(
                      animation: _motion,
                      builder: (context, _) => _buildTrack(context, width, rtl),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrack(BuildContext context, double width, bool rtl) {
    final theme = Theme.of(context);
    final vx = _reduced ? 0.0 : (_hover == null ? _position.velocity : _speed.value);
    final stretch = (vx.abs() * 0.022).clamp(0.0, 0.16);
    final lensScale = 1 + 0.10 * _lift.value;
    final progress = _lift.value.clamp(0.0, 1.0);
    return Stack(
      clipBehavior: Clip.none,
      fit: StackFit.expand,
      children: [
        PositionedDirectional(
          start: _position.value * width,
          top: 0,
          bottom: 0,
          width: width,
          child: Transform.scale(
            scaleX: (1 + stretch) * lensScale,
            scaleY: lensScale / math.sqrt(1 + stretch),
            child: CustomPaint(
              foregroundPainter: _LiquidLensPainter(
                progress,
                ((rtl ? -vx : vx) * 0.04).clamp(-0.35, 0.35),
                MediaQuery.highContrastOf(context),
              ),
              child: LiquidGlassSurface(
                preset: LiquidGlassPreset.pillIndicator,
                borderRadius: const BorderRadius.all(Radius.circular(27)),
                blurEnabled: false,
                lensProgress: progress,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < widget.items.length; i++)
              Expanded(
                child: _NavDockItemButton(
                  item: widget.items[i],
                  selected: i == _selected,
                  theme: theme,
                  scheme: theme.colorScheme,
                  weight: (1 - (_position.value - i).abs()).clamp(0.0, 1.0),
                  iconGrowth: _reduced ? 0 : (_hover == null ? 0.05 : 0.14),
                  focused: _focus == i,
                  onFocus: (show) => setState(() {
                    if (show || _focus == i) _focus = show ? i : null;
                  }),
                  onTap: () => _tap(i),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _LiquidLensPainter extends CustomPainter {
  const _LiquidLensPainter(this.progress, this.shift, this.highContrast);
  final double progress, shift;
  final bool highContrast;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final rim = RRect.fromRectAndRadius(bounds.deflate(1.3), const Radius.circular(27));
    final gain = highContrast ? 1.45 : 1 + 0.35 * progress;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = highContrast ? 2 : 1.3;
    // The inset bevel follows the capsule, with a dark lip and a cool lower reflection.
    stroke.shader = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Colors.transparent,
        const Color(0x26091426),
        const Color(0xffb4dcff).withValues(alpha: 0.54 * gain),
      ],
      stops: const [0.25, 0.87, 1],
    ).createShader(bounds);
    canvas.drawRRect(rim, stroke);
    stroke.shader = null;
    stroke.color = Colors.white.withValues(alpha: 0.64 * gain);
    stroke.strokeCap = StrokeCap.round;
    final center = size.width * (0.44 + shift * 0.25);
    final half = size.width * 0.13;
    canvas.drawPath(
      Path()
        ..moveTo(center - half, 3.4)
        ..quadraticBezierTo(center, 1.3, center + half, 2.7),
      stroke,
    );
    if (progress > 0) {
      stroke.color = const Color(0xffe5d9ff).withValues(alpha: 0.45 * progress);
      canvas.drawPath(
        Path()
          ..moveTo(size.width * 0.58, size.height - 3.0)
          ..quadraticBezierTo(
            size.width * 0.67,
            size.height - 2,
            size.width * 0.74,
            size.height - 4,
          ),
        stroke,
      );
      final halo = Paint()
        ..color = const Color(0xff92caff).withValues(alpha: 0.30 * progress)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(size.width / 2, size.height + 2),
          width: size.width * 0.60,
          height: 3,
        ),
        halo,
      );
    }
  }

  @override
  bool shouldRepaint(_LiquidLensPainter old) =>
      old.progress != progress || old.shift != shift || old.highContrast != highContrast;
}

class _NavDockItemButton extends StatelessWidget {
  const _NavDockItemButton({
    required this.item,
    required this.selected,
    required this.weight,
    required this.iconGrowth,
    required this.focused,
    required this.onFocus,
    required this.theme,
    required this.scheme,
    required this.onTap,
  });

  final LiquidGlassNavItem item;
  final bool selected;
  final double weight, iconGrowth;
  final bool focused;
  final ValueChanged<bool> onFocus;
  final ThemeData theme;
  final ColorScheme scheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = Color.lerp(scheme.onSurfaceVariant, scheme.primary, weight)!;
    final iconData = weight >= 0.5 ? item.selectedIcon : item.icon;
    Widget iconWidget = Transform.scale(
      scale: 1 + iconGrowth * weight,
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
      value: item.badgeCount > 0 ? '${item.badgeCount}' : null,
      onTap: onTap,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: onFocus,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              onTap();
              return null;
            },
          ),
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(27),
            border: focused ? Border.all(color: scheme.primary, width: 2) : null,
          ),
          child: ExcludeSemantics(
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
