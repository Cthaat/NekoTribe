import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/chat_models.dart';

class ChatHomeScreen extends ConsumerStatefulWidget {
  const ChatHomeScreen({super.key});

  @override
  ConsumerState<ChatHomeScreen> createState() => _ChatHomeScreenState();
}

class _ChatHomeScreenState extends ConsumerState<ChatHomeScreen>
    with TickerProviderStateMixin {
  late final TabController _tabController;
  List<V2DirectConversation> _conversations = [];
  List<V2ChatGroup> _groups = [];
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(chatApiProvider);
      final conversations = await api.listConversations();
      final groups = await api.listChatGroups();
      if (!mounted) return;
      setState(() {
        _conversations = conversations;
        _groups = groups;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
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
    try {
      final channels = await ref
          .read(chatApiProvider)
          .listChannels(group.groupId);
      if (!mounted) return;
      if (channels.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No channels in this group')),
        );
        return;
      }
      final channel = channels.first;
      context.push(
        '/chat/groups/${group.groupId}/channels/${channel.channelId}',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('tab.messages')),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Direct'),
            Tab(text: 'Groups'),
          ],
        ),
      ),
      body: _loading
          ? const LoadingView()
          : _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : TabBarView(
              controller: _tabController,
              children: [
                _conversations.isEmpty
                    ? EmptyView(message: l10n.t('chat.empty'))
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.separated(
                          itemCount: _conversations.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final c = _conversations[i];
                            return ListTile(
                              leading: AppAvatar(
                                url: c.participant.avatarUrl,
                                size: 48,
                              ),
                              title: Text(c.participant.displayName),
                              subtitle: Text(
                                c.lastMessage?.content ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    c.lastMessage != null
                                        ? _formatDate(c.lastMessage!.createdAt)
                                        : _formatDate(c.updatedAt),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                  if (c.unreadCount > 0) ...[
                                    const SizedBox(height: 4),
                                    Badge(label: Text('${c.unreadCount}')),
                                  ],
                                ],
                              ),
                              onTap: () => context.push(
                                '/chat/conversation/${c.conversationId}',
                              ),
                            );
                          },
                        ),
                      ),
                _groups.isEmpty
                    ? const EmptyView(message: 'No groups')
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.separated(
                          itemCount: _groups.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final g = _groups[i];
                            return ListTile(
                              leading: AppAvatar(url: g.avatarUrl, size: 48),
                              title: Text(g.name),
                              subtitle: Text(
                                '${g.memberCount} members · ${g.channelCount} channels',
                              ),
                              trailing: g.unreadCount > 0
                                  ? Badge(label: Text('${g.unreadCount}'))
                                  : null,
                              onTap: () => _openGroup(g),
                            );
                          },
                        ),
                      ),
              ],
            ),
    );
  }
}
