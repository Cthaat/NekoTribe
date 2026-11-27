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
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/glass/liquid_glass_bars.dart';
import '../../../shared/widgets/glass/liquid_glass_surface.dart';
import '../../../shared/widgets/glass/liquid_glass_tokens.dart';
import '../../../shared/widgets/safe_back_button.dart';
import '../../../shared/widgets/status_views.dart';
import '../../../core/network/api_exception.dart';
import '../../calls/presentation/call_widgets.dart';
import '../../links/presentation/content_link_preview.dart';
import '../../media/presentation/private_attachment_button.dart';
import '../../realtime/data/realtime_service.dart';
import '../data/chat_attachment_upload.dart';
import '../domain/chat_models.dart';
import 'chat_message_extras.dart';
import 'chat_message_search.dart';
import 'chat_realtime_binding.dart';
import 'chat_typing.dart';

class ConversationScreen extends ConsumerStatefulWidget {
  const ConversationScreen({
    super.key,
    required this.conversationId,
    this.title,
    this.embedded = false,
  });
  final int conversationId;
  final String? title;
  final bool embedded;

  @override
  ConsumerState<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends ConsumerState<ConversationScreen> {
  final _scrollController = ScrollController();
  final _composer = TextEditingController();
  double _composerHeight = 84;
  late final ChatRealtimeBinding _binding;
  late final ChatTyping _typing;
  late final AppLifecycleListener _lifecycle;
  final _viewport = GlobalKey();
  final _bubbleKeys = <int, GlobalKey>{};
  Timer? _readSyncTimer;
  CancelToken? _readStatusRequest, _readCommit;
  bool _readReady = false, _measureQueued = false;
  int _seenThrough = 0, _lastRead = 0, _peerRead = 0;
  int _readRevision = 0;
  bool _searchOpen = false;
  var _filters = const ChatMessageFilters();
  List<V2DirectMessage> _messages = [];
  Map<int, V2DirectMessage?>? _liveDirectChanges;
  final _deletedMessages = <int>{};
  final _messageFetches = <int, CancelToken>{};
  final _reactionRequests = <int, CancelToken>{};
  final _deferredUpdates = <int>{};
  final _attachments = <PlatformFile>[];
  final _uploadedAttachments = Map<PlatformFile, int>.identity();
  final _animateIds = <int>{};
  V2DirectMessage? _replyTo;
  CancelToken? _sendRequest;
  int? _viewerId;
  int? _deletingMessageId;
  bool _loading = true;
  bool _loadingLatest = false;
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
      onEvent: _onRealtime,
      onReset: _reset,
      onReload: _reload,
    );
    _typing = ChatTyping(
      scope: ChatTypingScope.direct,
      scopeId: () => widget.conversationId,
      ownId: () => _viewerId,
      send: _binding.sendTyping,
      onChange: () {
        if (mounted) setState(() {});
      },
    );
    _binding.bind(ref.read(realtimeServiceProvider));
    _lifecycle = AppLifecycleListener(
      onStateChange: (_) => _updateVisibility(),
    );
    ref.listenManual(realtimeServiceProvider, (_, next) => _binding.bind(next));
    _scrollController.addListener(_onScroll);
    _reload();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateVisibility();
  }

  @override
  void didUpdateWidget(covariant ConversationScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId != widget.conversationId) {
      _binding.changeRoute();
    }
  }

  void _reset() {
    _readRevision++;
    _readSyncTimer?.cancel();
    _readSyncTimer = null;
    _readStatusRequest?.cancel();
    _readCommit?.cancel();
    _readStatusRequest = _readCommit = null;
    _readReady = false;
    _seenThrough = _lastRead = _peerRead = 0;
    _bubbleKeys.clear();
    _typing.reset(notify: false);
    _liveDirectChanges = null;
    _viewerId = _deletingMessageId = null;
    _cancelDraftRequests();
    setState(() {
      _messages = [];
      _searchOpen = false;
      _filters = const ChatMessageFilters();
      _deletedMessages.clear();
      _attachments.clear();
      _uploadedAttachments.clear();
      _animateIds.clear();
      _replyTo = null;
      _composer.clear();
      _page = 1;
      _error = null;
      _loading = true;
      _loadingLatest = false;
      _hasNext = _loadingOlder = _sending = false;
      _pickingAttachment = false;
    });
  }

  @override
  void dispose() {
    _readSyncTimer?.cancel();
    _readStatusRequest?.cancel();
    _readCommit?.cancel();
    _typing.stop();
    _typing.reset(notify: false);
    _cancelDraftRequests();
    _lifecycle.dispose();
    _binding.dispose();
    _scrollController.removeListener(_onScroll);
    _composer.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _cancelDraftRequests() {
    _sendRequest?.cancel();
    _sendRequest = null;
    for (final request in [
      ..._messageFetches.values,
      ..._reactionRequests.values,
    ]) {
      request.cancel();
    }
    _messageFetches.clear();
    _reactionRequests.clear();
    _deferredUpdates.clear();
  }

  void _onScroll() {
    _observeDisplayedMessages();
    if (!_scrollController.hasClients || _loadingOlder || !_hasNext) return;
    // reverse:true — older messages load near maxScrollExtent.
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 80) {
      _loadOlder();
    }
  }

  int? _eventInt(Object? value) {
    return value is int && value > 0 && value <= 9007199254740991
        ? value
        : null;
  }

  void _onRealtime(Map<String, dynamic> event) {
    if (!mounted || _typing.receive(event)) return;
    final type = event['type'];
    final data = event['data'];
    if (!mounted ||
        data is! Map ||
        _eventInt(data['conversation_id']) != widget.conversationId) {
      return;
    }
    if (type == 'direct_message_deleted') {
      final messageId = _eventInt(data['message_id']);
      if (messageId == null) return;
      setState(() => _removeMessage(messageId));
      return;
    }
    if (type == 'direct_read_updated') {
      final readerId = _eventInt(data['reader_id']);
      final cursor = _eventInt(data['last_read_message_id']);
      if (readerId == null || cursor == null) return;
      if (_viewerId == null) {
        unawaited(_loadReadStatus());
      } else if (readerId == _viewerId) {
        if (cursor > _lastRead) setState(() => _lastRead = cursor);
      } else if (cursor > _peerRead) {
        setState(() => _peerRead = cursor);
      }
      return;
    }
    if (_filters.active) return;
    if (type == 'direct_message_updated') {
      final messageId = _eventInt(data['message_id']);
      if (messageId == null) return;
      if (_reactionRequests.containsKey(messageId)) {
        _deferredUpdates.add(messageId);
      } else {
        unawaited(_refreshMessage(messageId));
      }
      return;
    }

    if (type != 'direct_message') return;
    final rawMessage = data['direct_message'];
    if (rawMessage is! Map<String, dynamic> ||
        _eventInt(rawMessage['conversation_id']) != widget.conversationId ||
        _eventInt(rawMessage['message_id']) == null ||
        rawMessage['content'] is! String ||
        rawMessage['created_at'] is! String ||
        rawMessage['is_deleted'] != false) {
      return;
    }
    final author = rawMessage['author'];
    if (author is! Map || _eventInt(author['user_id']) == null) return;

    try {
      final message = V2DirectMessage.fromJson(rawMessage);
      if (_deletedMessages.contains(message.messageId)) return;
      final atLatest =
          !_scrollController.hasClients || _scrollController.offset < 80;
      setState(() {
        _animateIds.add(message.messageId);
        _upsertMessage(message);
      });
      if (atLatest && _visibleView) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      }
    } catch (_) {
      // Ignore malformed realtime payloads.
    }
  }

  V2DirectMessage _withoutDeletedQuote(V2DirectMessage message) =>
      _deletedMessages.contains(message.replyTo?.messageId)
      ? message.withoutReply()
      : message;

  void _upsertMessage(V2DirectMessage message, {bool insert = true}) {
    if (_filters.active ||
        message.conversationId != widget.conversationId ||
        _deletedMessages.contains(message.messageId)) {
      return;
    }
    final index = _messages.indexWhere((m) => m.messageId == message.messageId);
    if (index < 0 && !insert) return;
    final refreshed = _withoutDeletedQuote(message);
    _liveDirectChanges?[message.messageId] = refreshed;
    if (index >= 0) {
      _messages[index] = refreshed;
    } else {
      // reverse:true list expects newest-first.
      _messages.insert(0, refreshed);
    }
  }

  void _removeMessage(int messageId) {
    _trackDeletion(messageId);
    _messages = _messages
        .where((item) => item.messageId != messageId)
        .map(_withoutDeletedQuote)
        .toList();
  }

  void _trackDeletion(int messageId) {
    _deletedMessages.add(messageId);
    _liveDirectChanges?[messageId] = null;
    _messageFetches.remove(messageId)?.cancel();
    _reactionRequests.remove(messageId)?.cancel();
    _deferredUpdates.remove(messageId);
    _bubbleKeys.remove(messageId);
    if (_seenThrough == messageId) _seenThrough = 0;
    if (_replyTo?.messageId == messageId) _replyTo = null;
  }

  V2DirectMessage? _visibleMessage(int messageId) => _messages
      .where((item) => item.messageId == messageId && !item.isDeleted)
      .firstOrNull;

  Future<void> _refreshMessage(int messageId) async {
    final ownsPage = _binding.capture();
    if (!ownsPage() || _visibleMessage(messageId) == null) return;
    _messageFetches.remove(messageId)?.cancel();
    final cancel = CancelToken();
    _messageFetches[messageId] = cancel;
    bool current() =>
        ownsPage() && identical(_messageFetches[messageId], cancel);
    try {
      final message = await ref
          .read(chatApiProvider)
          .getDirectMessage(
            conversationId: widget.conversationId,
            messageId: messageId,
            cancelToken: cancel,
          );
      if (current() && message.messageId == messageId && !message.isDeleted) {
        setState(() => _upsertMessage(message, insert: false));
      }
    } on ApiException catch (error) {
      if (current() && error.isNotFound) {
        setState(() => _removeMessage(messageId));
      }
    } catch (_) {
      // An unavailable optional update leaves the current visible history intact.
    } finally {
      if (current()) _messageFetches.remove(messageId);
    }
  }

  Future<void> _react(int messageId, String emoji) async {
    final ownsPage = _binding.capture();
    final message = _visibleMessage(messageId);
    if (!ownsPage() ||
        message == null ||
        _reactionRequests.containsKey(messageId)) {
      return;
    }
    final inFlight = _messageFetches.remove(messageId);
    if (inFlight != null) {
      inFlight.cancel();
      _deferredUpdates.add(messageId);
    }
    final cancel = CancelToken();
    setState(() => _reactionRequests[messageId] = cancel);
    bool current() =>
        ownsPage() && identical(_reactionRequests[messageId], cancel);
    try {
      final reacted = !message.reactions.any(
        (reaction) => reaction.emoji == emoji && reaction.reactedByMe,
      );
      final updated = await ref
          .read(chatApiProvider)
          .setDirectMessageReaction(
            conversationId: widget.conversationId,
            messageId: messageId,
            emoji: emoji,
            reacted: reacted,
            cancelToken: cancel,
          );
      if (current() && updated.messageId == messageId && !updated.isDeleted) {
        setState(() => _upsertMessage(updated, insert: false));
      }
    } catch (error) {
      if (current()) _showMessage(ErrorView.describe(context, error));
    } finally {
      if (current()) {
        setState(() => _reactionRequests.remove(messageId));
        if (_deferredUpdates.remove(messageId)) {
          unawaited(_refreshMessage(messageId));
        }
      }
    }
  }

  bool get _visibleView {
    final state = WidgetsBinding.instance.lifecycleState;
    return mounted &&
        !_searchOpen &&
        ModalRoute.of(context)?.isCurrent == true &&
        (state == null || state == AppLifecycleState.resumed);
  }

  void _updateVisibility() {
    final visible = _visibleView;
    _typing.setVisible(visible);
    if (visible) {
      _observeDisplayedMessages();
    } else {
      _readSyncTimer?.cancel();
      _readSyncTimer = null;
    }
  }

  void _observeDisplayedMessages() {
    if (_measureQueued || !_visibleView || _loading || _error != null) return;
    _measureQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureQueued = false;
      if (!_visibleView || _loading || _error != null) return;
      final bounds = _globalBounds(_viewport);
      if (bounds == null) return;
      final viewport = Rect.fromLTRB(
        bounds.left,
        bounds.top +
            (_searchOpen
                ? 0
                : kToolbarHeight + MediaQuery.paddingOf(context).top),
        bounds.right,
        bounds.bottom - (_searchOpen ? 0 : _composerHeight),
      );
      if (viewport.isEmpty) return;
      for (final message in _messages) {
        if (message.isDeleted || message.messageId <= _seenThrough) continue;
        final bounds = _globalBounds(_bubbleKeys[message.messageId]);
        if (bounds != null && viewport.overlaps(bounds)) {
          _seenThrough = message.messageId;
        }
      }
      _scheduleReadSync();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Rect? _globalBounds(GlobalKey? key) {
    final object = key?.currentContext?.findRenderObject();
    if (object is! RenderBox || !object.attached || !object.hasSize) {
      return null;
    }
    return object.localToGlobal(Offset.zero) & object.size;
  }

  void _scheduleReadSync() {
    if (!_readReady ||
        _seenThrough <= _lastRead ||
        _readSyncTimer != null ||
        _readCommit != null ||
        !_visibleView ||
        _loading ||
        _error != null) {
      return;
    }
    final ownsPage = _binding.capture();
    _readSyncTimer = Timer(const Duration(milliseconds: 250), () async {
      _readSyncTimer = null;
      final through = _seenThrough;
      if (!ownsPage() ||
          !_visibleView ||
          _loading ||
          _error != null ||
          through <= _lastRead ||
          _visibleMessage(through) == null) {
        return;
      }
      final cancel = CancelToken();
      _readCommit = cancel;
      bool current() => ownsPage() && identical(_readCommit, cancel);
      var committed = false;
      try {
        final status = await ref
            .read(chatApiProvider)
            .setDirectReadStatus(
              conversationId: widget.conversationId,
              lastReadMessageId: through,
              cancelToken: cancel,
            );
        if (!current()) return;
        _applyReadStatus(status);
        committed = true;
      } catch (_) {
        // A display update or reconnection can retry without changing the visible history.
      } finally {
        if (current()) {
          _readCommit = null;
          if (committed) _scheduleReadSync();
        }
      }
    });
  }

  void _reload() {
    unawaited(_loadReadStatus());
    unawaited(
      _load(background: !_filters.active && !_loading && _error == null),
    );
  }

  void _openMessageSearch() {
    _readCommit?.cancel();
    _readCommit = null;
    _seenThrough = 0;
    setState(() => _searchOpen = true);
    _updateVisibility();
  }

  Future<List<ChatSearchSender>> _loadSearchSenders() async {
    final current = _binding.capture();
    if (!current()) return [];
    final self = AppLocalizations.of(context).t('chat.search_self');
    final conversationId = widget.conversationId;
    final conversation = await ref
        .read(chatApiProvider)
        .getDirectConversation(conversationId);
    if (!current()) return [];
    final peer = conversation?.participant;
    final viewer = _viewerId;
    return [
      if (viewer != null) (id: viewer, name: self),
      if (peer != null && peer.userId > 0 && peer.userId != viewer)
        (
          id: peer.userId,
          name: peer.displayName.isEmpty ? peer.username : peer.displayName,
        ),
    ];
  }

  void _searchMessages(ChatMessageFilters filters) {
    for (final request in [
      ..._messageFetches.values,
      ..._reactionRequests.values,
    ]) {
      request.cancel();
    }
    _messageFetches.clear();
    _reactionRequests.clear();
    _deferredUpdates.clear();
    setState(() {
      _filters = filters;
      _messages = [];
      _hasNext = false;
    });
    unawaited(_load());
  }

  void _closeMessageSearch() {
    setState(() => _searchOpen = false);
    _searchMessages(const ChatMessageFilters());
    _updateVisibility();
  }

  Future<void> _loadReadStatus() async {
    final ownsPage = _binding.capture();
    if (!ownsPage()) return;
    _readStatusRequest?.cancel();
    final cancel = CancelToken();
    _readStatusRequest = cancel;
    bool current() => ownsPage() && identical(_readStatusRequest, cancel);
    try {
      final status = await ref
          .read(chatApiProvider)
          .getDirectReadStatus(
            conversationId: widget.conversationId,
            cancelToken: cancel,
          );
      if (current()) _applyReadStatus(status);
    } catch (_) {
      // Legacy servers or temporary failures can still display the conversation.
    } finally {
      if (current()) {
        _readStatusRequest = null;
        _scheduleReadSync();
      }
    }
  }

  void _applyReadStatus(V2DirectReadStatus status) {
    if (status.conversationId != widget.conversationId) return;
    setState(() {
      _readReady = true;
      final own = status.lastReadMessageId ?? 0;
      final peer = status.participantLastReadMessageId ?? 0;
      if (own > _lastRead) _lastRead = own;
      if (peer > _peerRead) _peerRead = peer;
    });
  }

  Future<void> _load({bool background = false}) async {
    final ownsPage = _binding.capture();
    if (!ownsPage()) return;
    if (!background) unawaited(_loadViewer(ownsPage));
    final revision = ++_readRevision;
    final filters = _filters;
    final changes = <int, V2DirectMessage?>{};
    _liveDirectChanges = changes;
    _loadingLatest = true;
    bool current() => ownsPage() && revision == _readRevision;
    if (!background || _loadingOlder) {
      setState(() {
        _loadingOlder = false;
        if (!background) {
          _loading = true;
          _error = null;
        }
      });
    }
    try {
      final page = await ref
          .read(chatApiProvider)
          .listDirectMessages(
            conversationId: widget.conversationId,
            page: 1,
            size: 20,
            markRead: false,
            search: filters.query,
            senderId: filters.senderId,
            startAt: filters.startAt,
            endAt: filters.endAt,
          );
      if (!current()) return;
      setState(() {
        final oldestRefreshed = page.items.firstOrNull;
        final byId = {
          if (background && page.hasNext && oldestRefreshed != null)
            for (final message in _messages)
              if (_newestFirst(message, oldestRefreshed) > 0)
                message.messageId: message,
          for (final message in page.items) message.messageId: message,
        };
        for (final entry in changes.entries) {
          final message = entry.value;
          if (message == null) {
            byId.remove(entry.key);
          } else {
            byId[entry.key] = message;
          }
        }
        if (background) {
          for (final message in _messages) {
            if (!byId.containsKey(message.messageId)) {
              _trackDeletion(message.messageId);
            }
          }
        }
        _messages =
            byId.values
                .where(
                  (message) => !_deletedMessages.contains(message.messageId),
                )
                .map(_withoutDeletedQuote)
                .toList()
              ..sort(_newestFirst);
        if (!background || _page == 1 || !page.hasNext) {
          _page = 1;
          _hasNext = page.hasNext;
        }
        _loading = false;
      });
    } catch (e) {
      if (!current() || background) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    } finally {
      if (identical(_liveDirectChanges, changes)) _liveDirectChanges = null;
      if (current()) {
        _loadingLatest = false;
        _scheduleReadSync();
      }
    }
  }

  int _newestFirst(V2DirectMessage left, V2DirectMessage right) {
    final leftTime =
        DateTime.tryParse(left.createdAt)?.millisecondsSinceEpoch ?? 0;
    final rightTime =
        DateTime.tryParse(right.createdAt)?.millisecondsSinceEpoch ?? 0;
    final byTime = rightTime.compareTo(leftTime);
    return byTime == 0 ? right.messageId.compareTo(left.messageId) : byTime;
  }

  Future<void> _loadViewer(bool Function() current) async {
    try {
      final pair = await ref.read(tokenStoreProvider).read();
      final userId = pair == null
          ? null
          : realtimeUserIdFromAccessToken(pair.accessToken);
      if (current() && _viewerId != userId) setState(() => _viewerId = userId);
    } catch (_) {
      // The backend still authenticates every request. Keep actions hidden if ownership is unknown.
      if (current() && _viewerId != null) setState(() => _viewerId = null);
    }
  }

  bool _canDelete(V2DirectMessage message) =>
      message.conversationId == widget.conversationId &&
      message.author.userId == _viewerId &&
      message.canDelete &&
      !message.isDeleted;

  Future<void> _deleteDirectMessage(V2DirectMessage message) async {
    final current = _binding.capture();
    if (!current() || !_canDelete(message) || _deletingMessageId != null) {
      return;
    }
    setState(() => _deletingMessageId = message.messageId);
    final l10n = AppLocalizations.of(context);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.t('chat.delete_message')),
          content: Text(l10n.t('chat.delete_direct_message_body')),
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
      if (confirmed != true || !current() || !_canDelete(message)) return;
      await ref
          .read(chatApiProvider)
          .deleteDirectMessage(
            conversationId: message.conversationId,
            messageId: message.messageId,
          );
      if (!current()) return;
      setState(() => _removeMessage(message.messageId));
    } catch (error) {
      if (current()) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorView.describe(context, error))),
        );
      }
    } finally {
      if (current()) setState(() => _deletingMessageId = null);
    }
  }

  Future<void> _loadOlder() async {
    if (_loading || _loadingLatest || _loadingOlder || !_hasNext) return;
    final ownsPage = _binding.capture();
    if (!ownsPage()) return;
    final revision = _readRevision;
    final filters = _filters;
    bool current() => ownsPage() && revision == _readRevision;
    final changes = <int, V2DirectMessage?>{};
    _liveDirectChanges = changes;
    setState(() => _loadingOlder = true);
    final nextPage = _page + 1;
    try {
      // Page-based history only — server has no reliable `before` cursor.
      final page = await ref
          .read(chatApiProvider)
          .listDirectMessages(
            conversationId: widget.conversationId,
            page: nextPage,
            size: 20,
            markRead: false,
            search: filters.query,
            senderId: filters.senderId,
            startAt: filters.startAt,
            endAt: filters.endAt,
          );
      if (!current()) return;
      if (page.page != nextPage) {
        throw const FormatException('Unexpected direct history page');
      }
      final existing = _messages.map((m) => m.messageId).toSet();
      final older = page.items.reversed
          .where(
            (m) =>
                !existing.contains(m.messageId) &&
                !_deletedMessages.contains(m.messageId) &&
                !(changes.containsKey(m.messageId) &&
                    changes[m.messageId] == null),
          )
          .map(_withoutDeletedQuote)
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
      if (identical(_liveDirectChanges, changes)) _liveDirectChanges = null;
      if (current()) _scheduleReadSync();
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

  void _showMessage(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _pickAttachments() async {
    final current = _binding.capture();
    if (!current() || _sending || _pickingAttachment) return;
    setState(() => _pickingAttachment = true);
    try {
      final picked = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: false,
        withReadStream: kIsWeb,
      );
      if (!current() || picked == null) return;
      final l10n = AppLocalizations.of(context);
      if (_attachments.length + picked.files.length > directMessageMaxMedia) {
        _showMessage(l10n.t('chat.attachment_count'));
      } else if (picked.files.any(
        (file) => file.size > chatAttachmentMaxBytes,
      )) {
        _showMessage(l10n.t('compose.media_size'));
      } else if (picked.files.any((file) => file.size <= 0)) {
        _showMessage(l10n.t('chat.attachment_empty'));
      } else {
        setState(() => _attachments.addAll(picked.files));
      }
    } catch (error) {
      if (current()) _showMessage(ErrorView.describe(context, error));
    } finally {
      if (current()) setState(() => _pickingAttachment = false);
    }
  }

  Future<List<int>?> _uploadAttachments(
    bool Function() current,
    CancelToken cancel,
  ) async {
    if (_attachments.isEmpty) return const [];
    final api = ref.read(mediaApiProvider);
    final ids = <int>[];
    for (final file in List.of(_attachments)) {
      if (!current()) return null;
      if (_uploadedAttachments[file] case final uploaded?) {
        ids.add(uploaded);
        continue;
      }
      try {
        final asset = await uploadChatAttachment(api, file, cancel);
        if (!current()) return null;
        if (asset.privateContentPath == null) {
          throw const FormatException('Invalid private attachment receipt');
        }
        _uploadedAttachments[file] = asset.mediaId;
        ids.add(asset.mediaId);
      } catch (_) {
        if (!current()) return null;
        if (file.bytes != null || file.readStream == null) rethrow;
        setState(() => _attachments.remove(file));
        _showMessage(
          '${file.name}: ${AppLocalizations.of(context).t('chat.attachment_reselect')}',
        );
        return null;
      }
    }
    return ids;
  }

  Future<void> _send() async {
    final draft = _composer.text;
    final text = draft.trim();
    if ((text.isEmpty && _attachments.isEmpty) ||
        _sending ||
        _pickingAttachment) {
      return;
    }
    final current = _binding.capture();
    if (!current()) return;
    if (!validDirectMessageContent(text)) {
      _showMessage(AppLocalizations.of(context).t('chat.dm.content_size'));
      return;
    }
    final replyId = _replyTo?.messageId;
    _typing.stop();
    final cancel = CancelToken();
    _sendRequest = cancel;
    setState(() => _sending = true);
    try {
      final ids = await _uploadAttachments(current, cancel);
      if (!current() || ids == null) return;
      if (_deletedMessages.contains(replyId)) {
        _showMessage(AppLocalizations.of(context).t('chat.deleted_message'));
        return;
      }
      final message = await ref
          .read(chatApiProvider)
          .sendDirectMessage(
            conversationId: widget.conversationId,
            content: text,
            mediaIds: ids,
            replyToMessageId: replyId,
            cancelToken: cancel,
          );
      if (!current()) return;
      setState(() {
        _animateIds.add(message.messageId);
        _upsertMessage(message);
        if (_composer.text == draft) _composer.clear();
        _attachments.clear();
        _uploadedAttachments.clear();
        _replyTo = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } catch (e) {
      if (current()) _showMessage(ErrorView.describe(context, e));
    } finally {
      if (current()) {
        _sendRequest = null;
        setState(() => _sending = false);
      }
    }
  }

  String _formatTime(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return DateFormat.Hm().format(dt.toLocal());
  }

  DateTime? _calendarDay(String iso) {
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return null;
    return DateTime(dt.year, dt.month, dt.day);
  }

  bool _withinFiveMinutes(V2DirectMessage a, V2DirectMessage b) {
    final da = DateTime.tryParse(a.createdAt);
    final db = DateTime.tryParse(b.createdAt);
    if (da == null || db == null) return false;
    return da.difference(db).inMilliseconds.abs() <= 300000;
  }

  String _formatDayLabel(
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

  String get _appBarTitle {
    final title = widget.title?.trim();
    if (title != null && title.isNotEmpty) return title;
    return AppLocalizations.of(context).t('chat.conversation');
  }

  Widget _buildComposer(AppLocalizations l10n, ThemeData theme) {
    final scheme = theme.colorScheme;
    final busy = _sending || _pickingAttachment;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_typing.hasRemoteTyping)
          Padding(
            padding: const EdgeInsets.only(left: 10, bottom: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _TypingDots(color: scheme.primary),
                const SizedBox(width: 6),
                Text(
                  l10n.t('chat.dm.typing'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        if (_replyTo case final reply?)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Expanded(
                  child: ChatReplyQuote(
                    replyTo: V2ChatMessageReply(
                      messageId: reply.messageId,
                      authorName: reply.author.displayName.isEmpty
                          ? reply.author.username
                          : reply.author.displayName,
                      content: reply.content.isEmpty
                          ? reply.media.firstOrNull?.fileName ?? ''
                          : reply.content,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: l10n.t('chat.dm.cancel_reply'),
                  onPressed: busy
                      ? null
                      : () => setState(() => _replyTo = null),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ),
        if (_attachments.isNotEmpty)
          SizedBox(
            height: 48,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _attachments.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (_, index) {
                final file = _attachments[index];
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 224),
                    child: InputChip(
                      label: Text(
                        file.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onDeleted: busy
                          ? null
                          : () => setState(() {
                              _attachments.remove(file);
                              _uploadedAttachments.remove(file);
                            }),
                    ),
                  ),
                );
              },
            ),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              key: const Key('dm-attach-button'),
              tooltip: l10n.t('chat.upload_attachment'),
              color: scheme.onSurfaceVariant,
              icon: const Icon(Icons.attach_file_rounded),
              onPressed: busy || _attachments.length >= directMessageMaxMedia
                  ? null
                  : _pickAttachments,
            ),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: SocialColors.of(context).surfaceSubtle,
                  borderRadius: BorderRadius.circular(AppRadius.tile),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: TextField(
                  key: const Key('dm-composer-field'),
                  controller: _composer,
                  maxLines: 5,
                  minLines: 1,
                  textInputAction: TextInputAction.send,
                  onChanged: (text) =>
                      setState(() => _typing.input(text.trim().isNotEmpty)),
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: l10n.t('chat.message_hint'),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    isDense: true,
                    filled: false,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _composer,
              builder: (context, value, _) {
                final hasContent =
                    value.text.trim().isNotEmpty || _attachments.isNotEmpty;
                return AnimatedScale(
                  scale: hasContent ? 1.0 : 0.92,
                  duration: AppMotion.resolve(context, AppMotion.fast),
                  curve: AppMotion.emphasizedDecelerate,
                  child: IconButton.filled(
                    key: const Key('dm-send-button'),
                    tooltip: l10n.t('chat.dm.send'),
                    style: IconButton.styleFrom(
                      disabledBackgroundColor: scheme.surfaceContainerHigh,
                      disabledForegroundColor: scheme.onSurfaceVariant,
                    ),
                    icon: _sending
                        ? SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: scheme.onSurfaceVariant,
                            ),
                          )
                        : const Icon(Icons.send_rounded, size: 19),
                    onPressed: busy || !hasContent ? null : _send,
                  ),
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    _observeDisplayedMessages();
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final topInset = kToolbarHeight + MediaQuery.paddingOf(context).top;
    final receipt = _messages.fold(
      0,
      (highest, message) =>
          !message.isDeleted &&
              message.author.userId == _viewerId &&
              message.messageId <= _peerRead &&
              message.messageId > highest
          ? message.messageId
          : highest,
    );
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
            key: const Key('dm-call-menu'),
            onSelected: (mode) {
              final current = _binding.capture();
              unawaited(
                ref
                    .read(callControllerProvider)
                    .start(
                      conversationId: widget.conversationId,
                      mode: mode,
                      peerName: widget.title,
                      current: () =>
                          mounted &&
                          current() &&
                          ModalRoute.isCurrentOf(context) == true,
                    ),
              );
            },
          ),
          IconButton(
            key: const Key('dm-search-toggle'),
            tooltip: l10n.t(
              _searchOpen ? 'common.close' : 'chat.dm.search_messages',
            ),
            onPressed:
                _sending || _pickingAttachment || _deletingMessageId != null
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
                        inputKey: const Key('dm-search-input'),
                        title: l10n.t('chat.dm.search_messages'),
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
                        ? ErrorView(error: _error!, onRetry: _reload)
                        : _messages.isEmpty && !_hasNext
                        ? EmptyView(
                            message: l10n.t(
                              _filters.active
                                  ? 'chat.search_empty'
                                  : 'chat.dm.empty',
                            ),
                          )
                        : LayoutBuilder(
                            builder: (context, constraints) {
                              final maxBubbleWidth = math.min(
                                constraints.maxWidth * 0.72,
                                460.0,
                              );
                              return ListView.builder(
                                key: _viewport,
                                controller: _scrollController,
                                reverse: true,
                                padding: EdgeInsets.fromLTRB(
                                  12,
                                  _searchOpen ? 12 : topInset + 12,
                                  12,
                                  _searchOpen ? 12 : _composerHeight + 12,
                                ),
                                itemCount:
                                    _messages.length + (_hasNext ? 1 : 0),
                                itemBuilder: (_, i) {
                                  if (i == _messages.length) {
                                    return TextButton(
                                      onPressed: _loadingOlder
                                          ? null
                                          : _loadOlder,
                                      child: Text(l10n.t('chat.dm.load_older')),
                                    );
                                  }
                                  final message = _messages[i];
                                  final prev = i + 1 < _messages.length
                                      ? _messages[i + 1]
                                      : null;
                                  final next = i - 1 >= 0
                                      ? _messages[i - 1]
                                      : null;
                                  final day = _calendarDay(message.createdAt);
                                  final prevDay = prev == null
                                      ? null
                                      : _calendarDay(prev.createdAt);
                                  final showDatePill =
                                      day != null && day != prevDay;
                                  final samePrev =
                                      prev != null &&
                                      !message.isDeleted &&
                                      !prev.isDeleted &&
                                      prev.author.userId ==
                                          message.author.userId &&
                                      day == prevDay &&
                                      _withinFiveMinutes(prev, message);
                                  final sameNext =
                                      next != null &&
                                      !message.isDeleted &&
                                      !next.isDeleted &&
                                      next.author.userId ==
                                          message.author.userId &&
                                      _calendarDay(next.createdAt) == day &&
                                      _withinFiveMinutes(message, next);
                                  final bubble = _MessageBubble(
                                    key: _bubbleKeys.putIfAbsent(
                                      message.messageId,
                                      GlobalKey.new,
                                    ),
                                    message: message,
                                    formatTime: _formatTime,
                                    isSelf: message.author.userId == _viewerId,
                                    samePrev: samePrev,
                                    sameNext: sameNext,
                                    maxWidth: maxBubbleWidth,
                                    animateEntrance: _animateIds.remove(
                                      message.messageId,
                                    ),
                                    showReadReceipt:
                                        message.messageId == receipt,
                                    onReply:
                                        _searchOpen ||
                                            message.isDeleted ||
                                            _sending
                                        ? null
                                        : () {
                                            if (_binding.capture()() &&
                                                _visibleMessage(
                                                      message.messageId,
                                                    ) !=
                                                    null) {
                                              setState(
                                                () => _replyTo = message,
                                              );
                                            }
                                          },
                                    onReact:
                                        _searchOpen ||
                                            message.isDeleted ||
                                            _reactionRequests.containsKey(
                                              message.messageId,
                                            )
                                        ? null
                                        : (emoji) => unawaited(
                                            _react(message.messageId, emoji),
                                          ),
                                    onDelete:
                                        !_searchOpen &&
                                            _canDelete(message) &&
                                            _deletingMessageId == null
                                        ? () => unawaited(
                                            _deleteDirectMessage(message),
                                          )
                                        : null,
                                  );
                                  if (!showDatePill) return bubble;
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
                                            _formatDayLabel(context, l10n, day),
                                            style: theme.textTheme.labelSmall
                                                ?.copyWith(
                                                  color:
                                                      scheme.onSurfaceVariant,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                          ),
                                        ),
                                      ),
                                      bubble,
                                    ],
                                  );
                                },
                              );
                            },
                          ),
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
                        margin: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                        padding: const EdgeInsets.all(8),
                        child: _buildComposer(l10n, theme),
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

class _TypingDots extends StatefulWidget {
  const _TypingDots({required this.color});

  final Color color;

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
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

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    super.key,
    required this.message,
    required this.formatTime,
    required this.isSelf,
    required this.samePrev,
    required this.sameNext,
    required this.maxWidth,
    required this.animateEntrance,
    required this.showReadReceipt,
    this.onDelete,
    this.onReply,
    this.onReact,
  });

  final V2DirectMessage message;
  final String Function(String) formatTime;
  final bool isSelf;
  final bool samePrev;
  final bool sameNext;
  final double maxWidth;
  final bool animateEntrance;
  final bool showReadReceipt;
  final VoidCallback? onDelete;
  final VoidCallback? onReply;
  final ValueChanged<String>? onReact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final social = SocialColors.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context);
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
    final secondaryColor = isSelf
        ? (isDark
              ? scheme.onSurfaceVariant
              : scheme.onPrimary.withValues(alpha: 0.78))
        : scheme.onSurfaceVariant;
    final displayName = message.author.displayName.isEmpty
        ? message.author.username
        : message.author.displayName;
    final radius = BorderRadius.only(
      topLeft: Radius.circular(isSelf ? 18 : (samePrev ? 4 : 18)),
      topRight: Radius.circular(isSelf ? (samePrev ? 4 : 18) : 18),
      bottomLeft: Radius.circular(isSelf ? 18 : 4),
      bottomRight: Radius.circular(isSelf ? 4 : 18),
    );
    final child = Align(
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
                      if (!isSelf &&
                          !samePrev &&
                          message.author.displayName.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Text(
                            message.author.displayName,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      if (!message.isDeleted && message.replyTo != null) ...[
                        ChatReplyQuote(replyTo: message.replyTo!),
                        const SizedBox(height: 6),
                      ],
                      if (message.isDeleted ||
                          message.content.isNotEmpty ||
                          message.media.isEmpty)
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
                            fontStyle:
                                message.isDeleted || message.content.isEmpty
                                ? FontStyle.italic
                                : null,
                          ),
                        ),
                      if (!message.isDeleted)
                        ContentLinkPreview(content: message.content),
                      if (!message.isDeleted && message.media.isNotEmpty)
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            for (final asset in message.media)
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 220,
                                ),
                                child: PrivateAttachmentButton(
                                  key: ValueKey(asset.mediaId),
                                  asset: asset,
                                ),
                              ),
                          ],
                        ),
                      if (!message.isDeleted && message.reactions.isNotEmpty)
                        Wrap(
                          spacing: 6,
                          children: [
                            for (final reaction in message.reactions)
                              ChatReactionChip(
                                key: ValueKey(
                                  'dm-reaction-${message.messageId}-${reaction.emoji}',
                                ),
                                reaction: reaction,
                                onPressed: onReact == null
                                    ? null
                                    : () => onReact!(reaction.emoji),
                              ),
                          ],
                        ),
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            formatTime(message.createdAt),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: secondaryColor,
                              fontSize: 11,
                            ),
                          ),
                          if (showReadReceipt)
                            Padding(
                              padding: const EdgeInsetsDirectional.only(
                                start: 6,
                              ),
                              child: Text(
                                l10n.t('chat.dm.read'),
                                key: ValueKey('dm-read-${message.messageId}'),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: secondaryColor,
                                ),
                              ),
                            ),
                          if (!message.isDeleted) ...[
                            IconButton(
                              key: ValueKey('dm-reply-${message.messageId}'),
                              tooltip: l10n.t('chat.reply'),
                              visualDensity: VisualDensity.compact,
                              onPressed: onReply,
                              icon: Icon(
                                Icons.reply_rounded,
                                size: 18,
                                color: secondaryColor,
                              ),
                            ),
                            PopupMenuButton<String>(
                              key: ValueKey(
                                'dm-reaction-menu-${message.messageId}',
                              ),
                              tooltip: l10n.t('chat.dm.react'),
                              enabled: onReact != null,
                              onSelected: onReact,
                              icon: Icon(
                                Icons.add_reaction_outlined,
                                size: 18,
                                color: secondaryColor,
                              ),
                              itemBuilder: (_) => [
                                for (final emoji in const [
                                  '👍',
                                  '❤️',
                                  '😂',
                                  '🎉',
                                  '😮',
                                  '😢',
                                ])
                                  PopupMenuItem(
                                    value: emoji,
                                    child: Text(emoji),
                                  ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (onDelete != null)
                IconButton(
                  key: ValueKey('dm-delete-${message.messageId}'),
                  tooltip: AppLocalizations.of(
                    context,
                  ).t('chat.delete_message'),
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline, size: 18),
                ),
              if (isSelf) const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
    if (!animateEntrance || AppMotion.reduced(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AppMotion.base,
      curve: AppMotion.emphasizedDecelerate,
      builder: (context, t, inner) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * 10),
          child: Transform.scale(scale: 0.92 + 0.08 * t, child: inner),
        ),
      ),
      child: child,
    );
  }
}
