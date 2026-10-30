import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../data/ai_writing_api.dart';

class AiWritingScreen extends ConsumerStatefulWidget {
  const AiWritingScreen({super.key, this.knowledge = false});
  final bool knowledge;
  @override
  ConsumerState<AiWritingScreen> createState() => _AiWritingScreenState();
}

class _AiWritingScreenState extends ConsumerState<AiWritingScreen> {
  final _input = TextEditingController();
  final _search = TextEditingController();
  String? _conversation;
  List<AiWritingMessage> _messages = [];
  bool _busy = false;
  bool _needsRefresh = false;
  String? _notice;

  @override
  void dispose() {
    _input.dispose();
    _search.dispose();
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
      builder: (_) => _HistoryDialog(
        api: ref.read(aiWritingApiProvider),
        knowledge: widget.knowledge,
      ),
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
      _search.clear();
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
    final phrase = widget.knowledge ? _validatedSearch() : null;
    if (widget.knowledge && phrase == null) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final api = ref.read(aiWritingApiProvider);
      final id =
          _conversation ??
          await (widget.knowledge
              ? api.createKnowledgeConversation()
              : api.createConversation());
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
      await _generate(api, id, phrase);
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
    final phrase = generate && widget.knowledge ? _validatedSearch() : null;
    if (generate && widget.knowledge && phrase == null) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await _refresh();
      if (!mounted) return;
      if (generate && _messages.isNotEmpty && _messages.last.role == 'user') {
        await _generate(ref.read(aiWritingApiProvider), _conversation!, phrase);
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

  String? _validatedSearch() {
    final raw = _search.text;
    final units = raw.codeUnits;
    for (var i = 0; i < units.length; i++) {
      final n = units[i];
      if (n >= 0xd800 && n <= 0xdbff) {
        if (i + 1 >= units.length ||
            units[i + 1] < 0xdc00 ||
            units[i + 1] > 0xdfff) {
          setState(() => _notice = 'ai.knowledge.search_invalid');
          return null;
        }
        i++;
      } else if (n >= 0xdc00 && n <= 0xdfff) {
        setState(() => _notice = 'ai.knowledge.search_invalid');
        return null;
      }
    }
    const spaces =
        r'[\u0009-\u000d\u0020\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]';
    final phrase = raw
        .replaceFirst(RegExp('^$spaces+'), '')
        .replaceFirst(RegExp('$spaces+\$'), '');
    if (phrase.isEmpty ||
        utf8.encode(phrase).length > 256 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(phrase)) {
      setState(() => _notice = 'ai.knowledge.search_invalid');
      return null;
    }
    return phrase;
  }

  Future<void> _generate(AiWritingApi api, String id, String? phrase) async {
    if (!widget.knowledge) {
      await api.generate(id);
    } else if (!await api.generateKnowledge(id, searchPhrase: phrase) &&
        mounted) {
      setState(() => _notice = 'ai.knowledge.insufficient');
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
      _search.clear();
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
        title: Text(
          l10n.t(widget.knowledge ? 'ai.knowledge.title' : 'ai.writing.title'),
        ),
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
                      _search.clear();
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
                  l10n.t(
                    widget.knowledge
                        ? 'ai.knowledge.description'
                        : 'ai.writing.description',
                  ),
                  style: theme.textTheme.bodySmall,
                ),
              ),
              Expanded(
                child: _messages.isEmpty
                    ? Center(
                        child: Text(
                          l10n.t(
                            widget.knowledge
                                ? 'ai.knowledge.empty'
                                : 'ai.writing.empty',
                          ),
                        ),
                      )
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
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SelectableText(message.content),
                                    if (message.citations.isNotEmpty) ...[
                                      const SizedBox(height: 8),
                                      Text(
                                        l10n.t('ai.knowledge.sources'),
                                        style: theme.textTheme.labelSmall,
                                      ),
                                      for (final source in message.citations)
                                        source.kind == 'post' ||
                                                source.postId != null
                                            ? TextButton(
                                                onPressed: () => context.push(
                                                  '/posts/${source.postId ?? source.id}',
                                                ),
                                                child: Text(
                                                  '${l10n.t(source.kind == 'post' ? 'ai.knowledge.post' : 'ai.knowledge.comment')} #${source.id}',
                                                ),
                                              )
                                            : Text(
                                                '${l10n.t('ai.knowledge.comment')} #${source.id}',
                                              ),
                                    ],
                                  ],
                                ),
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
                    style: TextStyle(
                      color: _notice == 'ai.knowledge.insufficient'
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.error,
                    ),
                  ),
                ),
              if (widget.knowledge)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: TextField(
                    key: const Key('ai-knowledge-search'),
                    controller: _search,
                    enabled: !_busy,
                    decoration: InputDecoration(
                      labelText: l10n.t('ai.knowledge.search_label'),
                      hintText: l10n.t('ai.knowledge.search_placeholder'),
                      helperText: l10n.t('ai.knowledge.search_hint'),
                      border: const OutlineInputBorder(),
                    ),
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
                          hintText: l10n.t(
                            widget.knowledge
                                ? 'ai.knowledge.placeholder'
                                : 'ai.writing.placeholder',
                          ),
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
  const _HistoryDialog({required this.api, required this.knowledge});
  final AiWritingApi api;
  final bool knowledge;
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
        _items.addAll(
          page.items.where(
            (item) =>
                item.purpose == (widget.knowledge ? 'knowledge' : 'writing'),
          ),
        );
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
                  ? Center(
                      child: Text(
                        l10n.t(
                          widget.knowledge
                              ? 'ai.knowledge.history_empty'
                              : 'ai.writing.history_empty',
                        ),
                      ),
                    )
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
