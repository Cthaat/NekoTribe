import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/network/api_exception.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/status_views.dart';
import '../../../shared/widgets/viewport_visibility.dart';
import '../domain/post_poll.dart';

class PostPollCard extends ConsumerStatefulWidget {
  const PostPollCard({
    super.key,
    required this.postId,
    required this.poll,
    this.groupId,
    this.canWrite = true,
  });

  final int postId;
  final int? groupId;
  final V2PostPoll poll;
  final bool canWrite;

  @override
  ConsumerState<PostPollCard> createState() => _PostPollCardState();
}

class _PostPollCardState extends ConsumerState<PostPollCard>
    with WidgetsBindingObserver {
  static const _refreshInterval = Duration(seconds: 5);

  late V2PostPoll _poll = widget.poll;
  final _selection = <int>{};
  Timer? _timer;
  CancelToken? _request;
  bool _sending = false;
  bool _unavailable = false;
  bool _needsScopeRefresh = false;
  bool _trustEmbedded = true;
  bool _routeActive = false;
  late VoidCallback _stopSession;

  bool get _canVote =>
      !_needsScopeRefresh &&
      !_unavailable &&
      !_poll.closed &&
      _poll.myOptionIds.isEmpty &&
      widget.canWrite &&
      ref.read(authSessionProvider).isAuthenticated;

  @override
  void initState() {
    super.initState();
    final tokens = ref.read(tokenStoreProvider);
    _needsScopeRefresh = tokens.isSessionChanging;
    _trustEmbedded = !_needsScopeRefresh;
    _stopSession = tokens.listenSessionChanges(_scopeChanged);
    if (widget.groupId == null) {
      ref.listenManual(postsApiProvider, (_, _) => _scopeChanged());
    } else {
      ref.listenManual(groupsApiProvider, (_, _) => _scopeChanged());
    }
    ref.listenManual(tokenStoreProvider, (_, next) {
      _stopSession();
      _stopSession = next.listenSessionChanges(_scopeChanged);
      _scopeChanged();
    });
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeActive =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    _syncTimer();
  }

  @override
  void didUpdateWidget(PostPollCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    assert(widget.postId == oldWidget.postId);
    assert(widget.groupId == oldWidget.groupId);
    assert(widget.poll.pollId == oldWidget.poll.pollId);
    if (_trustEmbedded &&
        !_unavailable &&
        !identical(widget.poll, oldWidget.poll)) {
      _apply(widget.poll);
    }
    if (!widget.canWrite) _selection.clear();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _syncTimer();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopSession();
    _timer?.cancel();
    _request?.cancel();
    super.dispose();
  }

  void _scopeChanged() {
    if (!mounted) return;
    _request?.cancel();
    _request = null;
    setState(() {
      _needsScopeRefresh = true;
      _trustEmbedded = false;
      _unavailable = false;
      _sending = false;
      _selection.clear();
    });
    _syncTimer();
  }

  void _hide() {
    _request = null;
    setState(() => _unavailable = true);
    _syncTimer();
  }

  void _syncTimer() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (_unavailable ||
        (!_needsScopeRefresh && _poll.closed) ||
        !_routeActive ||
        (lifecycle != null && lifecycle != AppLifecycleState.resumed)) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(_refreshInterval, (_) {
      if (intersectsVisibleViewport(context)) unawaited(_refresh());
    });
  }

  bool _current(CancelToken request) =>
      mounted && !_unavailable && identical(_request, request);

  void _apply(V2PostPoll next) {
    if (next.pollId != _poll.pollId ||
        (!_needsScopeRefresh &&
            (next.totalBallots < _poll.totalBallots ||
                (_poll.closed && !next.closed) ||
                (_poll.myOptionIds.isNotEmpty && next.myOptionIds.isEmpty)))) {
      return;
    }
    _poll = next;
    _needsScopeRefresh = false;
    if (next.closed || next.myOptionIds.isNotEmpty) _selection.clear();
    _syncTimer();
  }

  Future<void> _refresh() async {
    if (_request != null ||
        _unavailable ||
        (!_needsScopeRefresh && _poll.closed) ||
        ref.read(tokenStoreProvider).isSessionChanging) {
      return;
    }
    final request = _request = CancelToken();
    try {
      final groupId = widget.groupId;
      final next = groupId == null
          ? await ref
                .read(postsApiProvider)
                .getPoll(widget.postId, cancelToken: request)
          : await ref
                .read(groupsApiProvider)
                .getPoll(
                  groupId: groupId,
                  postId: widget.postId,
                  cancelToken: request,
                );
      if (!_current(request)) return;
      if (next.pollId != widget.poll.pollId) {
        _hide();
        return;
      }
      setState(() => _apply(next));
    } on ApiException catch (error) {
      if (_current(request) &&
          (error.isNotFound || error.isForbidden || error.isUnauthorized)) {
        _hide();
      }
    } catch (_) {
      // Keep the last confirmed result through transient refresh failures.
    } finally {
      if (_current(request)) _request = null;
    }
  }

  Future<void> _vote() async {
    if (!_canVote || _sending || _selection.isEmpty) return;
    _request?.cancel();
    final request = _request = CancelToken();
    final selected = _selection.toList()..sort();
    setState(() => _sending = true);
    var refreshAfterConflict = false;
    try {
      final groupId = widget.groupId;
      final next = groupId == null
          ? await ref
                .read(postsApiProvider)
                .votePoll(widget.postId, selected, cancelToken: request)
          : await ref
                .read(groupsApiProvider)
                .votePoll(
                  groupId: groupId,
                  postId: widget.postId,
                  optionIds: selected,
                  cancelToken: request,
                );
      if (!_current(request)) return;
      if (next.pollId != _poll.pollId ||
          next.myOptionIds.length != selected.length ||
          !next.myOptionIds.every(selected.contains)) {
        throw const FormatException('Invalid post poll receipt');
      }
      setState(() => _apply(next));
    } catch (error) {
      if (!_current(request)) return;
      if (error is ApiException && error.isNotFound) {
        _hide();
        return;
      }
      final conflict =
          error is ApiException &&
          (error.statusCode == 409 || error.code == 40901);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            conflict
                ? AppLocalizations.of(context).t('poll.vote_conflict')
                : ErrorView.describe(context, error),
          ),
        ),
      );
      refreshAfterConflict = conflict;
    } finally {
      if (_current(request)) {
        _request = null;
        setState(() => _sending = false);
        if (refreshAfterConflict) unawaited(_refresh());
      }
    }
  }

  void _toggleOption(int id) {
    setState(() {
      if (_poll.multiple) {
        if (!_selection.remove(id)) _selection.add(id);
      } else {
        _selection
          ..clear()
          ..add(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(authSessionProvider.select((value) => value.isAuthenticated));
    if (_unavailable) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    if (_needsScopeRefresh) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(l10n.t('poll.loading')),
      );
    }
    final materials = MaterialLocalizations.of(context);
    final theme = Theme.of(context);
    final deadline = _poll.closesAt.toLocal();
    final canVote = _canVote;
    final canSelect = canVote && !_sending;
    final percent = NumberFormat.decimalPercentPattern(
      locale: l10n.locale.languageCode,
      decimalDigits: 1,
    );
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Wrap(
              spacing: 10,
              children: [
                Text(
                  l10n.t(
                    _poll.multiple
                        ? 'poll.multiple_choice'
                        : 'poll.single_choice',
                  ),
                ),
                Text(
                  l10n
                      .t('poll.ballots')
                      .replaceFirst('{count}', '${_poll.totalBallots}'),
                ),
                Text(
                  l10n
                      .t(_poll.closed ? 'poll.closed_at' : 'poll.closes_at')
                      .replaceFirst(
                        '{date}',
                        '${materials.formatShortDate(deadline)} '
                            '${TimeOfDay.fromDateTime(deadline).format(context)}',
                      ),
                ),
              ],
            ),
          ),
          for (final option in _poll.options)
            ListTile(
              key: ValueKey('post-poll-choice-${option.optionId}'),
              dense: true,
              leading: _poll.myOptionIds.contains(option.optionId)
                  ? Tooltip(
                      message: l10n.t('poll.your_choice'),
                      child: const Icon(Icons.check_circle),
                    )
                  : canVote
                  ? Icon(
                      _poll.multiple
                          ? _selection.contains(option.optionId)
                                ? Icons.check_box
                                : Icons.check_box_outline_blank
                          : _selection.contains(option.optionId)
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                    )
                  : null,
              selected:
                  _selection.contains(option.optionId) ||
                  _poll.myOptionIds.contains(option.optionId),
              onTap: canSelect ? () => _toggleOption(option.optionId) : null,
              title: Text(option.text),
              subtitle: Text(
                l10n
                    .t('poll.option_results')
                    .replaceFirst('{count}', '${option.votesCount}')
                    .replaceFirst(
                      '{percent}',
                      percent.format(option.percent / 100),
                    ),
              ),
            ),
          if (canVote)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: FilledButton.tonal(
                key: const Key('post-poll-vote'),
                onPressed: canSelect && _selection.isNotEmpty ? _vote : null,
                child: Text(l10n.t('poll.vote')),
              ),
            ),
        ],
      ),
    );
  }
}
