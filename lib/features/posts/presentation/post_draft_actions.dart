import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/group_post_link.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/routing/auth_navigation.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/post_draft.dart';
import 'post_draft_scope.dart';

String draftDateLabel(BuildContext context, DateTime date) {
  final local = date.toLocal();
  return '${MaterialLocalizations.of(context).formatShortDate(local)} '
      '${TimeOfDay.fromDateTime(local).format(context)}';
}

String draftStatusLabel(BuildContext context, V2PostDraft draft) {
  final l10n = AppLocalizations.of(context);
  final status = l10n.t('draft.status.${draft.status.name}');
  final at = draft.scheduledAt;
  if (draft.status == PostDraftStatus.scheduled && at != null) {
    return '$status · ${draftDateLabel(context, at)}';
  }
  final reason = draft.lastError;
  if (draft.status == PostDraftStatus.failed && reason != null) {
    return '$status · ${l10n.t('draft.error.$reason')}';
  }
  return status;
}

void openPublishedDraft(BuildContext context, V2PostDraft draft) {
  final id = draft.publishedPostId;
  if (id == null) return;
  final groupId = draft.payload.groupId;
  context.push(
    groupId == null
        ? '/posts/$id'
        : groupPostLocation((groupId: groupId, postId: id, commentId: null)),
  );
}

Future<bool> confirmDraftAction(
  BuildContext context,
  String title,
  String description,
) async {
  final l10n = AppLocalizations.of(context);
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.t(title)),
          content: Text(description),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.t('common.cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.t(title)),
            ),
          ],
        ),
      ) ??
      false;
}

class PostDraftActions extends ConsumerStatefulWidget {
  const PostDraftActions({
    super.key,
    this.initial,
    required this.readInput,
    required this.onChanged,
    required this.onWorkingChanged,
    this.enabled = true,
  });

  final ScopedPostDraft? initial;
  final V2PostDraftInput Function() readInput;
  final ValueChanged<V2PostDraft> onChanged;
  final ValueChanged<bool> onWorkingChanged;
  final bool enabled;

  @override
  ConsumerState<PostDraftActions> createState() => _PostDraftActionsState();
}

class _PostDraftActionsState extends ConsumerState<PostDraftActions> {
  late PostDraftScope? _scope = widget.initial?.scope;
  late V2PostDraft? _draft = widget.initial?.draft;
  CancelToken? _request;
  String? _message;
  late final VoidCallback _stopSession;

  bool get _active => mounted && !(_scope?.isCurrent(ref) == false);

  @override
  void initState() {
    super.initState();
    _stopSession = ref.read(tokenStoreProvider).listenSessionChanges(() {
      if (!mounted || _scope == null || _active) return;
      _request?.cancel();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _stopSession();
    _request?.cancel();
    super.dispose();
  }

  Future<void> _run(
    Future<void> Function(PostDraftScope scope, CancelToken request) operation,
  ) async {
    if (!widget.enabled || _request != null || !_active) return;
    if (!requireAuthenticatedAction(context, ref)) return;
    final scope = _scope ??= PostDraftScope(ref);
    if (!scope.isCurrent(ref)) return;
    final token = CancelToken();
    setState(() {
      _request = token;
      _message = null;
    });
    widget.onWorkingChanged(true);
    try {
      await operation(scope, token);
    } catch (error) {
      if (_active) {
        setState(() => _message = ErrorView.describe(context, error));
      }
    } finally {
      if (_active && identical(token, _request)) {
        setState(() => _request = null);
        widget.onWorkingChanged(false);
      }
    }
  }

  void _record(V2PostDraft draft) {
    if (!_active) return;
    setState(() => _draft = draft);
    widget.onChanged(draft);
  }

  void _showError(String key) {
    setState(() => _message = AppLocalizations.of(context).t(key));
  }

  Future<V2PostDraft> _saveIfChanged(
    PostDraftScope scope,
    CancelToken request,
    V2PostDraftInput input, {
    bool force = false,
  }) async {
    final current = _draft;
    if (!force && current != null && current.payload.matches(input)) {
      return current;
    }
    final saved = await scope.api.save(input, id: current?.id, cancel: request);
    _record(saved);
    return saved;
  }

  Future<void> _save() async {
    if (!_active) return;
    final input = widget.readInput();
    if (!input.canSave) {
      _showError('draft.invalid');
      return;
    }
    if (_draft?.status == PostDraftStatus.scheduled &&
        !await confirmDraftAction(
          context,
          'draft.save',
          AppLocalizations.of(context).t('draft.confirm_save'),
        )) {
      return;
    }
    if (!_active) return;
    await _run((scope, request) async {
      await _saveIfChanged(scope, request, input, force: true);
      if (_active) _showError('draft.saved');
    });
  }

  Future<void> _schedule() async {
    if (!_active) return;
    final input = widget.readInput();
    if (!input.canPublish) {
      _showError('draft.not_publishable');
      return;
    }
    final now = DateTime.now();
    final existing = _draft?.scheduledAt?.toLocal();
    final initial = existing != null && existing.isAfter(now)
        ? existing
        : now.add(const Duration(hours: 1));
    final date = await showDatePicker(
      context: context,
      firstDate: now,
      initialDate: initial,
      lastDate: DateTime(9999, 12, 31),
    );
    if (!_active || date == null) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (!_active || time == null) return;
    final at = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    if (!at.isAfter(DateTime.now())) {
      _showError('draft.future_date');
      return;
    }
    if (input.poll case final poll? when !poll.closesAt.isAfter(at)) {
      _showError('draft.before_poll');
      return;
    }
    final l10n = AppLocalizations.of(context);
    final confirmed = await confirmDraftAction(
      context,
      'draft.schedule',
      l10n
          .t('draft.confirm_schedule')
          .replaceFirst('{date}', draftDateLabel(context, at)),
    );
    if (!_active || !confirmed) return;
    await _run((scope, request) async {
      final draft = await _saveIfChanged(scope, request, input);
      if (!_active) return;
      _record(await scope.api.schedule(draft, at, cancel: request));
    });
  }

  Future<void> _publish() async {
    if (!_active) return;
    final input = widget.readInput();
    if (!input.canPublish) {
      _showError('draft.not_publishable');
      return;
    }
    final confirmed = await confirmDraftAction(
      context,
      'draft.publish',
      AppLocalizations.of(context).t('draft.confirm_publish'),
    );
    if (!_active || !confirmed) return;
    await _run((scope, request) async {
      final draft = await _saveIfChanged(scope, request, input);
      if (!_active) return;
      _record(await scope.api.publish(draft, cancel: request));
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_scope != null) {
      ref.watch(authSessionProvider.select((state) => state.isAuthenticated));
      if (!_active) return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    final enabled = widget.enabled && _request == null;
    final draft = _draft;
    final published = draft?.status == PostDraftStatus.published;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (draft != null) Text(draftStatusLabel(context, draft)),
        if (_message != null) Text(_message!),
        Wrap(
          spacing: 8,
          children: [
            if (!published) ...[
              TextButton.icon(
                key: const Key('cloud-draft-save'),
                onPressed: enabled ? _save : null,
                icon: const Icon(Icons.cloud_upload_outlined),
                label: Text(l10n.t('draft.save')),
              ),
              TextButton(
                key: const Key('cloud-draft-schedule'),
                onPressed: enabled ? _schedule : null,
                child: Text(l10n.t('draft.schedule')),
              ),
            ],
            if (draft?.status == PostDraftStatus.scheduled)
              TextButton(
                key: const Key('cloud-draft-unschedule'),
                onPressed: enabled
                    ? () => _run((scope, request) async {
                        _record(
                          await scope.api.unschedule(draft!, cancel: request),
                        );
                      })
                    : null,
                child: Text(l10n.t('draft.unschedule')),
              ),
            if (draft != null && !published)
              FilledButton(
                key: const Key('cloud-draft-publish'),
                onPressed: enabled ? _publish : null,
                child: Text(l10n.t('draft.publish')),
              ),
            if (draft != null && published)
              TextButton(
                onPressed: () => openPublishedDraft(context, draft),
                child: Text(l10n.t('draft.open_post')),
              ),
          ],
        ),
      ],
    );
  }
}
