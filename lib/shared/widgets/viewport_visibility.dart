import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

bool intersectsVisibleViewport(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize) return false;
  var bounds = MatrixUtils.transformRect(
    box.getTransformTo(null),
    box.paintBounds,
  ).intersect(Offset.zero & MediaQuery.sizeOf(context));
  if (bounds.isEmpty) return false;
  var viewport = RenderAbstractViewport.maybeOf(box.parent);
  while (viewport != null) {
    final area = MatrixUtils.transformRect(
      viewport.getTransformTo(null),
      viewport.paintBounds,
    );
    bounds = bounds.intersect(area);
    if (bounds.isEmpty) return false;
    viewport = RenderAbstractViewport.maybeOf(viewport.parent);
  }
  return true;
}
