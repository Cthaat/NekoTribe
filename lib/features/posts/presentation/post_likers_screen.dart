import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../users/domain/user_models.dart';

class PostLikersScreen extends ConsumerStatefulWidget {
  const PostLikersScreen({super.key, required this.postId});

  final int postId;

  @override
  ConsumerState<PostLikersScreen> createState() => _PostLikersScreenState();
}

class _PostLikersScreenState extends ConsumerState<PostLikersScreen> {
  CancelToken? _request;
  late final VoidCallback _unsubscribe;
  List<V2PublicUser> _users = [];
  int _page = 1;
  bool _hasNext = false, _failed = false, _expired = false;

  @override
  void initState() {
    super.initState();
    _unsubscribe = ref.read(tokenStoreProvider).listenSessionChanges(() {
      _request?.cancel();
      if (!mounted) return;
      setState(() {
        _request = null;
        _users = [];
        _expired = true;
      });
    });
    _load(1);
  }

  @override
  void dispose() {
    _unsubscribe();
    _request?.cancel();
    super.dispose();
  }

  Future<void> _load(int page) async {
    if (_expired || _request != null) return;
    final request = CancelToken();
    setState(() {
      _request = request;
      _page = page;
      _users = [];
      _hasNext = false;
      _failed = false;
    });
    try {
      final result = await ref
          .read(postsApiProvider)
          .postLikers(widget.postId, page: page, cancelToken: request);
      if (!mounted || _request != request) return;
      setState(() {
        _request = null;
        _users = result.items;
        _hasNext = result.hasNext;
      });
    } catch (_) {
      if (!mounted || _request != request) return;
      setState(() {
        _request = null;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    String label(String key) => l10n.t('post.likers.$key');
    return Scaffold(
      appBar: AppBar(title: Text(label('title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_request != null)
            const LinearProgressIndicator()
          else if (_expired)
            Text(label('expired'))
          else if (_failed)
            Text(label('failed'))
          else if (_users.isEmpty)
            Text(label('empty')),
          for (final user in _users)
            ListTile(
              title: Text(
                user.displayName.isEmpty ? user.username : user.displayName,
              ),
              subtitle: Text('@${user.username}'),
              onTap: () => context.push('/users/${user.userId}'),
            ),
          if (!_expired && _request == null)
            Wrap(
              spacing: 8,
              children: [
                if (_failed)
                  OutlinedButton(
                    onPressed: () => _load(_page),
                    child: Text(label('retry')),
                  ),
                if (_page > 1)
                  OutlinedButton(
                    onPressed: () => _load(_page - 1),
                    child: Text(label('previous')),
                  ),
                if (_hasNext)
                  OutlinedButton(
                    onPressed: () => _load(_page + 1),
                    child: Text(label('next')),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
