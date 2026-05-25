import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/responsive.dart';
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
            category: draft.category,
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
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppBreakpoints.contentMaxWidth,
                ),
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _conversations.isEmpty
                        ? EmptyView(message: l10n.t('chat.empty'))
                        : RefreshIndicator(
                            onRefresh: _load,
                            child: ListView.separated(
                              itemCount: _conversations.length,
                              separatorBuilder: (_, _) => Divider(
                                height: 1,
                                color: Theme.of(context).dividerColor,
                              ),
                              itemBuilder: (_, i) {
                                final c = _conversations[i];
                                return ListTile(
                                  leading: AppAvatar(
                                    url: c.participant.avatarUrl,
                                    size: 48,
                                  ),
                                  title: Text(
                                    c.participant.displayName.isEmpty
                                        ? c.participant.username
                                        : c.participant.displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
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
                                            ? _formatDate(
                                                c.lastMessage!.createdAt,
                                              )
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
                              separatorBuilder: (_, _) => Divider(
                                height: 1,
                                color: Theme.of(context).dividerColor,
                              ),
                              itemBuilder: (_, i) {
                                final g = _groups[i];
                                return ListTile(
                                  leading: AppAvatar(
                                    url: g.avatarUrl,
                                    size: 48,
                                  ),
                                  title: Text(
                                    g.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    l10n
                                        .t('chat.members_channels')
                                        .replaceAll(
                                          '{members}',
                                          '${g.memberCount}',
                                        )
                                        .replaceAll(
                                          '{channels}',
                                          '${g.channelCount}',
                                        ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
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
              ),
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
    if (value.isEmpty) return;
    Navigator.of(context).pop(
      _ChannelDraft(
        name: value,
        category: _category.text.trim().isEmpty ? null : _category.text.trim(),
        isPrivate: _isPrivate,
      ),
    );
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
            key: const Key('chat-channel-name-field'),
            controller: _name,
            autofocus: true,
            decoration: InputDecoration(labelText: l10n.t('chat.channel_name')),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _category,
            decoration: InputDecoration(
              labelText: l10n.t('chat.channel_category'),
            ),
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
          onPressed: _submit,
          child: Text(l10n.t('common.create')),
        ),
      ],
    );
  }
}

class _GroupChannelPicker extends ConsumerStatefulWidget {
  const _GroupChannelPicker({
    required this.group,
    required this.channels,
    this.onCreate,
  });

  final V2ChatGroup group;
  final List<V2ChatChannel> channels;
  final Future<V2ChatChannel?> Function()? onCreate;

  @override
  ConsumerState<_GroupChannelPicker> createState() =>
      _GroupChannelPickerState();
}

class _GroupChannelPickerState extends ConsumerState<_GroupChannelPicker> {
  late List<V2ChatChannel> _channels;
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _channels = List.of(widget.channels);
  }

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

  Future<void> _handleMute(V2ChatChannel channel) async {
    final nextMuted = !channel.isMutedByMe;
    try {
      await ref
          .read(chatApiProvider)
          .setChannelMuteStatus(
            channelId: channel.channelId,
            isMuted: nextMuted,
          );
      if (!mounted) return;
      setState(() {
        _replaceChannel(_copyChannel(channel, isMutedByMe: nextMuted));
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _handleEdit(V2ChatChannel channel) async {
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
    if (draft == null) return;
    try {
      final updated = await ref
          .read(chatApiProvider)
          .updateChannel(
            channelId: channel.channelId,
            name: draft.name,
            category: draft.category,
            isPrivate: draft.isPrivate,
          );
      if (!mounted) return;
      setState(() => _replaceChannel(updated));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _handleDelete(V2ChatChannel channel) async {
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
    if (confirmed != true) return;
    try {
      await ref.read(chatApiProvider).deleteChannel(channel.channelId);
      if (!mounted) return;
      setState(() {
        _channels.removeWhere((item) => item.channelId == channel.channelId);
      });
    } catch (e) {
      if (!mounted) return;
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
      _channels[index] = channel;
    }
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
                itemCount: _channels.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final channel = _channels[index];
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
                        IconButton(
                          key: Key('chat-channel-mute-${channel.channelId}'),
                          visualDensity: VisualDensity.compact,
                          tooltip: channel.isMutedByMe
                              ? l10n.t('chat.unmute_channel')
                              : l10n.t('chat.mute_channel'),
                          icon: Icon(
                            channel.isMutedByMe
                                ? Icons.notifications_active_outlined
                                : Icons.notifications_off_outlined,
                            size: 18,
                          ),
                          onPressed: () => _handleMute(channel),
                        ),
                        if (channel.canManage) ...[
                          IconButton(
                            key: Key('chat-channel-edit-${channel.channelId}'),
                            visualDensity: VisualDensity.compact,
                            tooltip: l10n.t('chat.edit_channel'),
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            onPressed: () => _handleEdit(channel),
                          ),
                          IconButton(
                            key: Key(
                              'chat-channel-delete-${channel.channelId}',
                            ),
                            visualDensity: VisualDensity.compact,
                            tooltip: l10n.t('chat.delete_channel'),
                            icon: const Icon(Icons.delete_outline, size: 18),
                            onPressed: () => _handleDelete(channel),
                          ),
                        ],
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
