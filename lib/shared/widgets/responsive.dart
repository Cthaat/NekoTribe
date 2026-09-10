import 'package:flutter/material.dart';

/// Breakpoint helpers used across the app.
class AppBreakpoints {
  AppBreakpoints._();

  /// Below this width we treat the layout as compact (phone / narrow window).
  static const double compact = 600;

  /// Side rail navigation enables at this width.
  static const double medium = 800;

  /// Extended labels on the rail enable at this width.
  static const double expanded = 1100;

  /// Maximum width for primary content columns (feed, profile, settings).
  static const double contentMaxWidth = 680;

  /// Wider content cap for screens that benefit from extra room (search,
  /// moderation tables).
  static const double wideContentMaxWidth = 960;

  static bool isCompact(BuildContext context) =>
      MediaQuery.sizeOf(context).width < compact;

  static bool isMedium(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= medium;

  static bool isExpanded(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= expanded;
}

/// Constrains its child to a sensible maximum width and centres it. Use for
/// the main column inside feed-style screens so that content does not stretch
/// edge-to-edge on desktop windows.
class ContentColumn extends StatelessWidget {
  const ContentColumn({
    super.key,
    required this.child,
    this.maxWidth = AppBreakpoints.contentMaxWidth,
    this.horizontalPadding = 16,
  });

  final Widget child;
  final double maxWidth;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          child: child,
        ),
      ),
    );
  }
}

/// A scrollable column that auto-applies the [ContentColumn] constraint.
/// Drop-in replacement for a `ListView` when you want max-width content but
/// still need scroll behaviour, padding and a refresh indicator support via
/// child wrapping.
class ContentScrollView extends StatelessWidget {
  const ContentScrollView({
    super.key,
    required this.slivers,
    this.controller,
    this.maxWidth = AppBreakpoints.contentMaxWidth,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    this.physics,
  });

  final List<Widget> slivers;
  final ScrollController? controller;
  final double maxWidth;
  final EdgeInsetsGeometry padding;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: CustomScrollView(
          controller: controller,
          physics: physics,
          slivers: [
            SliverPadding(
              padding: padding,
              sliver: SliverList(
                delegate: SliverChildListDelegate.fixed(slivers),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
