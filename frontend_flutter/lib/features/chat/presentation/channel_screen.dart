import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/chat_models.dart';

class ChannelScreen extends ConsumerStatefulWidget {
  const ChannelScreen({
    super.key,
    required this.groupId,
    required this.channelId,
  });

  final int groupId;
  final int channelId;

  @override
  ConsumerState<ChannelScreen> createState() => _ChannelScreenState();
}

class _ChannelScreenState extends ConsumerState<ChannelScreen> {
  final _composer = TextEditingController();
  final _scroll = ScrollController();
  List<V2ChatMessage> _messages = [];
  bool _loading = true;
  bool _sending = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final realtime = ref.read(realtimeServiceProvider);
      realtime.connect();
      realtime.send({
        'type': 'chat_join_channel',
        'channel_id': widget.channelId,
      });
      realtime.addListener(_onRealtime);
    });
  }

  @override
  void dispose() {
    ref.read(realtimeServiceProvider)
      ..send({'type': 'chat_leave_channel', 'channel_id': widget.channelId})
      ..removeListener(_onRealtime);
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onRealtime(Map<String, dynamic> event) {
    final type = event['type'];
    final payload = event['payload'];
    if (type != 'chat_message_created' || payload is! Map<String, dynamic>) {
      return;
    }
    final message = V2ChatMessage.fromJson(payload);
    if (message.channelId != widget.channelId) return;
    if (!mounted) return;
    setState(() => _messages.add(message));
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await ref
          .read(chatApiProvider)
          .listMessages(channelId: widget.channelId);
      if (!mounted) return;
      setState(() {
        _messages = page.items.reversed.toList();
        _loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      await ref
          .read(chatApiProvider)
          .setChannelReadStatus(
            channelId: widget.channelId,
            lastReadMessageId: _messages.isEmpty
                ? null
                : _messages.last.messageId,
          );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final message = await ref
          .read(chatApiProvider)
          .sendChannelMessage(channelId: widget.channelId, content: text);
      if (!mounted) return;
      setState(() {
        _messages.add(message);
        _composer.clear();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _react(V2ChatMessage message) async {
    try {
      await ref
          .read(chatApiProvider)
          .reactMessage(messageId: message.messageId, emoji: '👍');
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _pin(V2ChatMessage message) async {
    try {
      final api = ref.read(chatApiProvider);
      if (message.isPinned) {
        await api.unpinMessage(message.messageId);
      } else {
        await api.pinMessage(message.messageId);
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  String _time(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return DateFormat.Hm().format(dt.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('#${widget.channelId}')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppBreakpoints.contentMaxWidth,
          ),
          child: Column(
            children: [
              Expanded(
                child: _loading
                    ? const LoadingView()
                    : _error != null
                    ? ErrorView(error: _error!, onRetry: _load)
                    : _messages.isEmpty
                    ? EmptyView(message: l10n.t('chat.empty_messages'))
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                        itemCount: _messages.length,
                        itemBuilder: (_, i) => _ChannelMessageTile(
                          message: _messages[i],
                          timeLabel: _time(_messages[i].createdAt),
                          onReact: () => _react(_messages[i]),
                          onPin: _messages[i].canPin
                              ? () => _pin(_messages[i])
                              : null,
                        ),
                      ),
              ),
              Container(
                decoration: BoxDecoration(
                  color: theme.scaffoldBackgroundColor,
                  border: Border(top: BorderSide(color: theme.dividerColor)),
                ),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _composer,
                            minLines: 1,
                            maxLines: 5,
                            decoration: InputDecoration(
                              hintText: l10n.t('chat.message_hint'),
                              isDense: true,
                            ),
                            onSubmitted: (_) => _send(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: _sending ? null : _send,
                          icon: _sending
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  Icons.send_rounded,
                                  color: theme.colorScheme.primary,
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChannelMessageTile extends StatelessWidget {
  const _ChannelMessageTile({
    required this.message,
    required this.timeLabel,
    required this.onReact,
    this.onPin,
  });

  final V2ChatMessage message;
  final String timeLabel;
  final VoidCallback onReact;
  final VoidCallback? onPin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppAvatar(url: message.author.avatarUrl, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        message.author.displayName.isEmpty
                            ? message.author.username
                            : message.author.displayName,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      timeLabel,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (message.isPinned) ...[
                      const SizedBox(width: 6),
                      Icon(
                        Icons.push_pin,
                        size: 14,
                        color: theme.colorScheme.primary,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  message.isDeleted ? '(deleted)' : message.content,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontStyle: message.isDeleted ? FontStyle.italic : null,
                    color: message.isDeleted
                        ? theme.colorScheme.onSurfaceVariant
                        : null,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            tooltip: '👍',
            icon: const Icon(Icons.thumb_up_alt_outlined),
            onPressed: onReact,
          ),
          if (onPin != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              icon: Icon(
                message.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
              ),
              onPressed: onPin,
            ),
        ],
      ),
    );
  }
}
