import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/notifications/domain/notification_models.dart';
import '../../features/realtime/data/realtime_service.dart';
import '../i18n/app_localizations.dart';
import '../providers/providers.dart';
import '../widgets/responsive.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.child});
  final Widget child;

  static const _primaryTabs = [
    ('/feed', Icons.home_outlined, Icons.home, 'tab.home'),
    ('/groups', Icons.groups_outlined, Icons.groups, 'group.title'),
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
      '/ai/knowledge',
      Icons.psychology_outlined,
      Icons.psychology,
      'ai.knowledge.title',
    ),
    (
      '/ai/writing',
      Icons.edit_note_outlined,
      Icons.edit_note,
      'ai.writing.title',
    ),
    ('/me', Icons.person_outline, Icons.person, 'tab.profile'),
  ];

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  var _didStartRealtime = false;
  RealtimeService? _realtime;
  RealtimeListener? _onRealtimeEvent;
  StreamSubscription<int>? _recovery;
  Timer? _unreadRefresh;
  late final VoidCallback _stopSession;

  @override
  void initState() {
    super.initState();
    final store = ref.read(tokenStoreProvider);
    var revision = store.revision;
    var changing = store.isSessionChanging;
    _stopSession = store.listenSessionChanges(() {
      final service = _realtime;
      if (service != null && revision != store.revision) {
        _unreadRefresh?.cancel();
        _unreadRefresh = null;
        ref.read(notificationsUnreadProvider.notifier).set(0);
      }
      final changed =
          revision != store.revision || changing != store.isSessionChanging;
      revision = store.revision;
      changing = store.isSessionChanging;
      if (service != null && changed && !changing) _queueUnreadRefresh(service);
    });
  }

  @override
  void dispose() {
    _stopSession();
    _unbindRealtime();
    super.dispose();
  }

  void _unbindRealtime() {
    _unreadRefresh?.cancel();
    _unreadRefresh = null;
    final listener = _onRealtimeEvent;
    if (listener != null) _realtime?.removeListener(listener);
    _onRealtimeEvent = null;
    _realtime = null;
    unawaited(_recovery?.cancel());
    _recovery = null;
  }

  void _queueUnreadRefresh(RealtimeService service) {
    if (!mounted || !identical(_realtime, service) || _unreadRefresh != null) {
      return;
    }
    final store = ref.read(tokenStoreProvider);
    if (store.isSessionChanging) return;
    final revision = store.revision;
    _unreadRefresh = Timer(const Duration(milliseconds: 120), () {
      _unreadRefresh = null;
      if (!mounted ||
          !identical(_realtime, service) ||
          store.revision != revision ||
          store.isSessionChanging ||
          !ref.read(authSessionProvider).isAuthenticated) {
        return;
      }
      unawaited(ref.read(notificationsUnreadProvider.notifier).refresh());
    });
  }

  void _bindRealtime(RealtimeService service) {
    if (identical(_realtime, service)) return;
    final replacing = _realtime != null;
    _unbindRealtime();
    _realtime = service;
    void onEvent(Map<String, dynamic> event) {
      if (isNotificationRealtimeEvent(event['type'])) {
        _queueUnreadRefresh(service);
      }
    }

    _onRealtimeEvent = onEvent;
    service.addListener(onEvent);
    _recovery = service.recovery.listen((_) => _queueUnreadRefresh(service));
    if (replacing) {
      ref.read(notificationsUnreadProvider.notifier).set(0);
      _queueUnreadRefresh(service);
    }
    unawaited(service.connect());
  }

  int _indexFor(
    String location,
    List<(String, IconData, IconData, String)> tabs,
  ) {
    // Prefer exact / prefix match so `/me` does not steal unrelated paths.
    var best = -1;
    var bestLen = -1;
    for (var i = 0; i < tabs.length; i++) {
      final path = tabs[i].$1;
      final hit = location == path || location.startsWith('$path/');
      if (hit && path.length > bestLen) {
        best = i;
        bestLen = path.length;
      }
    }
    // NavigationBar requires a non-negative index; unmatched shell routes
    // fall back to home. On mobile /discover hides the bar entirely.
    return best < 0 ? 0 : best;
  }

  Widget _tabIcon(IconData icon, {required int badgeCount}) {
    if (badgeCount <= 0) return Icon(icon);
    return Badge(
      label: Text(badgeCount > 99 ? '99+' : '$badgeCount'),
      child: Icon(icon),
    );
  }

  void _maybeStartRealtime(bool isAuthenticated) {
    if (!isAuthenticated || _didStartRealtime) return;
    _didStartRealtime = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !ref.read(authSessionProvider).isAuthenticated) return;
      _bindRealtime(ref.read(realtimeServiceProvider));
      unawaited(ref.read(notificationsUnreadProvider.notifier).refresh());
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

    ref.listen(realtimeServiceProvider, (_, next) {
      if (ref.read(authSessionProvider).isAuthenticated) {
        _bindRealtime(next);
      }
    });

    ref.listen(authSessionProvider, (prev, next) {
      if (!next.isAuthenticated) {
        _didStartRealtime = false;
        _unbindRealtime();
        unawaited(ref.read(realtimeServiceProvider).disconnect());
        ref.read(notificationsUnreadProvider.notifier).set(0);
      } else if (prev?.isAuthenticated != true) {
        _maybeStartRealtime(true);
      }
    });

    _maybeStartRealtime(isAuthenticated);

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

    // Discover is in-shell for desktop rail parity; hide bottom bar on mobile
    // so no primary tab is falsely highlighted.
    final hideBottomNav =
        location == '/discover' || location.startsWith('/discover/');

    return Scaffold(
      body: widget.child,
      bottomNavigationBar: hideBottomNav
          ? null
          : Container(
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
  '/ai/knowledge',
  '/ai/writing',
  '/me',
];

const desktopAppShellPaths = <String>{
  '/feed',
  '/discover',
  '/notifications',
  '/chat',
  '/groups',
  '/moderation',
  '/ai/knowledge',
  '/ai/writing',
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
              borderRadius: BorderRadius.circular(12),
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
                  color: theme.colorScheme.onSurface,
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
    return Badge(label: Text(count > 99 ? '99+' : '$count'), child: iconWidget);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface;
    final bg = selected
        ? theme.colorScheme.primary.withValues(alpha: 0.12)
        : Colors.transparent;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
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
