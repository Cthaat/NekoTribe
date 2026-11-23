import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/utils/ai_conversation_link.dart';
import '../../groups/domain/group_models.dart';
import '../../posts/domain/post_models.dart';
import '../../posts/presentation/compose_post_screen.dart';
import '../data/ai_conversation_page.dart';
import '../data/ai_writing_api.dart';
import '../data/moderation_rule_catalog.dart';
import 'ai_quota_notice.dart';
import 'ai_skill_metadata.dart';
import 'public_terms_dialog.dart';

const _messageMaxBytes = 65536;

class AiWritingRouteScreen extends StatefulWidget {
  const AiWritingRouteScreen({
    super.key,
    required this.conversationId,
    this.knowledge = false,
  });

  final String? conversationId;
  final bool knowledge;

  @override
  State<AiWritingRouteScreen> createState() => _AiWritingRouteScreenState();
}

class _AiWritingRouteScreenState extends State<AiWritingRouteScreen> {
  int _screenVersion = 0;
  ({String? id})? _localNavigation;

  @override
  void didUpdateWidget(AiWritingRouteScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId == widget.conversationId) return;
    final local = _localNavigation;
    _localNavigation = null;
    if (local == null || local.id != widget.conversationId) _screenVersion++;
  }

  @override
  Widget build(BuildContext context) => AiWritingScreen(
    key: ValueKey(_screenVersion),
    knowledge: widget.knowledge,
    initialConversationId: widget.conversationId,
    onCurrentConversationLink: (id) => _localNavigation = (id: id),
  );
}

class AiWritingScreen extends ConsumerStatefulWidget {
  const AiWritingScreen({
    super.key,
    this.knowledge = false,
    this.initialConversationId,
    this.initialDiscussion,
    this.composerDraft,
    this.onCurrentConversationLink,
  });
  final bool knowledge;
  final String? initialConversationId;
  final String? initialDiscussion;
  final String? composerDraft;
  final void Function(String?)? onCurrentConversationLink;
  @override
  ConsumerState<AiWritingScreen> createState() => _AiWritingScreenState();
}

enum _WritingMode { draft, polish, tags, summary }

class _AiWritingScreenState extends ConsumerState<AiWritingScreen> {
  final _input = TextEditingController();
  final _search = TextEditingController();
  String _titleDraft = '';
  _WritingMode _writingMode = _WritingMode.draft;
  String? _conversation;
  AiKnowledgeScope _knowledgeScope = AiKnowledgeScope.public;
  int? _scopeGroupId;
  String? _scopeGroupName;
  bool get _scopeReady =>
      _knowledgeScope != AiKnowledgeScope.group || _scopeGroupId != null;
  List<AiWritingMessage> _messages = [];
  bool _forwardOnly = false;
  bool _oldestPageComplete = false;
  bool get _hasOlderMessages =>
      !_oldestPageComplete && (_messages.firstOrNull?.sequence ?? 0) > 1;
  bool _busy = false;
  bool _needsRefresh = false;
  bool _savedReplyPending = false;
  String? _notice;
  int _quotaRetry = 0;
  int _groupCitationRequest = 0;
  bool _expired = false;
  bool _explicitSkill = false;
  CancelToken? _generation;
  String _preview = '';
  VoidCallback? _stopListening;
  Route<Object?>? _dialog;
  bool get _active => mounted && !_expired;

  Future<void> _openGroupCitation(AiKnowledgeCitation source) async {
    final groupId = source.groupId, postId = source.postId;
    if (!_active || _busy || groupId == null || postId == null) return;
    final store = ref.read(tokenStoreProvider);
    if (store.isSessionChanging) return;
    final config = ref.read(appConfigProvider);
    final groups = ref.read(groupsApiProvider);
    final revision = store.revision;
    final request = ++_groupCitationRequest;
    bool current() =>
        _active &&
        !_busy &&
        request == _groupCitationRequest &&
        !store.isSessionChanging &&
        store.revision == revision &&
        identical(ref.read(tokenStoreProvider), store) &&
        identical(ref.read(appConfigProvider), config) &&
        identical(ref.read(groupsApiProvider), groups) &&
        ModalRoute.of(context)?.isCurrent != false &&
        _messages.any((message) => message.citations.contains(source));

    try {
      final group = await groups.getGroupById(groupId);
      if (!current()) return;
      if (group.groupId == groupId &&
          (group.privacy == 'public' ||
              (_knowledgeScope == AiKnowledgeScope.group &&
                  _scopeGroupId == groupId &&
                  group.membership.isMember &&
                  group.membership.status == 'active')) &&
          group.isActive == 1 &&
          group.slug.isNotEmpty) {
        final path = '/groups/${Uri.encodeComponent(group.slug)}/posts/$postId';
        final comment = source.kind == 'group_comment'
            ? '?comment=${source.id}'
            : '';
        unawaited(context.push<void>('$path$comment'));
        return;
      }
    } on Exception {
      if (!current()) return;
    }
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.t('ai.groupDraft.sourceUnavailable'))),
    );
  }

  Future<void> _copyReply(String text) async {
    if (!_active || ref.read(tokenStoreProvider).isSessionChanging) return;
    final l10n = AppLocalizations.of(context);
    String feedback;
    try {
      await Clipboard.setData(ClipboardData(text: text));
      feedback = 'ai.writing.reply_copied';
    } catch (_) {
      feedback = 'ai.writing.copy_failed';
    }
    if (_active) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.t(feedback))));
    }
  }

  void _useAsPost(String text) {
    if (!_active ||
        widget.knowledge ||
        text.trim().isEmpty ||
        text.length > 280) {
      return;
    }
    final tokens = ref.read(tokenStoreProvider);
    if (tokens.isSessionChanging) return;
    if (widget.composerDraft != null) {
      Navigator.of(context).pop(text);
      return;
    }
    final revision = tokens.revision;
    final config = ref.read(appConfigProvider);
    Navigator.of(context).push(
      MaterialPageRoute<V2Post>(
        builder: (_) {
          final draft =
              _active &&
                  !tokens.isSessionChanging &&
                  tokens.revision == revision &&
                  identical(ref.read(tokenStoreProvider), tokens) &&
                  identical(ref.read(appConfigProvider), config)
              ? text
              : null;
          return ComposePostScreen(initialDraft: draft);
        },
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    final store = ref.read(tokenStoreProvider);
    _expired = store.isSessionChanging;
    _stopListening = store.listenSessionChanges(_expire);
    final id = widget.initialConversationId;
    final discussion = widget.initialDiscussion;
    final draft = widget.composerDraft;
    if (!_expired && !widget.knowledge && id == null && draft != null) {
      _input.text = draft;
      if (draft.trim().isNotEmpty) _writingMode = _WritingMode.polish;
    } else if (!_expired &&
        !widget.knowledge &&
        id == null &&
        discussion != null) {
      _input.text = discussion;
      _writingMode = _WritingMode.summary;
    }
    if (id != null) _restoreConversation(id);
  }

  void _dismissDialog() {
    final dialog = _dialog;
    _dialog = null;
    if (dialog != null) {
      scheduleMicrotask(() {
        if (dialog.isActive) dialog.navigator?.removeRoute(dialog);
      });
    }
  }

  void _expire() {
    if (!_active) return;
    _generation?.cancel();
    _dismissDialog();
    _input.clear();
    _search.clear();
    setState(() {
      _expired = true;
      _explicitSkill = false;
      _conversation = null;
      _titleDraft = '';
      _messages = [];
      _notice = null;
    });
  }

  Future<T?> _showScopedDialog<T>({required WidgetBuilder builder}) async {
    if (!_active || _dialog != null) return null;
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<T>(
      context: context,
      builder: builder,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
    );
    _dialog = route;
    try {
      return await navigator.push(route);
    } finally {
      if (identical(_dialog, route)) _dialog = null;
    }
  }

  void _openTerms(AiKnowledgeCitation source, String title) {
    final version = source.version;
    if (!_active || _dialog != null || version == null) return;
    final document = readModerationRule((
      id: source.id,
      version: version,
    ), bundle: DefaultAssetBundle.of(context));
    _showScopedDialog<void>(
      builder: (_) => PublicTermsDialog(title: title, document: document),
    );
  }

  bool _generationEnabled(AsyncValue<AiAvailability> availability) {
    if (availability.isLoading || availability.hasError) return false;
    final flags = availability.asData?.value;
    return (widget.knowledge ? flags?.knowledge : flags?.writing) == true &&
        (widget.knowledge
                ? flags?.inference?.knowledge
                : flags?.inference?.writing) !=
            false;
  }

  @override
  void dispose() {
    _generation?.cancel();
    _stopListening?.call();
    _dismissDialog();
    _input.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final id = _conversation;
    if (!_active || id == null) return;
    final recent = await _readRecent(id);
    if (!_active) return;
    setState(() {
      _messages = recent.messages;
      _oldestPageComplete = recent.messages.length < 50;
      _forwardOnly = recent.forwardOnly;
      _needsRefresh = false;
      _savedReplyPending = false;
    });
  }

  bool _forgetMissing(String? id, Object error, {String? submitted}) {
    if (!_active || id == null || error is! ApiException || !error.isNotFound) {
      return false;
    }
    final linked = _conversation == id || widget.initialConversationId == id;
    if (_conversation == id && _input.text.isEmpty && submitted != null) {
      _input.text = submitted;
    }
    setState(() {
      if (_conversation == id) {
        _conversation = null;
        _messages = [];
        _needsRefresh = false;
        _savedReplyPending = false;
      }
      _notice = 'ai.writing.conversation_missing';
    });
    if (linked) _updateLocation(null);
    return true;
  }

  Future<List<AiWritingMessage>> _readMessagePage(
    String id, {
    int after = 0,
    int? before,
  }) async {
    final api = ref.read(aiWritingApiProvider);
    final page = await api.listMessages(
      id,
      afterSequence: after,
      beforeSequence: before,
    );
    if (!_active) return const [];
    if (page.length > 50) {
      throw const FormatException('Invalid AI history size');
    }
    for (final message in page) {
      if (message.sequence <= after ||
          (before != null && message.sequence >= before)) {
        throw const FormatException('Invalid AI history order');
      }
      after = message.sequence;
    }
    return page;
  }

  Future<List<AiWritingMessage>> _readForwardWindow(
    String id, {
    List<AiWritingMessage> initial = const [],
    int before = 10000000000,
  }) async {
    final entries = [...initial];
    var after = entries.lastOrNull?.sequence ?? 0;
    while (_active) {
      final page = await _readMessagePage(id, after: after);
      entries.addAll(page.where((message) => message.sequence < before));
      if (entries.length > 50) entries.removeRange(0, entries.length - 50);
      final last = page.lastOrNull?.sequence ?? after;
      if (page.length < 50 || last >= before) return entries;
      after = last;
    }
    return const [];
  }

  Future<({List<AiWritingMessage> messages, bool forwardOnly})> _readRecent(
    String id,
  ) async {
    final recent = await _readMessagePage(id, before: 10000000000);
    // Older servers ignore before_sequence and may return their first full page.
    final forwardOnly = recent.length == 50 && recent.first.sequence == 1;
    final messages = forwardOnly
        ? await _readForwardWindow(id, initial: recent)
        : recent;
    return (messages: messages, forwardOnly: forwardOnly);
  }

  Future<List<AiWritingMessage>> _readOlder(String id, int before) async {
    if (!_forwardOnly) return _readMessagePage(id, before: before);
    final after = before > 51 ? before - 51 : 0;
    final nearby = (await _readMessagePage(
      id,
      after: after,
    )).where((message) => message.sequence < before).toList();
    // A sequence gap can leave part or all of the page outside this range.
    return after == 0 || nearby.length == 50
        ? nearby
        : _readForwardWindow(id, before: before);
  }

  Future<void> _loadOlderMessages() async {
    final id = _conversation;
    if (!_active ||
        _busy ||
        _savedReplyPending ||
        id == null ||
        !_hasOlderMessages) {
      return;
    }
    final before = _messages.first.sequence;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final page = await _readOlder(id, before);
      if (!_active) return;
      setState(() {
        _messages = [...page, ..._messages];
        _oldestPageComplete = page.length < 50;
      });
    } catch (error) {
      if (!_forgetMissing(id, error) && _active) {
        setState(() => _notice = 'ai.writing.history_failed');
      }
    } finally {
      if (_active) setState(() => _busy = false);
    }
  }

  Future<void> _openHistory() async {
    if (!_active || _busy || !_scopeReady) return;
    final id = await _showScopedDialog<String>(
      builder: (_) => _HistoryDialog(
        api: ref.read(aiWritingApiProvider),
        knowledge: widget.knowledge,
        knowledgeScope: widget.knowledge ? _knowledgeScope : null,
        groupId: _scopeGroupId,
      ),
    );
    if (!_active || id == null) return;
    if (id == _conversation) {
      await _reconcile();
      return;
    }
    if (_updateLocation(id)) return;
    await _restoreConversation(id);
  }

  void _setKnowledgeScope(AiKnowledgeScope scope, [V2Group? group]) {
    if (!_active ||
        _busy ||
        (_knowledgeScope == scope && _scopeGroupId == group?.groupId)) {
      return;
    }
    _search.clear();
    setState(() {
      _knowledgeScope = scope;
      _scopeGroupId = group?.groupId;
      _scopeGroupName = group?.name;
      _conversation = null;
      _titleDraft = '';
      _messages = [];
      _forwardOnly = false;
      _oldestPageComplete = false;
      _needsRefresh = false;
      _savedReplyPending = false;
      _notice = null;
    });
    _updateLocation(null);
  }

  Future<void> _chooseKnowledgeGroup() async {
    if (!_active || _busy || _dialog != null) return;
    final l10n = AppLocalizations.of(context);
    final api = ref.read(groupsApiProvider);
    Future<List<V2Group>> loadGroups() async {
      final groups = <V2Group>[];
      for (var page = 1; _active; page++) {
        final result = await api.myGroups(page: page, size: 50);
        if (!_active) return const [];
        groups.addAll(
          result.items.where(
            (group) =>
                group.isActive == 1 &&
                group.membership.isMember &&
                group.membership.status == 'active',
          ),
        );
        if (!result.hasNext || result.items.isEmpty) break;
      }
      return groups;
    }

    final groups = loadGroups();
    final selected = await _showScopedDialog<V2Group>(
      builder: (dialogContext) => SimpleDialog(
        title: Text(l10n.t('ai.knowledge.scope.choose_group')),
        children: [
          FutureBuilder<List<V2Group>>(
            future: groups,
            builder: (context, result) {
              if (result.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final active = result.data ?? const [];
              if (active.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    l10n.t(
                      result.hasError
                          ? 'ai.writing.history_failed'
                          : 'ai.knowledge.scope.no_groups',
                    ),
                  ),
                );
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final group in active)
                    SimpleDialogOption(
                      onPressed: () => Navigator.of(dialogContext).pop(group),
                      child: Text(group.name),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
    if (selected != null) _setKnowledgeScope(AiKnowledgeScope.group, selected);
  }

  bool _updateLocation(String? id) {
    if (!_active ||
        widget.composerDraft != null ||
        ModalRoute.of(context)?.isCurrent == false) {
      return false;
    }
    final router = GoRouter.maybeOf(context);
    if (router == null) return false;
    final safe = id == null ? null : validAiConversationLinkId(id);
    if (id != null && safe == null) return false;
    final path = widget.knowledge ? '/ai/knowledge' : '/ai/writing';
    final top = router.routerDelegate.currentConfiguration.lastOrNull;
    final pending = router.routeInformationProvider.value.uri;
    // On native pushes the reported URI can still be the page below this one.
    final linked =
        (pending.path == path
            ? pending.queryParametersAll['conversation']
            : null) ??
        (top is ImperativeRouteMatch
            ? top.matches.uri.queryParametersAll['conversation']
            : null);
    if (safe == null
        ? linked == null
        : linked?.length == 1 && linked?.first == safe) {
      return false;
    }
    final location = Uri(
      path: path,
      queryParameters: safe == null ? null : {'conversation': safe},
    );
    if (id == _conversation) widget.onCurrentConversationLink?.call(safe);
    Router.neglect(context, () {
      if (top is ImperativeRouteMatch) {
        unawaited(router.replace<void>(location.toString()));
      } else {
        router.go(location.toString());
      }
    });
    return true;
  }

  Future<void> _restoreConversation(String id) async {
    if (!_active || _busy) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final record = await ref.read(aiWritingApiProvider).readConversation(id);
      if (!_active) return;
      if (record.id != id ||
          record.purpose != (widget.knowledge ? 'knowledge' : 'writing')) {
        setState(() => _notice = 'ai.writing.conversation_missing');
        return;
      }
      final recent = await _readRecent(id);
      if (!_active) return;
      _input.clear();
      _search.clear();
      setState(() {
        _conversation = id;
        _knowledgeScope = record.knowledgeScope;
        if (_scopeGroupId != record.groupId) _scopeGroupName = null;
        _scopeGroupId = record.groupId;
        _titleDraft = '';
        _messages = recent.messages;
        _oldestPageComplete = recent.messages.length < 50;
        _forwardOnly = recent.forwardOnly;
        _needsRefresh = false;
        _savedReplyPending = false;
      });
    } catch (error) {
      if (!_forgetMissing(id, error) && _active) {
        setState(() => _notice = 'ai.writing.history_failed');
      }
    } finally {
      if (_active) setState(() => _busy = false);
    }
  }

  Future<void> _editTitle() async {
    if (!_active || _busy || _conversation != null) return;
    final l10n = AppLocalizations.of(context);
    var draft = _titleDraft;
    final result = await _showScopedDialog<String>(
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(l10n.t('ai.writing.conversation_title')),
          content: TextFormField(
            key: const Key('ai-conversation-title-input'),
            initialValue: draft,
            onChanged: (value) => update(() => draft = value),
            decoration: InputDecoration(
              errorText: draft.trim().length > 200
                  ? l10n.t('ai.writing.conversation_title_too_long')
                  : null,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.t('common.cancel')),
            ),
            FilledButton(
              onPressed: draft.trim().length > 200
                  ? null
                  : () => Navigator.of(dialogContext).pop(draft.trim()),
              child: Text(l10n.t('common.save')),
            ),
          ],
        ),
      ),
    );
    if (_active && result != null && _conversation == null && !_busy) {
      setState(() => _titleDraft = result);
    }
  }

  String _outgoingContent(String text, AppLocalizations l10n) {
    final draft = text.trim();
    if (draft.isEmpty ||
        widget.knowledge ||
        _writingMode == _WritingMode.draft) {
      return draft;
    }
    final instruction = l10n.t('ai.writing.instruction.${_writingMode.name}');
    return '$instruction\n\n$draft';
  }

  Future<void> _send() async {
    final draft = _input.text.trim();
    if (!_active ||
        _busy ||
        _needsRefresh ||
        !_scopeReady ||
        draft.isEmpty ||
        !_generationEnabled(ref.read(aiAvailabilityProvider))) {
      return;
    }
    final content = _outgoingContent(draft, AppLocalizations.of(context));
    if (utf8.encode(content).length > _messageMaxBytes) {
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
      final title = _titleDraft.isEmpty ? null : _titleDraft;
      final existing = _conversation;
      final id =
          existing ??
          await (widget.knowledge
              ? api.createKnowledgeConversation(
                  title: title,
                  knowledgeScope: _knowledgeScope,
                  groupId: _scopeGroupId,
                )
              : api.createConversation(title: title));
      if (!_active) return;
      _conversation = id;
      _titleDraft = '';
      if (existing == null) _updateLocation(id);
      final int sequence;
      try {
        sequence = await api.appendMessage(id, content);
      } catch (error) {
        if (!_forgetMissing(id, error) && _active) {
          setState(() {
            _needsRefresh = true;
            _notice = 'ai.writing.append_unknown';
          });
        }
        return;
      }
      if (!_active) return;
      _input.clear();
      await _refresh();
      if (!_active) return;
      if (!_matchesLatestUser(sequence)) {
        setState(() => _notice = 'ai.writing.sequence_conflict');
        return;
      }
      if (!await _generate(api, id, phrase, sequence)) return;
      if (!_active) return;
      await _refresh();
    } catch (error) {
      if (!_forgetMissing(_conversation, error, submitted: draft) && _active) {
        setState(() {
          _needsRefresh = _conversation != null;
          _notice = _savedReplyPending
              ? 'ai.writing.reply_saved'
              : 'ai.writing.failed';
        });
      }
    } finally {
      if (_active) setState(() => _busy = false);
    }
  }

  Future<void> _reconcile({bool generate = false}) async {
    final id = _conversation;
    if (!_active || _busy || id == null) return;
    if (generate &&
        (_savedReplyPending ||
            !_generationEnabled(ref.read(aiAvailabilityProvider)))) {
      return;
    }
    final phrase = generate && widget.knowledge ? _validatedSearch() : null;
    if (generate && widget.knowledge && phrase == null) return;
    final last = _messages.lastOrNull;
    final expected = last?.role == 'user' ? last?.sequence : null;
    setState(() {
      _busy = true;
      _notice = null;
      if (!generate && widget.knowledge) _messages = [];
    });
    try {
      await _refresh();
      if (!_active) return;
      if (generate && expected != null) {
        if (!_matchesLatestUser(expected)) {
          setState(() => _notice = 'ai.writing.sequence_conflict');
          return;
        }
        if (!await _generate(
          ref.read(aiWritingApiProvider),
          id,
          phrase,
          expected,
        )) {
          return;
        }
        if (!_active) return;
        await _refresh();
      }
    } catch (error) {
      if (!_forgetMissing(id, error) && _active) {
        setState(() {
          _needsRefresh = true;
          _notice = _savedReplyPending
              ? 'ai.writing.reply_saved'
              : !generate && widget.knowledge
              ? 'ai.writing.history_failed'
              : 'ai.writing.failed';
        });
      }
    } finally {
      if (_active) setState(() => _busy = false);
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

  bool _matchesLatestUser(int sequence) {
    final last = _messages.lastOrNull;
    return last?.role == 'user' && last?.sequence == sequence;
  }

  Future<bool> _generate(
    AiWritingApi api,
    String id,
    String? phrase,
    int sequence,
  ) async {
    final generation = CancelToken();
    setState(() {
      _generation = generation;
      _preview = '';
    });
    void preview(String text) {
      if (_active && !generation.isCancelled) {
        setState(() => _preview += text);
      }
    }

    try {
      var hasEvidence = true;
      final availability = ref.read(aiAvailabilityProvider);
      final skill = availability
          .asData
          ?.value
          .skills[widget.knowledge ? 'knowledge' : 'writing'];
      final selectSkill =
          _explicitSkill &&
          _generationEnabled(availability) &&
          skill?.explicitSelection == true &&
          skill?.enabled == true;
      if (!widget.knowledge) {
        await api.generate(
          id,
          cancelToken: generation,
          selectSkill: selectSkill,
          expectedSequence: sequence,
          onDelta: preview,
        );
      } else {
        hasEvidence = await api.generateKnowledge(
          id,
          searchPhrase: phrase,
          cancelToken: generation,
          selectSkill: selectSkill,
          expectedSequence: sequence,
          onDelta: preview,
        );
      }
      if (generation.isCancelled) throw generation.cancelError!;
      if (!_active) return false;
      if (!hasEvidence) {
        setState(() => _notice = 'ai.knowledge.insufficient');
        return false;
      }
      _savedReplyPending = true;
      return true;
    } catch (error) {
      if (generation.isCancelled) {
        if (_active) {
          setState(() {
            _needsRefresh = true;
            _notice = 'ai.writing.stopped';
          });
        }
        return false;
      }
      if (error is ApiException && error.statusCode == 409) {
        if (_active) {
          setState(() {
            _needsRefresh = true;
            _notice = 'ai.writing.sequence_conflict';
          });
        }
        return false;
      }
      final retry = aiQuotaRetry(error);
      if (retry == null) {
        if (_active) setState(() => _needsRefresh = true);
        rethrow;
      }
      if (_active) {
        setState(() {
          _quotaRetry = retry;
          _notice = 'quota';
        });
      }
      return false;
    } finally {
      if (_active) {
        setState(() {
          _generation = null;
          _preview = '';
        });
      }
    }
  }

  Future<void> _delete() async {
    final id = _conversation;
    if (!_active || _busy || id == null) return;
    final l10n = AppLocalizations.of(context);
    final confirmed = await _showScopedDialog<bool>(
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
    if (!_active || confirmed != true) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await ref.read(aiWritingApiProvider).deleteConversation(id);
      if (!_active) return;
      _input.clear();
      _search.clear();
      setState(() {
        _conversation = null;
        _messages = [];
        _needsRefresh = false;
        _savedReplyPending = false;
      });
      _updateLocation(null);
    } catch (error) {
      if (!_forgetMissing(id, error) && _active) {
        setState(() {
          _needsRefresh = true;
          _notice = 'ai.writing.delete_unknown';
        });
      }
    } finally {
      if (_active) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    ref.listen(aiWritingApiProvider, (previous, next) {
      if (!identical(previous, next)) _expire();
    });
    if (_expired) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(l10n.t('visibility.sessionChanged'))),
      );
    }
    final availability = ref.watch(aiAvailabilityProvider);
    final flags = availability.isLoading || availability.hasError
        ? null
        : availability.asData?.value;
    final skill = flags?.skills[widget.knowledge ? 'knowledge' : 'writing'];
    final modelConfigRevision = flags?.modelConfigRevision;
    final canGenerate = _generationEnabled(availability);
    final availabilityState = availability.isLoading
        ? 'loading'
        : availability.hasError || availability.asData == null
        ? 'unknown'
        : canGenerate
        ? 'enabled'
        : (widget.knowledge
                  ? availability.asData?.value.knowledge
                  : availability.asData?.value.writing) ==
              true
        ? 'unconfigured'
        : 'disabled';
    final canRetry =
        !_savedReplyPending &&
        _messages.isNotEmpty &&
        _messages.last.role == 'user';
    return Scaffold(
      appBar: AppBar(
        title: Text(
          l10n.t(widget.knowledge ? 'ai.knowledge.title' : 'ai.writing.title'),
        ),
        actions: [
          if (_conversation == null)
            IconButton(
              key: const Key('ai-conversation-title'),
              tooltip: l10n.t('ai.writing.conversation_title'),
              onPressed: _busy ? null : _editTitle,
              icon: Icon(
                _titleDraft.isEmpty ? Icons.label_outline : Icons.label,
              ),
            ),
          IconButton(
            key: const Key('ai-writing-history'),
            tooltip: l10n.t('ai.writing.history'),
            onPressed: _busy || !_scopeReady ? null : _openHistory,
            icon: const Icon(Icons.history),
          ),
          if (_conversation != null || widget.initialConversationId != null)
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
                        _titleDraft = '';
                        _messages = [];
                        _needsRefresh = false;
                        _savedReplyPending = false;
                        _notice = null;
                      });
                      _updateLocation(null);
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
              if (widget.composerDraft != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(l10n.t('ai.writing.composer_source')),
                ),
              if (widget.initialDiscussion != null &&
                  _conversation == null &&
                  _input.text.isNotEmpty &&
                  _writingMode == _WritingMode.summary)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(l10n.t('ai.writing.discussion_prefilled')),
                ),
              if (widget.knowledge)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Wrap(
                    spacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Semantics(
                        label: l10n.t('ai.knowledge.scope.label'),
                        child: SizedBox(
                          width: 300,
                          child: DropdownButton<AiKnowledgeScope>(
                            isExpanded: true,
                            value: _knowledgeScope,
                            onChanged: _busy
                                ? null
                                : (scope) {
                                    if (scope != null &&
                                        scope != _knowledgeScope) {
                                      _setKnowledgeScope(scope);
                                      if (scope == AiKnowledgeScope.group) {
                                        unawaited(_chooseKnowledgeGroup());
                                      }
                                    }
                                  },
                            items: [
                              for (final scope in AiKnowledgeScope.values)
                                DropdownMenuItem(
                                  value: scope,
                                  child: Text(
                                    l10n.t('ai.knowledge.scope.${scope.name}'),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      if (_knowledgeScope == AiKnowledgeScope.group)
                        OutlinedButton(
                          onPressed: _busy ? null : _chooseKnowledgeGroup,
                          child: Text(
                            _scopeGroupName ??
                                (_scopeGroupId == null
                                    ? l10n.t('ai.knowledge.scope.choose_group')
                                    : '#$_scopeGroupId'),
                          ),
                        ),
                    ],
                  ),
                ),
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
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Semantics(
                      liveRegion: true,
                      child: Text(l10n.t('ai.availability.$availabilityState')),
                    ),
                    TextButton(
                      key: const Key('ai-availability-refresh'),
                      onPressed: _busy || availability.isLoading
                          ? null
                          : () {
                              setState(() => _explicitSkill = false);
                              ref.invalidate(aiAvailabilityProvider);
                            },
                      child: Text(l10n.t('ai.availability.refresh')),
                    ),
                  ],
                ),
              ),
              if (skill != null || modelConfigRevision != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: AiSkillMetadata(
                    skill: skill,
                    modelConfigRevision: modelConfigRevision,
                  ),
                ),
              if (skill?.explicitSelection == true && skill?.enabled == true)
                CheckboxListTile(
                  key: const Key('ai-writing-explicit-skill'),
                  title: Text(l10n.t('ai.availability.select_explicitly')),
                  value: _explicitSkill,
                  onChanged: !_busy && canGenerate
                      ? (value) =>
                            setState(() => _explicitSkill = value == true)
                      : null,
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
                        reverse: true,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount:
                            _messages.length + (_hasOlderMessages ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == _messages.length) {
                            return TextButton(
                              onPressed: _busy || _savedReplyPending
                                  ? null
                                  : _loadOlderMessages,
                              child: Text(l10n.t('chat.dm.load_older')),
                            );
                          }
                          final message =
                              _messages[_messages.length - 1 - index];
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
                                    if (message.role == 'assistant' &&
                                        message.content.trim().isNotEmpty)
                                      Wrap(
                                        spacing: 6,
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        children: [
                                          TextButton.icon(
                                            onPressed: () =>
                                                _copyReply(message.content),
                                            icon: const Icon(
                                              Icons.copy,
                                              size: 16,
                                            ),
                                            label: Text(
                                              l10n.t('ai.writing.copy_reply'),
                                            ),
                                          ),
                                          if (!widget.knowledge &&
                                              message.content.length <= 280)
                                            OutlinedButton(
                                              onPressed: () =>
                                                  _useAsPost(message.content),
                                              child: Text(
                                                l10n.t(
                                                  widget.composerDraft == null
                                                      ? 'ai.writing.use_as_post'
                                                      : 'ai.writing.apply_to_composer',
                                                ),
                                              ),
                                            ),
                                          if (!widget.knowledge &&
                                              message.content.length > 280)
                                            Text(
                                              l10n.t(
                                                'ai.writing.post_too_long',
                                              ),
                                              style: theme.textTheme.bodySmall,
                                            ),
                                        ],
                                      ),
                                    if (message.modelVersion
                                        case final version?)
                                      Text(
                                        '${l10n.t('ai.modelVersion')} · $version',
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    if (message.configRevision
                                        case final revision?)
                                      Text(
                                        l10n
                                            .t('ai.replyConfigRevision')
                                            .replaceAll(
                                              '{revision}',
                                              '$revision',
                                            ),
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    if (message.citations.isNotEmpty) ...[
                                      const SizedBox(height: 8),
                                      Text(
                                        l10n.t('ai.knowledge.sources'),
                                        style: theme.textTheme.labelSmall,
                                      ),
                                      for (final source in message.citations)
                                        if (source.kind == 'terms')
                                          _termsCitation(source, l10n)
                                        else if (source.kind == 'group_post' ||
                                            source.kind == 'group_comment')
                                          TextButton(
                                            onPressed: _busy
                                                ? null
                                                : () => _openGroupCitation(
                                                    source,
                                                  ),
                                            child: Text(
                                              '${l10n.t('ai.knowledge.${source.kind}')} #${source.id}',
                                            ),
                                          )
                                        else if (source.kind == 'post' ||
                                            source.postId != null)
                                          TextButton(
                                            onPressed: () => context.push(
                                              '/posts/${source.postId ?? source.id}${source.kind == 'comment' ? '?comment=${source.id}' : ''}',
                                            ),
                                            child: Text(
                                              '${l10n.t(source.kind == 'post' ? 'ai.knowledge.post' : 'ai.knowledge.comment')} #${source.id}',
                                            ),
                                          )
                                        else
                                          Text(
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
                    _notice == 'quota'
                        ? aiQuotaNotice(l10n, _quotaRetry)
                        : l10n.t(_notice!),
                    style: TextStyle(
                      color:
                          _notice == 'ai.knowledge.insufficient' ||
                              _notice == 'ai.writing.stopped'
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
              if (_needsRefresh || (widget.knowledge && _conversation != null))
                TextButton(
                  key: const Key('ai-writing-refresh'),
                  onPressed: _busy ? null : () => _reconcile(),
                  child: Text(
                    l10n.t(
                      widget.knowledge
                          ? 'ai.knowledge.recheck_sources'
                          : 'ai.writing.refresh',
                    ),
                  ),
                ),
              if (canRetry)
                TextButton(
                  key: const Key('ai-writing-retry'),
                  onPressed: _busy || !canGenerate
                      ? null
                      : () => _reconcile(generate: true),
                  child: Text(l10n.t('ai.writing.retry')),
                ),
              if (_generation != null)
                TextButton(
                  key: const Key('ai-writing-stop'),
                  onPressed: () => _generation?.cancel(),
                  child: Text(l10n.t('ai.writing.stop')),
                ),
              if (_generation != null && _preview.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(_preview),
                  ),
                ),
              if (!widget.knowledge)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Text(l10n.t('ai.writing.mode_label')),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButton<_WritingMode>(
                          key: const Key('ai-writing-mode'),
                          value: _writingMode,
                          isExpanded: true,
                          items: _WritingMode.values
                              .map(
                                (mode) => DropdownMenuItem(
                                  value: mode,
                                  child: Text(
                                    l10n.t('ai.writing.mode.${mode.name}'),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: _busy
                              ? null
                              : (mode) {
                                  if (mode != null) {
                                    setState(() => _writingMode = mode);
                                  }
                                },
                        ),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _input,
                  builder: (context, input, _) {
                    final bytes = utf8
                        .encode(_outgoingContent(input.text, l10n))
                        .length;
                    final tooLong = bytes > _messageMaxBytes;
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: TextField(
                            key: const Key('ai-writing-input'),
                            controller: _input,
                            enabled: !_busy,
                            minLines: 1,
                            maxLines: 5,
                            decoration: InputDecoration(
                              hintText: l10n.t(
                                widget.knowledge
                                    ? 'ai.knowledge.placeholder'
                                    : _writingMode == _WritingMode.draft
                                    ? 'ai.writing.placeholder'
                                    : 'ai.writing.source_placeholder',
                              ),
                              border: const OutlineInputBorder(),
                              counterText:
                                  '$bytes / $_messageMaxBytes ${l10n.t('ai.writing.bytes')}',
                              counterStyle: tooLong
                                  ? TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.error,
                                    )
                                  : null,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          key: const Key('ai-writing-send'),
                          onPressed:
                              _busy ||
                                  _needsRefresh ||
                                  !_scopeReady ||
                                  !canGenerate ||
                                  tooLong
                              ? null
                              : _send,
                          tooltip: l10n.t('ai.writing.send'),
                          icon: _busy
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.send),
                        ),
                      ],
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

  Widget _termsCitation(AiKnowledgeCitation source, AppLocalizations l10n) {
    final title = '${l10n.t('ai.knowledge.terms')} #${source.id}';
    if (source.version == null) return Text(title);
    return TextButton(
      onPressed: () => _openTerms(source, title),
      child: Text(title),
    );
  }
}

class _HistoryDialog extends StatefulWidget {
  const _HistoryDialog({
    required this.api,
    required this.knowledge,
    this.knowledgeScope,
    this.groupId,
  });
  final AiWritingApi api;
  final bool knowledge;
  final AiKnowledgeScope? knowledgeScope;
  final int? groupId;
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
      final cursor = _first ? null : _next;
      final page = await widget.api.listConversations(
        purpose: widget.knowledge ? 'knowledge' : 'writing',
        afterId: cursor,
        knowledgeScope: widget.knowledgeScope,
        groupId: widget.groupId,
      );
      if (!mounted) return;
      final next = validateAiConversationPage(
        page.items.map((item) => item.id),
        cursor,
        page.nextCursor,
      );
      setState(() {
        _items.addAll(
          page.items.where(
            (item) =>
                item.purpose == (widget.knowledge ? 'knowledge' : 'writing'),
          ),
        );
        _next = next;
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
                  l10n.t(_failed ? 'common.retry' : 'ai.writing.more'),
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
