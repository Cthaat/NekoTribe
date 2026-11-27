import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/notifications/domain/notification_models.dart';
import '../../features/realtime/data/realtime_service.dart';
import '../i18n/app_localizations.dart';
import '../providers/providers.dart';
import '../theme/tokens.dart';
import '../widgets/glass/liquid_glass_bars.dart';
import '../widgets/glass/liquid_glass_surface.dart';
import '../widgets/glass/liquid_glass_tokens.dart';
import '../widgets/app_avatar.dart';
import '../widgets/responsive.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.child});
  final Widget child;

  static const _primaryTabs = [
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

  static const _desktopPrimaryTabs = [
    ('/feed', Icons.home_outlined, Icons.home_rounded, 'tab.home'),
    (
      '/discover',
      Icons.explore_outlined,
      Icons.explore_rounded,
      'tab.discover',
    ),
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
    ('/groups', Icons.groups_outlined, Icons.groups_rounded, 'group.title'),
  ];

  static const _moreRoutes = [
    ('/moderation', Icons.shield_outlined, 'moderation.title'),
    ('/ai/knowledge', Icons.psychology_outlined, 'ai.knowledge.title'),
    ('/ai/writing', Icons.edit_note_outlined, 'ai.writing.title'),
    ('/settings', Icons.settings_outlined, 'common.settings'),
  ];

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  var _didStartRealtime = false;
  bool _dockExpanded = true;
  String _lastMobileLocation = '';
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
    List<(String, IconData, IconData, String)> tabs, {
    int fallback = 0,
  }) {
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
    return best < 0 ? fallback : best;
  }

  bool _isMoreLocation(String location) {
    for (final item in AppShell._moreRoutes) {
      if (location == item.$1 || location.startsWith('${item.$1}/')) {
        return true;
      }
    }
    return false;
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

  bool _isMobilePrimaryLocation(String location) {
    if (location == '/feed' ||
        location == '/notifications' ||
        location == '/chat' ||
        location == '/me') {
      return true;
    }
    return location == '/groups' ||
        location == '/groups/discover' ||
        location == '/groups/my' ||
        location == '/groups/invites';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final location = GoRouterState.of(context).matchedLocation;
    final width = MediaQuery.sizeOf(context).width;
    final isWide = width >= AppBreakpoints.medium;
    final isExpanded = width >= AppBreakpoints.expanded;
    final social = SocialColors.of(context);
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
      final isProfileSelected =
          location == '/me' ||
          location.startsWith('/me/') ||
          location == '/account' ||
          location.startsWith('/account/') ||
          location == '/settings' ||
          location.startsWith('/settings/');
      final isMoreSelected = _isMoreLocation(location);
      final selectedPrimaryIndex = isProfileSelected || isMoreSelected
          ? -1
          : _indexFor(location, AppShell._desktopPrimaryTabs, fallback: -1);

      return Scaffold(
        backgroundColor: social.shellFrame,
        body: Row(
          children: [
            _SideNav(
              extended: isExpanded,
              currentIndex: selectedPrimaryIndex,
              profileSelected: isProfileSelected,
              moreSelected: isMoreSelected,
              tabs: AppShell._desktopPrimaryTabs,
              moreRoutes: AppShell._moreRoutes,
              labelFor: l10n.t,
              notificationsUnread: unread,
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 8, 8, 8),
                child: ClipRSuperellipse(
                  borderRadius: BorderRadius.circular(AppRadius.canvas),
                  child: ColoredBox(
                    color: social.surfaceBase,
                    child: widget.child,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    const mobileTabs = AppShell._primaryTabs;
    final currentIndex = _indexFor(location, mobileTabs);
    final hideBottomNav = !_isMobilePrimaryLocation(location);
    final reduced = AppMotion.reduced(context);
    if (_lastMobileLocation != location) {
      _lastMobileLocation = location;
      _dockExpanded = true;
    }

    final innerBody = reduced
        ? widget.child
        : TweenAnimationBuilder<double>(
            key: ValueKey(
              hideBottomNav
                  ? 'mobile-discover-$location'
                  : 'mobile-$currentIndex',
            ),
            tween: Tween(begin: 0.0, end: 1.0),
            duration: AppMotion.fast,
            curve: AppMotion.curve,
            builder: (context, value, child) =>
                Opacity(opacity: 0.8 + 0.2 * value, child: child),
            child: widget.child,
          );

    final bodyContent = NotificationListener<ScrollUpdateNotification>(
      onNotification: (notification) {
        final metrics = notification.metrics;
        if (hideBottomNav ||
            reduced ||
            notification.depth != 0 ||
            metrics.axis != Axis.vertical) {
          return false;
        }
        final delta = notification.scrollDelta ?? 0;
        var expanded = _dockExpanded;
        if (metrics.extentBefore <= 24 ||
            metrics.extentAfter <= 24 ||
            delta < 0) {
          expanded = true;
        } else if (metrics.extentBefore > 48 && delta > 0) {
          expanded = false;
        }
        if (expanded != _dockExpanded) {
          setState(() => _dockExpanded = expanded);
        }
        return false;
      },
      child: innerBody,
    );

    final dockExpanded = reduced || _dockExpanded;

    return Scaffold(
      backgroundColor: social.surfaceBase,
      extendBody: true,
      body: bodyContent,
      bottomNavigationBar: hideBottomNav
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: AnimatedSlide(
                  offset: dockExpanded ? Offset.zero : const Offset(0, .08),
                  duration: AppMotion.resolve(context, AppMotion.glide),
                  curve: AppMotion.glideCurve,
                  child: AnimatedScale(
                    scale: dockExpanded ? 1 : .96,
                    alignment: Alignment.bottomCenter,
                    duration: AppMotion.resolve(context, AppMotion.glide),
                    curve: AppMotion.glideCurve,
                    child: LiquidGlassNavDock(
                      selectedIndex: currentIndex,
                      onSelected: (i) => context.go(mobileTabs[i].$1),
                      items: [
                        for (final t in mobileTabs)
                          LiquidGlassNavItem(
                            icon: t.$2,
                            selectedIcon: t.$3,
                            label: l10n.t(t.$4),
                            badgeCount: t.$1 == '/notifications' ? unread : 0,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

class _SideNav extends StatelessWidget {
  const _SideNav({
    required this.extended,
    required this.currentIndex,
    required this.profileSelected,
    required this.moreSelected,
    required this.tabs,
    required this.moreRoutes,
    required this.labelFor,
    required this.notificationsUnread,
  });

  final bool extended;
  final int currentIndex;
  final bool profileSelected;
  final bool moreSelected;
  final List<(String, IconData, IconData, String)> tabs;
  final List<(String, IconData, String)> moreRoutes;
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
    final scheme = theme.colorScheme;
    final social = SocialColors.of(context);
    final width = extended ? 220.0 : 72.0;

    return Container(
      width: width,
      color: social.shellFrame,
      padding: EdgeInsets.symmetric(
        vertical: 14,
        horizontal: extended ? 12 : 8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Brand(extended: extended),
                  const SizedBox(height: 14),
                  for (var i = 0; i < tabs.length; i++)
                    _NavItem(
                      icon: tabs[i].$2,
                      selectedIcon: tabs[i].$3,
                      label: labelFor(tabs[i].$4),
                      selected: i == currentIndex,
                      extended: extended,
                      badgeCount: _badgeFor(tabs[i].$1),
                      onTap: () => GoRouter.of(context).go(tabs[i].$1),
                    ),
                  _MoreNavMenu(
                    extended: extended,
                    selected: moreSelected,
                    routes: moreRoutes,
                    labelFor: labelFor,
                  ),
                  const SizedBox(height: 14),
                  if (extended)
                    SizedBox(
                      height: 42,
                      child: FilledButton(
                        key: const Key('app-shell-compose-button'),
                        onPressed: () => GoRouter.of(context).push('/meow'),
                        style: FilledButton.styleFrom(
                          backgroundColor: scheme.primary,
                          foregroundColor: scheme.onPrimary,
                          shape: const StadiumBorder(),
                          textStyle: theme.textTheme.labelLarge?.copyWith(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        child: Text(labelFor('common.post')),
                      ),
                    )
                  else
                    Center(
                      child: Tooltip(
                        message: labelFor('common.post'),
                        child: SizedBox(
                          width: 42,
                          height: 42,
                          child: FilledButton(
                            key: const Key('app-shell-compose-button'),
                            onPressed: () => GoRouter.of(context).push('/meow'),
                            style: FilledButton.styleFrom(
                              backgroundColor: scheme.primary,
                              foregroundColor: scheme.onPrimary,
                              padding: EdgeInsets.zero,
                              shape: const CircleBorder(),
                            ),
                            child: const Icon(Icons.edit_rounded, size: 19),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          _ProfileFooterPill(
            extended: extended,
            selected: profileSelected,
            label: labelFor('tab.profile'),
            settingsLabel: labelFor('common.settings'),
            onOpenMe: () => GoRouter.of(context).go('/me'),
            onOpenSettings: () => GoRouter.of(context).go('/settings'),
          ),
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
    final scheme = theme.colorScheme;
    final social = SocialColors.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.inner),
      hoverColor: social.surfaceHover,
      onTap: () => GoRouter.of(context).go('/feed'),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: extended ? 10 : 0,
          vertical: 8,
        ),
        child: Row(
          mainAxisAlignment: extended
              ? MainAxisAlignment.start
              : MainAxisAlignment.center,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.pets_rounded,
                color: scheme.onPrimary,
                size: 18,
              ),
            ),
            if (extended) ...[
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'NekoTribe',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                    color: scheme.onSurface,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
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

  Widget _icon(BuildContext context, Color color) {
    final reduced = AppMotion.reduced(context);
    final iconWidget = reduced
        ? Icon(selected ? selectedIcon : icon, color: color, size: 20)
        : AnimatedSwitcher(
            duration: AppMotion.fast,
            child: Icon(
              selected ? selectedIcon : icon,
              key: ValueKey((selected, selectedIcon.codePoint)),
              color: color,
              size: 20,
            ),
          );
    final count = badgeCount ?? 0;
    if (count <= 0) return iconWidget;
    return Builder(
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        final social = SocialColors.of(context);
        return Badge(
          backgroundColor: Color.alphaBlend(
            social.primarySoft,
            social.surfaceCard,
          ),
          textColor: scheme.primary,
          label: Text(count > 99 ? '99+' : '$count'),
          child: iconWidget,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final social = SocialColors.of(context);
    final fg = selected ? scheme.primary : scheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected ? social.primarySoft : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          hoverColor: social.surfaceHover,
          child: SizedBox(
            height: 42,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: extended ? 12 : 0),
              child: extended
                  ? Row(
                      children: [
                        _icon(context, fg),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            label,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontSize: 14.5,
                              color: fg,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ),
                      ],
                    )
                  : Center(
                      child: Tooltip(message: label, child: _icon(context, fg)),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MoreNavMenu extends StatelessWidget {
  const _MoreNavMenu({
    required this.extended,
    required this.selected,
    required this.routes,
    required this.labelFor,
  });

  final bool extended;
  final bool selected;
  final List<(String, IconData, String)> routes;
  final String Function(String) labelFor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final social = SocialColors.of(context);
    final moreLabel = labelFor('common.more');
    final fg = selected ? scheme.primary : scheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: MenuAnchor(
        style: const MenuStyle(
          backgroundColor: WidgetStatePropertyAll(Colors.transparent),
          surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
          shadowColor: WidgetStatePropertyAll(Colors.transparent),
          elevation: WidgetStatePropertyAll(0),
          padding: WidgetStatePropertyAll(EdgeInsets.zero),
        ),
        menuChildren: [
          LiquidGlassSurface(
            preset: LiquidGlassPreset.popover,
            borderRadius: BorderRadius.circular(AppRadius.card),
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final item in routes)
                  MenuItemButton(
                    onPressed: () => GoRouter.of(context).go(item.$1),
                    leadingIcon: Icon(item.$2, size: 19),
                    child: Text(labelFor(item.$3)),
                  ),
              ],
            ),
          ),
        ],
        builder: (context, controller, child) => Tooltip(
          message: moreLabel,
          child: Material(
            color: selected ? social.primarySoft : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const Key('app-shell-more-button'),
              onTap: () =>
                  controller.isOpen ? controller.close() : controller.open(),
              child: Ink(
                height: 42,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: extended ? 12 : 0),
                  child: extended
                      ? Row(
                          children: [
                            Icon(
                              Icons.more_horiz_rounded,
                              size: 20,
                              color: selected ? scheme.primary : fg,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                moreLabel,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontSize: 14.5,
                                  color: selected ? scheme.primary : fg,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        )
                      : Center(
                          child: Icon(
                            Icons.more_horiz_rounded,
                            size: 20,
                            color: selected ? scheme.primary : fg,
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileFooterPill extends StatelessWidget {
  const _ProfileFooterPill({
    required this.extended,
    required this.selected,
    required this.label,
    required this.settingsLabel,
    required this.onOpenMe,
    required this.onOpenSettings,
  });

  final bool extended;
  final bool selected;
  final String label;
  final String settingsLabel;
  final VoidCallback onOpenMe;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final social = SocialColors.of(context);
    return Material(
      color: selected ? social.primarySoft : Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpenMe,
        hoverColor: social.surfaceHover,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: extended ? 10 : 0,
            vertical: 8,
          ),
          child: extended
              ? Row(
                  children: [
                    AppAvatar(url: null, size: 32, name: label, seed: 2),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: selected ? scheme.primary : scheme.onSurface,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: settingsLabel,
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        Icons.settings_outlined,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                      onPressed: onOpenSettings,
                    ),
                  ],
                )
              : Center(
                  child: Tooltip(
                    message: label,
                    child: AppAvatar(url: null, size: 32, name: label, seed: 2),
                  ),
                ),
        ),
      ),
    );
  }
}
