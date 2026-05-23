import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/app_localizations.dart';

class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.child});
  final Widget child;

  static const _tabs = [
    ('/feed', Icons.home_outlined, Icons.home, 'tab.home'),
    ('/discover', Icons.explore_outlined, Icons.explore, 'tab.discover'),
    ('/notifications', Icons.notifications_outlined, Icons.notifications,
        'tab.notifications'),
    ('/chat', Icons.chat_bubble_outline, Icons.chat_bubble, 'tab.messages'),
    ('/me', Icons.person_outline, Icons.person, 'tab.profile'),
  ];

  int _indexFor(String location) {
    for (var i = 0; i < _tabs.length; i++) {
      if (location.startsWith(_tabs[i].$1)) return i;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final location = GoRouterState.of(context).matchedLocation;
    final currentIndex = _indexFor(location);
    final isWide = MediaQuery.of(context).size.width >= 800;

    if (isWide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              extended: MediaQuery.of(context).size.width >= 1100,
              selectedIndex: currentIndex,
              onDestinationSelected: (i) {
                context.go(_tabs[i].$1);
              },
              destinations: [
                for (final t in _tabs)
                  NavigationRailDestination(
                    icon: Icon(t.$2),
                    selectedIcon: Icon(t.$3),
                    label: Text(l10n.t(t.$4)),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: child),
          ],
        ),
      );
    }
    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: currentIndex,
        onDestinationSelected: (i) => context.go(_tabs[i].$1),
        destinations: [
          for (final t in _tabs)
            NavigationDestination(
              icon: Icon(t.$2),
              selectedIcon: Icon(t.$3),
              label: l10n.t(t.$4),
            ),
        ],
      ),
    );
  }
}
