import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/post_draft.dart';
import 'post_draft_actions.dart';
import 'post_draft_scope.dart';

class PostDraftsScreen extends ConsumerStatefulWidget {
  const PostDraftsScreen({super.key, this.groupId, required this.openEditor});

  /// A null scope lists every draft, and zero lists only regular posts.
  final int? groupId;
  final Future<void> Function(BuildContext context, ScopedPostDraft draft)
  openEditor;

  @override
  ConsumerState<PostDraftsScreen> createState() => _PostDraftsScreenState();
}

class _PostDraftsScreenState extends ConsumerState<PostDraftsScreen> {
  late final PostDraftScope _scope;
  late final VoidCallback _stopSession;
  CancelToken? _request;
  final List<V2PostDraft> _drafts = [];
  int? _cursor;
  Object? _error;
  bool _initial = true;
  bool _expired = false;

  bool get _current => mounted && !_expired && _scope.isCurrent(ref);

  @override
  void initState() {
    super.initState();
    _scope = PostDraftScope(ref);
    _stopSession = _scope.store.listenSessionChanges(_expire);
    ref.listenManual(postDraftsApiProvider, (_, _) => _expire());
    ref.listenManual(authSessionProvider, (_, next) {
      if (!next.isAuthenticated) _expire();
    });
    _load();
  }

  @override
  void dispose() {
    _stopSession();
    _request?.cancel();
    super.dispose();
  }

  void _expire() {
    if (!mounted || _expired) return;
    _request?.cancel();
    setState(() {
      _expired = true;
      _drafts.clear();
    });
  }

  Future<void> _load({bool more = false}) async {
    if (!_current || _request != null || (more && _cursor == null)) return;
    final token = CancelToken();
    setState(() {
      _request = token;
      _error = null;
    });
    try {
      final page = await _scope.api.list(
        groupId: widget.groupId,
        beforeId: more ? _cursor : null,
        cancel: token,
      );
      if (!_current) return;
      setState(() {
        if (!more) _drafts.clear();
        _drafts.addAll(page.items);
        _cursor = page.cursor;
      });
    } catch (error) {
      if (_current) setState(() => _error = error);
    } finally {
      if (_current) {
        setState(() {
          _initial = false;
          _request = null;
        });
      }
    }
  }

  Future<void> _open(V2PostDraft draft) async {
    if (!_current || _request != null) return;
    if (draft.status == PostDraftStatus.published) {
      openPublishedDraft(context, draft);
      return;
    }
    await widget.openEditor(context, (scope: _scope, draft: draft));
    if (_current) await _load();
  }

  Future<void> _remove(V2PostDraft draft) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await confirmDraftAction(
      context,
      'draft.delete',
      l10n.t('draft.confirm_delete'),
    );
    if (!confirmed || !_current || _request != null) return;
    final token = CancelToken();
    setState(() => _request = token);
    try {
      await _scope.api.remove(draft.id, cancel: token);
    } catch (error) {
      if (!_current) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorView.describe(context, error))),
      );
    } finally {
      if (_current) setState(() => _request = null);
    }
    if (_current) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('draft.title')),
        actions: [
          IconButton(
            tooltip: l10n.t('draft.refresh'),
            onPressed: _expired || _request != null ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppBreakpoints.contentMaxWidth,
          ),
          child: _expired
              ? EmptyView(message: l10n.t('visibility.sessionChanged'))
              : _initial
              ? const LoadingView()
              : _error != null && _drafts.isEmpty
              ? ErrorView(error: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      if (_drafts.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(l10n.t('draft.empty')),
                        ),
                      for (final draft in _drafts)
                        ListTile(
                          key: ValueKey('cloud-draft-${draft.id}'),
                          title: Text(
                            draft.payload.content.trim().isEmpty
                                ? l10n.t('draft.blank')
                                : draft.payload.content.trim(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(draftStatusLabel(context, draft)),
                          leading: Icon(
                            draft.payload.groupId == null
                                ? Icons.notes
                                : Icons.groups_outlined,
                          ),
                          onTap: _request != null ? null : () => _open(draft),
                          trailing: IconButton(
                            tooltip: l10n.t('draft.delete'),
                            onPressed: _request != null
                                ? null
                                : () => _remove(draft),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ),
                      if (_request != null) const LinearProgressIndicator(),
                      if (_error != null && _drafts.isNotEmpty)
                        ErrorView(error: _error!, onRetry: _load),
                      if (_cursor != null && _request == null)
                        TextButton(
                          onPressed: () => _load(more: true),
                          child: Text(l10n.t('draft.more')),
                        ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}
