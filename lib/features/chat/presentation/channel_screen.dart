import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/theme/tokens.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/media_lightbox.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/glass/liquid_glass_bars.dart';
import '../../../shared/widgets/glass/liquid_glass_surface.dart';
import '../../../shared/widgets/glass/liquid_glass_tokens.dart';
import '../../../shared/widgets/safe_back_button.dart';
import '../../../shared/widgets/status_views.dart';
import '../../calls/data/call_signaling.dart';
import '../../calls/presentation/call_widgets.dart';
import '../../links/presentation/content_link_preview.dart';
import '../../media/presentation/private_attachment_button.dart';
import '../../posts/domain/post_models.dart';
import '../../realtime/data/realtime_service.dart'
    show realtimeUserIdFromAccessToken;
import '../data/chat_attachment_upload.dart';
import '../domain/chat_models.dart';
import 'chat_realtime_binding.dart';
import 'chat_message_extras.dart';
import 'chat_message_search.dart';
import 'chat_typing.dart';

class ChannelScreen extends ConsumerStatefulWidget {
  const ChannelScreen({
    super.key,
    required this.groupId,
    required this.channelId,
    this.channelName,
    this.embedded = false,
  });

  final int groupId;
  final int channelId;
  final String? channelName;
  final bool embedded;

  @override
  ConsumerState<ChannelScreen> createState() => _ChannelScreenState();
}

class _ChannelScreenState extends ConsumerState<ChannelScreen> {
  static const _maxAttachments = 32;

  final _composer = TextEditingController();
  double _composerHeight = 84;
  bool _searchOpen = false;
  Future<List<V2ChatMember>>? _members;
  var _filters = const ChatMessageFilters();
  final _deletedSearchResults = <int>{};
  final _scroll = ScrollController();
  late final ChatRealtimeBinding _binding;
  late final ChatTyping _typing;
  late final AppLifecycleListener _lifecycle;
  int _readRevision = 0;
  Timer? _readTimer;
  int _pendingRead = 0;
  bool _syncingRead = false;
  bool _loadingMessageActions = false;
  bool? _canManageChannel;
  int? _currentUserId;
  int _callSelection = 0;
  final _pendingMessageActions = <int>{};
  final _pendingReactions = <int>{};
  List<V2ChatMessage> _messages = [];
  Map<int, V2ChatMessage?>? _liveChannelChanges;
  final List<PlatformFile> _attachments = [];
  final Map<PlatformFile, int> _uploadedAttachments = Map.identity();
  CancelToken? _attachmentUpload;
  V2ChatMessage? _replyTo;
  bool _loading = true;
  bool _loadingOlder = false;
  bool _hasNext = false;
  bool _sending = false;
  bool _pickingAttachment = false;
  int _page = 1;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _binding = ChatRealtimeBinding(
      tokenStore: ref.read(tokenStoreProvider),
      channelId: widget.channelId,
      onEvent: _onRealtime,
      onReset: _reset,
      onReload: () => unawaited(_load()),
    );
    _typing = ChatTyping(
      scope: ChatTypingScope.channel,
      scopeId: () => widget.channelId,
      ownId: () => _currentUserId,
      send: _binding.sendTyping,
      onChange: () {
        if (mounted) setState(() {});
      },
    );
    _binding.bind(ref.read(realtimeServiceProvider));
    _lifecycle = AppLifecycleListener(
      onStateChange: (_) => _typing.setVisible(_visibleChannel),
      onResume: () {
        _scheduleRead();
        if (mounted &&
            _page == 1 &&
            ModalRoute.of(context)?.isCurrent == true) {
          unawaited(_load());
        }
      },
    );
    ref.listenManual(realtimeServiceProvider, (_, next) => _binding.bind(next));
    _scroll.addListener(_onScroll);
    unawaited(_load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _typing.setVisible(_visibleChannel);
  }

  @override
  void didUpdateWidget(covariant ChannelScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channelId != widget.channelId ||
        oldWidget.groupId != widget.groupId) {
      _binding.changeRoute(nextChannelId: widget.channelId);
    }
  }

  void _reset() {
    _clearPendingRead();
    _typing.reset(notify: false);
    _attachmentUpload?.cancel();
    _attachmentUpload = null;
    _readRevision++;
    _liveChannelChanges = null;
    _loadingMessageActions = false;
    _canManageChannel = null;
    _currentUserId = null;
    _pendingMessageActions.clear();
    _pendingReactions.clear();
    setState(() {
      _members = null;
      _messages = [];
      _composer.clear();
      _searchOpen = false;
      _filters = const ChatMessageFilters();
      _deletedSearchResults.clear();
      _attachments.clear();
      _uploadedAttachments.clear();
      _replyTo = null;
      _page = 1;
      _error = null;
      _loading = true;
      _hasNext = _loadingOlder = _sending = _pickingAttachment = false;
    });
    _typing.setVisible(_visibleChannel);
  }

  @override
  void dispose() {
    _clearPendingRead();
    _typing.stop();
    _typing.reset(notify: false);
    _attachmentUpload?.cancel();
    _lifecycle.dispose();
    _scroll.removeListener(_onScroll);
    _binding.dispose();
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loadingOlder || !_hasNext) return;
    // reverse:true — older messages load near maxScrollExtent.
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 80) {
      _loadOlder();
    }
  }

  void _onRealtime(Map<String, dynamic> event) {
    if (!mounted || _typing.receive(event)) return;
    final type = event['type'];
    final data = _eventData(event);
    if (data == null) return;

    if (type == 'chat_message_deleted') {
      _removeDeletedMessage(data);
      return;
    }
    if (_filters.active) return;

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
    final existing = _messages
        .where((item) => item.messageId == message.messageId)
        .firstOrNull;
    if (type == 'chat_reaction_updated') {
      if (existing == null) return;
      final selected = existing.reactions
          .where((reaction) => reaction.reactedByMe)
          .map((reaction) => reaction.emoji)
          .toSet();
      final reactions = data['viewer_neutral'] == true
          ? message.reactions
                .map(
                  (reaction) => V2ChatReactionSummary(
                    emoji: reaction.emoji,
                    count: reaction.count,
                    reactedByMe: selected.contains(reaction.emoji),
                  ),
                )
                .toList()
          : message.reactions;
      setState(
        () => _upsertMessage(_copyMessage(existing, reactions: reactions)),
      );
      return;
    }
    if (data['viewer_neutral'] == true) {
      final canManage = _canManageChannel;
      final reacted = existing?.reactions
          .where((reaction) => reaction.reactedByMe)
          .map((reaction) => reaction.emoji)
          .toSet();
      setState(
        () => _upsertMessage(
          _copyMessage(
            message,
            reactions: message.reactions
                .map(
                  (reaction) => V2ChatReactionSummary(
                    emoji: reaction.emoji,
                    count: reaction.count,
                    reactedByMe: reacted?.contains(reaction.emoji) ?? false,
                  ),
                )
                .toList(),
            canDelete: canManage == null
                ? existing?.canDelete
                : canManage || _currentUserId == message.author.userId,
            canPin: canManage ?? existing?.canPin,
          ),
        ),
      );
      if (existing == null && canManage == null) {
        _pendingMessageActions.add(message.messageId);
        if (!_loadingMessageActions) unawaited(_resolveMessageActions());
      }
    } else {
      setState(() => _upsertMessage(message));
    }
    if (type == 'chat_message' || type == 'chat_message_created') {
      if (existing == null &&
          message.author.userId != _currentUserId &&
          message.messageId > _pendingRead) {
        _pendingRead = message.messageId;
        _scheduleRead();
      }
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
      if (_filters.active) _deletedSearchResults.add(messageId);
      _liveChannelChanges?[messageId] = null;
      _messages.removeWhere((message) => message.messageId == messageId);
      if (_replyTo?.messageId == messageId) {
        _replyTo = null;
      }
    });
  }

  void _upsertMessage(V2ChatMessage message) {
    if (_filters.active) return;
    if (_liveChannelChanges?.containsKey(message.messageId) == true &&
        _liveChannelChanges?[message.messageId] == null) {
      return;
    }
    _liveChannelChanges?[message.messageId] = message;
    final index = _messages.indexWhere((m) => m.messageId == message.messageId);
    if (index >= 0) {
      _messages[index] = message;
    } else {
      // reverse:true list expects newest-first.
      _messages.insert(0, message);
    }
  }

  Future<bool> _readMessageOwner(bool Function() current) async {
    try {
      final pair = await ref.read(tokenStoreProvider).read();
      if (!current() || pair == null) return false;
      final id = realtimeUserIdFromAccessToken(pair.accessToken);
      if (_currentUserId != id) setState(() => _currentUserId = id);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _resolveMessageActions() async {
    final current = _binding.capture();
    _loadingMessageActions = true;
    try {
      if (!await _readMessageOwner(current) || !current()) return;
      final channels = await ref
          .read(chatApiProvider)
          .listChannels(widget.groupId);
      if (!mounted || !current()) return;
      final canManage = channels.any(
        (channel) => channel.channelId == widget.channelId && channel.canManage,
      );
      _canManageChannel = canManage;
      setState(() {
        for (var index = 0; index < _messages.length; index++) {
          final message = _messages[index];
          if (_pendingMessageActions.contains(message.messageId)) {
            _messages[index] = _copyMessage(
              message,
              canDelete: canManage || _currentUserId == message.author.userId,
              canPin: canManage,
            );
          }
        }
        _pendingMessageActions.clear();
      });
    } catch (_) {
      // Keep the server-provided permissions until history can be reloaded.
    } finally {
      if (current()) _loadingMessageActions = false;
    }
  }

  Future<void> _load() async {
    final ownsPage = _binding.capture();
    if (!ownsPage()) return;
    if (_currentUserId == null) unawaited(_readMessageOwner(ownsPage));
    final revision = ++_readRevision;
    bool current() => ownsPage() && revision == _readRevision;
    final api = ref.read(chatApiProvider);
    final channelId = widget.channelId;
    final filters = _filters;
    final changes = <int, V2ChatMessage?>{};
    _liveChannelChanges = changes;
    setState(() {
      _loading = true;
      _loadingOlder = false;
      _error = null;
    });
    try {
      final page = await api.listMessages(
        channelId: channelId,
        page: 1,
        search: filters.query,
        senderId: filters.senderId,
        startAt: filters.startAt,
        endAt: filters.endAt,
      );
      if (!current()) return;
      // Server returns ASC (oldest→newest within page). Store newest-first.
      setState(() {
        _liveChannelChanges = null;
        _pendingMessageActions.clear();
        _canManageChannel = null;
        _messages = page.items.reversed
            .where(
              (message) => !_deletedSearchResults.contains(message.messageId),
            )
            .toList();
        for (final entry in changes.entries) {
          final message = entry.value;
          if (message == null) {
            _messages.removeWhere((item) => item.messageId == entry.key);
          } else {
            _upsertMessage(message);
          }
        }
        _page = 1;
        _hasNext = page.hasNext;
        _loading = false;
      });
      if (!filters.active && _visibleChannel) {
        final cursor = _displayedCursor();
        if (cursor > 0) {
          if (_pendingRead <= cursor) _pendingRead = 0;
          await _acknowledgeRead(cursor);
        }
      }
    } catch (e) {
      if (!current()) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    } finally {
      if (identical(_liveChannelChanges, changes)) _liveChannelChanges = null;
      if (current()) _scheduleRead();
    }
  }

  bool get _visibleChannel {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return mounted &&
        _members == null &&
        !_searchOpen &&
        ModalRoute.of(context)?.isCurrent == true &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed);
  }

  void _clearPendingRead() {
    _readTimer?.cancel();
    _readTimer = null;
    _pendingRead = 0;
  }

  int _displayedCursor({int? through}) => _messages.fold(
    0,
    (latest, message) =>
        (through == null || message.messageId <= through) &&
            message.messageId > latest
        ? message.messageId
        : latest,
  );

  void _scheduleRead() {
    if (_pendingRead == 0 ||
        _readTimer != null ||
        _syncingRead ||
        _loading ||
        !_visibleChannel) {
      return;
    }
    final current = _binding.capture();
    _readTimer = Timer(const Duration(milliseconds: 250), () async {
      _readTimer = null;
      if (!current() || _loading || !_visibleChannel) return;
      final cursor = _displayedCursor(through: _pendingRead);
      _pendingRead = 0;
      if (cursor == 0) return;
      _syncingRead = true;
      try {
        await _acknowledgeRead(cursor);
      } finally {
        _syncingRead = false;
        _scheduleRead();
      }
    });
  }

  Future<void> _acknowledgeRead(int cursor) async {
    try {
      await ref
          .read(chatApiProvider)
          .setChannelReadStatus(
            channelId: widget.channelId,
            lastReadMessageId: cursor,
          );
    } catch (_) {
      // Keep displayed messages and retry when history refreshes.
    }
  }

  Future<void> _loadOlder() async {
    if (_loading || _loadingOlder || !_hasNext) return;
    final ownsPage = _binding.capture();
    if (!ownsPage()) return;
    final revision = _readRevision;
    final filters = _filters;
    bool current() => ownsPage() && revision == _readRevision;
    final changes = <int, V2ChatMessage?>{};
    _liveChannelChanges = changes;
    setState(() => _loadingOlder = true);
    final nextPage = _page + 1;
    try {
      // Page-based history only — server has no reliable `before` cursor.
      final page = await ref
          .read(chatApiProvider)
          .listMessages(
            channelId: widget.channelId,
            page: nextPage,
            search: filters.query,
            senderId: filters.senderId,
            startAt: filters.startAt,
            endAt: filters.endAt,
          );
      if (!current()) return;
      final existing = _messages.map((m) => m.messageId).toSet();
      final older = page.items.reversed
          .where(
            (m) =>
                !existing.contains(m.messageId) &&
                !(changes.containsKey(m.messageId) &&
                    changes[m.messageId] == null) &&
                !_deletedSearchResults.contains(m.messageId),
          )
          .toList();
      setState(() {
        _messages = [..._messages, ...older];
        _page = nextPage;
        _hasNext = page.hasNext;
        _loadingOlder = false;
      });
    } catch (e) {
      if (!current()) return;
      setState(() => _loadingOlder = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      if (identical(_liveChannelChanges, changes)) _liveChannelChanges = null;
    }
  }

  void _openMessageSearch() {
    _clearPendingRead();
    setState(() => _searchOpen = true);
    _typing.setVisible(false);
  }

  Future<List<ChatSearchSender>> _loadSearchSenders() async {
    final current = _binding.capture();
    if (!current()) return [];
    final members = await ref.read(chatApiProvider).listMembers(widget.groupId);
    if (!current()) return [];
    return [
      for (final member in members)
        if (member.userId > 0 && member.userId <= 9007199254740991)
          (
            id: member.userId,
            name: member.displayName.isEmpty
                ? member.username
                : member.displayName,
          ),
    ];
  }

  Future<void> _startChannelCall(CallMode mode) async {
    final scope = _binding.capture();
    final selection = ++_callSelection;
    bool current() =>
        mounted &&
        scope() &&
        selection == _callSelection &&
        ModalRoute.isCurrentOf(context) == true;
    if (!current() || ref.read(callControllerProvider).phase != null) return;
    try {
      final tokens = await ref.read(tokenStoreProvider).read();
      if (!current() || tokens == null) return;
      final self = realtimeUserIdFromAccessToken(tokens.accessToken);
      if (self == null) return;
      final members = (await _loadSearchSenders())
          .where((member) => member.id != self)
          .toList();
      if (!current()) return;
      final member = await showDialog<ChatSearchSender>(
        context: context,
        builder: (context) {
          final l10n = AppLocalizations.of(context);
          return SimpleDialog(
            title: Text(l10n.t('call.select_member')),
            children: [
              if (members.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(l10n.t('call.no_members')),
                ),
              for (final member in members)
                SimpleDialogOption(
                  onPressed: () =>
                      Navigator.of(context).pop(scope() ? member : null),
                  child: Text(member.name),
                ),
            ],
          );
        },
      );
      if (!current() || member == null) return;
      final conversation = await ref
          .read(chatApiProvider)
          .openConversation(userId: member.id);
      if (!current()) return;
      await ref
          .read(callControllerProvider)
          .start(
            conversationId: conversation.conversationId,
            mode: mode,
            peerId: member.id,
            peerName: member.name,
            current: current,
          );
    } catch (error) {
      if (current()) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorView.describe(context, error))),
        );
      }
    }
  }

  void _searchMessages(ChatMessageFilters filters) {
    _clearPendingRead();
    setState(() {
      _filters = filters;
      _messages = [];
      _hasNext = false;
    });
    _typing.setVisible(_visibleChannel);
    unawaited(_load());
  }

  void _closeMessageSearch() {
    setState(() => _searchOpen = false);
    _searchMessages(const ChatMessageFilters());
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    // reverse:true — offset 0 is the newest messages.
    _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if ((text.isEmpty && _attachments.isEmpty) ||
        _sending ||
        _pickingAttachment) {
      return;
    }
    final current = _binding.capture();
    if (!current()) return;
    _typing.stop();
    final cancel = CancelToken();
    _attachmentUpload = cancel;
    setState(() => _sending = true);
    try {
      final mediaIds = await _uploadAttachments(current, cancel);
      if (!current() || mediaIds == null) return;
      final message = await ref
          .read(chatApiProvider)
          .sendChannelMessage(
            channelId: widget.channelId,
            content: text,
            replyToMessageId: _replyTo?.messageId,
            mediaIds: mediaIds,
          );
      if (!current()) return;
      setState(() {
        _upsertMessage(message);
        _composer.clear();
        _attachments.clear();
        _uploadedAttachments.clear();
        _replyTo = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } catch (e) {
      if (!current()) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      if (current()) {
        _attachmentUpload = null;
        setState(() => _sending = false);
      }
    }
  }

  Future<void> _pickAttachment({
    FileType type = FileType.any,
    List<String>? allowedExtensions,
  }) async {
    if (_pickingAttachment || _sending) return;
    final current = _binding.capture();
    if (!current()) return;
    setState(() => _pickingAttachment = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: type,
        allowedExtensions: allowedExtensions,
        allowMultiple: true,
        withData: false,
        withReadStream: kIsWeb,
      );
      if (!current() || result == null) return;
      final l10n = AppLocalizations.of(context);
      final String? selectionError;
      if (_attachments.length + result.files.length > _maxAttachments) {
        selectionError = l10n.t('chat.attachment_count');
      } else if (result.files.any(
        (file) => file.size > chatAttachmentMaxBytes,
      )) {
        selectionError = l10n.t('compose.media_size');
      } else if (result.files.any((file) => file.size <= 0)) {
        selectionError = l10n.t('chat.attachment_empty');
      } else {
        selectionError = null;
      }
      if (selectionError != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(selectionError)));
        return;
      }
      setState(() => _attachments.addAll(result.files));
    } catch (e) {
      if (!current()) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      if (current()) setState(() => _pickingAttachment = false);
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
    _typing.input(updated.trim().isNotEmpty);
  }

  Future<List<int>?> _uploadAttachments(
    bool Function() current,
    CancelToken cancel,
  ) async {
    if (_attachments.isEmpty) return const [];
    final api = ref.read(mediaApiProvider);
    final mediaIds = <int>[];
    for (final attachment in List.of(_attachments)) {
      if (!current()) return null;
      final uploadedId = _uploadedAttachments[attachment];
      if (uploadedId != null) {
        mediaIds.add(uploadedId);
        continue;
      }
      final V2MediaAsset asset;
      try {
        asset = await uploadChatAttachment(api, attachment, cancel);
      } catch (_) {
        if (!current()) return null;
        if (attachment.bytes != null || attachment.readStream == null) rethrow;
        // A browser picker stream can only be consumed once.
        setState(() => _attachments.remove(attachment));
        final hint = AppLocalizations.of(context).t('chat.attachment_reselect');
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('${attachment.name}: $hint')));
        return null;
      }
      if (!current()) return null;
      _uploadedAttachments[attachment] = asset.mediaId;
      mediaIds.add(asset.mediaId);
    }
    return mediaIds;
  }

  Future<void> _react(V2ChatMessage message, [String emoji = '👍']) async {
    final current = _binding.capture();
    if (!current()) return;
    final messageId = message.messageId;
    final visible = _messages
        .where((item) => item.messageId == messageId)
        .firstOrNull;
    if (visible == null || !_pendingReactions.add(messageId)) return;
    try {
      final reacted = visible.reactions.any(
        (reaction) => reaction.emoji == emoji && reaction.reactedByMe,
      );
      final api = ref.read(chatApiProvider);
      final updated = reacted
          ? await api.unreactMessage(messageId: messageId, emoji: emoji)
          : await api.reactMessage(messageId: messageId, emoji: emoji);
      if (!current()) return;
      if (updated.channelId != widget.channelId ||
          updated.groupId != widget.groupId ||
          updated.messageId != messageId) {
        throw const FormatException('Unexpected chat reaction scope');
      }
      final latest = _messages
          .where((item) => item.messageId == messageId)
          .firstOrNull;
      if (latest != null) {
        setState(
          () => _upsertMessage(
            _copyMessage(latest, reactions: updated.reactions),
          ),
        );
      }
    } catch (e) {
      if (!current()) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      if (current()) _pendingReactions.remove(messageId);
    }
  }

  V2ChatMessage _copyMessage(
    V2ChatMessage message, {
    List<V2ChatReactionSummary>? reactions,
    bool? isPinned,
    bool? canDelete,
    bool? canPin,
  }) {
    return V2ChatMessage(
      messageId: message.messageId,
      channelId: message.channelId,
      groupId: message.groupId,
      messageType: message.messageType,
      content: message.content,
      author: message.author,
      replyTo: message.replyTo,
      media: message.media,
      reactions: reactions ?? message.reactions,
      isPinned: isPinned ?? message.isPinned,
      isDeleted: message.isDeleted,
      canDelete: canDelete ?? message.canDelete,
      canPin: canPin ?? message.canPin,
      createdAt: message.createdAt,
      updatedAt: message.updatedAt,
      editedAt: message.editedAt,
      deletedAt: message.deletedAt,
    );
  }

  void _startReply(V2ChatMessage message) {
    setState(() => _replyTo = message);
  }

  Future<void> _editMessage(V2ChatMessage message) async {
    final current = _binding.capture();
    if (!current()) return;
    final l10n = AppLocalizations.of(context);
    try {
      final content = await showDialog<String>(
        context: context,
        builder: (context) =>
            _EditMessageDialog(initialContent: message.content),
      );
      final trimmed = content?.trim();
      if (!current() ||
          trimmed == null ||
          trimmed.isEmpty ||
          trimmed == message.content) {
        return;
      }
      final updated = await ref
          .read(chatApiProvider)
          .editMessage(messageId: message.messageId, content: trimmed);
      if (!current()) return;
      if (updated.channelId != widget.channelId ||
          updated.groupId != widget.groupId) {
        throw const FormatException('Unexpected chat message scope');
      }
      if (!_messages.any((item) => item.messageId == message.messageId)) return;
      setState(() => _upsertMessage(updated));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.t('chat.message_updated'))));
    } catch (e) {
      if (!current()) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _deleteMessage(V2ChatMessage message) async {
    final current = _binding.capture();
    if (!current()) return;
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
    if (confirmed != true || !current()) return;
    try {
      await ref.read(chatApiProvider).deleteMessage(message.messageId);
      if (!current()) return;
      _removeDeletedMessage({
        'channel_id': widget.channelId,
        'message_id': message.messageId,
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.t('chat.message_deleted'))));
    } catch (e) {
      if (!current()) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _pin(V2ChatMessage message) async {
    final current = _binding.capture();
    if (!current()) return;
    try {
      final api = ref.read(chatApiProvider);
      final updated = message.isPinned
          ? await api.unpinMessage(message.messageId)
          : await api.pinMessage(message.messageId);
      if (!current()) return;
      if (updated.channelId != widget.channelId ||
          updated.groupId != widget.groupId) {
        throw const FormatException('Unexpected chat message scope');
      }
      final index = _messages.indexWhere(
        (item) => item.messageId == message.messageId,
      );
      if (index < 0) return;
      setState(
        () => _upsertMessage(
          _copyMessage(_messages[index], isPinned: updated.isPinned),
        ),
      );
    } catch (e) {
      if (!current()) return;
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

  String get _appBarTitle {
    final name = widget.channelName?.trim();
    if (name != null && name.isNotEmpty) return '#$name';
    return '#${widget.channelId}';
  }

  void _loadMembers() {
    if (!_binding.capture()()) return;
    _clearPendingRead();
    final pending = ref.read(chatApiProvider).listMembers(widget.groupId);
    setState(() {
      _members = pending;
    });
    _typing.setVisible(false);
  }

  void _closeMembers() {
    setState(() => _members = null);
    _typing.setVisible(_visibleChannel);
  }

  Widget _buildMembers(
    Future<List<V2ChatMember>> members,
    AppLocalizations l10n,
  ) {
    final format = MaterialLocalizations.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closeMembers();
      },
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: LiquidGlassAppBar(
          leading: BackButton(
            key: const Key('chat-channel-members'),
            onPressed: _closeMembers,
          ),
          title: Text(l10n.t('group.members_title')),
          actions: [
            IconButton(
              tooltip: l10n.t('chat.members_refresh'),
              onPressed: _loadMembers,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: FutureBuilder<List<V2ChatMember>>(
          future: members,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const LoadingView();
            }
            if (snapshot.hasError) {
              return ErrorView(error: snapshot.error!, onRetry: _loadMembers);
            }
            final rows = snapshot.requireData;
            if (rows.isEmpty) {
              return EmptyView(message: l10n.t('chat.members_empty'));
            }
            return ListView.builder(
              padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final member = rows[index];
                final role = switch (member.role) {
                  'owner' => l10n.t('chat.member_owner'),
                  'admin' => l10n.t('chat.member_admin'),
                  'moderator' => l10n.t('chat.member_moderator'),
                  _ => l10n.t('group.members_title'),
                };
                final seen = member.lastSeenAt?.toLocal();
                return ListTile(
                  leading: AppAvatar(url: member.avatarUrl),
                  title: Text(
                    member.displayName.isEmpty
                        ? member.username
                        : member.displayName,
                  ),
                  subtitle: Text(
                    [
                      role,
                      if (member.status == 'muted')
                        l10n.t('chat.member_silenced'),
                      if (member.onlineStatus == 'online')
                        l10n.t('chat.member_online'),
                      if (member.onlineStatus == 'offline')
                        l10n.t('chat.member_offline'),
                      if (seen != null)
                        '${format.formatShortDate(seen)} ${format.formatTimeOfDay(TimeOfDay.fromDateTime(seen))}',
                    ].join(' · '),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (ModalRoute.isCurrentOf(context) == true) _scheduleRead();
    final l10n = AppLocalizations.of(context);
    final members = _members;
    if (members != null) return _buildMembers(members, l10n);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final topInset = kToolbarHeight + MediaQuery.paddingOf(context).top;
    final width = MediaQuery.sizeOf(context).width;
    final compactTools = width < 600;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: LiquidGlassAppBar(
        automaticallyImplyLeading: !widget.embedded,
        leading: widget.embedded
            ? null
            : const SafeBackButton(fallbackRoute: '/chat'),
        title: Text(_appBarTitle),
        actions: [
          CallMenu(
            key: const Key('chat-channel-call-menu'),
            onSelected: (mode) => unawaited(_startChannelCall(mode)),
          ),
          IconButton(
            key: const Key('chat-channel-members'),
            tooltip: l10n.t('group.members_title'),
            onPressed: _searchOpen ? null : _loadMembers,
            icon: const Icon(Icons.group_outlined),
          ),
          IconButton(
            key: const Key('chat-channel-search-toggle'),
            tooltip: l10n.t(
              _searchOpen ? 'common.close' : 'chat.search_messages',
            ),
            onPressed: _sending || _pickingAttachment
                ? null
                : _searchOpen
                ? _closeMessageSearch
                : _openMessageSearch,
            icon: Icon(_searchOpen ? Icons.close : Icons.search),
          ),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppBreakpoints.contentMaxWidth,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Column(
                children: [
                  if (_searchOpen)
                    Padding(
                      padding: EdgeInsets.only(top: topInset),
                      child: ChatMessageSearch(
                        inputKey: const Key('chat-channel-search-input'),
                        title: l10n.t('chat.search_messages'),
                        loadSenders: _loadSearchSenders,
                        isCurrent: _binding.capture(),
                        onApply: _searchMessages,
                        onClear: _closeMessageSearch,
                      ),
                    ),
                  Expanded(
                    child: _loading
                        ? const LoadingView()
                        : _error != null
                        ? ErrorView(error: _error!, onRetry: _load)
                        : _messages.isEmpty
                        ? EmptyView(
                            message: l10n.t(
                              !_filters.active
                                  ? 'chat.empty_messages'
                                  : 'chat.search_empty',
                            ),
                          )
                        : LayoutBuilder(
                            builder: (context, constraints) {
                              final maxBubbleWidth = math.min(
                                constraints.maxWidth * 0.72,
                                460.0,
                              );
                              return ListView.builder(
                                controller: _scroll,
                                reverse: true,
                                padding: EdgeInsets.fromLTRB(
                                  12,
                                  _searchOpen ? 12 : topInset + 12,
                                  12,
                                  _searchOpen ? 12 : _composerHeight + 12,
                                ),
                                itemCount:
                                    _messages.length + (_loadingOlder ? 1 : 0),
                                itemBuilder: (_, i) {
                                  if (_loadingOlder && i == _messages.length) {
                                    return const Padding(
                                      padding: EdgeInsets.symmetric(
                                        vertical: 12,
                                      ),
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
                                  final prev = i + 1 < _messages.length
                                      ? _messages[i + 1]
                                      : null;
                                  final next = i - 1 >= 0
                                      ? _messages[i - 1]
                                      : null;
                                  final day = _channelCalendarDay(
                                    message.createdAt,
                                  );
                                  final prevDay = prev == null
                                      ? null
                                      : _channelCalendarDay(prev.createdAt);
                                  final showDatePill =
                                      day != null && day != prevDay;
                                  final samePrev =
                                      prev != null &&
                                      !message.isDeleted &&
                                      !prev.isDeleted &&
                                      prev.author.userId ==
                                          message.author.userId &&
                                      day == prevDay &&
                                      _channelWithinFiveMinutes(prev, message);
                                  final sameNext =
                                      next != null &&
                                      !message.isDeleted &&
                                      !next.isDeleted &&
                                      next.author.userId ==
                                          message.author.userId &&
                                      _channelCalendarDay(next.createdAt) ==
                                          day &&
                                      _channelWithinFiveMinutes(message, next);
                                  final isSelf =
                                      _currentUserId != null &&
                                      message.author.userId == _currentUserId;
                                  final tile = _ChannelMessageTile(
                                    message: message,
                                    isSelf: isSelf,
                                    samePrev: samePrev,
                                    sameNext: sameNext,
                                    maxWidth: maxBubbleWidth,
                                    readOnly: _searchOpen,
                                    timeLabel: _time(message.createdAt),
                                    onReply: () => _startReply(message),
                                    onReact: () => _react(message),
                                    onReactionSelected: (emoji) =>
                                        _react(message, emoji),
                                    onPin: message.canPin
                                        ? () => _pin(message)
                                        : null,
                                    onEdit:
                                        message.author.userId ==
                                                _currentUserId &&
                                            message.messageType == 'text'
                                        ? () => _editMessage(message)
                                        : null,
                                    onDelete: message.canDelete
                                        ? () => _deleteMessage(message)
                                        : null,
                                  );
                                  if (!showDatePill) return tile;
                                  return Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 10,
                                        ),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: scheme.surfaceContainerHigh,
                                            borderRadius: BorderRadius.circular(
                                              999,
                                            ),
                                          ),
                                          child: Text(
                                            _formatChannelDayLabel(
                                              context,
                                              l10n,
                                              day,
                                            ),
                                            style: theme.textTheme.labelSmall
                                                ?.copyWith(
                                                  color:
                                                      scheme.onSurfaceVariant,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                          ),
                                        ),
                                      ),
                                      tile,
                                    ],
                                  );
                                },
                              );
                            },
                          ),
                  ),
                  if (_filters.active &&
                      _hasNext &&
                      !_loading &&
                      _error == null)
                    TextButton(
                      onPressed: _loadingOlder ? null : _loadOlder,
                      child: Text(l10n.t('chat.dm.load_older')),
                    ),
                ],
              ),
              if (!_searchOpen)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: measureGlassOverlay(
                    SafeArea(
                      top: false,
                      child: LiquidGlassSurface(
                        preset: LiquidGlassPreset.floatingIsland,
                        borderRadius: BorderRadius.circular(AppRadius.canvas),
                        margin: const EdgeInsets.fromLTRB(8, 8, 8, 10),
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_typing.hasRemoteTyping)
                              Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: Padding(
                                  padding: const EdgeInsets.only(
                                    left: 10,
                                    bottom: 6,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _ChannelTypingDots(color: scheme.primary),
                                      const SizedBox(width: 6),
                                      Text(
                                        l10n.t('chat.channel.typing'),
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: scheme.onSurfaceVariant,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
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
                                        : () => setState(() {
                                            final attachment = _attachments
                                                .removeAt(i);
                                            _uploadedAttachments.remove(
                                              attachment,
                                            );
                                          }),
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
                                      : () => _pickAttachment(),
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
                                      : () => _pickAttachment(
                                          type: FileType.image,
                                        ),
                                  icon: const Icon(Icons.image_outlined),
                                ),
                                if (!compactTools) ...[
                                  PopupMenuButton<String>(
                                    key: const Key('chat-channel-emoji-button'),
                                    tooltip: 'Emoji',
                                    onSelected: _insertComposerText,
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(
                                        value: '😀',
                                        child: Text('😀'),
                                      ),
                                      PopupMenuItem(
                                        value: '😂',
                                        child: Text('😂'),
                                      ),
                                      PopupMenuItem(
                                        value: '❤️',
                                        child: Text('❤️'),
                                      ),
                                      PopupMenuItem(
                                        value: '👍',
                                        child: Text('👍'),
                                      ),
                                      PopupMenuItem(
                                        value: '✨',
                                        child: Text('✨'),
                                      ),
                                    ],
                                    icon: const Icon(
                                      Icons.emoji_emotions_outlined,
                                    ),
                                  ),
                                  IconButton(
                                    key: const Key(
                                      'chat-channel-mention-button',
                                    ),
                                    tooltip: '@',
                                    onPressed: _sending
                                        ? null
                                        : () => _insertComposerText('@'),
                                    icon: const Icon(Icons.alternate_email),
                                  ),
                                  IconButton(
                                    key: const Key(
                                      'chat-channel-channel-button',
                                    ),
                                    tooltip: '#',
                                    onPressed: _sending
                                        ? null
                                        : () => _insertComposerText('#'),
                                    icon: const Icon(Icons.tag),
                                  ),
                                  IconButton(
                                    key: const Key(
                                      'chat-channel-sticker-button',
                                    ),
                                    tooltip: 'Sticker',
                                    onPressed: _sending
                                        ? null
                                        : () => _insertComposerText('🎁 '),
                                    icon: const Icon(
                                      Icons.card_giftcard_outlined,
                                    ),
                                  ),
                                ] else
                                  PopupMenuButton<String>(
                                    key: const Key('chat-channel-more-tools'),
                                    tooltip: l10n.t('common.more'),
                                    enabled: !_sending,
                                    onSelected: _insertComposerText,
                                    itemBuilder: (_) => [
                                      PopupMenuItem(
                                        key: const Key(
                                          'chat-channel-emoji-button',
                                        ),
                                        value: '😀',
                                        child: const Text('😀'),
                                      ),
                                      const PopupMenuItem(
                                        value: '😂',
                                        child: Text('😂'),
                                      ),
                                      const PopupMenuItem(
                                        value: '❤️',
                                        child: Text('❤️'),
                                      ),
                                      const PopupMenuItem(
                                        value: '👍',
                                        child: Text('👍'),
                                      ),
                                      const PopupMenuItem(
                                        value: '✨',
                                        child: Text('✨'),
                                      ),
                                      PopupMenuItem(
                                        key: const Key(
                                          'chat-channel-mention-button',
                                        ),
                                        value: '@',
                                        child: const Text('@'),
                                      ),
                                      PopupMenuItem(
                                        key: const Key(
                                          'chat-channel-channel-button',
                                        ),
                                        value: '#',
                                        child: const Text('#'),
                                      ),
                                      PopupMenuItem(
                                        key: const Key(
                                          'chat-channel-sticker-button',
                                        ),
                                        value: '🎁 ',
                                        child: const Text('🎁'),
                                      ),
                                    ],
                                    icon: const Icon(Icons.more_horiz),
                                  ),
                                Expanded(
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: SocialColors.of(
                                        context,
                                      ).surfaceSubtle,
                                      borderRadius: BorderRadius.circular(
                                        AppRadius.tile,
                                      ),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                    ),
                                    child: TextField(
                                      key: const Key(
                                        'chat-channel-composer-field',
                                      ),
                                      controller: _composer,
                                      minLines: 1,
                                      maxLines: 5,
                                      decoration: InputDecoration(
                                        hintText: l10n.t('chat.message_hint'),
                                        border: InputBorder.none,
                                        enabledBorder: InputBorder.none,
                                        focusedBorder: InputBorder.none,
                                        isDense: true,
                                        filled: false,
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              vertical: 10,
                                            ),
                                      ),
                                      onSubmitted: (_) => _send(),
                                      onChanged: (text) => setState(
                                        () => _typing.input(
                                          text.trim().isNotEmpty,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                ValueListenableBuilder<TextEditingValue>(
                                  valueListenable: _composer,
                                  builder: (context, value, _) {
                                    final hasContent =
                                        value.text.trim().isNotEmpty ||
                                        _attachments.isNotEmpty;
                                    return AnimatedScale(
                                      scale: hasContent ? 1.0 : 0.92,
                                      duration: AppMotion.resolve(
                                        context,
                                        AppMotion.fast,
                                      ),
                                      curve: AppMotion.emphasizedDecelerate,
                                      child: IconButton.filled(
                                        key: const Key(
                                          'chat-channel-send-button',
                                        ),
                                        tooltip: l10n.t('chat.send'),
                                        style: IconButton.styleFrom(
                                          disabledBackgroundColor:
                                              scheme.surfaceContainerHigh,
                                          disabledForegroundColor:
                                              scheme.onSurfaceVariant,
                                        ),
                                        onPressed:
                                            _sending ||
                                                _pickingAttachment ||
                                                !hasContent
                                            ? null
                                            : _send,
                                        icon: _sending
                                            ? SizedBox.square(
                                                dimension: 18,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                      color: scheme
                                                          .onSurfaceVariant,
                                                    ),
                                              )
                                            : const Icon(
                                                Icons.send_rounded,
                                                size: 19,
                                              ),
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    (height) {
                      if (_composerHeight != height) {
                        setState(() => _composerHeight = height);
                      }
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

DateTime? _channelCalendarDay(String iso) {
  final dt = DateTime.tryParse(iso)?.toLocal();
  if (dt == null) return null;
  return DateTime(dt.year, dt.month, dt.day);
}

bool _channelWithinFiveMinutes(V2ChatMessage a, V2ChatMessage b) {
  final da = DateTime.tryParse(a.createdAt);
  final db = DateTime.tryParse(b.createdAt);
  if (da == null || db == null) return false;
  return da.difference(db).inMilliseconds.abs() <= 300000;
}

String _formatChannelDayLabel(
  BuildContext context,
  AppLocalizations l10n,
  DateTime day,
) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  if (day == today) return l10n.t('chat.date_today');
  if (day == today.subtract(const Duration(days: 1))) {
    return l10n.t('chat.date_yesterday');
  }
  return DateFormat.MMMd(
    Localizations.localeOf(context).toString(),
  ).format(day);
}

class _ChannelTypingDots extends StatefulWidget {
  const _ChannelTypingDots({required this.color});

  final Color color;

  @override
  State<_ChannelTypingDots> createState() => _ChannelTypingDotsState();
}

class _ChannelTypingDotsState extends State<_ChannelTypingDots>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active =
        TickerMode.valuesOf(context).enabled && !AppMotion.reduced(context);
    if (active) {
      _controller ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1100),
      )..repeat();
    } else {
      _controller?.dispose();
      _controller = null;
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            CircleAvatar(radius: 2.5, backgroundColor: widget.color),
          ],
        ],
      );
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: 3),
              Builder(
                builder: (_) {
                  final phase = (controller.value - i * 0.16) % 1.0;
                  final wave = math.sin(phase * math.pi * 2);
                  final dy = wave > 0 ? -wave * 3.0 : 0.0;
                  final opacity = 0.4 + (wave > 0 ? wave * 0.6 : 0.0);
                  return Transform.translate(
                    offset: Offset(0, dy),
                    child: Opacity(
                      opacity: opacity,
                      child: CircleAvatar(
                        radius: 2.5,
                        backgroundColor: widget.color,
                      ),
                    ),
                  );
                },
              ),
            ],
          ],
        );
      },
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
    this.isSelf = false,
    this.samePrev = false,
    this.sameNext = false,
    this.maxWidth = 460,
    this.onPin,
    this.onEdit,
    this.onDelete,
    this.readOnly = false,
  });

  final V2ChatMessage message;
  final String timeLabel;
  final VoidCallback onReply;
  final VoidCallback onReact;
  final ValueChanged<String> onReactionSelected;
  final bool isSelf;
  final bool samePrev;
  final bool sameNext;
  final double maxWidth;
  final VoidCallback? onPin;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final social = SocialColors.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final displayName = message.author.displayName.isEmpty
        ? message.author.username
        : message.author.displayName;
    final bubbleColor = isSelf
        ? (isDark
              ? Color.alphaBlend(
                  scheme.primary.withValues(alpha: 0.22),
                  social.surfaceCard,
                )
              : scheme.primary)
        : scheme.surfaceContainerHigh;
    final textColor = isSelf
        ? (isDark ? scheme.onSurface : scheme.onPrimary)
        : scheme.onSurface;
    final mutedColor = isSelf
        ? (isDark
              ? scheme.onSurfaceVariant
              : scheme.onPrimary.withValues(alpha: 0.78))
        : scheme.onSurfaceVariant;
    final radius = BorderRadius.only(
      topLeft: Radius.circular(isSelf ? 18 : (samePrev ? 4 : 18)),
      topRight: Radius.circular(isSelf ? (samePrev ? 4 : 18) : 18),
      bottomLeft: Radius.circular(isSelf ? 18 : 4),
      bottomRight: Radius.circular(isSelf ? 4 : 18),
    );
    final menuButton = !readOnly
        ? PopupMenuButton<_ChannelMessageAction>(
            key: Key('chat-channel-more-${message.messageId}'),
            tooltip: l10n.t('common.more'),
            icon: Icon(
              Icons.more_horiz,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
            onSelected: (action) {
              switch (action) {
                case _ChannelMessageAction.reply:
                  onReply();
                  break;
                case _ChannelMessageAction.react:
                  onReact();
                  break;
                case _ChannelMessageAction.pin:
                  onPin?.call();
                  break;
                case _ChannelMessageAction.edit:
                  onEdit?.call();
                  break;
                case _ChannelMessageAction.delete:
                  onDelete?.call();
                  break;
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                key: Key('chat-channel-reply-${message.messageId}'),
                value: _ChannelMessageAction.reply,
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.reply_rounded),
                  title: Text(l10n.t('chat.reply')),
                ),
              ),
              const PopupMenuItem(
                value: _ChannelMessageAction.react,
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.thumb_up_alt_outlined),
                  title: Text('👍'),
                ),
              ),
              if (onPin != null)
                PopupMenuItem(
                  value: _ChannelMessageAction.pin,
                  child: ListTile(
                    dense: true,
                    leading: Icon(
                      message.isPinned
                          ? Icons.push_pin
                          : Icons.push_pin_outlined,
                    ),
                    title: Text(
                      message.isPinned
                          ? l10n.t('chat.unpin')
                          : l10n.t('chat.pin'),
                    ),
                  ),
                ),
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
          )
        : null;

    return Align(
      alignment: isSelf ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: EdgeInsets.only(
          top: samePrev ? 1.5 : 6,
          bottom: sameNext ? 1.5 : 4,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!isSelf) ...[
                if (!sameNext)
                  AppAvatar(
                    url: message.author.avatarUrl,
                    size: 32,
                    name: displayName,
                    seed: message.author.userId,
                  )
                else
                  const SizedBox(width: 32),
                const SizedBox(width: 8),
              ],
              if (isSelf && menuButton != null) menuButton,
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 15,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: bubbleColor,
                    borderRadius: radius,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!isSelf && !samePrev)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Text(
                            displayName,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      if (message.replyTo != null) ...[
                        ChatReplyQuote(replyTo: message.replyTo!),
                        const SizedBox(height: 6),
                      ],
                      if (message.isDeleted)
                        Text(
                          l10n.t('chat.deleted_message'),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontStyle: FontStyle.italic,
                            color: mutedColor,
                          ),
                        )
                      else if (message.content.isNotEmpty)
                        Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(text: message.content),
                              if (message.editedAt != null)
                                TextSpan(
                                  text: ' (${l10n.t('chat.edited')})',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: mutedColor,
                                  ),
                                ),
                            ],
                          ),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: textColor,
                          ),
                        )
                      else if (message.media.isEmpty)
                        Text(
                          l10n.t('chat.message_hint'),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: mutedColor,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      if (!message.isDeleted)
                        ContentLinkPreview(content: message.content),
                      if (message.media.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (var i = 0; i < message.media.length; i++)
                              _MessageAttachment(
                                heroOwner: context,
                                media: message.media[i],
                                allMedia: message.media,
                                index: i,
                              ),
                          ],
                        ),
                      ],
                      if (message.reactions.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final reaction in message.reactions)
                              ChatReactionChip(
                                key: Key(
                                  'chat-channel-reaction-${message.messageId}-${reaction.emoji}',
                                ),
                                reaction: reaction,
                                onPressed: readOnly
                                    ? null
                                    : () => onReactionSelected(reaction.emoji),
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 3),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            timeLabel,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: mutedColor,
                              fontSize: 10.5,
                            ),
                          ),
                          if (message.isPinned) ...[
                            const SizedBox(width: 5),
                            Icon(
                              Icons.push_pin,
                              size: 12,
                              color: isSelf ? scheme.onPrimary : scheme.primary,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (!isSelf && menuButton != null) menuButton,
            ],
          ),
        ),
      ),
    );
  }
}

enum _ChannelMessageAction { reply, react, pin, edit, delete }

class _MessageAttachment extends StatelessWidget {
  const _MessageAttachment({
    required this.heroOwner,
    required this.media,
    this.allMedia = const [],
    this.index = 0,
  });

  final V2MediaAsset media;
  final BuildContext heroOwner;
  final List<V2MediaAsset> allMedia;
  final int index;

  @override
  Widget build(BuildContext context) {
    if (media.usesContentRoute) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: PrivateAttachmentButton(
          key: ValueKey(media.mediaId),
          asset: media,
        ),
      );
    }
    final theme = Theme.of(context);
    final isImage =
        media.mediaType == 'image' || media.mimeType.startsWith('image/');
    if (isImage) {
      final images = allMedia
          .where(
            (m) =>
                !m.usesContentRoute &&
                (m.mediaType == 'image' || m.mimeType.startsWith('image/')),
          )
          .toList();
      final imageIndex = images.indexWhere((m) => m.mediaId == media.mediaId);
      return GestureDetector(
        onTap: () {
          if (images.isEmpty) return;
          showMediaLightbox(
            context: context,
            items: [
              for (final m in images)
                MediaLightboxItem(url: m.publicUrl, altText: m.fileName, heroTag: (heroOwner, m.mediaId)),
            ],
            initialIndex: imageIndex >= 0 ? imageIndex : index,
          );
        },
        child: AppMediaImage(
          heroTag: (heroOwner, media.mediaId),
          url: media.publicUrl,
          width: 140,
          height: 104,
          borderRadius: BorderRadius.circular(12),
        ),
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
