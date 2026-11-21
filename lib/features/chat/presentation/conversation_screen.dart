import 'dart:async';

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
import 'chat_realtime_binding.dart';

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
  late final ChatRealtimeBinding _binding;
  late final AppLifecycleListener _lifecycle;
  Timer? _readSyncTimer;
  bool _readSyncPending = false;
  bool _syncingRead = false;
  int _readRevision = 0;
  List<V2DirectMessage> _messages = [];
  Map<int, V2DirectMessage?>? _liveDirectChanges;
  int? _viewerId;
  int? _deletingMessageId;
  bool _loading = true;
  bool _loadingOlder = false;
  bool _hasNext = false;
  bool _sending = false;
  int _page = 1;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _binding = ChatRealtimeBinding(
      tokenStore: ref.read(tokenStoreProvider),
      onEvent: _onRealtime,
      onReset: _reset,
      onReload: () => unawaited(_load()),
    );
    _binding.bind(ref.read(realtimeServiceProvider));
    _lifecycle = AppLifecycleListener(onResume: _scheduleReadSync);
    ref.listenManual(realtimeServiceProvider, (_, next) => _binding.bind(next));
    _scrollController.addListener(_onScroll);
    unawaited(_load());
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
    _readSyncPending = false;
    _liveDirectChanges = null;
    _viewerId = _deletingMessageId = null;
    setState(() {
      _messages = [];
      _composer.clear();
      _page = 1;
      _error = null;
      _loading = true;
      _hasNext = _loadingOlder = _sending = false;
    });
  }

  @override
  void dispose() {
    _readSyncTimer?.cancel();
    _lifecycle.dispose();
    _binding.dispose();
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

  int? _eventInt(Object? value) {
    return value is int && value > 0 && value <= 9007199254740991
        ? value
        : null;
  }

  void _onRealtime(Map<String, dynamic> event) {
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
      setState(() {
        _liveDirectChanges?[messageId] = null;
        _messages.removeWhere((m) => m.messageId == messageId);
      });
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
      final isNew = !_messages.any(
        (item) => item.messageId == message.messageId,
      );
      setState(() => _upsertMessage(message));
      if (isNew && message.author.userId != _viewerId) {
        _readSyncPending = true;
        _scheduleReadSync();
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } catch (_) {
      // Ignore malformed realtime payloads.
    }
  }

  void _upsertMessage(V2DirectMessage message) {
    if (_liveDirectChanges?.containsKey(message.messageId) == true &&
        _liveDirectChanges?[message.messageId] == null) {
      return;
    }
    _liveDirectChanges?[message.messageId] = message;
    final index = _messages.indexWhere((m) => m.messageId == message.messageId);
    if (index >= 0) {
      _messages[index] = message;
    } else {
      // reverse:true list expects newest-first.
      _messages.insert(0, message);
    }
  }

  bool get _canSyncRead {
    final state = WidgetsBinding.instance.lifecycleState;
    return mounted &&
        ModalRoute.of(context)?.isCurrent == true &&
        (state == null || state == AppLifecycleState.resumed) &&
        !_loading &&
        !_loadingOlder &&
        !_syncingRead;
  }

  void _scheduleReadSync() {
    if (!_readSyncPending || _readSyncTimer != null || !_canSyncRead) return;
    final current = _binding.capture();
    _readSyncTimer = Timer(const Duration(milliseconds: 250), () async {
      _readSyncTimer = null;
      if (!current() || !_readSyncPending || !_canSyncRead) return;
      _readSyncPending = false;
      _syncingRead = true;
      try {
        await _load(background: true);
      } finally {
        _syncingRead = false;
        _scheduleReadSync();
      }
    });
  }

  Future<void> _load({bool background = false}) async {
    final ownsPage = _binding.capture();
    if (!ownsPage()) return;
    if (!background) unawaited(_loadViewer(ownsPage));
    final revision = ++_readRevision;
    final changes = <int, V2DirectMessage?>{};
    _liveDirectChanges = changes;
    bool current() => ownsPage() && revision == _readRevision;
    if (!background) {
      setState(() {
        _loading = true;
        _loadingOlder = false;
        _error = null;
      });
    }
    try {
      final page = await ref
          .read(chatApiProvider)
          .listDirectMessages(
            conversationId: widget.conversationId,
            page: 1,
            size: 20,
          );
      if (!current()) return;
      setState(() {
        final byId = {
          if (background)
            for (final message in _messages) message.messageId: message,
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
        _messages = byId.values.toList()
          ..sort((left, right) {
            final leftTime =
                DateTime.tryParse(left.createdAt)?.millisecondsSinceEpoch ?? 0;
            final rightTime =
                DateTime.tryParse(right.createdAt)?.millisecondsSinceEpoch ?? 0;
            final byTime = rightTime.compareTo(leftTime);
            return byTime == 0
                ? right.messageId.compareTo(left.messageId)
                : byTime;
          });
        if (!background || _page == 1) {
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
      if (current()) _scheduleReadSync();
    }
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
      setState(() {
        _liveDirectChanges?[message.messageId] = null;
        _messages.removeWhere((item) => item.messageId == message.messageId);
      });
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
    if (_loading || _loadingOlder || _syncingRead || !_hasNext) return;
    final ownsPage = _binding.capture();
    if (!ownsPage()) return;
    final revision = _readRevision;
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
                !(changes.containsKey(m.messageId) &&
                    changes[m.messageId] == null),
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

  Future<void> _send() async {
    final draft = _composer.text;
    final text = draft.trim();
    if (text.isEmpty || _sending) return;
    final current = _binding.capture();
    if (!current()) return;
    setState(() => _sending = true);
    try {
      final message = await ref
          .read(chatApiProvider)
          .sendDirectMessage(
            conversationId: widget.conversationId,
            content: text,
          );
      if (!current()) return;
      setState(() {
        _upsertMessage(message);
        if (_composer.text == draft) _composer.clear();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } catch (e) {
      if (!current()) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      if (current()) setState(() => _sending = false);
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
    if (ModalRoute.isCurrentOf(context) == true) _scheduleReadSync();
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
                    : _messages.isEmpty && !_hasNext
                    ? EmptyView(message: l10n.t('chat.dm.empty'))
                    : ListView.builder(
                        controller: _scrollController,
                        reverse: true,
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                        itemCount: _messages.length + (_hasNext ? 1 : 0),
                        itemBuilder: (_, i) {
                          if (i == _messages.length) {
                            return TextButton(
                              onPressed: _loadingOlder ? null : _loadOlder,
                              child: Text(l10n.t('chat.dm.load_older')),
                            );
                          }
                          final message = _messages[i];
                          return _MessageBubble(
                            message: message,
                            formatTime: _formatTime,
                            isSelf: message.author.userId == _viewerId,
                            onDelete:
                                _canDelete(message) &&
                                    _deletingMessageId == null
                                ? () => unawaited(_deleteDirectMessage(message))
                                : null,
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
    required this.isSelf,
    this.onDelete,
  });

  final V2DirectMessage message;
  final String Function(String) formatTime;
  final bool isSelf;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                          fontStyle:
                              message.isDeleted || message.content.isEmpty
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
  }
}
