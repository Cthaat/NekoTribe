import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/app_localizations.dart';
import '../providers/providers.dart';
import '../widgets/responsive.dart';

class AppShell extends ConsumerStatefulWidget {
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
    ('/feed', Icons.home_outlined, Icons.home, 'tab.home'),
    ('/discover', Icons.explore_outlined, Icons.explore, 'tab.discover'),
    (
      '/notifications',
      Icons.notifications_outlined,
      Icons.notifications,
      'tab.notifications',
    ),
    ('/chat', Icons.chat_bubble_outline, Icons.chat_bubble, 'tab.messages'),
    ('/groups', Icons.groups_outlined, Icons.groups, 'group.title'),
    ('/moderation', Icons.shield_outlined, Icons.shield, 'moderation.title'),
    (
      '/sentiment',
      Icons.psychology_outlined,
      Icons.psychology,
      'sentiment.title',
    ),
    ('/me', Icons.person_outline, Icons.person, 'tab.profile'),
  ];

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  var _didRequestUnread = false;

  int _indexFor(
    String location,
    List<(String, IconData, IconData, String)> tabs,
  ) {
    for (var i = 0; i < tabs.length; i++) {
      if (location.startsWith(tabs[i].$1)) return i;
    }
    return 0;
  }

  Widget _tabIcon(IconData icon, {required int badgeCount}) {
    if (badgeCount <= 0) return Icon(icon);
    return Badge(
      label: Text(badgeCount > 99 ? '99+' : '$badgeCount'),
      child: Icon(icon),
    );
  }

  void _maybeRefreshUnread(bool isAuthenticated) {
    if (!isAuthenticated || _didRequestUnread) return;
    _didRequestUnread = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(notificationsUnreadProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final location = GoRouterState.of(context).matchedLocation;
    final width = MediaQuery.sizeOf(context).width;
    final isWide = width >= AppBreakpoints.medium;
    final isExpanded = width >= AppBreakpoints.expanded;
    final tabs = isWide ? AppShell._desktopTabs : AppShell._primaryTabs;
    final currentIndex = _indexFor(location, tabs);
    final theme = Theme.of(context);
    final unread = ref.watch(notificationsUnreadProvider);
    final isAuthenticated = ref.watch(
      authSessionProvider.select((s) => s.isAuthenticated),
    );
    _maybeRefreshUnread(isAuthenticated);

    if (isWide) {
      return Scaffold(
        body: Row(
          children: [
            _SideNav(
              extended: isExpanded,
              currentIndex: currentIndex,
              tabs: tabs,
              labelFor: l10n.t,
              notificationsUnread: unread,
            ),
            VerticalDivider(width: 1, thickness: 1, color: theme.dividerColor),
            Expanded(child: widget.child),
          ],
        ),
      );
    }
    return Scaffold(
      body: widget.child,
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: theme.dividerColor)),
        ),
        child: NavigationBar(
          selectedIndex: currentIndex,
          onDestinationSelected: (i) => context.go(tabs[i].$1),
          destinations: [
            for (final t in tabs)
              NavigationDestination(
                icon: _tabIcon(
                  t.$2,
                  badgeCount: t.$1 == '/notifications' ? unread : 0,
                ),
                selectedIcon: _tabIcon(
                  t.$3,
                  badgeCount: t.$1 == '/notifications' ? unread : 0,
                ),
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
    required this.notificationsUnread,
  });

  final bool extended;
  final int currentIndex;
  final List<(String, IconData, IconData, String)> tabs;
  final String Function(String) labelFor;
  final int notificationsUnread;

  int? _badgeFor(String path) {
    if (path == '/notifications' && notificationsUnread > 0) {
      return notificationsUnread;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = extended ? 240.0 : 80.0;
    final profileIndex = tabs.indexWhere((tab) => tab.$1 == '/me');
    final profileTab = profileIndex >= 0 ? tabs[profileIndex] : null;
    return Container(
      width: width,
      color: theme.scaffoldBackgroundColor,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Brand(extended: extended),
                  const SizedBox(height: 24),
                  for (var i = 0; i < tabs.length; i++)
                    if (i != profileIndex)
                      _NavItem(
                        icon: tabs[i].$2,
                        selectedIcon: tabs[i].$3,
                        label: labelFor(tabs[i].$4),
                        selected: i == currentIndex,
                        extended: extended,
                        badgeCount: _badgeFor(tabs[i].$1),
                        onTap: () => GoRouter.of(context).go(tabs[i].$1),
                      ),
                  const SizedBox(height: 8),
                  if (extended)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 12,
                      ),
                      child: FilledButton.icon(
                        key: const Key('app-shell-compose-button'),
                        onPressed: () => GoRouter.of(context).push('/meow'),
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
                            key: const Key('app-shell-compose-button'),
                            onPressed: () => GoRouter.of(context).push('/meow'),
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
          ),
          if (profileTab != null) ...[
            Divider(height: 24, color: theme.dividerColor),
            _NavItem(
              icon: profileTab.$2,
              selectedIcon: profileTab.$3,
              label: labelFor(profileTab.$4),
              selected: profileIndex == currentIndex,
              extended: extended,
              badgeCount: _badgeFor(profileTab.$1),
              onTap: () => GoRouter.of(context).go(profileTab.$1),
            ),
          ],
        ],
      ),
    );
  }
}

const desktopAppShellPathOrder = <String>[
  '/feed',
  '/discover',
  '/notifications',
  '/chat',
  '/groups',
  '/moderation',
  '/sentiment',
  '/me',
];

const desktopAppShellPaths = <String>{
  '/feed',
  '/discover',
  '/notifications',
  '/chat',
  '/groups',
  '/moderation',
  '/sentiment',
  '/me',
};

class _Brand extends StatelessWidget {
  const _Brand({required this.extended});

  final bool extended;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: extended ? 10 : 0, vertical: 4),
      child: Row(
        mainAxisAlignment: extended
            ? MainAxisAlignment.start
            : MainAxisAlignment.center,
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
    this.badgeCount,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final bool extended;
  final VoidCallback onTap;
  final int? badgeCount;

  Widget _icon(Color color) {
    final data = selected ? selectedIcon : icon;
    final iconWidget = Icon(data, color: color);
    final count = badgeCount ?? 0;
    if (count <= 0) return iconWidget;
    return Badge(
      label: Text(count > 99 ? '99+' : '$count'),
      child: iconWidget,
    );
  }

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
                      _icon(color),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          label,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: color,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                    ],
                  )
                : Tooltip(message: label, child: _icon(color)),
          ),
        ),
      ),
    );
  }
}
