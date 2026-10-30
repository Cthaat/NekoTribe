import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../data/ai_writing_api.dart';

class AiWritingScreen extends ConsumerStatefulWidget {
  const AiWritingScreen({super.key});
  @override
  ConsumerState<AiWritingScreen> createState() => _AiWritingScreenState();
}

class _AiWritingScreenState extends ConsumerState<AiWritingScreen> {
  final _input = TextEditingController();
  String? _conversation;
  List<AiWritingMessage> _messages = [];
  bool _busy = false;
  bool _needsRefresh = false;
  String? _notice;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final id = _conversation;
    if (id == null) return;
    final result = await _readHistory(id);
    if (!mounted) return;
    setState(() {
      _messages = result;
      _needsRefresh = false;
    });
  }

  Future<List<AiWritingMessage>> _readHistory(String id) async {
    final api = ref.read(aiWritingApiProvider);
    final result = <AiWritingMessage>[];
    var after = 0;
    while (true) {
      final page = await api.listMessages(id, afterSequence: after);
      for (final message in page) {
        if (message.sequence <= after) {
          throw const FormatException('Invalid AI history order');
        }
        after = message.sequence;
        result.add(message);
      }
      if (page.length < 50) break;
    }
    return result;
  }

  Future<void> _openHistory() async {
    if (_busy) return;
    final id = await showDialog<String>(
      context: context,
      builder: (_) => _HistoryDialog(api: ref.read(aiWritingApiProvider)),
    );
    if (!mounted || id == null) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final messages = await _readHistory(id);
      if (!mounted) return;
      _input.clear();
      setState(() {
        _conversation = id;
        _messages = messages;
        _needsRefresh = false;
      });
    } catch (_) {
      if (mounted) setState(() => _notice = 'ai.writing.history_failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() async {
    final content = _input.text.trim();
    if (_busy || _needsRefresh || content.isEmpty) return;
    if (utf8.encode(content).length > 65536) {
      setState(() => _notice = 'ai.writing.too_long');
      return;
    }
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final api = ref.read(aiWritingApiProvider);
      final id = _conversation ?? await api.createConversation();
      if (!mounted) return;
      _conversation = id;
      try {
        await api.appendMessage(id, content);
      } catch (_) {
        if (mounted) {
          setState(() {
            _needsRefresh = true;
            _notice = 'ai.writing.append_unknown';
          });
        }
        return;
      }
      if (!mounted) return;
      _input.clear();
      await _refresh();
      if (!mounted) return;
      await api.generate(id);
      if (!mounted) return;
      await _refresh();
    } catch (_) {
      if (mounted) {
        setState(() {
          _needsRefresh = _conversation != null;
          _notice = 'ai.writing.failed';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reconcile({bool generate = false}) async {
    if (_busy || _conversation == null) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await _refresh();
      if (!mounted) return;
      if (generate && _messages.isNotEmpty && _messages.last.role == 'user') {
        await ref.read(aiWritingApiProvider).generate(_conversation!);
        if (!mounted) return;
        await _refresh();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _needsRefresh = true;
          _notice = 'ai.writing.failed';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final id = _conversation;
    if (_busy || id == null) return;
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.t('ai.writing.delete_title')),
        content: Text(l10n.t('ai.writing.delete_prompt')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.t('ai.writing.cancel')),
          ),
          TextButton(
            key: const Key('ai-writing-confirm-delete'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.t('ai.writing.delete')),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await ref.read(aiWritingApiProvider).deleteConversation(id);
      if (!mounted) return;
      _input.clear();
      setState(() {
        _conversation = null;
        _messages = [];
        _needsRefresh = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _needsRefresh = true;
          _notice = 'ai.writing.delete_unknown';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final canRetry = _messages.isNotEmpty && _messages.last.role == 'user';
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('ai.writing.title')),
        actions: [
          IconButton(
            key: const Key('ai-writing-history'),
            tooltip: l10n.t('ai.writing.history'),
            onPressed: _busy ? null : _openHistory,
            icon: const Icon(Icons.history),
          ),
          if (_conversation != null)
            IconButton(
              key: const Key('ai-writing-new'),
              tooltip: l10n.t('ai.writing.new'),
              onPressed: _busy
                  ? null
                  : () {
                      _input.clear();
                      setState(() {
                        _conversation = null;
                        _messages = [];
                        _needsRefresh = false;
                        _notice = null;
                      });
                    },
              icon: const Icon(Icons.add_comment_outlined),
            ),
          if (_conversation != null)
            IconButton(
              key: const Key('ai-writing-delete'),
              tooltip: l10n.t('ai.writing.delete'),
              onPressed: _busy ? null : _delete,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  l10n.t('ai.writing.description'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
              Expanded(
                child: _messages.isEmpty
                    ? Center(child: Text(l10n.t('ai.writing.empty')))
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          final message = _messages[index];
                          final isUser = message.role == 'user';
                          return Align(
                            alignment: isUser
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Card(
                              color: isUser
                                  ? theme.colorScheme.primaryContainer
                                  : theme.colorScheme.surfaceContainerHighest,
                              child: Padding(
                                padding: const EdgeInsets.all(14),
                                child: SelectableText(message.content),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              if (_notice != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    l10n.t(_notice!),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              if (_needsRefresh)
                TextButton(
                  key: const Key('ai-writing-refresh'),
                  onPressed: _busy ? null : () => _reconcile(),
                  child: Text(l10n.t('ai.writing.refresh')),
                ),
              if (canRetry)
                TextButton(
                  key: const Key('ai-writing-retry'),
                  onPressed: _busy ? null : () => _reconcile(generate: true),
                  child: Text(l10n.t('ai.writing.retry')),
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('ai-writing-input'),
                        controller: _input,
                        enabled: !_busy && !_needsRefresh,
                        minLines: 1,
                        maxLines: 5,
                        decoration: InputDecoration(
                          hintText: l10n.t('ai.writing.placeholder'),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      key: const Key('ai-writing-send'),
                      onPressed: _busy || _needsRefresh ? null : _send,
                      tooltip: l10n.t('ai.writing.send'),
                      icon: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.send),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryDialog extends StatefulWidget {
  const _HistoryDialog({required this.api});
  final AiWritingApi api;
  @override
  State<_HistoryDialog> createState() => _HistoryDialogState();
}

class _HistoryDialogState extends State<_HistoryDialog> {
  final _items = <AiConversation>[];
  String? _next;
  bool _loading = false;
  bool _first = true;
  bool _failed = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final page = await widget.api.listConversations(
        afterId: _first ? null : _next,
      );
      if (!mounted) return;
      if (page.nextCursor != null &&
          _next != null &&
          page.nextCursor!.compareTo(_next!) <= 0) {
        throw const FormatException('Invalid AI cursor');
      }
      setState(() {
        _items.addAll(page.items.where((item) => item.purpose == 'writing'));
        _next = page.nextCursor;
        _first = false;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.t('ai.writing.history')),
      content: SizedBox(
        width: 500,
        height: MediaQuery.sizeOf(context).height * 0.5,
        child: Column(
          children: [
            Expanded(
              child: _items.isEmpty && !_loading && !_failed
                  ? Center(child: Text(l10n.t('ai.writing.history_empty')))
                  : ListView.builder(
                      itemCount: _items.length,
                      itemBuilder: (context, index) {
                        final item = _items[index];
                        return ListTile(
                          title: Text(
                            item.title?.isNotEmpty == true
                                ? item.title!
                                : item.id,
                          ),
                          subtitle: Text(item.updatedAt),
                          onTap: () => Navigator.pop(context, item.id),
                        );
                      },
                    ),
            ),
            if (_loading) const CircularProgressIndicator(),
            if (_failed) Text(l10n.t('ai.writing.history_failed')),
            if (!_loading && (_failed || _next != null))
              TextButton(
                onPressed: _load,
                child: Text(
                  l10n.t(_failed ? 'ai.writing.retry' : 'ai.writing.more'),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.t('ai.writing.cancel')),
        ),
      ],
    );
  }
}
