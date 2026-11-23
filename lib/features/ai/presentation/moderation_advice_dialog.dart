import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/utils/group_post_link.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../data/ai_moderation_advice_api.dart';
import '../data/ai_writing_api.dart';
import '../data/moderation_rule_catalog.dart';
import 'ai_quota_notice.dart';
import 'ai_skill_metadata.dart';
import 'public_terms_dialog.dart';

class ModerationAdviceButton extends StatelessWidget {
  const ModerationAdviceButton({
    super.key,
    required this.kind,
    required this.targetId,
  });
  final String kind;
  final int targetId;

  @override
  Widget build(BuildContext context) {
    final target = moderationAdviceTarget(kind, targetId);
    if (target == null) return const SizedBox.shrink();
    final router = GoRouter.maybeOf(context);
    return OutlinedButton(
      onPressed: () => showDialog<void>(
        context: context,
        builder: (_) => _ModerationAdviceDialog(target: target, router: router),
      ),
      child: Text(AppLocalizations.of(context).t('moderation.advice.title')),
    );
  }
}

enum _Request { history, older, generate, feedback, remove }

class _ModerationAdviceDialog extends ConsumerStatefulWidget {
  const _ModerationAdviceDialog({required this.target, this.router});
  final ModerationAdviceTarget target;
  final GoRouter? router;

  @override
  ConsumerState<_ModerationAdviceDialog> createState() =>
      _ModerationAdviceDialogState();
}

class _ModerationAdviceDialogState
    extends ConsumerState<_ModerationAdviceDialog> {
  ModerationAdviceHistory? _history;
  ({
    ModerationAdviceHistory history,
    String id,
    ModerationAdviceMessage? message,
  })?
  _deleteConfirm;
  CancelToken? _active;
  _Request? _busy;
  bool _generating = false;
  String _preview = '';
  String? _notice;
  String _availability = 'loading';
  AiSkillAvailability? _skill;
  int? _modelConfigRevision;
  bool _explicitSkill = false;
  int _quotaRetry = 0;
  bool _expired = false;
  VoidCallback? _stopListening;

  @override
  void initState() {
    super.initState();
    final store = ref.read(tokenStoreProvider);
    _expired = store.isSessionChanging;
    if (_expired) _notice = 'sessionChanged';
    _stopListening = store.listenSessionChanges(_expire);
    ref.listenManual(apiClientProvider, (previous, next) {
      if (!identical(previous, next)) _expire();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load(_Request.history);
    });
  }

  @override
  void dispose() {
    _stopListening?.call();
    _active?.cancel();
    super.dispose();
  }

  void _expire() {
    if (!mounted || _expired) return;
    _active?.cancel();
    setState(() {
      _expired = true;
      _history = null;
      _deleteConfirm = null;
      _active = null;
      _busy = null;
      _generating = false;
      _preview = '';
      _notice = 'sessionChanged';
      _availability = 'loading';
      _skill = null;
      _modelConfigRevision = null;
      _explicitSkill = false;
    });
  }

  Future<void> _load(
    _Request mode, {
    ({ModerationAdviceMessage message, ModerationRating rating})? feedback,
  }) async {
    final store = ref.read(tokenStoreProvider);
    if (_active != null || _expired || store.isSessionChanging) return;
    final previous = _history;
    final deleteId =
        mode == _Request.remove && previous == _deleteConfirm?.history
        ? _deleteConfirm?.id
        : null;
    if (mode == _Request.remove && deleteId == null) return;
    if (mode == _Request.older && previous?.older.isNotEmpty != true) return;
    if (mode == _Request.generate &&
        (previous == null || _availability != 'enabled')) {
      return;
    }
    if (mode == _Request.feedback &&
        (feedback == null ||
            feedback.message.advice == null ||
            feedback.message.rating == feedback.rating ||
            previous?.messages.contains(feedback.message) != true)) {
      return;
    }
    final client = ref.read(apiClientProvider);
    final api = AiModerationAdviceApi(client);
    final revision = store.revision;
    final token = CancelToken();
    final locale = AppLocalizations.of(context).locale.languageCode == 'en'
        ? 'en'
        : 'zh';
    bool valid() =>
        mounted &&
        identical(_active, token) &&
        !token.isCancelled &&
        !_expired &&
        !store.isSessionChanging &&
        store.revision == revision &&
        identical(ref.read(tokenStoreProvider), store) &&
        identical(ref.read(apiClientProvider), client);
    setState(() {
      _active = token;
      _busy = mode;
      _deleteConfirm = null;
      if (feedback == null && mode != _Request.older) _history = null;
      if (mode == _Request.history) {
        _availability = 'loading';
        _skill = null;
        _modelConfigRevision = null;
        _explicitSkill = false;
      }
      _notice = null;
    });
    var generationSaved = false;
    try {
      var insufficient = false;
      if (mode == _Request.generate && previous != null) {
        final id =
            previous.conversationId ?? await api.create(widget.target, token);
        if (!valid()) return;
        setState(() => _generating = true);
        insufficient = !await api.generate(
          id,
          widget.target,
          locale,
          previous.sequence,
          token,
          selectSkill:
              _explicitSkill &&
              _skill?.explicitSelection == true &&
              _skill?.enabled == true,
          onDelta: (text) {
            if (valid()) setState(() => _preview += text);
          },
        );
        if (!valid()) return;
        generationSaved = !insufficient;
        setState(() {
          _generating = false;
          _preview = '';
        });
      }
      if (feedback != null && previous != null) {
        final confirmed = await api.rate(
          feedback.message,
          feedback.rating,
          widget.target,
          token,
        );
        if (!valid()) return;
        setState(() {
          _history = confirmed == null
              ? null
              : (
                  conversationId: previous.conversationId,
                  sequence: previous.sequence,
                  messages: [
                    for (final message in previous.messages)
                      message == feedback.message ? confirmed : message,
                  ],
                  older: previous.older,
                  latestSequences: previous.latestSequences,
                );
          _notice = confirmed == null ? 'conflict' : 'feedbackSaved';
        });
        return;
      }
      if (deleteId != null) {
        await api.remove(deleteId, token);
        if (!valid()) return;
      }
      final statusRequest = mode == _Request.history
          ? _readAvailability(AiWritingApi(client), token, valid)
          : Future<void>.value();
      final history = mode == _Request.older && previous != null
          ? await api.older(previous, widget.target, token)
          : await api.history(widget.target, token);
      if (!valid()) return;
      setState(() {
        _history = history;
        if (insufficient) _notice = 'insufficient';
        if (deleteId != null) _notice = 'deleted';
      });
      await statusRequest;
    } catch (error) {
      if (!valid()) return;
      final status = error is ApiException ? error.statusCode : null;
      final retry = mode == _Request.generate ? aiQuotaRetry(error) : null;
      setState(() {
        if (retry != null) {
          _quotaRetry = retry;
          _history = previous;
          _notice = 'quota';
          return;
        }
        _history = null;
        if (deleteId != null) {
          _notice = 'deleteUnknown';
          return;
        }
        _notice = switch (status) {
          _
              when generationSaved &&
                  status != 401 &&
                  status != 403 &&
                  status != 404 =>
            'generationSaved',
          409 => 'conflict',
          404 when feedback != null => 'conflict',
          503 => feedback != null ? 'feedbackUnavailable' : 'unavailable',
          401 || 403 => 'forbidden',
          _ => feedback != null ? 'feedbackFailed' : 'failed',
        };
      });
    } finally {
      if (mounted && identical(_active, token)) {
        setState(() {
          _active = null;
          _busy = null;
          _generating = false;
          _preview = '';
        });
      }
    }
  }

  void _askDelete([ModerationAdviceMessage? message]) {
    final history = _history;
    if (_busy != null || _expired || history == null) return;
    if (message != null && !history.messages.contains(message)) return;
    final id = message?.conversationId ?? history.conversationId;
    if (id != null) {
      setState(
        () => _deleteConfirm = (history: history, id: id, message: message),
      );
    }
  }

  void _stopGeneration() {
    if (!_generating || _active == null) return;
    _active!.cancel();
    setState(() {
      _active = null;
      _busy = null;
      _generating = false;
      _preview = '';
      _notice = 'generationStopped';
    });
  }

  void _openRule(ModerationRule reference) {
    final l10n = AppLocalizations.of(context);
    final rule = readModerationRule(
      reference,
      bundle: DefaultAssetBundle.of(context),
    );
    showDialog<void>(
      context: context,
      builder: (_) =>
          PublicTermsDialog(title: _ruleLabel(l10n, reference), document: rule),
    );
  }

  void _openSource(ModerationAdviceSource source) {
    if (!mounted ||
        _expired ||
        ref.read(tokenStoreProvider).isSessionChanging) {
      return;
    }
    final groupId = source.groupId;
    final commentId = source.commentId;
    final location = groupId == null
        ? Uri(
            path: '/posts/${source.postId}',
            queryParameters: commentId == null
                ? null
                : {'comment': '$commentId'},
          ).toString()
        : groupPostLocation((
            groupId: groupId,
            postId: source.postId,
            commentId: commentId,
          ));
    widget.router?.push<void>(location);
  }

  Future<void> _readAvailability(
    AiWritingApi api,
    CancelToken token,
    bool Function() valid,
  ) async {
    String state;
    AiSkillAvailability? skill;
    int? modelConfigRevision;
    try {
      final flags = await api.availabilityWithCancel(token);
      state = flags.workflowStatus(forModeration: true);
      skill = flags.skills['moderation'];
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

  String _ruleLabel(AppLocalizations l10n, ModerationRule rule) => l10n
      .t('moderation.advice.rule')
      .replaceAll('{id}', '${rule.id}')
      .replaceAll('{version}', rule.version.substring(0, 8));

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final material = MaterialLocalizations.of(context);
    String label(String key) => l10n.t('moderation.advice.$key');
    String timestamp(String raw) {
      final date = DateTime.tryParse(raw)?.toLocal();
      if (date == null) return '';
      final time = material.formatTimeOfDay(TimeOfDay.fromDateTime(date));
      return '${material.formatShortDate(date)} $time';
    }

    final status = switch (_busy) {
      _Request.history || _Request.older => 'loading',
      _Request.generate => 'generating',
      _Request.feedback => 'feedbackSaving',
      _Request.remove => 'deleting',
      null => _notice,
    };
    final history = _history;
    final confirmation = _deleteConfirm;
    final historicalConversations = <String>{};
    final availability = _availability;
    return AlertDialog(
      scrollable: true,
      title: Text(label('title')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!_expired) ...[
            Text(label('description')),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed:
                      _busy == null &&
                          history != null &&
                          availability == 'enabled'
                      ? () => _load(_Request.generate)
                      : null,
                  child: Text(label('generate')),
                ),
                if (_generating)
                  OutlinedButton(
                    key: const Key('moderation-advice-stop'),
                    onPressed: _stopGeneration,
                    child: Text(label('stopGeneration')),
                  ),
                TextButton(
                  onPressed: _busy == null
                      ? () => _load(_Request.history)
                      : null,
                  child: Text(label('refresh')),
                ),
                if (history?.conversationId != null && _deleteConfirm == null)
                  OutlinedButton(
                    onPressed: _busy == null ? () => _askDelete() : null,
                    child: Text(label('deleteConversation')),
                  ),
              ],
            ),
            if (_generating && _preview.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: SingleChildScrollView(child: Text(_preview)),
              ),
            if (confirmation != null)
              Text(
                label(
                  confirmation.message == null
                      ? 'deletePrompt'
                      : 'deleteHistoricalPrompt',
                ),
              ),
            if (confirmation?.message case final message?)
              Text(timestamp(message.createdAt)),
            if (_skill != null || _modelConfigRevision != null)
              AiSkillMetadata(
                skill: _skill,
                modelConfigRevision: _modelConfigRevision,
              ),
            if (_skill?.explicitSelection == true && _skill?.enabled == true)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.t('ai.availability.select_explicitly')),
                value: _explicitSkill,
                onChanged: _busy == null && availability == 'enabled'
                    ? (value) => setState(() => _explicitSkill = value == true)
                    : null,
              ),
            if (availability != 'enabled')
              Semantics(
                liveRegion: true,
                child: Text(l10n.t('ai.availability.$availability')),
              ),
          ],
          if (status != null)
            Semantics(
              liveRegion: true,
              child: Text(
                status == 'quota'
                    ? aiQuotaNotice(l10n, _quotaRetry)
                    : label(status),
              ),
            ),
          if (history != null && _deleteConfirm == null) ...[
            if (status == null && history.messages.isEmpty)
              Text(label('empty')),
            for (final message in history.messages) ...[
              const Divider(),
              Text(
                timestamp(message.createdAt),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (message.conversationId != history.conversationId &&
                  historicalConversations.add(message.conversationId))
                OutlinedButton(
                  onPressed: _busy == null ? () => _askDelete(message) : null,
                  child: Text(label('deleteHistoricalConversation')),
                ),
              if (message.advice case final advice?) ...[
                Text(
                  '${label('risk.${advice.risk}')} · ${label('recommendation.${advice.recommendation}')}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                SelectableText(advice.reason),
                Text(
                  label('analysis.${advice.analysisMode.name}'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (widget.router != null && advice.source != null)
                  TextButton(
                    onPressed: () => _openSource(advice.source!),
                    child: Text(label('openSource')),
                  ),
                if (message.modelVersion case final version?)
                  Text(
                    '${l10n.t('ai.modelVersion')} · $version',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                if (message.configRevision case final revision?)
                  Text(
                    l10n
                        .t('ai.replyConfigRevision')
                        .replaceAll('{revision}', '$revision'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                for (final rule in advice.rules)
                  TextButton(
                    onPressed: () => _openRule(rule),
                    child: Text(_ruleLabel(l10n, rule)),
                  ),
                Semantics(
                  container: true,
                  label: label('feedbackLabel'),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      for (final rating in ModerationRating.values)
                        ChoiceChip(
                          key: ValueKey('rating-${message.id}-${rating.name}'),
                          label: Text(label('feedback.${rating.name}')),
                          selected: rating == message.rating,
                          onSelected: _busy != null
                              ? null
                              : (selected) {
                                  if (selected) {
                                    _load(
                                      _Request.feedback,
                                      feedback: (
                                        message: message,
                                        rating: rating,
                                      ),
                                    );
                                  }
                                },
                        ),
                    ],
                  ),
                ),
              ] else
                Text(label('expired')),
            ],
            if (history.older.isNotEmpty)
              TextButton(
                onPressed: _busy == null ? () => _load(_Request.older) : null,
                child: Text(l10n.t('chat.dm.load_older')),
              ),
          ],
        ],
      ),
      actions: [
        if (_deleteConfirm == null)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.t('common.close')),
          )
        else ...[
          TextButton(
            onPressed: () => setState(() => _deleteConfirm = null),
            child: Text(l10n.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => _load(_Request.remove),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: Text(label('confirmDelete')),
          ),
        ],
      ],
    );
  }
}
