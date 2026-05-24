import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/app_localizations.dart';
import '../widgets/responsive.dart';

class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.child});
  final Widget child;

  static const _primaryTabs = [
    ('/feed', Icons.home_outlined, Icons.home, 'tab.home'),
    ('/discover', Icons.explore_outlined, Icons.explore, 'tab.discover'),
    (
      '/notifications',
      Icons.notifications_outlined,
      Icons.notifications,
      'tab.notifications',
    ),
    ('/chat', Icons.chat_bubble_outline, Icons.chat_bubble, 'tab.messages'),
    ('/me', Icons.person_outline, Icons.person, 'tab.profile'),
  ];

  static const _desktopTabs = [
    ..._primaryTabs,
    ('/groups', Icons.groups_outlined, Icons.groups, 'group.title'),
    ('/moderation', Icons.shield_outlined, Icons.shield, 'moderation.title'),
    (
      '/sentiment',
      Icons.psychology_outlined,
      Icons.psychology,
      'sentiment.title',
    ),
  ];

  int _indexFor(
    String location,
    List<(String, IconData, IconData, String)> tabs,
  ) {
    for (var i = 0; i < tabs.length; i++) {
      if (location.startsWith(tabs[i].$1)) return i;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final location = GoRouterState.of(context).matchedLocation;
    final width = MediaQuery.sizeOf(context).width;
    final isWide = width >= AppBreakpoints.medium;
    final isExpanded = width >= AppBreakpoints.expanded;
    final tabs = isWide ? _desktopTabs : _primaryTabs;
    final currentIndex = _indexFor(location, tabs);
    final theme = Theme.of(context);

    if (isWide) {
      return Scaffold(
        body: Row(
          children: [
            _SideNav(
              extended: isExpanded,
              currentIndex: currentIndex,
              tabs: tabs,
              labelFor: l10n.t,
            ),
            VerticalDivider(
              width: 1,
              thickness: 1,
              color: theme.dividerColor,
            ),
            Expanded(child: child),
          ],
        ),
      );
    }
    return Scaffold(
      body: child,
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.dividerColor),
          ),
        ),
        child: NavigationBar(
          selectedIndex: currentIndex,
          onDestinationSelected: (i) => context.go(tabs[i].$1),
          destinations: [
            for (final t in tabs)
              NavigationDestination(
                icon: Icon(t.$2),
                selectedIcon: Icon(t.$3),
                label: l10n.t(t.$4),
              ),
          ],
        ),
      ),
    );
  }
}

class _SideNav extends StatelessWidget {
  const _SideNav({
    required this.extended,
    required this.currentIndex,
    required this.tabs,
    required this.labelFor,
  });

  final bool extended;
  final int currentIndex;
  final List<(String, IconData, IconData, String)> tabs;
  final String Function(String) labelFor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = extended ? 240.0 : 80.0;
    return Container(
      width: width,
      color: theme.scaffoldBackgroundColor,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Brand(extended: extended),
            const SizedBox(height: 24),
            for (var i = 0; i < tabs.length; i++)
              _NavItem(
                icon: tabs[i].$2,
                selectedIcon: tabs[i].$3,
                label: labelFor(tabs[i].$4),
                selected: i == currentIndex,
                extended: extended,
                onTap: () => GoRouter.of(context).go(tabs[i].$1),
              ),
            const SizedBox(height: 8),
            if (extended)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                child: FilledButton.icon(
                  onPressed: () => GoRouter.of(context).push('/account/profile'),
                  icon: const Icon(Icons.edit, size: 18),
                  label: Text(labelFor('common.post')),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Center(
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: FilledButton(
                      onPressed: () =>
                          GoRouter.of(context).push('/account/profile'),
                      style: FilledButton.styleFrom(
                        padding: EdgeInsets.zero,
                        shape: const CircleBorder(),
                      ),
                      child: const Icon(Icons.edit, size: 20),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({required this.extended});

  final bool extended;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: extended ? 10 : 0,
        vertical: 4,
      ),
      child: Row(
        mainAxisAlignment:
            extended ? MainAxisAlignment.start : MainAxisAlignment.center,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: primary.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.pets, color: primary, size: 20),
          ),
          if (extended) ...[
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'NekoTribe',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.extended,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final bool extended;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface;
    final bg = selected
        ? theme.colorScheme.primary.withValues(alpha: 0.10)
        : Colors.transparent;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: extended ? 14 : 0,
              vertical: 12,
            ),
            child: extended
                ? Row(
                    children: [
                      Icon(selected ? selectedIcon : icon, color: color),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          label,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: color,
                            fontWeight:
                                selected ? FontWeight.w700 : FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                    ],
                  )
                : Tooltip(
                    message: label,
                    child: Icon(selected ? selectedIcon : icon, color: color),
                  ),
          ),
        ),
      ),
    );
  }
}

const desktopAppShellPaths = <String>{
  '/feed',
  '/discover',
  '/notifications',
  '/chat',
  '/me',
  '/groups',
  '/moderation',
  '/sentiment',
};
