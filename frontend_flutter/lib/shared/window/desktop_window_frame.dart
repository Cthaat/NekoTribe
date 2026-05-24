import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../i18n/app_localizations.dart';

const desktopWindowDragAreaKey = ValueKey('desktop-window-drag-area');
const desktopWindowMinimizeButtonKey = ValueKey(
  'desktop-window-minimize-button',
);
const desktopWindowMaximizeButtonKey = ValueKey(
  'desktop-window-maximize-button',
);
const desktopWindowCloseButtonKey = ValueKey('desktop-window-close-button');

bool get isDesktopWindowFrameSupported {
  if (kIsWeb) return false;
  try {
    return Platform.isWindows;
  } catch (_) {
    return false;
  }
}

abstract interface class WindowControls {
  Future<void> startDragging();
  Future<void> minimize();
  Future<bool> isMaximized();
  Future<void> maximize();
  Future<void> unmaximize();
  Future<void> close();
}

class WindowManagerControls implements WindowControls {
  const WindowManagerControls();

  @override
  Future<void> startDragging() => windowManager.startDragging();

  @override
  Future<void> minimize() => windowManager.minimize();

  @override
  Future<bool> isMaximized() => windowManager.isMaximized();

  @override
  Future<void> maximize() => windowManager.maximize();

  @override
  Future<void> unmaximize() => windowManager.unmaximize();

  @override
  Future<void> close() => windowManager.close();
}

class DesktopWindowFrame extends StatelessWidget {
  const DesktopWindowFrame({
    super.key,
    required this.child,
    this.enabled = true,
    this.controls = const WindowManagerControls(),
  });

  final Widget child;
  final bool enabled;
  final WindowControls controls;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;

    return Column(
      children: [
        _DesktopWindowTitleBar(controls: controls),
        Expanded(child: child),
      ],
    );
  }
}

class _DesktopWindowTitleBar extends StatefulWidget {
  const _DesktopWindowTitleBar({required this.controls});

  final WindowControls controls;

  @override
  State<_DesktopWindowTitleBar> createState() => _DesktopWindowTitleBarState();
}

class _DesktopWindowTitleBarState extends State<_DesktopWindowTitleBar> {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    _refreshMaximized();
  }

  Future<void> _refreshMaximized() async {
    final maximized = await widget.controls.isMaximized();
    if (!mounted) return;
    setState(() => _isMaximized = maximized);
  }

  Future<void> _toggleMaximized() async {
    final maximized = await widget.controls.isMaximized();
    if (maximized) {
      await widget.controls.unmaximize();
    } else {
      await widget.controls.maximize();
    }
    await _refreshMaximized();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final borderColor = colors.outlineVariant.withValues(alpha: 0.55);

    return Material(
      color: colors.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: borderColor)),
        ),
        child: SizedBox(
          height: 36,
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  key: desktopWindowDragAreaKey,
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) => widget.controls.startDragging(),
                  onDoubleTap: _toggleMaximized,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        Icon(Icons.pets, size: 16, color: colors.primary),
                        const SizedBox(width: 8),
                        Text(
                          l10n.t('app.title'),
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelLarge,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              _WindowControlButton(
                key: desktopWindowMinimizeButtonKey,
                tooltip: l10n.t('window.minimize'),
                icon: Icons.minimize,
                onPressed: widget.controls.minimize,
              ),
              _WindowControlButton(
                key: desktopWindowMaximizeButtonKey,
                tooltip: _isMaximized
                    ? l10n.t('window.restore')
                    : l10n.t('window.maximize'),
                icon: _isMaximized
                    ? Icons.filter_none_outlined
                    : Icons.crop_square,
                onPressed: _toggleMaximized,
              ),
              _WindowControlButton(
                key: desktopWindowCloseButtonKey,
                tooltip: l10n.t('window.close'),
                icon: Icons.close,
                isClose: true,
                onPressed: widget.controls.close,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WindowControlButton extends StatefulWidget {
  const _WindowControlButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.isClose = false,
  });

  final String tooltip;
  final IconData icon;
  final Future<void> Function() onPressed;
  final bool isClose;

  @override
  State<_WindowControlButton> createState() => _WindowControlButtonState();
}

class _WindowControlButtonState extends State<_WindowControlButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final closeHover = widget.isClose && _hovered;
    final foreground = closeHover ? Colors.white : colors.onSurface;
    final background = closeHover
        ? colors.error
        : _hovered
        ? colors.surfaceContainerHighest
        : Colors.transparent;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Tooltip(
        message: widget.tooltip,
        child: SizedBox(
          width: 46,
          height: 36,
          child: TextButton(
            style: TextButton.styleFrom(
              foregroundColor: foreground,
              backgroundColor: background,
              shape: const RoundedRectangleBorder(),
              padding: EdgeInsets.zero,
            ),
            onPressed: widget.onPressed,
            child: Icon(widget.icon, size: 16),
          ),
        ),
      ),
    );
  }
}
