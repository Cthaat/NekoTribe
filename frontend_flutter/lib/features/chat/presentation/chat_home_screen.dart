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
    List<V2ChatChannel> channels;
    try {
      channels = await ref.read(chatApiProvider).listChannels(group.groupId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
      return;
    }
    if (!mounted) return;
    if (channels.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).t('chat.no_channels')),
        ),
      );
      return;
    }

    final selected = await showModalBottomSheet<V2ChatChannel>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => _GroupChannelPicker(
        group: group,
        channels: channels,
        onCreate: group.canManage ? () => _createChannel(group) : null,
      ),
    );
    if (!mounted || selected == null) return;
    _openChannel(selected);
  }

  void _openChannel(V2ChatChannel channel) {
    context.push(
      '/chat/groups/${channel.groupId}/channels/${channel.channelId}',
    );
  }

  Future<V2ChatChannel?> _createChannel(V2ChatGroup group) async {
    final draft = await _showCreateChannelDialog();
    if (draft == null) return null;
    try {
      return await ref
          .read(chatApiProvider)
          .createChannel(
            groupId: group.groupId,
            name: draft.name,
            isPrivate: draft.isPrivate,
          );
    } catch (e) {
      if (!mounted) return null;
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
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('tab.messages')),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: l10n.t('chat.direct')),
            Tab(text: l10n.t('chat.groups')),
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
                    ? EmptyView(message: l10n.t('chat.no_groups'))
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
                                l10n
                                    .t('chat.members_channels')
                                    .replaceAll('{members}', '${g.memberCount}')
                                    .replaceAll(
                                      '{channels}',
                                      '${g.channelCount}',
                                    ),
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

class _ChannelDraft {
  const _ChannelDraft({required this.name, required this.isPrivate});

  final String name;
  final bool isPrivate;
}

class _CreateChannelDialog extends StatefulWidget {
  const _CreateChannelDialog();

  @override
  State<_CreateChannelDialog> createState() => _CreateChannelDialogState();
}

class _CreateChannelDialogState extends State<_CreateChannelDialog> {
  final _name = TextEditingController();
  bool _isPrivate = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _name.text.trim();
    if (value.isEmpty) return;
    Navigator.of(
      context,
    ).pop(_ChannelDraft(name: value, isPrivate: _isPrivate));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.t('chat.create_channel')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: InputDecoration(labelText: l10n.t('chat.channel_name')),
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
        FilledButton(onPressed: _submit, child: Text(l10n.t('common.create'))),
      ],
    );
  }
}

class _GroupChannelPicker extends StatefulWidget {
  const _GroupChannelPicker({
    required this.group,
    required this.channels,
    this.onCreate,
  });

  final V2ChatGroup group;
  final List<V2ChatChannel> channels;
  final Future<V2ChatChannel?> Function()? onCreate;

  @override
  State<_GroupChannelPicker> createState() => _GroupChannelPickerState();
}

class _GroupChannelPickerState extends State<_GroupChannelPicker> {
  bool _creating = false;

  Future<void> _handleCreate() async {
    final onCreate = widget.onCreate;
    if (onCreate == null || _creating) return;
    setState(() => _creating = true);
    final channel = await onCreate();
    if (!mounted) return;
    if (channel == null) {
      setState(() => _creating = false);
      return;
    }
    Navigator.of(context).pop(channel);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
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
                itemCount: widget.channels.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final channel = widget.channels[index];
                  return ListTile(
                    leading: const Icon(Icons.tag),
                    title: Text('#${channel.name}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (channel.isPrivate) ...[
                          Tooltip(
                            message: l10n.t('chat.private_channel'),
                            child: const Icon(Icons.lock_outline, size: 18),
                          ),
                          const SizedBox(width: 8),
                        ],
                        if (channel.isMutedByMe) ...[
                          Tooltip(
                            message: l10n.t('chat.muted'),
                            child: const Icon(
                              Icons.notifications_off_outlined,
                              size: 18,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        if (channel.unreadCount > 0)
                          Badge(label: Text('${channel.unreadCount}')),
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
