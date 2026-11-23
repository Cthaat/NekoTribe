import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_exception.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/responsive.dart';
import '../../groups/domain/group_models.dart';
import '../../posts/domain/post_draft.dart';
import '../../posts/presentation/post_draft_scope.dart';
import '../data/ai_group_draft_api.dart';
import '../data/ai_writing_api.dart';
import 'ai_quota_notice.dart';
import 'ai_skill_metadata.dart';

bool canUseGroupDrafts(V2Group group) =>
    group.privacy == 'public' &&
    group.isActive == 1 &&
    group.membership.status == 'active' &&
    (group.membership.role == 'owner' || group.membership.role == 'admin');

class AiGroupDraftScreen extends ConsumerStatefulWidget {
  const AiGroupDraftScreen({
    super.key,
    required this.groupId,
    required this.slug,
  });
  final int groupId;
  final String slug;

  @override
  ConsumerState<AiGroupDraftScreen> createState() => _AiGroupDraftScreenState();
}

enum _Phase { load, page, generate, review, publish, saveDraft, delete }

class _AiGroupDraftScreenState extends ConsumerState<AiGroupDraftScreen> {
  final _edited = TextEditingController();
  final _search = TextEditingController();
  String get _searchTerm => _search.text.trim();
  bool get _invalidSearch {
    final term = _searchTerm;
    final bytes = utf8.encode(term);
    return bytes.length > 256 ||
        utf8.decode(bytes) != term ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(term);
  }

  GroupDraftKind _kind = GroupDraftKind.weeklyReport;
  bool _explicitSkill = false;
  List<GroupDraftConversation> _history = [];
  List<GroupDraftMessage> _messages = [];
  bool _forwardOnly = false;
  bool _oldestPageComplete = false;
  bool get _hasOlderMessages =>
      !_oldestPageComplete && (_messages.firstOrNull?.sequence ?? 0) > 1;
  GroupDraftMessage? _review;
  String? _selected, _next, _notice;
  int _quotaRetry = 0;
  String _availability = 'loading';
  AiSkillAvailability? _skill;
  int? _modelConfigRevision;
  String _groupName = '';
  int? _published;
  V2PostDraftInput? _savedDraftInput;
  bool _publicationUnconfirmed = false;
  bool _publicationRetryConfirmed = false;
  bool get _publicationNeedsConfirmation =>
      _publicationUnconfirmed && !_publicationRetryConfirmed;
  bool _allowed = false, _needsRefresh = false, _expired = false;
  bool _announcement = false;
  bool _deleteConfirm = false;
  _Phase? _phase;
  CancelToken? _current;
  String _preview = '';
  VoidCallback? _stopListening;

  @override
  void initState() {
    super.initState();
    _stopListening = ref.read(tokenStoreProvider).listenSessionChanges(_expire);
    _reload();
  }

  @override
  void didUpdateWidget(covariant AiGroupDraftScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.groupId == oldWidget.groupId && widget.slug == oldWidget.slug) {
      return;
    }
    _current?.cancel();
    _current = null;
    _phase = null;
    _preview = '';
    _clearScope();
    if (!_expired) {
      _notice = null;
      _reload();
    }
  }

  @override
  void dispose() {
    _stopListening?.call();
    _current?.cancel();
    _edited.dispose();
    _search.dispose();
    super.dispose();
  }

  void _clearReview() {
    _review = null;
    _savedDraftInput = null;
    _publicationUnconfirmed = false;
    _publicationRetryConfirmed = false;
    _deleteConfirm = false;
    _edited.clear();
    _announcement = false;
  }

  void _forgetConversation(String id) {
    _history = _history.where((item) => item.id != id).toList();
    _selected = null;
    _messages = [];
    _forwardOnly = false;
    _needsRefresh = false;
    _clearReview();
    _notice = 'conversationMissing';
  }

  void _clearScope() {
    _allowed = false;
    _groupName = '';
    _history = [];
    _messages = [];
    _forwardOnly = false;
    _explicitSkill = false;
    _search.clear();
    _selected = null;
    _next = null;
    _published = null;
    _needsRefresh = false;
    _availability = 'loading';
    _skill = null;
    _modelConfigRevision = null;
    _clearReview();
  }

  void _expire() {
    if (!mounted || _expired) return;
    _current?.cancel();
    setState(() {
      _expired = true;
      _phase = null;
      _current = null;
      _notice = 'sessionChanged';
      _clearScope();
    });
  }

  Future<void> _work(
    _Phase phase,
    Future<void> Function(
      AiGroupDraftApi api,
      CancelToken token,
      bool Function() valid,
    )
    action, {
    String? historyConversationId,
  }) async {
    if (_current != null || _expired) return;
    final store = ref.read(tokenStoreProvider);
    if (store.isSessionChanging) return;
    final revision = store.revision;
    final api = ref.read(aiGroupDraftApiProvider);
    final groups = ref.read(groupsApiProvider);
    final groupId = widget.groupId;
    final slug = widget.slug;
    final token = CancelToken();
    bool valid() =>
        mounted &&
        identical(_current, token) &&
        !_expired &&
        !token.isCancelled &&
        store.revision == revision &&
        widget.groupId == groupId &&
        widget.slug == slug &&
        identical(ref.read(groupsApiProvider), groups) &&
        identical(ref.read(tokenStoreProvider), store) &&
        identical(ref.read(aiGroupDraftApiProvider), api);
    setState(() {
      _current = token;
      _phase = phase;
      _notice = null;
    });
    try {
      await action(api, token, valid);
    } catch (error) {
      if (!valid()) return;
      final status = error is ApiException ? error.statusCode : null;
      setState(() {
        if (status == 404 &&
            historyConversationId != null &&
            _selected == historyConversationId) {
          _forgetConversation(historyConversationId);
          return;
        }
        if (status == 401 || status == 403) {
          _clearScope();
          _notice = 'forbidden';
          return;
        }
        if (phase == _Phase.saveDraft) {
          _notice = 'saveCloudFailed';
          return;
        }
        final retry = phase == _Phase.generate ? aiQuotaRetry(error) : null;
        if (retry != null) {
          _quotaRetry = retry;
          _notice = 'quota';
          return;
        }
        if (phase != _Phase.page) {
          _messages = [];
          _needsRefresh = true;
          if (phase != _Phase.publish && phase != _Phase.load) _clearReview();
        }
        _notice = phase == _Phase.publish && _publicationUnconfirmed
            ? 'publishFailed'
            : phase == _Phase.delete
            ? 'deleteFailed'
            : status == 409
            ? 'conflict'
            : status == 503
            ? 'unavailable'
            : 'requestFailed';
      });
    } finally {
      if (valid()) {
        setState(() {
          _phase = null;
          _preview = '';
          _current = null;
        });
      }
    }
  }

  Future<void> _pageHistory(
    AiGroupDraftApi api,
    CancelToken token,
    bool Function() valid,
    String? after,
  ) async {
    final page = await api.history(widget.groupId, after, token);
    if (!valid()) return;
    final entries = <String, GroupDraftConversation>{
      if (after != null)
        for (final item in _history) item.id: item,
      for (final item in page.items)
        if (item.purpose == 'group' && item.groupId == widget.groupId)
          item.id: item,
    };
    setState(() {
      _history = entries.values.toList();
      _next = page.next;
    });
  }

  Future<List<GroupDraftMessage>> _readForwardPage(
    AiGroupDraftApi api,
    CancelToken token,
    String id, {
    List<GroupDraftMessage> initial = const [],
    int before = 10000000000,
  }) async {
    final entries = [...initial];
    var after = entries.lastOrNull?.sequence ?? 0;
    while (!token.isCancelled) {
      final page = await api.messages(id, after, 50, token);
      entries.addAll(page.where((message) => message.sequence < before));
      if (entries.length > 50) entries.removeRange(0, entries.length - 50);
      final last = page.lastOrNull?.sequence ?? after;
      if (page.length < 50 || last >= before) return entries;
      after = last;
    }
    throw const FormatException('Cancelled group history');
  }

  Future<({List<GroupDraftMessage> messages, bool forwardOnly})> _readMessages(
    AiGroupDraftApi api,
    CancelToken token,
    String id,
  ) async {
    final entries = await api.messages(id, 0, 50, token, before: 10000000000);
    // Older servers may ignore before_sequence and return the first page.
    if (entries.length < 50 || entries.first.sequence != 1) {
      return (messages: entries, forwardOnly: false);
    }
    final messages = await _readForwardPage(api, token, id, initial: entries);
    return (messages: messages, forwardOnly: true);
  }

  Future<void> _loadOlder() async {
    final id = _selected;
    final first = _messages.firstOrNull?.sequence;
    if (!_allowed ||
        _needsRefresh ||
        id == null ||
        first == null ||
        !_hasOlderMessages) {
      return;
    }
    await _work(_Phase.page, (api, token, valid) async {
      final page = _forwardOnly
          ? await _readForwardPage(api, token, id, before: first)
          : await api.messages(id, 0, 50, token, before: first);
      if (valid()) {
        setState(() {
          _messages = [...page, ..._messages];
          _oldestPageComplete = page.length < 50;
        });
      }
    }, historyConversationId: id);
  }

  Future<void> _reload() => _work(_Phase.load, (api, token, valid) async {
    final previousReview = _review;
    setState(() {
      _publicationRetryConfirmed = false;
      _allowed = false;
      _availability = 'loading';
      _skill = null;
      _modelConfigRevision = null;
      _messages = [];
      _deleteConfirm = false;
    });
    final group = await ref.read(groupsApiProvider).getGroup(widget.slug);
    if (!valid()) return;
    if (group.groupId != widget.groupId || !canUseGroupDrafts(group)) {
      setState(() {
        _clearScope();
        _notice = 'forbidden';
      });
      return;
    }
    setState(() {
      _groupName = group.name;
    });
    await Future.wait([
      _pageHistory(api, token, valid, null),
      _readAvailability(token, valid),
    ]);
    if (!valid()) return;
    final id = _selected;
    var messages = <GroupDraftMessage>[];
    var forwardOnly = false;
    GroupDraftMessage? freshReview;
    if (id != null) {
      try {
        final recent = await _readMessages(api, token, id);
        messages = recent.messages;
        forwardOnly = recent.forwardOnly;
        if (!valid()) return;
        if (previousReview != null) {
          freshReview = messages
              .where((row) => row.id == previousReview.id)
              .firstOrNull;
          if (freshReview == null &&
              messages.isNotEmpty &&
              previousReview.sequence < messages.first.sequence) {
            final page = await api.messages(
              id,
              previousReview.sequence - 1,
              1,
              token,
            );
            freshReview = page.firstOrNull;
          }
        }
      } on ApiException catch (error) {
        if (!error.isNotFound) rethrow;
        messages = [];
        forwardOnly = false;
        if (valid()) setState(() => _forgetConversation(id));
      }
    }
    if (valid()) {
      setState(() {
        _allowed = true;
        _messages = messages;
        _oldestPageComplete = messages.length < 50;
        _forwardOnly = forwardOnly;
        _needsRefresh = false;
        if (previousReview != null && _selected != null) {
          final fresh = freshReview;
          if (fresh != null && _sameDraft(previousReview, fresh)) {
            _review = fresh;
            _notice = 'reviewRestored';
          } else {
            _clearReview();
            _notice = 'conflict';
          }
        }
      });
    }
  });

  Future<void> _readAvailability(
    CancelToken token,
    bool Function() valid,
  ) async {
    String state;
    AiSkillAvailability? skill;
    int? modelConfigRevision;
    try {
      final flags = await ref
          .read(aiWritingApiProvider)
          .availabilityWithCancel(token);
      state = flags.workflowStatus(forModeration: false);
      skill = flags.skills['group'];
      modelConfigRevision = flags.modelConfigRevision;
    } catch (_) {
      state = 'unknown';
    }
    if (valid()) {
      setState(() {
        _availability = state;
        _skill = skill;
        _modelConfigRevision = modelConfigRevision;
      });
    }
  }

  Future<void> _open(GroupDraftConversation item) {
    if (_selected == item.id) return _reload();
    return _work(_Phase.load, (api, token, valid) async {
      setState(() {
        _selected = item.id;
        _messages = [];
        _published = null;
        _clearReview();
      });
      final result = await _readMessages(api, token, item.id);
      if (valid()) {
        setState(() {
          _messages = result.messages;
          _oldestPageComplete = result.messages.length < 50;
          _forwardOnly = result.forwardOnly;
          _needsRefresh = false;
        });
      }
    }, historyConversationId: item.id);
  }

  void _newConversation() => setState(() {
    _selected = null;
    _messages = [];
    _notice = null;
    _published = null;
    _needsRefresh = false;
    _clearReview();
  });

  Future<void> _generate() async {
    if (!_allowed ||
        _needsRefresh ||
        _invalidSearch ||
        _review != null ||
        _deleteConfirm ||
        _availability != 'enabled') {
      return;
    }
    final kind = _kind;
    final explicitSkill = _explicitSkill;
    final searchTerm = _searchTerm;
    await _work(_Phase.generate, (api, token, valid) async {
      var id = _selected;
      if (id == null) {
        final item = await api.create(widget.groupId, token);
        if (!valid()) return;
        id = item.id;
        setState(() {
          _selected = item.id;
          _history = [item, ..._history.where((row) => row.id != item.id)];
        });
      }
      final sequence = _messages.isEmpty ? 0 : _messages.last.sequence;
      final generated = await api.generate(
        id,
        kind,
        sequence,
        token,
        explicitlySelectGroupBrief: explicitSkill,
        searchTerm: searchTerm.isEmpty ? null : searchTerm,
        onDelta: (text) {
          if (valid()) setState(() => _preview += text);
        },
      );
      if (!valid()) return;
      setState(() {
        _phase = _Phase.load;
        _preview = '';
      });
      try {
        final result = await _readMessages(api, token, id);
        if (!valid()) return;
        setState(() {
          _messages = result.messages;
          _oldestPageComplete = result.messages.length < 50;
          _forwardOnly = result.forwardOnly;
          if (!generated) _notice = 'insufficient';
        });
      } catch (error) {
        if (!valid()) return;
        final status = error is ApiException ? error.statusCode : null;
        if (!generated || status == 401 || status == 403 || status == 404) {
          rethrow;
        }
        setState(() {
          _messages = [];
          _needsRefresh = true;
          _clearReview();
          _notice = 'generationSaved';
        });
      }
    });
  }

  Future<void> _removeConversation() async {
    final id = _selected;
    if (id == null || !_allowed || !_deleteConfirm || _needsRefresh) return;
    await _work(_Phase.delete, (api, token, valid) async {
      await api.remove(id, token);
      if (!valid()) return;
      setState(() {
        _history = _history.where((row) => row.id != id).toList();
        _selected = null;
        _messages = [];
        _clearReview();
        _notice = 'deleted';
      });
    });
  }

  void _cancel() {
    if (_phase != _Phase.generate) return;
    _current?.cancel();
    setState(() {
      _current = null;
      _phase = null;
      _preview = '';
      _needsRefresh = true;
      _messages = [];
      _notice = 'cancelled';
    });
  }

  Future<bool> _matchesCurrent(
    AiGroupDraftApi api,
    CancelToken token,
    String id,
    GroupDraftMessage message,
  ) async {
    final page = await api.messages(id, message.sequence - 1, 1, token);
    if (page.isEmpty) return false;
    return _sameDraft(message, page.first);
  }

  bool _sameDraft(GroupDraftMessage message, GroupDraftMessage current) {
    return current.id == message.id &&
        current.sequence == message.sequence &&
        current.role == 'assistant' &&
        current.content == message.content &&
        current.sources.isNotEmpty &&
        listEquals(current.sources, message.sources);
  }

  void _markStale() => setState(() {
    _messages = [];
    _needsRefresh = true;
    _clearReview();
    _notice = 'conflict';
  });

  Future<void> _startReview(GroupDraftMessage message) async {
    final id = _selected;
    if (id == null ||
        !_allowed ||
        _needsRefresh ||
        _deleteConfirm ||
        message.sources.isEmpty) {
      return;
    }
    await _work(_Phase.review, (api, token, valid) async {
      final matches = await _matchesCurrent(api, token, id, message);
      if (!valid()) return;
      if (!matches) {
        _markStale();
        return;
      }
      setState(() {
        _review = message;
        _savedDraftInput = null;
        _edited.text = message.content;
        _announcement = false;
        _published = null;
      });
    });
  }

  Future<void> _publish() async {
    final id = _selected, draft = _review, content = _edited.text.trim();
    if (id == null ||
        draft == null ||
        !_allowed ||
        _needsRefresh ||
        _publicationNeedsConfirmation ||
        content.isEmpty ||
        utf8.encode(content).length > 4000) {
      return;
    }
    final announcement = _announcement;
    final groupId = widget.groupId;
    final groups = ref.read(groupsApiProvider);
    await _work(_Phase.publish, (api, token, valid) async {
      final matches = await _matchesCurrent(api, token, id, draft);
      if (!valid()) return;
      if (!matches) {
        _markStale();
        return;
      }
      _publicationUnconfirmed = true;
      _publicationRetryConfirmed = false;
      final post = await groups.createPost(
        groupId: groupId,
        content: content,
        isAnnouncement: announcement,
        cancelToken: token,
      );
      if (valid()) {
        setState(() {
          _clearReview();
          _published = post.postId;
          _notice = 'published';
        });
      }
    });
  }

  Future<void> _saveToCloudDraft() async {
    final id = _selected;
    final draft = _review;
    final content = _edited.text;
    if (id == null ||
        draft == null ||
        !_allowed ||
        _needsRefresh ||
        utf8.encode(content).length > 4000) {
      return;
    }
    final scope = PostDraftScope(ref);
    if (!scope.isCurrent(ref)) return;
    final input = V2PostDraftInput(
      groupId: widget.groupId,
      content: content,
      announcement: _announcement,
    );
    await _work(_Phase.saveDraft, (api, token, valid) async {
      final matches = await _matchesCurrent(api, token, id, draft);
      if (!valid() || !scope.isCurrent(ref)) return;
      if (!matches) {
        _markStale();
        return;
      }
      if (_savedDraftInput?.matches(input) == true) return;
      await scope.api.save(input, cancel: token);
      if (valid() && scope.isCurrent(ref)) {
        setState(() {
          _savedDraftInput = input;
          _notice = 'savedToCloud';
        });
      }
    });
  }

  void _openPost(int postId, {int? commentId}) {
    final path = '/groups/${Uri.encodeComponent(widget.slug)}/posts/$postId';
    context.push(commentId == null ? path : '$path?comment=$commentId');
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(aiGroupDraftApiProvider, (old, next) {
      if (old != null && !identical(old, next)) _expire();
    });
    ref.listen(groupsApiProvider, (old, next) {
      if (old != null && !identical(old, next)) _expire();
    });
    ref.listen(aiWritingApiProvider, (old, next) {
      if (old != null && !identical(old, next)) _expire();
    });
    final l10n = AppLocalizations.of(context);
    String label(String name) => l10n.t('ai.groupDraft.$name');
    final theme = Theme.of(context);
    final busy = _phase != null;
    final availability = _availability;
    final notice = _notice;
    final published = _published;
    final editedBytes = _review == null
        ? 0
        : utf8.encode(_edited.text.trim()).length;
    return Scaffold(
      appBar: AppBar(
        title: Text(label('title')),
        actions: [
          IconButton(
            key: const Key('group-draft-refresh'),
            tooltip: l10n.t('common.refresh'),
            icon: const Icon(Icons.refresh),
            onPressed: busy || _expired ? null : _reload,
          ),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppBreakpoints.contentMaxWidth,
          ),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (busy) const LinearProgressIndicator(),
              if (busy)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    label(_phase == _Phase.generate ? 'generating' : 'working'),
                  ),
                ),
              if (notice != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      notice == 'quota'
                          ? aiQuotaNotice(l10n, _quotaRetry)
                          : label(notice),
                    ),
                  ),
                ),
              if (published != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => _openPost(published),
                    child: Text(label('openPost')),
                  ),
                ),
              if (_publicationUnconfirmed && !busy)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => context.push(
                      '/groups/${Uri.encodeComponent(widget.slug)}',
                    ),
                    child: Text(label('checkGroupPosts')),
                  ),
                ),
              if (_allowed) ...[
                Text(_groupName, style: theme.textTheme.titleSmall),
                if (_skill != null || _modelConfigRevision != null)
                  AiSkillMetadata(
                    skill: _skill,
                    modelConfigRevision: _modelConfigRevision,
                  ),
                if (availability != 'enabled')
                  Semantics(
                    liveRegion: true,
                    child: Text(l10n.t('ai.availability.$availability')),
                  ),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(label('history'), style: theme.textTheme.titleMedium),
                    TextButton(
                      onPressed: busy ? null : _newConversation,
                      child: Text(label('new')),
                    ),
                    if (_selected != null && _review == null)
                      TextButton(
                        onPressed: busy || _needsRefresh
                            ? null
                            : () => setState(() => _deleteConfirm = true),
                        child: Text(label('delete')),
                      ),
                    if (_next != null)
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => _work(
                                _Phase.page,
                                (api, token, valid) =>
                                    _pageHistory(api, token, valid, _next),
                              ),
                        child: Text(label('more')),
                      ),
                  ],
                ),
                if (_history.isEmpty && !busy) Text(label('noHistory')),
                if (_history.isNotEmpty)
                  SizedBox(
                    height: 128,
                    child: ListView.builder(
                      primary: false,
                      itemCount: _history.length,
                      itemBuilder: (_, index) {
                        final item = _history[index];
                        return ListTile(
                          dense: true,
                          selected: _selected == item.id,
                          title: Text(
                            item.title?.isNotEmpty == true
                                ? item.title!
                                : label('untitled'),
                          ),
                          subtitle: Text(
                            item.updatedAt,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: busy ? null : () => _open(item),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 12),
                if (_deleteConfirm)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(label('deleteQuestion')),
                          Wrap(
                            spacing: 8,
                            children: [
                              TextButton(
                                onPressed: busy ? null : _removeConversation,
                                child: Text(label('confirmDelete')),
                              ),
                              TextButton(
                                onPressed: busy
                                    ? null
                                    : () => setState(
                                        () => _deleteConfirm = false,
                                      ),
                                child: Text(l10n.t('common.cancel')),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    DropdownButton<GroupDraftKind>(
                      value: _kind,
                      hint: Text(label('kind')),
                      items: GroupDraftKind.values
                          .map(
                            (kind) => DropdownMenuItem(
                              value: kind,
                              child: Text(label(kind.key)),
                            ),
                          )
                          .toList(),
                      onChanged: busy || _review != null
                          ? null
                          : (value) {
                              if (value != null) setState(() => _kind = value);
                            },
                    ),
                    Semantics(
                      label: label('skill'),
                      child: DropdownButton<bool>(
                        value: _explicitSkill,
                        items: [
                          DropdownMenuItem(
                            value: false,
                            child: Text(label('automaticSkill')),
                          ),
                          DropdownMenuItem(
                            value: true,
                            child: Text(label('groupBriefSkill')),
                          ),
                        ],
                        onChanged: busy || _review != null
                            ? null
                            : (value) {
                                if (value != null) {
                                  setState(() => _explicitSkill = value);
                                }
                              },
                      ),
                    ),
                    if (_review == null)
                      SizedBox(
                        width: 220,
                        child: TextField(
                          key: const Key('group-draft-search'),
                          controller: _search,
                          enabled: !busy,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            labelText: label('searchTerm'),
                          ),
                        ),
                      ),
                    FilledButton(
                      onPressed:
                          busy ||
                              _needsRefresh ||
                              _invalidSearch ||
                              availability != 'enabled' ||
                              _review != null ||
                              _deleteConfirm
                          ? null
                          : _generate,
                      child: Text(label('generate')),
                    ),
                    if (_phase == _Phase.generate)
                      OutlinedButton(
                        onPressed: _cancel,
                        child: Text(l10n.t('common.cancel')),
                      ),
                  ],
                ),
                if (_preview.isNotEmpty && _phase == _Phase.generate)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 160),
                    child: SingleChildScrollView(child: Text(_preview)),
                  ),
                if (_invalidSearch && _review == null)
                  Text(
                    label('searchInvalid'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (_review != null)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label('reviewTitle'),
                            style: theme.textTheme.titleSmall,
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            key: const Key('group-draft-editor'),
                            controller: _edited,
                            enabled: !busy,
                            minLines: 3,
                            maxLines: 7,
                            onChanged: (_) => setState(() {}),
                            decoration: InputDecoration(
                              labelText: label('draftText'),
                              counterText: label(
                                'draftBytes',
                              ).replaceFirst('{bytes}', '$editedBytes'),
                              errorText: editedBytes > 4000
                                  ? label('tooLong')
                                  : null,
                              border: const OutlineInputBorder(),
                            ),
                          ),
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(label('publishAsAnnouncement')),
                            value: _announcement,
                            onChanged: busy
                                ? null
                                : (value) => setState(
                                    () => _announcement = value ?? false,
                                  ),
                          ),
                          if (_publicationUnconfirmed && !_needsRefresh)
                            CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(label('confirmPublicationRetry')),
                              value: _publicationRetryConfirmed,
                              onChanged: busy
                                  ? null
                                  : (value) => setState(() {
                                      _publicationRetryConfirmed =
                                          value ?? false;
                                    }),
                            ),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              FilledButton(
                                onPressed:
                                    busy ||
                                        _needsRefresh ||
                                        _publicationNeedsConfirmation ||
                                        editedBytes == 0 ||
                                        editedBytes > 4000
                                    ? null
                                    : _publish,
                                child: Text(label('confirmPublish')),
                              ),
                              TextButton(
                                key: const Key('ai-group-save-cloud-draft'),
                                onPressed: busy || _needsRefresh || editedBytes > 4000
                                    ? null
                                    : _saveToCloudDraft,
                                child: Text(l10n.t('draft.save')),
                              ),
                              TextButton(
                                onPressed: busy
                                    ? null
                                    : () => setState(_clearReview),
                                child: Text(l10n.t('common.cancel')),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                for (final message in _messages.reversed.where(
                  (entry) => entry.role == 'assistant',
                ))
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SelectableText(
                            message.sources.isEmpty
                                ? label('staleDraft')
                                : message.content,
                          ),
                          if (message.sources.isNotEmpty &&
                              message.modelVersion != null)
                            Text(
                              '${l10n.t('ai.modelVersion')} · ${message.modelVersion}',
                              style: theme.textTheme.bodySmall,
                            ),
                          if (message.sources.isNotEmpty &&
                              message.configRevision != null)
                            Text(
                              l10n
                                  .t('ai.replyConfigRevision')
                                  .replaceAll(
                                    '{revision}',
                                    '${message.configRevision}',
                                  ),
                              style: theme.textTheme.bodySmall,
                            ),
                          if (message.tools.isNotEmpty)
                            Text(
                              label('usedTools').replaceAll(
                                '{tools}',
                                message.tools
                                    .map(label)
                                    .join(
                                      l10n.locale.languageCode == 'en'
                                          ? ', '
                                          : '、',
                                    ),
                              ),
                              style: theme.textTheme.bodySmall,
                            ),
                          if (message.sources.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(
                              label('sources'),
                              style: theme.textTheme.labelMedium,
                            ),
                            Wrap(
                              spacing: 6,
                              children: [
                                for (final source in message.sources)
                                  TextButton(
                                    onPressed: () => _openPost(
                                      source.postId,
                                      commentId: source.kind == 'comment'
                                          ? source.id
                                          : null,
                                    ),
                                    child: Text(
                                      '${label(source.kind)} #${source.id}',
                                    ),
                                  ),
                              ],
                            ),
                            OutlinedButton(
                              onPressed:
                                  busy ||
                                      _needsRefresh ||
                                      _review != null ||
                                      _deleteConfirm
                                  ? null
                                  : () => _startReview(message),
                              child: Text(label('review')),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                if (_hasOlderMessages)
                  TextButton(
                    onPressed: busy || _needsRefresh ? null : _loadOlder,
                    child: Text(l10n.t('chat.dm.load_older')),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
