import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../../realtime/data/realtime_service.dart';
import '../domain/chat_models.dart';

class ConversationScreen extends ConsumerStatefulWidget {
  const ConversationScreen({
    super.key,
    required this.conversationId,
    this.title,
  });
  final int conversationId;
  final String? title;

  @override
  ConsumerState<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends ConsumerState<ConversationScreen> {
  final _scrollController = ScrollController();
  final _composer = TextEditingController();
  late final RealtimeService _realtime;
  List<V2DirectMessage> _messages = [];
  bool _loading = true;
  bool _loadingOlder = false;
  bool _hasNext = false;
  bool _sending = false;
  int _page = 1;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _realtime = ref.read(realtimeServiceProvider);
    _scrollController.addListener(_onScroll);
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _realtime.connect();
      _realtime.addListener(_onRealtime);
    });
  }

  @override
  void dispose() {
    _realtime.removeListener(_onRealtime);
    _scrollController.removeListener(_onScroll);
    _composer.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients || _loadingOlder || !_hasNext) return;
    // reverse:true — older messages load near maxScrollExtent.
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 80) {
      _loadOlder();
    }
  }

  Map<String, dynamic>? _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, value) => MapEntry(key.toString(), value));
    }
    return null;
  }

  Map<String, dynamic>? _eventData(Map<String, dynamic> event) {
    final data = _asMap(event['data']);
    if (data != null) return data;
    return _asMap(event['payload']);
  }

  int? _eventInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  Map<String, dynamic>? _messageData(Map<String, dynamic> data) {
    final nested =
        _asMap(data['direct_message']) ??
        _asMap(data['message']) ??
        _asMap(data['dm']);
    if (nested != null) return nested;
    if (data.containsKey('message_id') && data.containsKey('conversation_id')) {
      return data;
    }
    return null;
  }

  void _onRealtime(Map<String, dynamic> event) {
    final type = event['type'];
    final data = _eventData(event);
    if (data == null) return;

    if (type == 'direct_message_deleted' || type == 'chat_dm_message_deleted') {
      final conversationId = _eventInt(data['conversation_id']);
      if (conversationId != null && conversationId != widget.conversationId) {
        return;
      }
      final messageId = _eventInt(data['message_id']);
      if (messageId == null) return;
      if (!mounted) return;
      setState(() {
        _messages.removeWhere((m) => m.messageId == messageId);
      });
      return;
    }

    final looksLikeDm =
        type == 'direct_message' ||
        type == 'direct_message_created' ||
        type == 'chat_dm_message' ||
        type == 'chat_dm_message_created' ||
        (type is String && type.contains('direct'));

    final rawMessage = _messageData(data);
    if (rawMessage == null) {
      // Generic fallback: conversation_id + message fields anywhere in data.
      if (!looksLikeDm) return;
      return;
    }

    final conversationId =
        _eventInt(rawMessage['conversation_id']) ??
        _eventInt(data['conversation_id']);
    if (conversationId != null && conversationId != widget.conversationId) {
      return;
    }
    // If no conversation_id on payload, still require a DM-shaped type.
    if (conversationId == null && !looksLikeDm) return;

    try {
      final message = V2DirectMessage.fromJson(rawMessage);
      if (message.conversationId != 0 &&
          message.conversationId != widget.conversationId) {
        return;
      }
      if (!mounted) return;
      setState(() => _upsertMessage(message));
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } catch (_) {
      // Ignore malformed realtime payloads.
    }
  }

  void _upsertMessage(V2DirectMessage message) {
    final index = _messages.indexWhere((m) => m.messageId == message.messageId);
    if (index >= 0) {
      _messages[index] = message;
    } else {
      // reverse:true list expects newest-first.
      _messages.insert(0, message);
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await ref
          .read(chatApiProvider)
          .listDirectMessages(conversationId: widget.conversationId, page: 1);
      if (!mounted) return;
      // Server returns ASC (oldest→newest within page). Store newest-first.
      setState(() {
        _messages = page.items.reversed.toList();
        _page = 1;
        _hasNext = page.hasNext;
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

  Future<void> _loadOlder() async {
    if (_loadingOlder || !_hasNext || _messages.isEmpty) return;
    setState(() => _loadingOlder = true);
    final nextPage = _page + 1;
    try {
      // Page-based history only — server has no reliable `before` cursor.
      final page = await ref
          .read(chatApiProvider)
          .listDirectMessages(
            conversationId: widget.conversationId,
            page: nextPage,
          );
      if (!mounted) return;
      final existing = _messages.map((m) => m.messageId).toSet();
      final older = page.items.reversed
          .where((m) => !existing.contains(m.messageId))
          .toList();
      setState(() {
        _messages = [..._messages, ...older];
        _page = nextPage;
        _hasNext = page.hasNext;
        _loadingOlder = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingOlder = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
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
          .sendDirectMessage(
            conversationId: widget.conversationId,
            content: text,
          );
      if (!mounted) return;
      setState(() {
        _upsertMessage(message);
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

  Future<void> _deleteMessage(V2DirectMessage m) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.t('chat.delete_message')),
        content: Text(l10n.t('chat.delete_message_body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.t('common.cancel')),
          ),
          FilledButton(
            key: const Key('dm-delete-confirm-button'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.t('common.delete')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(chatApiProvider).deleteMessage(m.messageId);
      if (!mounted) return;
      setState(() => _messages.removeWhere((x) => x.messageId == m.messageId));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  String _formatTime(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return DateFormat.Hm().format(dt.toLocal());
  }

  String get _appBarTitle {
    final title = widget.title?.trim();
    if (title != null && title.isNotEmpty) return title;
    return AppLocalizations.of(context).t('chat.conversation');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(_appBarTitle)),
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
                    ? EmptyView(message: l10n.t('chat.dm.empty'))
                    : ListView.builder(
                        controller: _scrollController,
                        reverse: true,
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                        itemCount: _messages.length + (_loadingOlder ? 1 : 0),
                        itemBuilder: (_, i) {
                          if (_loadingOlder && i == _messages.length) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 12),
                              child: Center(
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              ),
                            );
                          }
                          final message = _messages[i];
                          return _MessageBubble(
                            message: message,
                            onDelete: message.canDelete
                                ? () => _deleteMessage(message)
                                : null,
                            formatTime: _formatTime,
                          );
                        },
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
                            key: const Key('dm-composer-field'),
                            controller: _composer,
                            maxLines: 5,
                            minLines: 1,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _send(),
                            decoration: InputDecoration(
                              hintText: l10n.t('chat.message_hint'),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          key: const Key('dm-send-button'),
                          icon: _sending
                              ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  Icons.send_rounded,
                                  color: theme.colorScheme.primary,
                                ),
                          onPressed: _sending ? null : _send,
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

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.formatTime,
    this.onDelete,
  });

  final V2DirectMessage message;
  final String Function(String) formatTime;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSelf = message.canDelete;
    final bubbleColor = isSelf
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceContainerHighest;
    final textColor = isSelf
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;
    final secondaryColor = isSelf
        ? theme.colorScheme.onPrimary.withValues(alpha: 0.75)
        : theme.colorScheme.onSurfaceVariant;
    return Align(
      alignment: isSelf ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!isSelf) ...[
                AppAvatar(url: message.author.avatarUrl, size: 32),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: GestureDetector(
                  onLongPress: onDelete,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 11,
                    ),
                    decoration: BoxDecoration(
                      color: bubbleColor,
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(18),
                        topRight: const Radius.circular(18),
                        bottomLeft: Radius.circular(isSelf ? 18 : 5),
                        bottomRight: Radius.circular(isSelf ? 5 : 18),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!isSelf && message.author.displayName.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 3),
                            child: Text(
                              message.author.displayName,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        Text(
                          message.isDeleted
                              ? AppLocalizations.of(
                                  context,
                                ).t('chat.deleted_message')
                              : message.content.isEmpty
                              ? '…'
                              : message.content,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: textColor,
                            fontStyle: message.isDeleted || message.content.isEmpty
                                ? FontStyle.italic
                                : null,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          formatTime(message.createdAt),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: secondaryColor,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (isSelf) const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}
