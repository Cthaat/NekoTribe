import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Back navigation button that safely falls back to [fallbackRoute] when
/// a secondary screen is opened directly without an active back stack.
class SafeBackButton extends StatelessWidget {
  const SafeBackButton({
    super.key,
    this.fallbackRoute = '/feed',
    this.icon = Icons.arrow_back_rounded,
    this.tooltip,
  });

  final String fallbackRoute;
  final IconData icon;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip ?? MaterialLocalizations.of(context).backButtonTooltip,
      icon: Icon(icon),
      onPressed: () {
        final router = GoRouter.maybeOf(context);
        if (router != null && router.canPop()) {
          router.pop();
          return;
        }
        final navigator = Navigator.of(context);
        if (navigator.canPop()) {
          navigator.maybePop();
          return;
        }
        router?.go(fallbackRoute);
      },
    );
  }
}
