import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../theme/tokens.dart';

class DetailPage extends MaterialPage<void> {
  const DetailPage({required super.key, required super.child, super.name, super.arguments, super.restorationId});

  @override
  Route<void> createRoute(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    if (kIsWeb && !reduced) return super.createRoute(context);
    if (reduced) return _DetailRoute(this, reduced: true);
    return switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.windows => _DetailRoute(this),
      _ => super.createRoute(context),
    };
  }
}

class _DetailRoute extends CupertinoPageRoute<void> {
  _DetailRoute(DetailPage page, {this.reduced = false}) : super(settings: page, builder: (_) => page.child);

  @override
  Duration get transitionDuration => reduced ? Duration.zero : super.transitionDuration;

  @override
  Duration get reverseTransitionDuration => reduced ? Duration.zero : super.reverseTransitionDuration;

  final bool reduced;

  @override
  Widget buildContent(BuildContext context) => (settings as DetailPage).child;

  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      (context, animation, secondary, snapshot, child) => AppMotion.reduced(context)
      ? child
      : CupertinoPageTransition.delegatedTransition(context, animation, secondary, snapshot, child);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (AppMotion.reduced(context)) {
      return super.buildTransitions(context, kAlwaysCompleteAnimation, kAlwaysDismissedAnimation, child);
    }
    // Keep interactive pops linear. The small settling offset is push-only.
    final settle = !popGestureInProgress && animation.status == AnimationStatus.forward
        ? _settle.x(animation.value * 0.5) - animation.value
        : 0.0;
    final direction = Directionality.of(context) == TextDirection.ltr ? 1 : -1;
    return super.buildTransitions(
      context,
      animation,
      secondaryAnimation,
      FractionalTranslation(translation: Offset(-0.04 * direction * settle, 0), child: child),
    );
  }

  static final _settle = SpringSimulation(AppMotion.liquidSnapSpring, 0, 1, 0);
}
