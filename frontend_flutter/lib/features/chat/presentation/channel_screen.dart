import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mime/mime.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../../posts/domain/post_models.dart';
import '../../realtime/data/realtime_service.dart';
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
  late final RealtimeService _realtime;
  List<V2ChatMessage> _messages = [];
  final List<PlatformFile> _attachments = [];
  V2ChatMessage? _replyTo;
  bool _loading = true;
  bool _sending = false;
  bool _pickingAttachment = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _realtime = ref.read(realtimeServiceProvider);
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _realtime.connect();
      _realtime.send({
        'type': 'chat_join_channel',
        'channel_id': widget.channelId,
      });
      _realtime.addListener(_onRealtime);
    });
  }

  @override
  void dispose() {
    _realtime
      ..send({'type': 'chat_leave_channel', 'channel_id': widget.channelId})
      ..removeListener(_onRealtime);
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onRealtime(Map<String, dynamic> event) {
    final type = event['type'];
    final data = _eventData(event);
    if (data == null) return;

    if (type == 'chat_message_deleted') {
      _removeDeletedMessage(data);
      return;
    }

    if (type != 'chat_message' &&
        type != 'chat_message_created' &&
        type != 'chat_message_updated' &&
        type != 'chat_reaction_updated') {
      return;
    }

    final rawMessage = _messageData(data);
    if (rawMessage == null) return;
    final message = V2ChatMessage.fromJson(rawMessage);
    if (message.channelId != widget.channelId) return;
    if (!mounted) return;
    setState(() => _upsertMessage(message));
    if (type == 'chat_message' || type == 'chat_message_created') {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  Map<String, dynamic>? _eventData(Map<String, dynamic> event) {
    final data = _asMap(event['data']);
    if (data != null) return data;
    return _asMap(event['payload']);
  }

  Map<String, dynamic>? _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, value) => MapEntry(key.toString(), value));
    }
    return null;
  }

  Map<String, dynamic>? _messageData(Map<String, dynamic> data) {
    final nested = _asMap(data['message']);
    if (nested != null) return nested;
    if (data.containsKey('message_id')) return data;
    return null;
  }

  int? _eventInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  void _removeDeletedMessage(Map<String, dynamic> data) {
    final eventChannelId = _eventInt(data['channel_id']);
    if (eventChannelId != null && eventChannelId != widget.channelId) return;
    final messageId = _eventInt(data['message_id']);
    if (messageId == null) return;
    if (!mounted) return;
    setState(() {
      _messages.removeWhere((message) => message.messageId == messageId);
      if (_replyTo?.messageId == messageId) {
        _replyTo = null;
      }
    });
  }

  void _upsertMessage(V2ChatMessage message) {
    final index = _messages.indexWhere((m) => m.messageId == message.messageId);
    if (index >= 0) {
      _messages[index] = message;
    } else {
      _messages.add(message);
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
    if ((text.isEmpty && _attachments.isEmpty) || _sending) return;
    setState(() => _sending = true);
    try {
      final mediaIds = await _uploadAttachments();
      final message = await ref
          .read(chatApiProvider)
          .sendChannelMessage(
            channelId: widget.channelId,
            content: text,
            replyToMessageId: _replyTo?.messageId,
            mediaIds: mediaIds,
          );
      if (!mounted) return;
      setState(() {
        _upsertMessage(message);
        _composer.clear();
        _attachments.clear();
        _replyTo = null;
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

  Future<void> _pickAttachment({
    FileType type = FileType.any,
    List<String>? allowedExtensions,
  }) async {
    if (_pickingAttachment || _sending) return;
    setState(() => _pickingAttachment = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: type,
        allowedExtensions: allowedExtensions,
        allowMultiple: true,
        withData: true,
      );
      if (!mounted || result == null) return;
      setState(() => _attachments.addAll(result.files));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      if (mounted) setState(() => _pickingAttachment = false);
    }
  }

  void _insertComposerText(String text) {
    final selection = _composer.selection;
    final current = _composer.text;
    final start = selection.isValid ? selection.start : current.length;
    final end = selection.isValid ? selection.end : current.length;
    final updated = current.replaceRange(start, end, text);
    final offset = start + text.length;
    _composer.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: offset),
    );
  }

  Future<List<int>> _uploadAttachments() async {
    if (_attachments.isEmpty) return const [];
    final api = ref.read(mediaApiProvider);
    final mediaIds = <int>[];
    for (final attachment in _attachments) {
      V2MediaAsset asset;
      final mime = lookupMimeType(
        attachment.name,
        headerBytes: attachment.bytes?.take(16).toList(),
      );
      final mediaType = _chatMediaType(mime);
      if (attachment.bytes != null) {
        asset = await api.uploadBytes(
          bytes: attachment.bytes!,
          fileName: attachment.name,
          mediaType: mediaType,
          mimeType: mime,
          altText: attachment.name,
        );
      } else if (attachment.path != null) {
        asset = await api.uploadFile(
          file: File(attachment.path!),
          mediaType: mediaType,
          altText: attachment.name,
        );
      } else {
        throw Exception('attachment file is empty');
      }
      mediaIds.add(asset.mediaId);
    }
    return mediaIds;
  }

  String _chatMediaType(String? mimeType) {
    if (mimeType == null) return 'file';
    if (mimeType.startsWith('image/')) return 'image';
    if (mimeType.startsWith('video/')) return 'video';
    if (mimeType.startsWith('audio/')) return 'audio';
    return 'file';
  }

  Future<void> _react(V2ChatMessage message, [String emoji = '👍']) async {
    try {
      final reacted = message.reactions.any(
        (reaction) => reaction.emoji == emoji && reaction.reactedByMe,
      );
      final api = ref.read(chatApiProvider);
      if (reacted) {
        await api.unreactMessage(messageId: message.messageId, emoji: emoji);
      } else {
        await api.reactMessage(messageId: message.messageId, emoji: emoji);
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  void _startReply(V2ChatMessage message) {
    setState(() => _replyTo = message);
  }

  Future<void> _editMessage(V2ChatMessage message) async {
    final l10n = AppLocalizations.of(context);
    try {
      final content = await showDialog<String>(
        context: context,
        builder: (context) =>
            _EditMessageDialog(initialContent: message.content),
      );
      final trimmed = content?.trim();
      if (trimmed == null || trimmed.isEmpty || trimmed == message.content) {
        return;
      }
      final updated = await ref
          .read(chatApiProvider)
          .editMessage(messageId: message.messageId, content: trimmed);
      if (!mounted) return;
      setState(() => _upsertMessage(updated));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.t('chat.message_updated'))));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _deleteMessage(V2ChatMessage message) async {
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
            key: const Key('chat-channel-delete-confirm-button'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.t('common.delete')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(chatApiProvider).deleteMessage(message.messageId);
      if (!mounted) return;
      setState(() {
        _messages.removeWhere((m) => m.messageId == message.messageId);
        if (_replyTo?.messageId == message.messageId) {
          _replyTo = null;
        }
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.t('chat.message_deleted'))));
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
                          onReply: () => _startReply(_messages[i]),
                          onReact: () => _react(_messages[i]),
                          onReactionSelected: (emoji) =>
                              _react(_messages[i], emoji),
                          onPin: _messages[i].canPin
                              ? () => _pin(_messages[i])
                              : null,
                          onEdit: _messages[i].canDelete
                              ? () => _editMessage(_messages[i])
                              : null,
                          onDelete: _messages[i].canDelete
                              ? () => _deleteMessage(_messages[i])
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
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_replyTo != null) ...[
                          _ReplyPreview(
                            key: const Key('chat-channel-reply-preview'),
                            message: _replyTo!,
                            onCancel: _sending
                                ? null
                                : () => setState(() => _replyTo = null),
                          ),
                          const SizedBox(height: 8),
                        ],
                        if (_attachments.isNotEmpty) ...[
                          SizedBox(
                            height: 52,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: _attachments.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(width: 8),
                              itemBuilder: (_, i) => _AttachmentChip(
                                file: _attachments[i],
                                onRemove: _sending
                                    ? null
                                    : () => setState(
                                        () => _attachments.removeAt(i),
                                      ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            IconButton(
                              key: const Key('chat-channel-attach-button'),
                              tooltip: l10n.t('chat.upload_attachment'),
                              onPressed: _pickingAttachment || _sending
                                  ? null
                                  : _pickAttachment,
                              icon: _pickingAttachment
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.attach_file),
                            ),
                            IconButton(
                              key: const Key('chat-channel-image-button'),
                              tooltip: l10n.t('compose.media'),
                              onPressed: _pickingAttachment || _sending
                                  ? null
                                  : () => _pickAttachment(type: FileType.image),
                              icon: const Icon(Icons.image_outlined),
                            ),
                            PopupMenuButton<String>(
                              key: const Key('chat-channel-emoji-button'),
                              tooltip: 'Emoji',
                              onSelected: _insertComposerText,
                              itemBuilder: (_) => const [
                                PopupMenuItem(value: '😀', child: Text('😀')),
                                PopupMenuItem(value: '😂', child: Text('😂')),
                                PopupMenuItem(value: '❤️', child: Text('❤️')),
                                PopupMenuItem(value: '👍', child: Text('👍')),
                                PopupMenuItem(value: '✨', child: Text('✨')),
                              ],
                              icon: const Icon(Icons.emoji_emotions_outlined),
                            ),
                            IconButton(
                              key: const Key('chat-channel-mention-button'),
                              tooltip: '@',
                              onPressed: _sending
                                  ? null
                                  : () => _insertComposerText('@'),
                              icon: const Icon(Icons.alternate_email),
                            ),
                            IconButton(
                              key: const Key('chat-channel-channel-button'),
                              tooltip: '#',
                              onPressed: _sending
                                  ? null
                                  : () => _insertComposerText('#'),
                              icon: const Icon(Icons.tag),
                            ),
                            IconButton(
                              key: const Key('chat-channel-sticker-button'),
                              tooltip: 'Sticker',
                              onPressed: _sending
                                  ? null
                                  : () => _insertComposerText('🎁 '),
                              icon: const Icon(Icons.card_giftcard_outlined),
                            ),
                            Expanded(
                              child: TextField(
                                key: const Key('chat-channel-composer-field'),
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
                              key: const Key('chat-channel-send-button'),
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

class _EditMessageDialog extends StatefulWidget {
  const _EditMessageDialog({required this.initialContent});

  final String initialContent;

  @override
  State<_EditMessageDialog> createState() => _EditMessageDialogState();
}

class _EditMessageDialogState extends State<_EditMessageDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialContent);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.t('chat.edit_message')),
      content: TextField(
        key: const Key('chat-channel-edit-content-field'),
        controller: _controller,
        autofocus: true,
        minLines: 1,
        maxLines: 5,
        decoration: InputDecoration(hintText: l10n.t('chat.message_hint')),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.t('common.cancel')),
        ),
        FilledButton(
          key: const Key('chat-channel-edit-save-button'),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(l10n.t('common.save')),
        ),
      ],
    );
  }
}

class _ReplyPreview extends StatelessWidget {
  const _ReplyPreview({super.key, required this.message, this.onCancel});

  final V2ChatMessage message;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final author = message.author.displayName.isEmpty
        ? message.author.username
        : message.author.displayName;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.55,
        ),
        border: Border(
          left: BorderSide(color: theme.colorScheme.primary, width: 3),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.reply_rounded, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '${l10n.t('chat.replying_to')} '),
                  TextSpan(
                    text: author,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const TextSpan(text: ': '),
                  TextSpan(text: message.content),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          IconButton(
            key: const Key('chat-channel-cancel-reply-button'),
            visualDensity: VisualDensity.compact,
            tooltip: l10n.t('chat.cancel_reply'),
            onPressed: onCancel,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({required this.file, this.onRemove});

  final PlatformFile file;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(12),
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.55,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_drive_file_outlined, size: 18),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              file.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          const SizedBox(width: 4),
          InkWell(
            onTap: onRemove,
            customBorder: const CircleBorder(),
            child: const Padding(
              padding: EdgeInsets.all(2),
              child: Icon(Icons.close, size: 16),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChannelMessageTile extends StatelessWidget {
  const _ChannelMessageTile({
    required this.message,
    required this.timeLabel,
    required this.onReply,
    required this.onReact,
    required this.onReactionSelected,
    this.onPin,
    this.onEdit,
    this.onDelete,
  });

  final V2ChatMessage message;
  final String timeLabel;
  final VoidCallback onReply;
  final VoidCallback onReact;
  final ValueChanged<String> onReactionSelected;
  final VoidCallback? onPin;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
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
                if (message.replyTo != null) ...[
                  _MessageReplyQuote(replyTo: message.replyTo!),
                  const SizedBox(height: 6),
                ],
                if (message.isDeleted || message.content.isNotEmpty)
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: message.isDeleted
                              ? l10n.t('chat.deleted_message')
                              : message.content,
                        ),
                        if (!message.isDeleted && message.editedAt != null)
                          TextSpan(
                            text: ' (${l10n.t('chat.edited')})',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontStyle: message.isDeleted ? FontStyle.italic : null,
                      color: message.isDeleted
                          ? theme.colorScheme.onSurfaceVariant
                          : null,
                    ),
                  ),
                if (message.media.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final media in message.media)
                        _MessageAttachment(media: media),
                    ],
                  ),
                ],
                if (message.reactions.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final reaction in message.reactions)
                        _ReactionChip(
                          key: Key(
                            'chat-channel-reaction-${message.messageId}-${reaction.emoji}',
                          ),
                          reaction: reaction,
                          onPressed: () => onReactionSelected(reaction.emoji),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            key: Key('chat-channel-reply-${message.messageId}'),
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            tooltip: l10n.t('chat.reply'),
            icon: const Icon(Icons.reply_rounded),
            onPressed: onReply,
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
          if (onEdit != null || onDelete != null)
            PopupMenuButton<_ChannelMessageAction>(
              key: Key('chat-channel-more-${message.messageId}'),
              tooltip: l10n.t('common.more'),
              icon: const Icon(Icons.more_horiz),
              onSelected: (action) {
                switch (action) {
                  case _ChannelMessageAction.edit:
                    onEdit?.call();
                    break;
                  case _ChannelMessageAction.delete:
                    onDelete?.call();
                    break;
                }
              },
              itemBuilder: (context) => [
                if (onEdit != null)
                  PopupMenuItem(
                    key: Key('chat-channel-edit-${message.messageId}'),
                    value: _ChannelMessageAction.edit,
                    child: ListTile(
                      dense: true,
                      leading: const Icon(Icons.edit_outlined),
                      title: Text(l10n.t('common.edit')),
                    ),
                  ),
                if (onDelete != null)
                  PopupMenuItem(
                    key: Key('chat-channel-delete-${message.messageId}'),
                    value: _ChannelMessageAction.delete,
                    child: ListTile(
                      dense: true,
                      leading: const Icon(Icons.delete_outline),
                      title: Text(l10n.t('common.delete')),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

enum _ChannelMessageAction { edit, delete }

class _MessageReplyQuote extends StatelessWidget {
  const _MessageReplyQuote({required this.replyTo});

  final V2ChatMessageReply replyTo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.55,
        ),
        border: Border(
          left: BorderSide(color: theme.colorScheme.primary, width: 3),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.reply_rounded, size: 16),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '${replyTo.authorName}: ${replyTo.content}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReactionChip extends StatelessWidget {
  const _ReactionChip({super.key, required this.reaction, this.onPressed});

  final V2ChatReactionSummary reaction;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ActionChip(
      visualDensity: VisualDensity.compact,
      side: BorderSide(
        color: reaction.reactedByMe
            ? theme.colorScheme.primary.withValues(alpha: 0.45)
            : theme.dividerColor,
      ),
      backgroundColor: reaction.reactedByMe
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.55)
          : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(reaction.emoji),
          const SizedBox(width: 4),
          Text('${reaction.count}'),
        ],
      ),
      onPressed: onPressed,
    );
  }
}

class _MessageAttachment extends StatelessWidget {
  const _MessageAttachment({required this.media});

  final V2MediaAsset media;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isImage =
        media.mediaType == 'image' || media.mimeType.startsWith('image/');
    if (isImage) {
      return AppMediaImage(
        url: media.publicUrl,
        width: 140,
        height: 104,
        borderRadius: BorderRadius.circular(12),
      );
    }
    return Container(
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_drive_file_outlined, size: 18),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              media.fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
