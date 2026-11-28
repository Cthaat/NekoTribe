import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/motion/skeleton.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/theme/tokens.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/status_views.dart';
import '../../../shared/widgets/ui/surface_card.dart';
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final social = SocialColors.of(context);
    if (_changing || (_loading && _users.isEmpty)) {
      return SkeletonCrossFade(loading: true, child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [for (var i = 0; i < 4; i++) const ListTileSkeleton()],
      ));
    }
    if (_error != null && _users.isEmpty) {
      return SkeletonCrossFade(loading: false, child: ErrorView(error: _error!, onRetry: _load));
    }
    if (_users.isEmpty) {
      return SkeletonCrossFade(loading: false, child: EmptyView(
        message: l10n.t(
          widget.query.isEmpty
              ? 'search.no_recommendations'
              : 'search.no_users',
        ),
      ));
    }
    return SkeletonCrossFade(loading: false, child: ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 108),
      children: [
        if (widget.query.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
            child: Text(
              l10n.t('search.recommended_users'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        for (var i = 0; i < _users.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          SurfaceCard(
            key: ValueKey(_users[i].userId),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            onTap: () {
              final user = _users[i];
              if (_canRead && _users.contains(user)) {
                context.push('/user/${user.userId}/profile');
              }
            },
            child: Row(
              children: [
                AppAvatar(
                  url: _users[i].avatarUrl,
                  size: 44,
                  name: _users[i].displayName.isEmpty
                      ? _users[i].username
                      : _users[i].displayName,
                  seed: _users[i].userId,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              _users[i].displayName.isEmpty
                                  ? _users[i].username
                                  : _users[i].displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (_users[i].verified) ...[
                            const SizedBox(width: 4),
                            Icon(
                              Icons.verified_rounded,
                              size: 15,
                              color: scheme.primary,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '@${_users[i].username}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      if (_users[i].bio.trim().isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          _users[i].bio.trim(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: social.surfaceSubtle,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
        if (_error != null)
          ErrorView(error: _error!, onRetry: () => _load(more: true))
        else if (_hasNext)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: FilledButton.tonal(
                style: FilledButton.styleFrom(shape: const StadiumBorder()),
                onPressed: _loading ? null : () => _load(more: true),
                child: Text(
                  l10n.t(_loading ? 'common.loading' : 'search.load_more_users'),
                ),
              ),
            ),
          ),
      ],
    ));
  }
}
