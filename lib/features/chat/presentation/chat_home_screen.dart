import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../shared/widgets/glass/liquid_glass_overlays.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/motion/skeleton.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/theme/tokens.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../../../shared/widgets/ui/surface_card.dart';
import '../../realtime/data/realtime_service.dart'
    show realtimeUserIdFromAccessToken;
import '../domain/chat_models.dart';
import 'channel_screen.dart';
import 'chat_realtime_binding.dart';
import 'conversation_screen.dart';

class ChatHomeScreen extends ConsumerStatefulWidget {
  const ChatHomeScreen({super.key});

  @override
  ConsumerState<ChatHomeScreen> createState() => _ChatHomeScreenState();
}

class _ChatHomeScreenState extends ConsumerState<ChatHomeScreen>
    with TickerProviderStateMixin {
  late final TabController _tabController;
  late final ChatRealtimeBinding _realtime;
  Timer? _conversationRefresh;
  int _homeRequest = 0;
  int _conversationRequest = 0;
  bool _groupPickerOpen = false;
  final _channelMutes = <int, ({int groupId, Future<bool> receipt})>{};
  List<V2DirectConversation> _conversations = [];
  int _conversationPage = 1, _requestedConversationPage = 1;
  bool _hasMoreConversations = false, _loadingConversationPage = false;
  Object? _conversationError;
  List<V2ChatGroup> _groups = [];
  int _groupPage = 1;
  bool _hasMoreGroups = false, _loadingMoreGroups = false;
  bool _loading = true;
  Object? _error;
  ({int conversationId, String title})? _selectedDm;
  ({int groupId, int channelId, String name})? _selectedChannel;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _realtime = ChatRealtimeBinding(
      tokenStore: ref.read(tokenStoreProvider),
      onEvent: _onRealtime,
      onReset: _reset,
      onReload: () => unawaited(_load()),
    );
    _realtime.bind(ref.read(realtimeServiceProvider));
    ref.listenManual(
      realtimeServiceProvider,
      (_, next) => _realtime.bind(next),
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    _conversationRefresh?.cancel();
    _realtime.dispose();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final ownsPage = _realtime.capture();
    if (!ownsPage()) return;
    final request = ++_homeRequest;
    bool current() => mounted && ownsPage() && request == _homeRequest;
    setState(() {
      _loading = true;
      _loadingMoreGroups = false;
      _error = null;
    });
    try {
      final api = ref.read(chatApiProvider);
      await _refreshConversations();
      if (!current()) return;
      final groups = await api.listChatGroups();
      if (!current()) return;
      setState(() {
        _groups = groups.items;
        _groupPage = 1;
        _hasMoreGroups = groups.page == 1 && groups.hasNext;
        _loading = false;
      });
    } catch (e) {
      if (!current()) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _loadMoreGroups() async {
    if (_loading || _loadingMoreGroups || !_hasMoreGroups) return;
    final ownsPage = _realtime.capture();
    final request = _homeRequest;
    bool current() => mounted && ownsPage() && _homeRequest == request;
    if (!current()) return;
    final next = _groupPage + 1;
    setState(() => _loadingMoreGroups = true);
    try {
      final result = await ref.read(chatApiProvider).listChatGroups(page: next);
      if (!current()) return;
      if (result.page != next) {
        throw const FormatException('Unexpected chat group page');
      }
      setState(() {
        _groups = {
          for (final group in _groups) group.groupId: group,
          for (final group in result.items) group.groupId: group,
        }.values.toList();
        _groupPage = next;
        _hasMoreGroups = result.hasNext;
      });
    } catch (error) {
      if (current()) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorView.describe(context, error))),
        );
      }
    } finally {
      if (current()) setState(() => _loadingMoreGroups = false);
    }
  }

  void _reset() {
    _conversationRefresh?.cancel();
    _conversationRefresh = null;
    _homeRequest++;
    _conversationRequest++;
    _channelMutes.clear();
    setState(() {
      _conversations = [];
      _conversationPage = _requestedConversationPage = 1;
      _hasMoreConversations = _loadingConversationPage = false;
      _conversationError = null;
      _groups = [];
      _groupPage = 1;
      _hasMoreGroups = _loadingMoreGroups = false;
      _loading = true;
      _error = null;
      _selectedDm = null;
      _selectedChannel = null;
    });
  }

  void _onRealtime(Map<String, dynamic> event) {
    final type = event['type'];
    if (type != 'direct_message' &&
        type != 'direct_message_deleted' &&
        type != 'direct_read_updated') {
      return;
    }
    final data = event['data'];
    if (data is! Map || data['conversation_id'] is! int) return;
    final conversation = data['conversation_id'] as int;
    if (conversation <= 0 || conversation > 9007199254740991) return;
    if (type == 'direct_read_updated') {
      final reader = data['reader_id'], cursor = data['last_read_message_id'];
      if (reader is int &&
          reader > 0 &&
          reader <= 9007199254740991 &&
          cursor is int &&
          cursor > 0 &&
          cursor <= 9007199254740991) {
        unawaited(_refreshOwnRead(reader));
      }
      return;
    }
    if (type == 'direct_message_deleted') {
      final message = data['message_id'];
      if (message is! int || message <= 0 || message > 9007199254740991) return;
      final index = _conversations.indexWhere(
        (item) =>
            item.conversationId == conversation &&
            item.lastMessage?.messageId == message,
      );
      if (index >= 0) {
        final previous = _conversations[index];
        final redacted = V2DirectConversation(
          conversationId: previous.conversationId,
          participant: previous.participant,
          unreadCount: previous.unreadCount,
          createdAt: previous.createdAt,
          updatedAt: previous.updatedAt,
        );
        setState(
          () => _conversations = [..._conversations]..[index] = redacted,
        );
      }
    }
    _queueConversationRefresh();
  }

  Future<void> _refreshOwnRead(int readerId) async {
    final current = _realtime.capture();
    if (!current()) return;
    try {
      final pair = await ref.read(tokenStoreProvider).read();
      if (mounted &&
          current() &&
          pair != null &&
          realtimeUserIdFromAccessToken(pair.accessToken) == readerId) {
        _queueConversationRefresh();
      }
    } catch (_) {
      // Leave existing unread data intact if the viewer cannot be identified.
    }
  }

  void _queueConversationRefresh() {
    _conversationRequest++;
    _conversationRefresh ??= Timer(const Duration(milliseconds: 150), () {
      _conversationRefresh = null;
      unawaited(_refreshConversations());
    });
  }

  Future<void> _refreshConversations({
    int? page,
    bool userInitiated = false,
  }) async {
    final ownsPage = _realtime.capture();
    if (!ownsPage()) return;
    final request = ++_conversationRequest;
    bool current() => mounted && ownsPage() && request == _conversationRequest;
    var target = page ?? _requestedConversationPage;
    _requestedConversationPage = target;
    if (userInitiated) setState(() => _loadingConversationPage = true);
    try {
      final api = ref.read(chatApiProvider);
      var result = await api.listConversations(page: target);
      if (!current()) return;
      if (target > 1 && result.items.isEmpty) {
        target = 1;
        result = await api.listConversations();
        if (!current()) return;
      }
      if (result.page != target) {
        throw const FormatException('Unexpected conversation page');
      }
      setState(() {
        _conversations = result.items;
        _conversationError = null;
        _conversationPage = _requestedConversationPage = target;
        _hasMoreConversations = result.hasNext;
      });
    } catch (error) {
      if (!current()) return;
      _requestedConversationPage = _conversationPage;
      if (_conversations.isEmpty) setState(() => _conversationError = error);
      if (_loadingConversationPage) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorView.describe(context, error))),
        );
      }
    } finally {
      if (current() && _loadingConversationPage) {
        setState(() => _loadingConversationPage = false);
      }
    }
  }

  String _formatDate(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    final now = DateTime.now();
    final localDt = dt.toLocal();
    if (localDt.year == now.year &&
        localDt.month == now.month &&
        localDt.day == now.day) {
      return DateFormat.Hm().format(localDt);
    }
    return DateFormat.Md().format(localDt);
  }

  Future<void> _openGroup(V2ChatGroup group) async {
    if (_groupPickerOpen) return;
    _groupPickerOpen = true;
    try {
      await _showGroupPicker(group);
    } finally {
      _groupPickerOpen = false;
    }
  }

  Future<void> _showGroupPicker(V2ChatGroup group) async {
    final owner = _realtime.capture();
    final api = ref.read(chatApiProvider);
    bool current() =>
        mounted && owner() && identical(api, ref.read(chatApiProvider));
    if (!current()) return;
    List<V2ChatChannel> channels;
    try {
      // A dismissed picker can still have an authorized write in flight.
      await Future.wait([
        for (final write in _channelMutes.values)
          if (write.groupId == group.groupId)
            write.receipt.then<void>(
              (_) {},
              onError: (Object _, StackTrace _) {},
            ),
      ]);
      if (!mounted || !current()) return;
      channels = await api.listChannels(group.groupId);
    } catch (e) {
      if (!mounted || !current()) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
      return;
    }
    if (!mounted || !current()) return;
    if (channels.isEmpty) {
      if (!group.canManage) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).t('chat.no_channels')),
          ),
        );
        return;
      }
      // Managers can open the picker empty and create the first channel.
    }

    final selected = await showLiquidGlassBottomSheet<V2ChatChannel>(
      context: context,
      builder: (_) => _GroupChannelPicker(
        group: group,
        channels: channels,
        isCurrent: current,
        onMute: _writeChannelMute,
        onCreate: group.canManage ? () => _createChannel(group, current) : null,
      ),
    );
    if (!mounted || !current() || selected == null) return;
    _openChannel(selected);
  }

  Future<bool> _writeChannelMute(V2ChatChannel channel, bool muted) async {
    final receipt = ref
        .read(chatApiProvider)
        .setChannelMuteStatus(channelId: channel.channelId, isMuted: muted);
    _channelMutes[channel.channelId] = (
      groupId: channel.groupId,
      receipt: receipt,
    );
    try {
      return await receipt;
    } finally {
      if (_channelMutes[channel.channelId]?.receipt == receipt) {
        _channelMutes.remove(channel.channelId);
      }
    }
  }

  void _openChannel(V2ChatChannel channel) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    if (wide) {
      setState(() {
        _selectedDm = null;
        _selectedChannel = (
          groupId: channel.groupId,
          channelId: channel.channelId,
          name: channel.name,
        );
      });
      return;
    }
    context.push(
      '/chat/groups/${channel.groupId}/channels/${channel.channelId}',
      extra: {
        'name': channel.name,
        'groupId': channel.groupId,
        'channelId': channel.channelId,
      },
    );
  }

  Future<void> _openConversation(V2DirectConversation c) async {
    final title = c.participant.displayName.isEmpty
        ? c.participant.username
        : c.participant.displayName;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    if (wide) {
      setState(() {
        _selectedChannel = null;
        _selectedDm = (conversationId: c.conversationId, title: title);
      });
      return;
    }
    await context.push(
      '/chat/conversation/${c.conversationId}',
      extra: {'title': title, 'name': title},
    );
    if (mounted) await _refreshConversations();
  }

  Future<V2ChatChannel?> _createChannel(
    V2ChatGroup group,
    bool Function() current,
  ) async {
    if (!current()) return null;
    final draft = await _showCreateChannelDialog();
    if (draft == null || !current()) return null;
    try {
      return await ref
          .read(chatApiProvider)
          .createChannel(
            groupId: group.groupId,
            name: draft.name,
            category: draft.category,
            isPrivate: draft.isPrivate,
          );
    } catch (e) {
      if (!current()) return null;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
      return null;
    }
  }

  Future<_ChannelDraft?> _showCreateChannelDialog() async {
    return showDialog<_ChannelDraft>(
      context: context,
      builder: (_) => const _CreateChannelDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final social = SocialColors.of(context);
    final isWide = MediaQuery.sizeOf(context).width >= 900;

    final listColumn = Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: social.surfaceSubtle,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
            child: TabBar(
              controller: _tabController,
              indicator: BoxDecoration(
                color: social.surfaceCard,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              indicatorSize: TabBarIndicatorSize.tab,
              labelColor: scheme.onSurface,
              unselectedLabelColor: scheme.onSurfaceVariant,
              labelStyle: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
              unselectedLabelStyle: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w500,
              ),
              dividerColor: Colors.transparent,
              tabs: [
                Tab(height: 36, text: l10n.t('chat.direct')),
                Tab(height: 36, text: l10n.t('chat.groups')),
              ],
            ),
          ),
        ),
        Expanded(
          child: _loading
              ? ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    for (var i = 0; i < 6; i++) const ListTileSkeleton(),
                  ],
                )
              : _error != null
              ? ErrorView(error: _error!, onRetry: _load)
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _buildDirectList(l10n, theme, scheme, social, isWide),
                    _buildGroupsList(l10n, theme, scheme, social),
                  ],
                ),
        ),
      ],
    );

    if (isWide) {
      Widget detailPane;
      if (_selectedDm case final dm?) {
        detailPane = ConversationScreen(
          key: ValueKey('split-dm-${dm.conversationId}'),
          conversationId: dm.conversationId,
          title: dm.title,
          embedded: true,
        );
      } else if (_selectedChannel case final ch?) {
        detailPane = ChannelScreen(
          key: ValueKey('split-ch-${ch.groupId}-${ch.channelId}'),
          groupId: ch.groupId,
          channelId: ch.channelId,
          channelName: ch.name,
          embedded: true,
        );
      } else {
        detailPane = Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.forum_outlined,
                    size: 30,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  l10n.t('chat.select_conversation'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  l10n.t('chat.select_conversation_hint'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        );
      }

      return Scaffold(
        backgroundColor: social.surfaceBase,
        body: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              SizedBox(
                width: 344,
                child: SurfaceCard(
                  radius: AppRadius.card,
                  padding: EdgeInsets.zero,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AppBar(
                        backgroundColor: Colors.transparent,
                        elevation: 0,
                        scrolledUnderElevation: 0,
                        title: Text(l10n.t('tab.messages')),
                        automaticallyImplyLeading: false,
                      ),
                      Expanded(child: listColumn),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SurfaceCard(
                  radius: AppRadius.card,
                  padding: EdgeInsets.zero,
                  child: detailPane,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: social.surfaceBase,
      appBar: AppBar(
        backgroundColor: social.glassSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(l10n.t('tab.messages')),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppBreakpoints.contentMaxWidth,
          ),
          child: listColumn,
        ),
      ),
    );
  }

  Widget _buildDirectList(
    AppLocalizations l10n,
    ThemeData theme,
    ColorScheme scheme,
    SocialColors social,
    bool isWide,
  ) {
    if (_conversationError != null) {
      return ErrorView(
        error: _conversationError!,
        onRetry: () => _refreshConversations(userInitiated: true),
      );
    }
    if (_conversations.isEmpty &&
        _conversationPage == 1 &&
        !_hasMoreConversations) {
      return EmptyView(
        message: l10n.t('chat.empty'),
        icon: Icons.chat_bubble_outline,
        actionLabel: l10n.t('tab.discover'),
        onAction: () => context.push('/discover'),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _refreshConversations(
        page: _conversationPage,
        userInitiated: true,
      ),
      child: ListView.separated(
        padding: EdgeInsets.fromLTRB(10, 6, 10, isWide ? 16 : 108),
        itemCount:
            _conversations.length +
            (_conversationPage > 1 || _hasMoreConversations ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(height: 6),
        itemBuilder: (_, i) {
          if (i == _conversations.length) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Wrap(
                alignment: WrapAlignment.center,
                children: [
                  if (_conversationPage > 1)
                    TextButton(
                      onPressed: _loadingConversationPage
                          ? null
                          : () => _refreshConversations(
                              page: _conversationPage - 1,
                              userInitiated: true,
                            ),
                      child: Text(l10n.t('chat.conversations_previous_page')),
                    ),
                  if (_hasMoreConversations)
                    TextButton(
                      onPressed: _loadingConversationPage
                          ? null
                          : () => _refreshConversations(
                              page: _conversationPage + 1,
                              userInitiated: true,
                            ),
                      child: Text(l10n.t('chat.conversations_next_page')),
                    ),
                ],
              ),
            );
          }
          final c = _conversations[i];
          final name = c.participant.displayName.isEmpty
              ? c.participant.username
              : c.participant.displayName;
          final subtitle =
              c.lastMessage?.content.trim().isNotEmpty == true
              ? c.lastMessage!.content
              : '';
          final unread = c.unreadCount > 0;
          final selected =
              isWide && _selectedDm?.conversationId == c.conversationId;
          final timeLabel = c.lastMessage != null
              ? _formatDate(c.lastMessage!.createdAt)
              : _formatDate(c.updatedAt);
          return Material(
            color: selected ? social.surfaceSubtle : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.tile),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.tile),
              onTap: () => _openConversation(c),
              hoverColor: social.hover,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
              child: Row(
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      AppAvatar(
                        url: c.participant.avatarUrl,
                        size: 52,
                        name: name,
                        seed: c.participant.userId,
                      ),
                      if (c.participant.onlineStatus == 'online')
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              color: social.statusOnlineFg,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: scheme.surface,
                                width: 2.5,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: unread
                                      ? FontWeight.w700
                                      : FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              timeLabel,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: unread
                                    ? scheme.primary
                                    : scheme.onSurfaceVariant,
                                fontWeight: unread
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: unread
                                      ? scheme.onSurface
                                      : scheme.onSurfaceVariant,
                                  fontWeight: unread
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                            if (unread) ...[
                              const SizedBox(width: 8),
                              Container(
                                constraints: const BoxConstraints(minWidth: 20),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: scheme.primary,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  '${c.unreadCount}',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.onPrimary,
                                    fontWeight: FontWeight.w700,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        },
      ),
    );
  }

  Widget _buildGroupsList(
    AppLocalizations l10n,
    ThemeData theme,
    ColorScheme scheme,
    SocialColors social,
  ) {
    if (_groups.isEmpty && !_hasMoreGroups) {
      return EmptyView(
        message: l10n.t('chat.no_groups'),
        icon: Icons.groups_outlined,
        actionLabel: l10n.t('group.title'),
        onAction: () => context.go('/groups'),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 108),
        itemCount: _groups.length + (_hasMoreGroups ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(height: 6),
        itemBuilder: (_, i) {
          if (i == _groups.length) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Center(
                child: TextButton(
                  onPressed: _loadingMoreGroups ? null : _loadMoreGroups,
                  child: Text(l10n.t('chat.more_groups')),
                ),
              ),
            );
          }
          final g = _groups[i];
          final unread = g.unreadCount > 0;
          return Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => _openGroup(g),
              hoverColor: social.hover,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                child: Row(
                children: [
                  AppAvatar(
                    url: g.avatarUrl,
                    size: 52,
                    name: g.name,
                    seed: g.groupId,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                g.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: unread
                                      ? FontWeight.w700
                                      : FontWeight.w600,
                                ),
                              ),
                            ),
                            if (unread)
                              Container(
                                constraints: const BoxConstraints(minWidth: 20),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: scheme.primary,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  '${g.unreadCount}',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.onPrimary,
                                    fontWeight: FontWeight.w700,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l10n
                              .t('chat.members_channels')
                              .replaceAll('{members}', '${g.memberCount}')
                              .replaceAll('{channels}', '${g.channelCount}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        },
      ),
    );
  }
}

class _ChannelDraft {
  const _ChannelDraft({
    required this.name,
    required this.isPrivate,
    this.category,
  });

  final String name;
  final bool isPrivate;
  final String? category;
}

class _CreateChannelDialog extends StatefulWidget {
  const _CreateChannelDialog({this.initial});

  final _ChannelDraft? initial;

  @override
  State<_CreateChannelDialog> createState() => _CreateChannelDialogState();
}

class _CreateChannelDialogState extends State<_CreateChannelDialog> {
  final _name = TextEditingController();
  final _category = TextEditingController();
  bool _isPrivate = false;
  bool get _nameTooLong => utf8.encode(_name.text.trim()).length > 100;
  bool get _categoryTooLong => utf8.encode(_category.text.trim()).length > 50;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial != null) {
      _name.text = initial.name;
      _category.text = initial.category ?? '';
      _isPrivate = initial.isPrivate;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _category.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _name.text.trim();
    if (value.isEmpty || _nameTooLong || _categoryTooLong) return;
    Navigator.of(context).pop(
      _ChannelDraft(
        name: value,
        category: _category.text.trim(),
        isPrivate: _isPrivate,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(
        l10n.t(
          widget.initial == null ? 'chat.create_channel' : 'chat.edit_channel',
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('chat-channel-name-field'),
            controller: _name,
            autofocus: true,
            decoration: InputDecoration(
              labelText: l10n.t('chat.channel_name'),
              errorText: _nameTooLong
                  ? l10n.t('chat.channel_name_limit')
                  : null,
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _category,
            decoration: InputDecoration(
              labelText: l10n.t('chat.channel_category'),
              errorText: _categoryTooLong
                  ? l10n.t('chat.channel_category_limit')
                  : null,
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.t('chat.private_channel')),
            value: _isPrivate,
            onChanged: (value) => setState(() => _isPrivate = value),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.t('common.cancel')),
        ),
        FilledButton(
          key: const Key('chat-channel-save-button'),
          onPressed:
              _name.text.trim().isEmpty || _nameTooLong || _categoryTooLong
              ? null
              : _submit,
          child: Text(
            l10n.t(widget.initial == null ? 'common.create' : 'common.save'),
          ),
        ),
      ],
    );
  }
}

class _GroupChannelPicker extends ConsumerStatefulWidget {
  const _GroupChannelPicker({
    required this.group,
    required this.channels,
    required this.isCurrent,
    required this.onMute,
    this.onCreate,
  });

  final V2ChatGroup group;
  final List<V2ChatChannel> channels;
  final bool Function() isCurrent;
  final Future<bool> Function(V2ChatChannel, bool) onMute;
  final Future<V2ChatChannel?> Function()? onCreate;

  @override
  ConsumerState<_GroupChannelPicker> createState() =>
      _GroupChannelPickerState();
}

class _GroupChannelPickerState extends ConsumerState<_GroupChannelPicker> {
  late List<V2ChatChannel> _channels;
  late final VoidCallback _stopSessionListener;
  bool _creating = false;
  bool _expired = false;
  final _pendingMute = <int>{};

  @override
  void initState() {
    super.initState();
    _channels = List.of(widget.channels);
    _stopSessionListener = ref.read(tokenStoreProvider).listenSessionChanges(
      () {
        if (!widget.isCurrent()) _expire();
      },
    );
    ref.listenManual(chatApiProvider, (previous, next) {
      if (!identical(previous, next)) _expire();
    });
  }

  void _expire() {
    if (!mounted || _expired) return;
    setState(() {
      _expired = true;
      _channels.clear();
      _pendingMute.clear();
    });
  }

  @override
  void dispose() {
    _stopSessionListener();
    super.dispose();
  }

  Future<void> _handleCreate() async {
    final onCreate = widget.onCreate;
    if (onCreate == null || _creating || !widget.isCurrent()) return;
    setState(() => _creating = true);
    final channel = await onCreate();
    if (!mounted || !widget.isCurrent()) return;
    if (channel == null) {
      setState(() => _creating = false);
      return;
    }
    Navigator.of(context).pop(channel);
  }

  Future<void> _handleMute(V2ChatChannel channel) async {
    final id = channel.channelId;
    if (!widget.isCurrent() || _pendingMute.contains(id)) return;
    setState(() => _pendingMute.add(id));
    final nextMuted = !channel.isMutedByMe;
    try {
      final muted = await widget.onMute(channel, nextMuted);
      if (!mounted || !widget.isCurrent()) return;
      setState(() {
        final index = _channels.indexWhere((item) => item.channelId == id);
        if (index >= 0) {
          _channels[index] = _copyChannel(_channels[index], isMutedByMe: muted);
        }
      });
    } catch (e) {
      if (!mounted || !widget.isCurrent()) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      if (mounted && widget.isCurrent()) {
        setState(() => _pendingMute.remove(id));
      }
    }
  }

  Future<void> _handleEdit(V2ChatChannel channel) async {
    if (!widget.isCurrent()) return;
    final draft = await showDialog<_ChannelDraft>(
      context: context,
      builder: (_) => _CreateChannelDialog(
        initial: _ChannelDraft(
          name: channel.name,
          category: channel.category,
          isPrivate: channel.isPrivate,
        ),
      ),
    );
    if (draft == null || !mounted || !widget.isCurrent()) return;
    try {
      final updated = await ref
          .read(chatApiProvider)
          .updateChannel(
            channelId: channel.channelId,
            name: draft.name,
            category: draft.category,
            isPrivate: draft.isPrivate,
          );
      if (!mounted || !widget.isCurrent()) return;
      if (updated.groupId != widget.group.groupId ||
          updated.channelId != channel.channelId) {
        throw const FormatException('Invalid chat channel update response');
      }
      setState(() => _replaceChannel(updated));
    } catch (e) {
      if (!mounted || !widget.isCurrent()) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _handleDelete(V2ChatChannel channel) async {
    if (!widget.isCurrent()) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final l10n = AppLocalizations.of(context);
        return AlertDialog(
          title: Text(l10n.t('chat.delete_channel')),
          content: Text(l10n.t('chat.delete_channel_body')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.t('common.cancel')),
            ),
            FilledButton(
              key: const Key('chat-channel-delete-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.t('common.delete')),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted || !widget.isCurrent()) return;
    try {
      await ref.read(chatApiProvider).deleteChannel(channel.channelId);
      if (!mounted || !widget.isCurrent()) return;
      setState(() {
        _channels.removeWhere((item) => item.channelId == channel.channelId);
      });
    } catch (e) {
      if (!mounted || !widget.isCurrent()) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  void _replaceChannel(V2ChatChannel channel) {
    final index = _channels.indexWhere(
      (item) => item.channelId == channel.channelId,
    );
    if (index >= 0) {
      _channels[index] = _copyChannel(
        channel,
        isMutedByMe: _channels[index].isMutedByMe,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_expired) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(l10n.t('chat.channel_context_changed')),
        ),
      );
    }
    final theme = Theme.of(context);
    final maxListHeight = MediaQuery.sizeOf(context).height * 0.55;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.t('chat.choose_channel'),
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(widget.group.name, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxListHeight),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _channels.length,
                separatorBuilder: (_, _) => const SizedBox(height: 6),
                itemBuilder: (context, index) {
                  final channel = _channels[index];
                  return ListTile(
                    leading: const Icon(Icons.tag),
                    title: Text('#${channel.name}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (channel.isPrivate)
                          Tooltip(
                            message: l10n.t('chat.private_channel'),
                            child: const Icon(Icons.lock_outline, size: 18),
                          ),
                        if (channel.isMutedByMe) ...[
                          if (channel.isPrivate) const SizedBox(width: 8),
                          Tooltip(
                            message: l10n.t('chat.muted'),
                            child: const Icon(
                              Icons.notifications_off_outlined,
                              size: 18,
                            ),
                          ),
                        ],
                        if (channel.unreadCount > 0 &&
                            !channel.isMutedByMe) ...[
                          if (channel.isPrivate) const SizedBox(width: 8),
                          Badge(label: Text('${channel.unreadCount}')),
                        ],
                        PopupMenuButton<String>(
                          key: Key('chat-channel-actions-${channel.channelId}'),
                          onSelected: (value) {
                            if (value == 'mute') {
                              unawaited(_handleMute(channel));
                            } else if (value == 'edit') {
                              unawaited(_handleEdit(channel));
                            } else if (value == 'delete') {
                              unawaited(_handleDelete(channel));
                            }
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              key: Key(
                                'chat-channel-mute-${channel.channelId}',
                              ),
                              value: 'mute',
                              enabled: !_pendingMute.contains(
                                channel.channelId,
                              ),
                              child: Text(
                                channel.isMutedByMe
                                    ? l10n.t('chat.unmute_channel')
                                    : l10n.t('chat.mute_channel'),
                              ),
                            ),
                            if (channel.canManage) ...[
                              PopupMenuItem(
                                key: Key(
                                  'chat-channel-edit-${channel.channelId}',
                                ),
                                value: 'edit',
                                child: Text(l10n.t('chat.edit_channel')),
                              ),
                              PopupMenuItem(
                                key: Key(
                                  'chat-channel-delete-${channel.channelId}',
                                ),
                                value: 'delete',
                                child: Text(l10n.t('chat.delete_channel')),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                    onTap: () => Navigator.of(context).pop(channel),
                  );
                },
              ),
            ),
            if (widget.onCreate != null) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _creating ? null : _handleCreate,
                icon: _creating
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add),
                label: Text(l10n.t('chat.create_channel')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

V2ChatChannel _copyChannel(
  V2ChatChannel channel, {
  String? name,
  String? category,
  bool? isPrivate,
  bool? isMutedByMe,
}) {
  return V2ChatChannel(
    channelId: channel.channelId,
    groupId: channel.groupId,
    name: name ?? channel.name,
    type: channel.type,
    category: category ?? channel.category,
    position: channel.position,
    isPrivate: isPrivate ?? channel.isPrivate,
    isMutedByMe: isMutedByMe ?? channel.isMutedByMe,
    unreadCount: channel.unreadCount,
    lastMessage: channel.lastMessage,
    createdAt: channel.createdAt,
    updatedAt: channel.updatedAt,
    canManage: channel.canManage,
  );
}
