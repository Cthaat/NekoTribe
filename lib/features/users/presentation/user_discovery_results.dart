import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/status_views.dart';
import '../../auth/data/auth_repository.dart';
import '../domain/user_models.dart';

class UserDiscoveryResults extends ConsumerStatefulWidget {
  const UserDiscoveryResults({super.key, required this.query});

  final String query;

  @override
  ConsumerState<UserDiscoveryResults> createState() =>
      _UserDiscoveryResultsState();
}

class _UserDiscoveryResultsState extends ConsumerState<UserDiscoveryResults> {
  late AuthRepository _owner;
  late int _revision;
  late bool _changing;
  VoidCallback? _unsubscribe;
  int _request = 0;
  int _page = 1;
  bool _loading = false;
  bool _hasNext = false;
  Object? _error;
  List<V2PublicUser> _users = [];

  @override
  void initState() {
    super.initState();
    _observe(ref.read(authRepositoryProvider));
    _load();
  }

  @override
  void didUpdateWidget(covariant UserDiscoveryResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) _restart();
  }

  @override
  void dispose() {
    _unsubscribe?.call();
    super.dispose();
  }

  void _observe(AuthRepository owner) {
    _unsubscribe?.call();
    _owner = owner;
    _revision = owner.sessionRevision;
    _changing = owner.isSessionChanging;
    _unsubscribe = owner.listenSessionChanges(() {
      if (!mounted || !identical(_owner, owner)) return;
      if (_revision == owner.sessionRevision &&
          _changing == owner.isSessionChanging) {
        return;
      }
      _revision = owner.sessionRevision;
      _changing = owner.isSessionChanging;
      _restart();
    });
  }

  bool get _canRead =>
      mounted &&
      identical(_owner, ref.read(authRepositoryProvider)) &&
      !_owner.isSessionChanging &&
      _owner.sessionRevision == _revision &&
      ref.read(authSessionProvider).isAuthenticated;

  void _restart() {
    setState(() {
      _request++;
      _users = [];
      _page = 1;
      _error = null;
      _loading = false;
      _hasNext = false;
    });
    _load();
  }

  Future<void> _load({bool more = false}) async {
    if (!_canRead || _loading || (more && !_hasNext)) return;
    final repository = ref.read(usersRepositoryProvider);
    final request = ++_request;
    final query = widget.query;
    final page = more ? _page + 1 : 1;
    bool current() =>
        _canRead &&
        request == _request &&
        identical(repository, ref.read(usersRepositoryProvider));
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final result = query.isEmpty
          ? null
          : await repository.searchUsers(query, page: page);
      final users = result == null
          ? await repository.recommendations()
          : result.items;
      if (!current()) return;
      setState(() {
        final previous = more ? _users : <V2PublicUser>[];
        final indexed = {for (final user in previous) user.userId: user};
        for (final user in users) {
          indexed[user.userId] = user;
        }
        _users = indexed.values.toList();
        _page = page;
        _hasNext = result?.hasNext ?? false;
      });
    } catch (error) {
      if (current()) setState(() => _error = error);
    } finally {
      if (current()) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(authRepositoryProvider, (_, owner) {
      if (identical(_owner, owner)) return;
      _observe(owner);
      _restart();
    });
    ref.listen(usersRepositoryProvider, (_, _) => _restart());
    final l10n = AppLocalizations.of(context);
    if (_changing || (_loading && _users.isEmpty)) return const LoadingView();
    if (_error != null && _users.isEmpty) {
      return ErrorView(error: _error!, onRetry: _load);
    }
    if (_users.isEmpty) {
      return EmptyView(
        message: l10n.t(
          widget.query.isEmpty
              ? 'search.no_recommendations'
              : 'search.no_users',
        ),
      );
    }
    return ListView(
      children: [
        if (widget.query.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              l10n.t('search.recommended_users'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        for (final user in _users)
          ListTile(
            key: ValueKey(user.userId),
            leading: AppAvatar(url: user.avatarUrl, size: 36),
            title: Text(
              user.displayName.isEmpty ? user.username : user.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '@${user.username}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () {
              if (_canRead && _users.contains(user)) {
                context.push('/user/${user.userId}/profile');
              }
            },
          ),
        if (_error != null)
          ErrorView(error: _error!, onRetry: () => _load(more: true))
        else if (_hasNext)
          Center(
            child: OutlinedButton(
              onPressed: _loading ? null : () => _load(more: true),
              child: Text(
                l10n.t(_loading ? 'common.loading' : 'search.load_more_users'),
              ),
            ),
          ),
      ],
    );
  }
}
