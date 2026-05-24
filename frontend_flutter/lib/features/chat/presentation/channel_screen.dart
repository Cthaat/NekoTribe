import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/app_avatar.dart';
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
    return Scaffold(
      appBar: AppBar(title: Text('Channel #${widget.channelId}')),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const LoadingView()
                : _error != null
                ? ErrorView(error: _error!, onRetry: _load)
                : _messages.isEmpty
                ? const EmptyView(message: 'No messages yet')
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: _messages.length,
                    itemBuilder: (_, i) {
                      final m = _messages[i];
                      return Card(
                        child: ListTile(
                          leading: AppAvatar(url: m.author.avatarUrl, size: 36),
                          title: Text(m.author.displayName),
                          subtitle: Text(m.isDeleted ? '(deleted)' : m.content),
                          trailing: Wrap(
                            spacing: 2,
                            children: [
                              Text(_time(m.createdAt)),
                              IconButton(
                                icon: const Icon(Icons.thumb_up_alt_outlined),
                                onPressed: () => _react(m),
                              ),
                              if (m.canPin)
                                IconButton(
                                  icon: Icon(
                                    m.isPinned
                                        ? Icons.push_pin
                                        : Icons.push_pin_outlined,
                                  ),
                                  onPressed: () => _pin(m),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _composer,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: 'Message',
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
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
