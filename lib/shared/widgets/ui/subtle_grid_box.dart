import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// Paints a quiet 20px geometric grid texture (~3.5% opacity) for brand panels
/// and subtle tonal surfaces without decorative color gradients.
class SubtleGridBox extends StatelessWidget {
  const SubtleGridBox({
    super.key,
    required this.child,
    this.gridSize = 20,
    this.lineColor,
    this.backgroundColor,
    this.borderRadius,
    this.padding,
  });

  final Widget child;
  final double gridSize;
  final Color? lineColor;
  final Color? backgroundColor;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final effectiveLineColor = lineColor ?? SocialColors.of(context).gridLine;
    Widget content = padding == null
        ? child
        : Padding(padding: padding!, child: child);

    content = CustomPaint(
      painter: _SubtleGridPainter(
        gridSize: gridSize,
        lineColor: effectiveLineColor,
      ),
      child: content,
    );

    if (backgroundColor != null || borderRadius != null) {
      content = DecoratedBox(
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: borderRadius,
        ),
        child: borderRadius == null
            ? content
            : ClipRRect(borderRadius: borderRadius!, child: content),
      );
    }

    return content;
  }
}

class _SubtleGridPainter extends CustomPainter {
  const _SubtleGridPainter({required this.gridSize, required this.lineColor});

  final double gridSize;
  final Color lineColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (gridSize <= 0 || size.isEmpty) return;
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    for (double x = 0.5; x < size.width; x += gridSize) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0.5; y < size.height; y += gridSize) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_SubtleGridPainter oldDelegate) {
    return oldDelegate.gridSize != gridSize ||
        oldDelegate.lineColor != lineColor;
  }
}
