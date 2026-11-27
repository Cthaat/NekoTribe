import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n/app_localizations.dart';
import '../theme/tokens.dart';
import 'app_avatar.dart';

class MediaLightboxItem {
  const MediaLightboxItem({required this.url, this.altText, this.description});

  final String url;
  final String? altText;
  final String? description;
}

Future<void> showMediaLightbox({
  required BuildContext context,
  required List<MediaLightboxItem> items,
  int initialIndex = 0,
}) {
  if (items.isEmpty) return Future.value();
  final reduced = AppMotion.reduced(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.transparent,
    transitionDuration: reduced
        ? const Duration(milliseconds: 120)
        : const Duration(milliseconds: 240),
    pageBuilder: (_, _, _) => _MediaLightboxOverlay(
      items: items,
      initialIndex: initialIndex.clamp(0, items.length - 1),
    ),
    transitionBuilder: (_, animation, _, child) {
      if (reduced) {
        return FadeTransition(opacity: animation, child: child);
      }
      final curved = CurvedAnimation(
        parent: animation,
        curve: AppMotion.glideCurve,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.94, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class _MediaLightboxOverlay extends StatefulWidget {
  const _MediaLightboxOverlay({
    required this.items,
    required this.initialIndex,
  });

  final List<MediaLightboxItem> items;
  final int initialIndex;

  @override
  State<_MediaLightboxOverlay> createState() => _MediaLightboxOverlayState();
}

class _MediaLightboxOverlayState extends State<_MediaLightboxOverlay>
    with SingleTickerProviderStateMixin {
  late int _index = widget.initialIndex;
  late final PageController _pageController = PageController(
    initialPage: widget.initialIndex,
  );
  final Map<int, TransformationController> _zoomControllers = {};
  late final AnimationController _dragResetController;
  double _dragY = 0;
  double _currentScale = 1.0;

  @override
  void initState() {
    super.initState();
    _dragResetController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    _dragResetController.dispose();
    for (final controller in _zoomControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  TransformationController _controllerFor(int index) {
    return _zoomControllers.putIfAbsent(index, TransformationController.new);
  }

  void _resetCurrentZoom() {
    _zoomControllers[_index]?.value = Matrix4.identity();
    if (_currentScale != 1.0) {
      setState(() => _currentScale = 1.0);
    }
  }

  void _move(int delta) {
    final next = (_index + delta).clamp(0, widget.items.length - 1);
    if (next == _index) return;
    _resetCurrentZoom();
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        next,
        duration: AppMotion.resolve(context, AppMotion.base),
        curve: AppMotion.glideCurve,
      );
    } else {
      setState(() => _index = next);
    }
  }

  void _toggleDoubleTapZoom(int index) {
    final controller = _controllerFor(index);
    final current = controller.value.getMaxScaleOnAxis();
    setState(() {
      if (current > 1.05) {
        controller.value = Matrix4.identity();
        _currentScale = 1.0;
      } else {
        controller.value = Matrix4.diagonal3Values(2.2, 2.2, 1.0);
        _currentScale = 2.2;
      }
    });
  }

  void _animateDragBack() {
    final start = _dragY;
    if (AppMotion.reduced(context)) {
      setState(() => _dragY = 0);
      return;
    }
    final tween = Tween<double>(begin: start, end: 0).animate(
      CurvedAnimation(
        parent: _dragResetController,
        curve: AppMotion.glideCurve,
      ),
    );
    void listener() {
      if (mounted) setState(() => _dragY = tween.value);
    }

    _dragResetController
      ..reset()
      ..removeListener(listener)
      ..addListener(listener);
    _dragResetController.forward().whenComplete(() {
      _dragResetController.removeListener(listener);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final item = widget.items[_index];
    final hasMultiple = widget.items.length > 1;
    final hasPrevious = _index > 0;
    final hasNext = _index < widget.items.length - 1;
    final dragProgress = (_dragY.abs() / 360).clamp(0.0, 1.0);
    final backdropAlpha = (0.92 * (1 - dragProgress * 0.72)).clamp(0.24, 0.92);
    final dragScale = _dragY == 0
        ? 1.0
        : math.max(0.84, 1.0 - _dragY.abs() / 900.0);
    final caption = item.description ?? item.altText ?? '';

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _move(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _move(1),
      },
      child: Focus(
        autofocus: true,
        child: Material(
          type: MaterialType.transparency,
          child: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: backdropAlpha),
                ),
              ),
              Transform.translate(
                offset: Offset(0, _dragY),
                child: Transform.scale(
                  scale: dragScale,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onVerticalDragUpdate: _currentScale > 1.05
                        ? null
                        : (details) {
                            setState(() => _dragY += details.delta.dy);
                          },
                    onVerticalDragEnd: _currentScale > 1.05
                        ? null
                        : (details) {
                            final velocity =
                                details.velocity.pixelsPerSecond.dy.abs();
                            if (_dragY.abs() > 110 || velocity > 700) {
                              Navigator.of(context).pop();
                            } else {
                              _animateDragBack();
                            }
                          },
                    child: PageView.builder(
                      controller: _pageController,
                      physics: _currentScale > 1.05
                          ? const NeverScrollableScrollPhysics()
                          : const BouncingScrollPhysics(),
                      itemCount: widget.items.length,
                      onPageChanged: (page) {
                        _resetCurrentZoom();
                        setState(() => _index = page);
                      },
                      itemBuilder: (context, index) {
                        final entry = widget.items[index];
                        final controller = _controllerFor(index);
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 72,
                            ),
                            child: GestureDetector(
                              onDoubleTap: () => _toggleDoubleTapZoom(index),
                              child: InteractiveViewer(
                                transformationController: controller,
                                minScale: 1,
                                maxScale: 3.5,
                                onInteractionEnd: (_) {
                                  final scale = controller.value
                                      .getMaxScaleOnAxis();
                                  if ((scale - _currentScale).abs() > 0.01) {
                                    setState(() => _currentScale = scale);
                                  }
                                },
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(18),
                                  child: AppMediaImage(
                                    url: entry.url,
                                    fit: BoxFit.contain,
                                    borderRadius: BorderRadius.zero,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Row(
                      children: [
                        _LightboxGlassPill(
                          child: Text(
                            hasMultiple
                                ? '${_index + 1} / ${widget.items.length}'
                                : l10n.t('media.lightbox_title'),
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const Spacer(),
                        _LightboxGlassIconButton(
                          tooltip: l10n.t('common.close'),
                          icon: const Icon(
                            Icons.close,
                            size: 20,
                            color: Colors.white,
                          ),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (hasPrevious)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: _LightboxGlassIconButton(
                      tooltip: l10n.t('common.previous'),
                      icon: const Icon(
                        Icons.chevron_left,
                        size: 24,
                        color: Colors.white,
                      ),
                      onPressed: () => _move(-1),
                    ),
                  ),
                ),
              if (hasNext)
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: _LightboxGlassIconButton(
                      tooltip: l10n.t('common.next'),
                      icon: const Icon(
                        Icons.chevron_right,
                        size: 24,
                        color: Colors.white,
                      ),
                      onPressed: () => _move(1),
                    ),
                  ),
                ),
              if (caption.isNotEmpty || hasMultiple)
                SafeArea(
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (caption.isNotEmpty)
                            _LightboxGlassPill(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 560,
                                ),
                                child: Text(
                                  caption,
                                  textAlign: TextAlign.center,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          if (hasMultiple) ...[
                            const SizedBox(height: 10),
                            _LightboxGlassPill(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  for (
                                    var i = 0;
                                    i < math.min(widget.items.length, 8);
                                    i++
                                  )
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 3,
                                      ),
                                      child: AnimatedContainer(
                                        duration: AppMotion.resolve(
                                          context,
                                          AppMotion.fast,
                                        ),
                                        width: i == _index ? 18 : 7,
                                        height: 7,
                                        decoration: BoxDecoration(
                                          color: i == _index
                                              ? Colors.white
                                              : Colors.white.withValues(
                                                  alpha: 0.4,
                                                ),
                                          borderRadius: BorderRadius.circular(
                                            AppRadius.pill,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LightboxGlassPill extends StatelessWidget {
  const _LightboxGlassPill({
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: child,
    );
  }
}

class _LightboxGlassIconButton extends StatelessWidget {
  const _LightboxGlassIconButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
  });

  final Widget icon;
  final VoidCallback onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: Colors.black.withValues(alpha: 0.5),
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
          ),
          child: icon,
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}
