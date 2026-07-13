import 'dart:async';

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
    await context.push(
      '/chat/conversation/${c.conversationId}',
      extra: {'title': title, 'name': title},
    );
    if (mounted) _load();
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
                        ? EmptyView(
                            message: l10n.t('chat.empty'),
                            icon: Icons.chat_bubble_outline,
                            actionLabel: l10n.t('tab.discover'),
                            onAction: () => context.go('/discover'),
                          )
                        : RefreshIndicator(
                            onRefresh: _load,
                            child: ListView.separated(
                              padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                              itemCount: _conversations.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (_, i) {
                                final c = _conversations[i];
                                final name = c.participant.displayName.isEmpty
                                    ? c.participant.username
                                    : c.participant.displayName;
                                final subtitle =
                                    c.lastMessage?.content.trim().isNotEmpty ==
                                        true
                                    ? c.lastMessage!.content
                                    : '';
                                final theme = Theme.of(context);
                                return Material(
                                  color: theme
                                      .colorScheme
                                      .surfaceContainerHighest
                                      .withValues(alpha: 0.35),
                                  borderRadius: BorderRadius.circular(16),
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 4,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    leading: c.unreadCount > 0
                                        ? Badge(
                                            label: Text('${c.unreadCount}'),
                                            child: AppAvatar(
                                              url: c.participant.avatarUrl,
                                              size: 48,
                                            ),
                                          )
                                        : AppAvatar(
                                            url: c.participant.avatarUrl,
                                            size: 48,
                                          ),
                                    title: Text(
                                      name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.titleSmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                    subtitle: Text(
                                      subtitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                    trailing: Text(
                                      c.lastMessage != null
                                          ? _formatDate(
                                              c.lastMessage!.createdAt,
                                            )
                                          : _formatDate(c.updatedAt),
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                    onTap: () => _openConversation(c),
                                  ),
                                );
                              },
                            ),
                          ),
                    _groups.isEmpty
                        ? EmptyView(
                            message: l10n.t('chat.no_groups'),
                            icon: Icons.groups_outlined,
                            actionLabel: l10n.t('group.title'),
                            onAction: () => context.go('/groups'),
                          )
                        : RefreshIndicator(
                            onRefresh: _load,
                            child: ListView.separated(
                              padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                              itemCount: _groups.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (_, i) {
                                final g = _groups[i];
                                final theme = Theme.of(context);
                                return Material(
                                  color: theme
                                      .colorScheme
                                      .surfaceContainerHighest
                                      .withValues(alpha: 0.35),
                                  borderRadius: BorderRadius.circular(16),
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 4,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    leading: AppAvatar(
                                      url: g.avatarUrl,
                                      size: 48,
                                    ),
                                    title: Text(
                                      g.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.titleSmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
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
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                    trailing: g.unreadCount > 0
                                        ? Badge(
                                            label: Text('${g.unreadCount}'),
                                          )
                                        : null,
                                    onTap: () => _openGroup(g),
                                  ),
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
                        if (channel.unreadCount > 0) ...[
                          if (channel.isPrivate || channel.isMutedByMe)
                            const SizedBox(width: 8),
                          Badge(label: Text('${channel.unreadCount}')),
                        ],
                        PopupMenuButton<String>(
                          key: Key(
                            'chat-channel-actions-${channel.channelId}',
                          ),
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
