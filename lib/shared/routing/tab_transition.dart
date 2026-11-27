import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../theme/tokens.dart';
import '../widgets/responsive.dart';

const mobilePrimaryTabs = [
  ('/feed', Icons.home_outlined, Icons.home_rounded, 'tab.home'),
  ('/groups', Icons.groups_outlined, Icons.groups_rounded, 'group.title'),
  (
    '/notifications',
    Icons.notifications_outlined,
    Icons.notifications_rounded,
    'tab.notifications',
  ),
  (
    '/chat',
    Icons.chat_bubble_outline_rounded,
    Icons.chat_bubble_rounded,
    'tab.messages',
  ),
  ('/me', Icons.person_outline_rounded, Icons.person_rounded, 'tab.profile'),
];

int? mobilePrimaryTabIndexOf(String location) {
  final path = Uri.tryParse(location)?.path;
  final root = switch (path) {
    '/groups/discover' || '/groups/my' || '/groups/invites' => '/groups',
    _ => path,
  };
  final index = mobilePrimaryTabs.indexWhere((tab) => tab.$1 == root);
  return index < 0 ? null : index;
}

class TabTransitionTracker {
  int? _lastPrimaryIndex;
  int _direction = 0;
  int get direction => _direction;

  void prepare(String location) {
    _direction = _directionTo(mobilePrimaryTabIndexOf(location));
  }

  int _directionTo(int? next) {
    final previous = _lastPrimaryIndex;
    return next == null || previous == null ? 0 : (next - previous).sign;
  }

  // The delegate also sees deep links, redirects and pops, including when a
  // previously built page is uncovered without invoking its pageBuilder.
  VoidCallback observe(GoRouter router) {
    final delegate = router.routerDelegate;
    RouteMatch? previousMatch;
    void update() {
      final match = delegate.currentConfiguration.lastOrNull;
      if (previousMatch == match) return;
      previousMatch = match;
      final next = match == null
          ? null
          : mobilePrimaryTabIndexOf(match.matchedLocation);
      _direction = _directionTo(next);
      _lastPrimaryIndex = next;
    }

    update();
    delegate.addListener(update);
    return () => delegate.removeListener(update);
  }
}

CustomTransitionPage<void> buildDirectionalTabPage(
  BuildContext context,
  GoRouterState state,
  TabTransitionTracker tracker,
  Widget child,
) {
  final duration = AppMotion.resolve(
    context,
    const Duration(milliseconds: 280),
  );
  return CustomTransitionPage<void>(
    key: state.pageKey,
    transitionDuration: duration,
    reverseTransitionDuration: duration,
    child: child,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      if (AppMotion.reduced(context)) return child;
      final dir = MediaQuery.sizeOf(context).width < AppBreakpoints.medium
          ? tracker.direction
          : 0;
      // A replacement/push drives the old page's secondary animation. On a
      // pop the old page reverses its primary and the revealed page its secondary.
      final covered = !secondaryAnimation.isDismissed;
      final active = covered ? secondaryAnimation : animation;
      final reversing = active.status == AnimationStatus.reverse;
      final outgoing = covered != reversing;
      final progress = AppMotion.glideCurve.transform(
        reversing ? 1 - active.value : active.value,
      );
      return _TabTransitionFrame(
        direction: dir,
        progress: progress,
        outgoing: outgoing,
        child: child,
      );
    },
  );
}

class _TabTransitionFrame extends StatefulWidget {
  const _TabTransitionFrame({
    required this.direction,
    required this.progress,
    required this.outgoing,
    required this.child,
  });

  final int direction;
  final double progress;
  final bool outgoing;
  final Widget child;

  double get enteringX => direction * .32 * (1 - progress);
  double get enteringOpacity =>
      direction == 0 ? .86 + .14 * progress : progress;

  @override
  State<_TabTransitionFrame> createState() => _TabTransitionFrameState();
}

class _TabTransitionFrameState extends State<_TabTransitionFrame> {
  double _exitStartX = 0;
  double _exitStartOpacity = 1;

  @override
  void didUpdateWidget(_TabTransitionFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.outgoing && !oldWidget.outgoing) {
      // Preserve the displayed frame if another tab interrupts this entrance.
      _exitStartX = oldWidget.enteringX;
      _exitStartOpacity = oldWidget.enteringOpacity;
    }
  }

  @override
  Widget build(BuildContext context) {
    final x = widget.outgoing
        ? _exitStartX - widget.direction * .22 * widget.progress
        : widget.enteringX;
    final opacity = widget.outgoing
        ? _exitStartOpacity * (1 - .14 * widget.progress)
        : widget.enteringOpacity;
    return FractionalTranslation(
      translation: Offset(widget.direction == 0 ? 0 : x, 0),
      child: FadeTransition(
        opacity: AlwaysStoppedAnimation(opacity),
        child: widget.child,
      ),
    );
  }
}
