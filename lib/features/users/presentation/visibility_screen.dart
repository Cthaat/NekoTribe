import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../../auth/data/auth_repository.dart';
import '../data/users_repository.dart';
import '../domain/user_models.dart';

enum _Kind { blocks, mutes }

class VisibilityScreen extends ConsumerStatefulWidget {
  const VisibilityScreen({super.key});

  @override
  ConsumerState<VisibilityScreen> createState() => _VisibilityScreenState();
}

class _VisibilityScreenState extends ConsumerState<VisibilityScreen> {
  static const _size = 20;
  late final AuthRepository _owner;
  late final UsersRepository _repository;
  late final int _revision;
  late final VoidCallback _stopObserving;
  _Kind _kind = _Kind.blocks;
  List<V2PublicUser> _users = [];
  int _page = 1;
  int _total = 0;
  bool _loading = false;
  bool _expired = false;
  int? _removing;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _owner = ref.read(authRepositoryProvider);
    _repository = ref.read(usersRepositoryProvider);
    _revision = _owner.sessionRevision;
    _expired = _owner.isSessionChanging;
    _stopObserving = _owner.listenSessionChanges(() {
      if (mounted &&
          (_owner.sessionRevision != _revision || _owner.isSessionChanging)) {
        _expire();
      }
    });
    _load(1);
  }

  @override
  void dispose() {
    _stopObserving();
    super.dispose();
  }

  void _expire() {
    if (_expired) return;
    setState(() {
      _expired = true;
      _users = [];
      _error = null;
    });
  }

  bool get _current =>
      mounted &&
      !_expired &&
      identical(ref.read(authRepositoryProvider), _owner) &&
      identical(ref.read(usersRepositoryProvider), _repository) &&
      !_owner.isSessionChanging &&
      _owner.sessionRevision == _revision;
  bool get _busy => _loading || _removing != null;

  int _lastPage(int total) => total == 0 ? 1 : (total + _size - 1) ~/ _size;

  Future<void> _load(int page) async {
    if (!_current || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final fetchPage = _kind == _Kind.blocks
        ? _repository.blocks
        : _repository.mutes;
    try {
      var result = await fetchPage(page: page, size: _size);
      if (!_current) return;
      final lastPage = _lastPage(result.total);
      if (page > lastPage) {
        page = lastPage;
        result = await fetchPage(page: page, size: _size);
        if (!_current) return;
      }
      setState(() {
        _users = result.items;
        _total = result.total;
        _page = page;
      });
    } catch (error) {
      if (_current) setState(() => _error = error);
    } finally {
      if (_current) setState(() => _loading = false);
    }
  }

  void _select(_Kind next) {
    if (!_current || _busy || _kind == next) return;
    setState(() {
      _kind = next;
      _users = [];
      _page = 1;
      _total = 0;
    });
    _load(1);
  }

  Future<void> _remove(int target) async {
    if (!_current || _busy) return;
    setState(() => _removing = target);
    try {
      if (_kind == _Kind.blocks) {
        await _repository.unblockUser(target);
      } else {
        await _repository.unmuteUser(target);
      }
      if (_current) await _load(_page);
    } catch (error) {
      if (_current) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorView.describe(context, error))),
        );
      }
    } finally {
      if (_current) setState(() => _removing = null);
    }
  }

  String _duration(BuildContext context, String? value) {
    final l10n = AppLocalizations.of(context);
    final date = DateTime.tryParse(value ?? '')?.toLocal();
    if (date == null) return l10n.t('visibility.permanent');
    final material = MaterialLocalizations.of(context);
    final text =
        '${material.formatShortDate(date)} ${material.formatTimeOfDay(TimeOfDay.fromDateTime(date))}';
    return l10n.t('visibility.until').replaceFirst('{date}', text);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(authRepositoryProvider, (_, current) {
      if (!identical(_owner, current)) _expire();
    });
    ref.listen(usersRepositoryProvider, (_, current) {
      if (!identical(_repository, current)) _expire();
    });
    final l10n = AppLocalizations.of(context);
    final blocked = _kind == _Kind.blocks;
    final pages = _lastPage(_total);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('visibility.title'))),
      body: _expired
          ? EmptyView(message: l10n.t('visibility.sessionChanged'))
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppBreakpoints.contentMaxWidth,
                ),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SegmentedButton<_Kind>(
                        segments: [
                          ButtonSegment(
                            value: _Kind.blocks,
                            label: Text(l10n.t('visibility.blocks')),
                          ),
                          ButtonSegment(
                            value: _Kind.mutes,
                            label: Text(l10n.t('visibility.mutes')),
                          ),
                        ],
                        selected: {_kind},
                        onSelectionChanged: _busy
                            ? null
                            : (selection) => _select(selection.single),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_loading)
                      const LinearProgressIndicator()
                    else if (_error != null)
                      ErrorView(error: _error!, onRetry: () => _load(_page))
                    else if (_users.isEmpty)
                      EmptyView(
                        message: l10n.t(
                          blocked
                              ? 'visibility.emptyBlocks'
                              : 'visibility.emptyMutes',
                        ),
                      )
                    else
                      for (final user in _users)
                        ListTile(
                          key: ValueKey(user.userId),
                          leading: AppAvatar(url: user.avatarUrl, size: 36),
                          title: Text(
                            user.displayName.isEmpty
                                ? user.username
                                : user.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: blocked
                              ? null
                              : Text(_duration(context, user.muteExpiresAt)),
                          onTap: _busy
                              ? null
                              : () => context.push(
                                  '/user/${user.userId}/profile',
                                ),
                          trailing: TextButton(
                            onPressed: _busy
                                ? null
                                : () => _remove(user.userId),
                            child: Text(
                              l10n.t(
                                blocked
                                    ? 'visibility.unblock'
                                    : 'visibility.unmute',
                              ),
                            ),
                          ),
                        ),
                    if (pages > 1)
                      Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          OutlinedButton(
                            onPressed: _busy || _page <= 1
                                ? null
                                : () => _load(_page - 1),
                            child: Text(l10n.t('visibility.previous')),
                          ),
                          Text('$_page / $pages'),
                          OutlinedButton(
                            onPressed: _busy || _page >= pages
                                ? null
                                : () => _load(_page + 1),
                            child: Text(l10n.t('visibility.next')),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}
